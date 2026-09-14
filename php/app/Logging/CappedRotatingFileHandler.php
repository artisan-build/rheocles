<?php

namespace App\Logging;

use Monolog\Handler\RotatingFileHandler;
use Monolog\Level;
use Monolog\LogRecord;

/**
 * Monolog's file-per-day, with a ceiling on the day.
 *
 * Rotation bounds how long a log is kept, not how big one day can get: a
 * loop that logs on every pulse writes without limit until midnight. Once
 * the day's file passes `maxBytes` it takes one last line saying so and
 * nothing more until the next rotation. A desktop app's log is for the
 * morning after; it is never the disk's problem.
 */
final class CappedRotatingFileHandler extends RotatingFileHandler
{
    /** The file that hit the cap, so the cap lifts when the day rotates. */
    private ?string $capped = null;

    public function __construct(
        string $filename,
        int $maxFiles = 0,
        int|string|Level $level = Level::Debug,
        bool $bubble = true,
        private readonly int $maxBytes = 20 * 1024 * 1024,
    ) {
        parent::__construct($filename, $maxFiles, $level, $bubble);
    }

    protected function write(LogRecord $record): void
    {
        parent::write($record);

        if ($this->capped === $this->url || ! is_resource($this->stream)) {
            return;
        }
        // Append mode: after a write, the position is the file's size.
        if (ftell($this->stream) >= $this->maxBytes) {
            $this->capped = $this->url;
            $notice = $record->with(
                level: Level::Warning,
                message: sprintf('log capped at %d MB for today; nothing more until tomorrow', intdiv($this->maxBytes, 1024 * 1024)),
                context: [],
                extra: [],
            );
            parent::write($notice->with(formatted: $this->getFormatter()->format($notice)));
        }
    }

    public function isHandling(LogRecord $record): bool
    {
        // Capped for the day: nothing more is written, and nothing is
        // formatted for nothing. The cap is per file, so a day boundary
        // (a new url) lifts it — the parent rotates on the next write.
        if ($this->capped !== null && $this->capped === $this->url && $this->nextRotation > $record->datetime) {
            return false;
        }

        return parent::isHandling($record);
    }
}
