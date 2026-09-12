<?php

namespace App\Rheocles;

/**
 * The user's home directory. `$_SERVER['HOME']` is not guaranteed under
 * NativePHP's bundled PHP server the way it is on the CLI, and every path
 * this app abbreviates or reads (the token, the logs) hangs off it.
 */
final class Home
{
    public static function path(): string
    {
        $home = $_SERVER['HOME'] ?? getenv('HOME') ?: null;
        if (! $home && function_exists('posix_getpwuid')) {
            $home = posix_getpwuid(posix_geteuid())['dir'] ?? null;
        }

        return $home ?: '/Users/'.get_current_user();
    }

    /** `~/Movies/Rheocles` for a path under the home directory. */
    public static function abbreviate(string $path): string
    {
        $home = self::path();

        return str_starts_with($path, $home) ? '~'.substr($path, strlen($home)) : $path;
    }
}
