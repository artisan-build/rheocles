<?php

namespace App\Rheocles;

/**
 * What the menu bar icon says, from what the daemon says.
 *
 * The icon speaks for the daemon, not the app (the Swift app's
 * MenuBarIcon.State.derive, kept identical): recording is a take the daemon
 * reports as recording, armed is any stream it reports armed, and a daemon
 * that is launching or down shows idle — there is nothing live to show.
 *
 * Three states (spec §12): idle dims the whole mark to 40 %, armed is the
 * mark at full strength, recording adds a filled dot at the bar's foot. A
 * late-joined stream is a shorter stroke that starts to the right of the bar
 * (BRAND § Mark), so `lateJoined` is part of the state: indices 0–3, top to
 * bottom, of the take's streams that joined after the cue.
 */
final class IconState
{
    public const IDLE = 'idle';

    public const ARMED = 'armed';

    public const RECORDING = 'recording';

    /** @param  int[]  $lateJoined */
    private function __construct(public readonly string $kind, public readonly array $lateJoined = []) {}

    public static function idle(): self
    {
        return new self(self::IDLE);
    }

    public static function armed(): self
    {
        return new self(self::ARMED);
    }

    /** @param  int[]  $lateJoined */
    public static function recording(array $lateJoined = []): self
    {
        $lateJoined = array_values(array_unique(array_filter($lateJoined, fn ($i) => $i >= 0 && $i < 4)));
        sort($lateJoined);

        return new self(self::RECORDING, $lateJoined);
    }

    /**
     * @param  'launching'|'running'|'down'  $status  the daemon's condition
     * @param  array|null  $take  the active take's manifest, or null
     */
    public static function derive(string $status, ?array $take, int $armedCount): self
    {
        if ($status !== 'running') {
            return self::idle();
        }
        // Every recording stream is armed (join arms), so a `recording`
        // manifest with nothing armed is one a dead daemon left on disk and
        // the next daemon serves from there — not a take in progress.
        if ($take !== null && ($take['state'] ?? null) === 'recording' && $armedCount > 0) {
            return self::recording(self::lateJoined($take));
        }

        return $armedCount > 0 ? self::armed() : self::idle();
    }

    /**
     * Streams that joined after the cue, by position among the take's
     * streams: `started` more than a second after the take's `started`.
     * Only the first four strokes exist on the mark.
     *
     * @return int[]
     */
    public static function lateJoined(array $take): array
    {
        $cue = isset($take['started']) ? self::seconds($take['started']) : null;
        if ($cue === null) {
            return [];
        }
        $late = [];
        foreach (array_slice($take['streams'] ?? [], 0, 4) as $index => $stream) {
            $began = isset($stream['started']) ? self::seconds($stream['started']) : null;
            if ($began !== null && $began - $cue > 1) {
                $late[] = $index;
            }
        }

        return $late;
    }

    /** UTC ISO 8601 with milliseconds → seconds since the epoch. */
    private static function seconds(string $iso): ?float
    {
        $t = \DateTimeImmutable::createFromFormat('Y-m-d\TH:i:s.vp', $iso)
            ?: \DateTimeImmutable::createFromFormat('Y-m-d\TH:i:sp', $iso);

        return $t ? (float) $t->format('U.u') : null;
    }

    /**
     * The icon file for this state, without extension or `@2x`. Electron
     * treats a file whose name ends in `Template` as a template image — only
     * its alpha is used, tinted to match the bar — and finds `@2x` itself.
     * bin/make-icons renders one per state; a late-joined mask is four bits.
     */
    public function name(): string
    {
        return match ($this->kind) {
            self::IDLE => 'rheoIdleTemplate',
            self::ARMED => 'rheoArmedTemplate',
            self::RECORDING => 'rheoRecording'.$this->mask().'Template',
        };
    }

    /** `0101`: bit per stroke, top to bottom, 1 = joined late. */
    public function mask(): string
    {
        $bits = '';
        for ($i = 0; $i < 4; $i++) {
            $bits .= in_array($i, $this->lateJoined, true) ? '1' : '0';
        }

        return $bits;
    }

    public function path(): string
    {
        return resource_path('menubar/'.$this->name().'.png');
    }

    public function equals(self $other): bool
    {
        return $this->kind === $other->kind && $this->lateJoined === $other->lateJoined;
    }
}
