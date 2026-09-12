import { exec } from 'child_process';
import { join } from 'path';

const appUrl = process.env.APP_URL;
const appId = process.env.NATIVEPHP_APP_ID;
const appName = process.env.NATIVEPHP_APP_NAME;
const isBuilding = process.env.NATIVEPHP_BUILDING;
const appAuthor = process.env.NATIVEPHP_APP_AUTHOR;
const fileName = process.env.NATIVEPHP_APP_FILENAME;
const appVersion = process.env.NATIVEPHP_APP_VERSION;
const appCopyright = process.env.NATIVEPHP_APP_COPYRIGHT;
const deepLinkProtocol = process.env.NATIVEPHP_DEEPLINK_SCHEME;
const updaterEnabled = process.env.NATIVEPHP_UPDATER_ENABLED === 'true';
const deleteAppDataOnUninstall = process.env.NATIVEPHP_NSIS_DELETE_APP_DATA === 'true';

/*
 * On macOS, electron-builder NFD-normalises every name it writes to disk - the .app bundle,
 * the executable and each of the Electron helper apps - but it writes CFBundleName straight
 * from the product name, which reaches us composed (NFC). Electron locates its helper apps
 * by appending ' Helper (GPU).app' and friends to CFBundleName, so the two have to agree:
 * for a name like 'MUNĖ' they don't, and the app traps on launch before it can spawn a
 * single child process. Decomposing it ourselves puts CFBundleName in the same form as the
 * names on disk. NFD leaves ASCII names untouched, so this is a no-op for everyone else.
 *
 * https://github.com/NativePHP/desktop/issues/98
 */
const macBundleName = appName ? appName.normalize('NFD') : undefined;

// Azure signing configuration
const azureEndpoint = process.env.NATIVEPHP_AZURE_ENDPOINT;
const azureCertificateProfileName = process.env.NATIVEPHP_AZURE_CERTIFICATE_PROFILE_NAME;
const azureCodeSigningAccountName = process.env.NATIVEPHP_AZURE_CODE_SIGNING_ACCOUNT_NAME;

// Since we do not copy the php executable here, we only need these for building
const isWindows = process.argv.includes('--win');
const isLinux = process.argv.includes('--linux');
const isDarwin = process.argv.includes('--mac');

let targetOs;

if (isWindows) {
    targetOs = 'win';
}

if (isLinux) {
    targetOs = 'linux';
}

if (isDarwin) {
    targetOs = 'mac';
}

let updaterConfig = {};

try {
    updaterConfig = process.env.NATIVEPHP_UPDATER_CONFIG;
    updaterConfig = JSON.parse(updaterConfig);
} catch {
    updaterConfig = {};
}

if (isBuilding) {
    console.log('  • updater config', updaterConfig);
}

export default {
    appId: appId,
    productName: appName,
    copyright: appCopyright,
    directories: {
        buildResources: 'build',
        output: isBuilding ? join(process.env.APP_PATH, 'nativephp', 'electron', 'dist') : undefined,
    },
    files: [
        '!**/.vscode/*',
        '!src/*',
        '!dist/*',
        '!electron.vite.config.{js,ts,mjs,cjs}',
        '!{.eslintignore,.eslintrc.cjs,.prettierignore,.prettierrc.yaml,dev-app-update.yml,CHANGELOG.md,README.md}',
        '!{.env,.env.*,.npmrc,pnpm-lock.yaml}',
    ],
    beforePack: async (context) => {
        let arch = {
            1: 'x64',
            3: 'arm64',
        }[context.arch];

        if (arch === undefined) {
            console.error('Cannot build PHP for unsupported architecture');
            process.exit(1);
        }

        console.log(`  • building php binary - exec php.js --${targetOs} --${arch}`);
        exec(`node php.js --${targetOs} --${arch}`);
    },
    afterSign: 'build/notarize.js',
    win: {
        executableName: fileName,
        ...(azureEndpoint && azureCertificateProfileName && azureCodeSigningAccountName
            ? {
                  azureSignOptions: {
                      endpoint: azureEndpoint,
                      certificateProfileName: azureCertificateProfileName,
                      codeSigningAccountName: azureCodeSigningAccountName,
                  },
              }
            : {}),
    },
    nsis: {
        artifactName: appName + '-${version}-setup.${ext}',
        shortcutName: '${productName}',
        uninstallDisplayName: '${productName}',
        createDesktopShortcut: 'always',
        deleteAppDataOnUninstall: deleteAppDataOnUninstall,
    },
    protocols: {
        name: deepLinkProtocol,
        schemes: [deepLinkProtocol],
    },
    mac: {
        entitlementsInherit: 'build/entitlements.mac.plist',
        artifactName: appName + '-${version}-${arch}.${ext}',
        extendInfo: {
            ...(macBundleName ? { CFBundleName: macBundleName, CFBundleDisplayName: macBundleName } : {}),
            // The three grants Rheocles asks for, and only those. The scaffold
            // also declares Documents and Downloads; a purpose string for
            // access this app never makes is untrue and, on the first prompt
            // a user ever sees, alarming. Each string is paired with an
            // entitlement in build/entitlements.mac.plist (system audio needs
            // none); the nested rheocles-core inherits this bundle's TCC
            // identity, so these are the strings macOS shows for it.
            NSCameraUsageDescription:
                'Rheocles records your cameras to their own files when you arm them and cue a take. Nothing leaves this Mac.',
            NSMicrophoneUsageDescription:
                'Rheocles records your microphones to Broadcast Wave files when you arm them and cue a take. Nothing leaves this Mac.',
            NSAudioCaptureUsageDescription:
                'Rheocles records system audio to its own file when you arm it and cue a take. Nothing leaves this Mac.',

            // Menu bar only: no Dock icon, no window until the icon is
            // clicked — the Swift app's LSUIElement, and the same claim.
            // MenuBar::create() hides the Dock icon at runtime anyway, but
            // declaring it here means it is never shown and then withdrawn.
            LSUIElement: true,
        },
    },
    dmg: {
        artifactName: appName + '-${version}-${arch}.${ext}',
    },
    linux: {
        target: ['AppImage', 'deb'],
        maintainer: appUrl,
        category: 'Utility',
    },
    appImage: {
        artifactName: appName + '-${version}.${ext}',
    },
    npmRebuild: false,
    extraMetadata: {
        name: fileName,
        homepage: appUrl,
        version: appVersion,
        author: appAuthor,
    },
    extraResources: [
        {
            from: process.env.NATIVEPHP_BUILD_PATH,
            to: 'build',
            filter: ['**/*', '!{.git}'],
        },
    ],
    extraFiles: [
        {
            from: join(process.env.APP_PATH, 'extras'),
            to: 'extras',
            filter: ['**/*'],
        },
    ],
    ...(updaterEnabled ? { publish: updaterConfig } : {}),
};
