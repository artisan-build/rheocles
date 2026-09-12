<?php

namespace App\Rheocles;

use Native\Desktop\Facades\Settings;

/**
 * The app's own settings (spec §12) — the ones that are not the daemon's.
 *
 * `showWindows` is purely the app's: the window list is long and volatile,
 * so it is hidden unless asked for (spec §5). `codec` is a request field on
 * every take, so it is a preference here that travels with POST /record
 * (task 3). The output root and the token are the daemon's and live behind
 * its API, not here.
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
            'codec' => in_array($c = Settings::get('codec', 'hevc'), ['hevc', 'prores'], true) ? $c : 'hevc',
        ];
    }

    /** Set the keys given; anything else in the request is ignored. */
    public static function update(array $values): array
    {
        if (array_key_exists('showWindows', $values)) {
            Settings::set('showWindows', (bool) $values['showWindows']);
        }
        if (isset($values['codec']) && in_array($values['codec'], ['hevc', 'prores'], true)) {
            Settings::set('codec', $values['codec']);
        }

        return self::all();
    }
}
