<?php

namespace App\Console\Commands;

use App\Rheocles\Daemon;
use App\Rheocles\EventStream;
use App\Rheocles\Failure\Failure;
use App\Rheocles\IconState;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\Log;
use Native\Desktop\Facades\MenuBar;

/**
 * The one long-lived process behind the menu bar icon.
 *
 * PHP has no app object that outlives a request, and the popover's page
 * only exists while the popover is open — but the icon has to tell the
 * truth about the daemon all day (spec §12). So NativeAppServiceProvider
 * starts this command as a ChildProcess at launch and it does three things
 * for as long as the app runs:
 *
 *   1. owns the daemon's lifecycle (App\Rheocles\Daemon): probe, adopt or
 *      launch, notice death, relaunch under the crash guard;
 *   2. reads GET /events — its own connection, reconnected after a second
 *      when it drops — and derives the icon state from `stream` and `take`
 *      events, exactly as the Swift app's MenuBarIcon.State.derive does;
 *   3. publishes the daemon's state to a file the popover's routes read.
 *
 * It never touches a frame and never serves the popover: the web view holds
 * its own EventSource (brief, rule 2). Two SSE clients on one loopback
 * daemon cost nothing.
 */
class Watch extends Command
{
    protected $signature = 'rheo:watch';

    protected $description = 'Own the rheocles-core lifecycle and keep the menu bar icon true';

    /** @var array<string, bool> armed, by stream id */
    private array $armed = [];

    private ?array $take = null;

    private ?IconState $shown = null;

    public function handle(): int
    {
        $daemon = Daemon::fromConfig();
        Log::info('rheo:watch started, pid '.getmypid());

        $daemon->establish();
        $daemon->publish();

        while (true) {
            if ($daemon->status === Daemon::RUNNING) {
                $this->follow($daemon);
            } else {
                // Down, or launching and not yet answering. Show idle, wait
                // a pulse, and try again — a bare probe only, so a core the
                // Swift app starts meanwhile is adopted, and the crash guard
                // is not defeated by relaunching every three seconds. The
                // Relaunch button lifts the guard through a flag file.
                $this->show(IconState::idle());
                $daemon->publish();
                usleep((int) config('rheocles.pulse', 3) * 1_000_000);
                if ($this->relaunchRequested()) {
                    $daemon->relaunch();
                } else {
                    $daemon->check();
                }
                $daemon->publish();
            }
        }
    }

    /** Running: read everything once, then follow events until they stop. */
    private function follow(Daemon $daemon): void
    {
        $this->refresh($daemon);
        $this->show($this->derive($daemon));
        $daemon->publish();

        try {
            $events = EventStream::read(
                $daemon->client->host, $daemon->client->port, (string) $daemon->client->token,
                (float) config('rheocles.pulse', 3),
            );
            foreach ($events as $event) {
                if ($event === null) {
                    // Nothing said for a pulse: is it still there?
                    if (! $daemon->check()) {
                        break;
                    }
                    if ($this->relaunchRequested()) {
                        $daemon->relaunch();
                    }
                    $daemon->publish();

                    continue;
                }
                $this->handle_($event, $daemon);
                $this->show($this->derive($daemon));
            }
            Log::info('event stream closed');
        } catch (Failure $e) {
            Log::info("event stream: {$e->getMessage()}");
        }

        // The stream dropped. A second's grace, then the pulse decides
        // whether that was a hiccup or a death.
        usleep(1_000_000);
        $daemon->check();
        $daemon->publish();
    }

    /** `GET /streams` and the active take, so the first icon is right. */
    private function refresh(Daemon $daemon): void
    {
        try {
            $this->armed = [];
            foreach ($daemon->client->streams()['streams'] ?? [] as $stream) {
                $this->armed[$stream['id']] = (bool) ($stream['armed'] ?? false);
            }
        } catch (Failure $e) {
            Log::info("GET /streams: {$e->getMessage()}");
        }
        try {
            $this->take = null;
            foreach ($daemon->client->takes() as $summary) {
                if (($summary['state'] ?? null) === 'recording') {
                    $this->take = $daemon->client->take($summary['id']);
                    break;
                }
            }
        } catch (Failure $e) {
            Log::info("GET /takes: {$e->getMessage()}");
        }
    }

    private function handle_(array $event, Daemon $daemon): void
    {
        switch ($event['event']) {
            case 'stream':
                if (isset($event['stream']['id'])) {
                    $this->armed[$event['stream']['id']] = (bool) ($event['stream']['armed'] ?? false);
                }
                break;
            case 'take':
                if (isset($event['take']['state'])) {
                    $this->take = $event['take'];
                }
                break;
            case 'join':
            case 'leave':
            case 'marker':
            case 'error':
                // Planned (PROTOCOL § Events); any of them means the take
                // changed, so re-read it.
                if (isset($this->take['id'])) {
                    try {
                        $this->take = $daemon->client->take($this->take['id']);
                    } catch (Failure) {
                    }
                }
                break;
            default:
                // `levels`, `drift`: the popover's business, not the icon's.
                break;
        }
    }

    private function derive(Daemon $daemon): IconState
    {
        return IconState::derive($daemon->status, $this->take, count(array_filter($this->armed)));
    }

    /** Set the icon, only when it changes: one POST to the runtime per change. */
    private function show(IconState $state): void
    {
        if ($this->shown !== null && $this->shown->equals($state)) {
            return;
        }
        $this->shown = $state;
        try {
            MenuBar::icon($state->path());
        } catch (\Throwable $e) {
            Log::info("menu bar icon: {$e->getMessage()}");
        }
    }

    public static function relaunchFlag(): string
    {
        return storage_path('app/daemon.relaunch');
    }

    private function relaunchRequested(): bool
    {
        $flag = self::relaunchFlag();
        if (! file_exists($flag)) {
            return false;
        }
        @unlink($flag);

        return true;
    }
}
