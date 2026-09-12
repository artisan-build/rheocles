<?php

namespace App\Rheocles;

/**
 * The bearer token, as the daemon provisions it (spec §11).
 *
 * `rheocles-core` writes it to `~/Library/Application Support/Rheocles/token`
 * (mode 0600) on first launch; any app running as the same user reads the
 * file and is paired with zero clicks. This app never writes it — rotating
 * is the daemon's job, and until the route exists the file is read-only
 * from here.
 */
final class Token
{
    public static function path(): string
    {
        return config('rheocles.token_file')
            ?: Home::path().'/Library/Application Support/Rheocles/token';
    }

    /** The token, or null when the file is missing or empty. */
    public static function read(): ?string
    {
        $path = static::path();
        if (! is_readable($path)) {
            return null;
        }
        $token = trim((string) file_get_contents($path));

        return $token === '' ? null : $token;
    }

    /** `3f9a1c…a2b3c4`: enough to compare, not enough to use. */
    public static function masked(?string $token): ?string
    {
        if ($token === null || strlen($token) <= 12) {
            return $token;
        }

        return substr($token, 0, 6).'…'.substr($token, -6);
    }
}
