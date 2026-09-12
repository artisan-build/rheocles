<?php

namespace App\Rheocles;

use Native\Desktop\Facades\Settings;

/**
 * The app's own settings (spec §12) — the ones that are not the daemon's.
 *
 * `showWindows` is purely the app's: the window list is long and volatile,
 * so it is hidden unless asked for (spec §5). The output root, the default
 * codec and the token are the daemon's (`GET/PATCH /settings`,
 * `POST /token/rotate`) and live behind its API, not here — one setting for
 * both front ends, so a codec chosen in the Swift app is the codec here.
 *
 * Stored through NativePHP's Settings facade — `config.json` in the app's
 * data directory — so a preference survives a relaunch and moves with the
 * app when it is lifted into Pteroprompter.
 */
final class Preferences
{
    public static function all(): array
    {
        return [
            'showWindows' => (bool) Settings::get('showWindows', false),
        ];
    }

    /** Set the keys given; anything else in the request is ignored. */
    public static function update(array $values): array
    {
        if (array_key_exists('showWindows', $values)) {
            Settings::set('showWindows', (bool) $values['showWindows']);
        }

        return self::all();
    }
}
