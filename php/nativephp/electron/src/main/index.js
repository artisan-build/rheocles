// First, before the plugin reads app.getPath('userData'): see userData.js.
import './userData.js';
import NativePHP from '#plugin';
import { app, BrowserWindow } from 'electron';
import path from 'path';
import { createSplash } from './splash.js';
// Inherit User's PATH in Process & ChildProcess
import fixPath from 'fix-path';
import fs from 'fs';
import os from 'os';
fixPath();

/*
 * Errors go to a file, never a modal (brief, rule 10). Electron's default
 * for an uncaught exception in the main process is a "A JavaScript error
 * occurred in the main process" dialog per error — and a menu bar app that
 * loses its PHP server or a utility process for a moment can raise several
 * in a row, each one blocking the desktop until someone clicks it. Every
 * one of them is logged, with its stack, next to the daemon's log.
 *
 * The file is one day's, kept three days, and a day stops at 20 MB. It
 * reached 2 GB once (13 Sep 2026): an app whose `native:run` terminal had
 * gone away got EPIPE on every console.log — the PHP server's request line
 * for each 3 s pulse, the scheduler's line each minute — and each EPIPE
 * was an uncaught exception written here with its stack, for days. Now a
 * dead stdout is noted once and console output simply ends, and a message
 * that repeats is counted, not rewritten.
 */
const logDir = path.join(os.homedir(), 'Library', 'Logs', 'Rheocles');
const errorLog = path.join(logDir, 'Rheocles-php.log');
const LOG_KEEP_DAYS = 3;
const LOG_DAY_BYTES = 20 * 1024 * 1024;

// The local calendar day, as Laravel names its files.
const dayOf = (date) => new Date(date.getTime() - date.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
const log = { day: null, bytes: 0, capped: false, last: null, repeats: 0 };

/** Move yesterday's file aside and drop the ones older than three days. */
function rotateLog(today) {
    try {
        fs.mkdirSync(logDir, { recursive: true });
        const stat = fs.statSync(errorLog);
        const written = dayOf(stat.mtime);
        if (written !== today) {
            fs.renameSync(errorLog, path.join(logDir, `Rheocles-php-${written}.log`));
            log.bytes = 0;
        } else {
            log.bytes = stat.size;
        }
    } catch {
        log.bytes = 0; // no file yet
    }
    log.day = today;
    log.capped = log.bytes >= LOG_DAY_BYTES;
    const keepFrom = dayOf(new Date(Date.now() - LOG_KEEP_DAYS * 86400e3));
    try {
        for (const name of fs.readdirSync(logDir)) {
            const match = /^Rheocles-php-(\d{4}-\d{2}-\d{2})\.log$/.exec(name);
            if (match && match[1] < keepFrom) fs.rmSync(path.join(logDir, name), { force: true });
        }
    } catch {
        // Nothing to prune, or nowhere to look.
    }
}

function appendLog(line) {
    const today = dayOf(new Date());
    if (log.day !== today) rotateLog(today);
    if (log.capped) return;
    if (log.bytes + line.length > LOG_DAY_BYTES) {
        log.capped = true;
        line = `${new Date().toISOString()} log capped at ${LOG_DAY_BYTES / 1048576} MB for today; nothing more until tomorrow\n`;
    }
    try {
        fs.appendFileSync(errorLog, line);
        log.bytes += line.length;
    } catch {
        // Nowhere to write.
    }
}

/** The same message again is a count, written when something else comes. */
function logLine(text) {
    if (text === log.last) {
        log.repeats += 1;
        return;
    }
    if (log.repeats > 0) {
        appendLog(`${new Date().toISOString()} (the previous message repeated ${log.repeats} more times)\n`);
    }
    log.last = text;
    log.repeats = 0;
    appendLog(`${new Date().toISOString()} ${text}\n`);
}

const dead = new Set();
function logError(kind, error) {
    logLine(`${kind}: ${error && error.stack ? error.stack : String(error)}`);
    if (!dead.has(process.stderr)) {
        try {
            process.stderr.write(
                `${new Date().toISOString()} ${kind}: ${error && error.stack ? error.stack : String(error)}\n`,
            );
        } catch {
            /* noted below */
        }
    }
}
// stdout and stderr are whatever launched the app — `native:run`'s terminal
// in development, nothing in the bundle. When that end closes (the terminal
// went away under a running app), every later console.log fails with EPIPE
// and, with no 'error' listener, each failure is an uncaught exception.
// Listen, say so once, and let console output end there.
for (const [name, stream] of [
    ['stdout', process.stdout],
    ['stderr', process.stderr],
]) {
    stream.on('error', (error) => {
        if (dead.has(stream)) return;
        dead.add(stream);
        logLine(`${name} closed (${error && error.code ? error.code : error}); console output ends here`);
    });
}
process.on('uncaughtException', (error) => logError('uncaughtException', error));
process.on('unhandledRejection', (reason) => logError('unhandledRejection', reason));

const buildPath = path.resolve(import.meta.dirname, import.meta.env.MAIN_VITE_NATIVEPHP_BUILD_PATH);
const defaultIcon = path.join(buildPath, 'icon.png');
const certificate = path.join(buildPath, 'cacert.pem');

const executable = process.platform === 'win32' ? 'php.exe' : 'php';
const phpBinary = path.join(buildPath, 'php', executable);
const appPath = path.join(buildPath, 'app');

let splashWindow;

app.whenReady().then(() => {
    try {
        splashWindow = createSplash(appPath, import.meta.dirname);
    } catch (error) {
        console.error('Error creating splash screen:', error);
    }

    NativePHP.bootstrap(app, defaultIcon, phpBinary, certificate, appPath);
});

app.on('browser-window-created', (event, window) => {
    if (splashWindow && window !== splashWindow) {
        window.webContents.on('did-navigate', (evt, url) => {
            if (url.startsWith('http://127.0.0.1') || url.startsWith('http://localhost')) {
                if (splashWindow) {
                    splashWindow.close();
                    splashWindow = null;
                }
            }
        });
    }
});
