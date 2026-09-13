#!/usr/bin/env node
// Render a social-card source to PNG with the Playwright-cached Chromium.
//
//     node art/og.mjs og.html public/og/index.png              # 1200×630
//     node art/og.mjs og-strip.html src/assets/og-strip.png --size 320x44 --transparent
//
// The page is laid out at the given CSS size, rasterised at 2× so the type
// is supersampled, and written at the given size — the dimensions the
// og:image:width/height tags state. `--transparent` keeps the page's alpha
// (for the strip and the pill that astro-og-canvas composes onto the
// generated cards). `--keep-scale` writes the 2× pixels as they are.
//
// Never the installed Chrome: it opens the real profile and asks the
// keychain for Safe Storage. Playwright's own Chromium, a throwaway profile,
// a mock keychain, and the process killed when the file is written.
import { chromium } from 'playwright-core';
import { execSync } from 'node:child_process';
import { globSync, mkdtempSync, rmSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import sharp from 'sharp';

const args = process.argv.slice(2);
const flag = (name) => {
	const i = args.indexOf(name);
	if (i === -1) return undefined;
	const [, value] = args.splice(i, 2);
	return value;
};
const has = (name) => {
	const i = args.indexOf(name);
	if (i === -1) return false;
	args.splice(i, 1);
	return true;
};
const size = flag('--size') ?? '1200x630';
const transparent = has('--transparent');
const keepScale = has('--keep-scale');
const [source, out] = args;
if (!source || !out) {
	console.error('usage: node art/og.mjs <source.html> <out.png> [--size WxH] [--transparent] [--keep-scale]');
	process.exit(2);
}
const [width, height] = size.split('x').map(Number);

const executablePath =
	process.env.OG_CHROMIUM ??
	globSync(join(homedir(), 'Library/Caches/ms-playwright/chromium-*/chrome-mac-arm64/*.app/Contents/MacOS/*'))
		.sort()
		.at(-1);
if (!executablePath) {
	console.error('no Playwright Chromium under ~/Library/Caches/ms-playwright — `npx playwright install chromium`, or set OG_CHROMIUM');
	process.exit(1);
}

const profile = mkdtempSync(join(tmpdir(), 'og-chromium-'));
const context = await chromium.launchPersistentContext(profile, {
	executablePath,
	headless: true,
	args: ['--headless=new', '--use-mock-keychain', '--no-first-run', '--no-default-browser-check', '--disable-sync'],
	viewport: { width, height },
	deviceScaleFactor: 2,
});
// The browser process is the one naming this profile that is not a helper.
const pids = execSync(`pgrep -f -- '--user-data-dir=${profile}'`)
	.toString()
	.trim()
	.split('\n')
	.map(Number)
	.filter((p) => !execSync(`ps -o command= -p ${p}`).toString().includes('--type='));
try {
	const page = context.pages()[0] ?? (await context.newPage());
	await page.goto(pathToFileURL(resolve(source)).href, { waitUntil: 'networkidle' });
	await page.evaluate(() => document.fonts.ready);
	const raw = await page.screenshot({ omitBackground: transparent, clip: { x: 0, y: 0, width, height } });
	const image = sharp(raw);
	if (!keepScale) image.resize(width, height, { kernel: 'lanczos3' });
	await image.png().toFile(out);
	console.log(`${out} ${keepScale ? `${width * 2}×${height * 2}` : `${width}×${height}`}`);
} finally {
	await context.close();
	for (const pid of pids) {
		try {
			process.kill(pid, 'SIGKILL');
		} catch {}
	}
	rmSync(profile, { recursive: true, force: true });
}
