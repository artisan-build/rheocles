// The current tagged version, read at build time so nobody hard-codes it.
// GitHub's latest release is the source of truth; when that fetch fails
// (offline, rate-limited) the nearest tag in the local clone stands in; and
// when both fail the version is '' and the page leaves the line out — a
// placeholder would be a lie. Nothing is cached: the build is the cache, and
// release.yml re-runs the deploy after every tag so it cannot go stale.
import { execSync } from 'node:child_process';

const repo = 'artisan-build/rheocles';

function clean(tag: string): string {
	const m = tag.trim().match(/^v?(\d+\.\d+\.\d+\S*)$/);
	return m ? m[1] : '';
}

async function fromGitHub(): Promise<string> {
	// GITHUB_API_URL is what Actions sets; pointing it somewhere dead is the
	// test switch for the fallback.
	const base = process.env.GITHUB_API_URL || 'https://api.github.com';
	const res = await fetch(`${base}/repos/${repo}/releases/latest`, {
		headers: { Accept: 'application/vnd.github+json', 'User-Agent': 'rheocles.com build' },
		signal: AbortSignal.timeout(10_000),
	});
	if (!res.ok) throw new Error(`${res.status} from ${base}`);
	const body = (await res.json()) as { tag_name?: string };
	return clean(body.tag_name ?? '');
}

function fromGit(): string {
	try {
		return clean(
			execSync('git describe --tags --abbrev=0', { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }),
		);
	} catch {
		return '';
	}
}

async function resolve(): Promise<string> {
	try {
		const v = await fromGitHub();
		if (v) return v;
	} catch (e) {
		console.warn(`[version] release fetch failed (${(e as Error).message}); trying git`);
	}
	const v = fromGit();
	if (!v) console.warn('[version] no version from GitHub or git; the version line is omitted');
	return v;
}

/** `0.1.1`, or `''` when unknown. */
export const version: string = await resolve();

/** The release page for that tag, or `''`. */
export const releaseUrl: string = version ? `https://github.com/${repo}/releases/tag/v${version}` : '';
