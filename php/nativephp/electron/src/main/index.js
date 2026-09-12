import NativePHP from '#plugin';
import { app, BrowserWindow } from 'electron';
import path from 'path';

/*
 * Electron's user data defaults to ~/Library/Application Support/<product
 * name> — and the product name is Rheocles, which is the daemon's own
 * directory (spec §11: the token file, settings.json). Chromium caches and
 * cookies do not belong beside the token, and the Swift app keeps nothing
 * there either. Keyed by bundle id instead, before anything reads the path.
 */
app.setPath('userData', path.join(app.getPath('appData'), 'build.artisan.rheocles.php'));
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
 */
const errorLog = path.join(os.homedir(), 'Library', 'Logs', 'Rheocles', 'Rheocles-php.log');
function logError(kind, error) {
    const line = `${new Date().toISOString()} ${kind}: ${error && error.stack ? error.stack : String(error)}\n`;
    try {
        fs.mkdirSync(path.dirname(errorLog), { recursive: true });
        fs.appendFileSync(errorLog, line);
    } catch {
        // Nowhere to write.
    }
    // EPIPE is stdout going away — the terminal that launched `native:run`
    // closed under a running app. Writing about it to that same stdout is
    // the error again, so it is logged and nothing more.
    if (!(error && error.code === 'EPIPE')) {
        try { process.stderr.write(line); } catch { /* the same pipe */ }
    }
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
