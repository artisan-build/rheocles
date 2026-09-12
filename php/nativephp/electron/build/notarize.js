import { notarize } from '@electron/notarize';

/*
 * The scaffolded version of this hook wraps notarize() in a try/catch that
 * logs the error and then prints `done notarizing` regardless — so a build
 * with missing or wrong credentials ends on a success line with a stack
 * trace scrolled off above it. Sonocles shipped an ad-hoc signed DMG that
 * way (sonocles/php/FEASIBILITY.md). Here a failure fails: the error is
 * rethrown, electron-builder aborts, and the only build that says "done" is
 * one Apple accepted.
 */
export default async (context) => {
    // Only notarize when process is running on a Mac
    if (process.platform !== 'darwin') return;

    // And the current build target is macOS
    if (context.packager.platform.name !== 'mac') return;

    console.log('aftersign hook triggered, start to notarize app.');

    // Set, not merely present: the runtime passes these through as empty
    // strings when .env does not define them, and the scaffold's `in`
    // check then hands empty credentials to notarytool. Empty means "do
    // not notarize"; set means "notarize, and fail if that fails".
    if (
        !(
            process.env.NATIVEPHP_APPLE_ID &&
            process.env.NATIVEPHP_APPLE_ID_PASS &&
            process.env.NATIVEPHP_APPLE_TEAM_ID
        )
    ) {
        console.warn(
            'skipping notarizing, NATIVEPHP_APPLE_ID, NATIVEPHP_APPLE_ID_PASS and NATIVEPHP_APPLE_TEAM_ID env variables must be set.',
        );
        return;
    }

    const appId = process.env.NATIVEPHP_APP_ID;

    const { appOutDir } = context;

    const appName = context.packager.appInfo.productFilename;

    try {
        await notarize({
            appBundleId: appId,
            appPath: `${appOutDir}/${appName}.app`,
            appleId: process.env.NATIVEPHP_APPLE_ID,
            appleIdPassword: process.env.NATIVEPHP_APPLE_ID_PASS,
            teamId: process.env.NATIVEPHP_APPLE_TEAM_ID,
            tool: 'notarytool',
        });
    } catch (error) {
        console.error(`notarizing ${appId} failed:`, error);
        throw error;
    }

    console.log(`done notarizing ${appId}.`);
};
