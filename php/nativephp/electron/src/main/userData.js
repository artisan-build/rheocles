/*
 * Imported before '#plugin', on purpose: the plugin computes its storage,
 * database and bootstrap paths from app.getPath('userData') the moment it is
 * imported, so the path has to be set before that import evaluates.
 *
 * Electron's user data defaults to ~/Library/Application Support/<product
 * name> — and the product name is Rheocles, which is the daemon's own
 * directory (spec §11: the token file, settings.json). Chromium caches and
 * Laravel's storage do not belong beside the token, and the Swift app keeps
 * nothing there either. Keyed by bundle id instead.
 */
import { app } from 'electron';
import path from 'path';

app.setPath('userData', path.join(app.getPath('appData'), 'build.artisan.rheocles.php'));
