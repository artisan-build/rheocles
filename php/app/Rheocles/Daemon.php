<?php

namespace App\Rheocles;

use App\Rheocles\Failure\Failure;
use App\Rheocles\Failure\Unauthorized;
use App\Rheocles\Failure\Unreachable;
use Illuminate\Support\Facades\Log;
use Native\Desktop\Facades\ChildProcess;

/**
 * The daemon, as the app sees it — its lifecycle and nothing else (spec §3).
 *
 * Probe the port; use what answers; launch the bundled core if nothing does;
 * notice when it dies. The Swift app's DaemonModel, in PHP: the same probe,
 * the same ten-second launch window, the same three-in-a-minute crash guard.
 * Two front ends on one machine share one core, so a core launched by the
 * Swift app, or by hand, is used and left alone.
 *
 * Never kills a daemon it did not start. The only process this class ever
 * stops is the ChildProcess it spawned under its own alias; Electron ends
 * that one with the app anyway, and nothing else on the port is ours to end.
 *
 * This is a model, not a service: `rheo:watch` owns the one long-lived
 * instance and writes its state to a file for the popover's routes to read.
 * The hooks (`launcher`, `alive`, `sleep`, `now`) exist so tests can drive
 * it against a stub server without Electron.
 */
final class Daemon
{
    public const ALIAS = 'rheocles-core';

    public const LAUNCHING = 'launching';

    public const RUNNING = 'running';

    public const DOWN = 'down';

    public string $status = self::LAUNCHING;

    /** Why the daemon is down, when it is. */
    public ?string $why = null;

    /**
     * The last `GET /` answer. Kept through a brief outage so the popover
     * does not blank between two polls; cleared when the daemon is declared
     * down.
     */
    public ?array $discovery = null;

    /** Whether the running core is our child. */
    public bool $ours = false;

    /** Launch times within the crash window, for the guard. */
    private array $launches = [];

    private bool $stopping = false;

    public function __construct(
        public readonly Client $client,
        private readonly ?\Closure $launcher = null,
        private readonly ?\Closure $alive = null,
        private readonly ?\Closure $sleep = null,
        private readonly ?\Closure $now = null,
    ) {}

    public static function fromConfig(): self
    {
        return new self(Client::fromConfig());
    }

    // MARK: - discovery

    /** Probe once; if nothing answers, launch and wait. */
    public function establish(): void
    {
        $this->readToken();
        try {
            $this->discovery = $this->client->discovery();
            $this->status = self::RUNNING;
            $this->why = null;
            // Something answers. It is ours only if the child we launched
            // is still the one running; a core that took the port after
            // ours died belongs to whoever started it.
            $this->ours = $this->ours && $this->alive();
            if (! $this->ours) {
                Log::info("using a running rheocles-core on :{$this->client->port}");
            }

            return;
        } catch (Unreachable) {
            // Nothing there. Ours to launch.
        } catch (Unauthorized) {
            // A daemon is there and our token is not its token. Another
            // client may have rotated it: the file is the truth, so read it
            // again and ask once more before saying anything is wrong.
            $this->readToken();
            try {
                $this->discovery = $this->client->discovery();
                $this->status = self::RUNNING;
                $this->why = null;

                return;
            } catch (Failure) {
                $this->fail("daemon on :{$this->client->port} answered but refused the token in ".Token::path());

                return;
            }
        } catch (Failure $e) {
            // Answering, but not usefully — a foreign process on the port.
            // Launching another daemon behind it would not help.
            $this->fail("daemon on :{$this->client->port} answered but {$e->getMessage()}");

            return;
        }

        if (! $this->launch()) {
            return;
        }

        // Wait for the port. A core that exits before answering is launched
        // again, under the same crash-loop guard as one that dies later.
        $timeout = (int) config('rheocles.launch_timeout', 10);
        $deadline = $this->now() + $timeout;
        while ($this->now() < $deadline) {
            $this->sleep(0.1);
            if (! $this->alive()) {
                Log::info('rheocles-core exited before answering');
                if (! $this->launch()) {
                    return;
                }
                $deadline = $this->now() + $timeout;

                continue;
            }
            $this->readToken();
            try {
                $this->discovery = $this->client->discovery();
                $this->status = self::RUNNING;
                $this->why = null;
                Log::info("rheocles-core {$this->discovery['version']} answering on :{$this->client->port}");

                return;
            } catch (Failure) {
                // Not yet.
            }
        }
        $this->fail("rheocles-core did not answer on :{$this->client->port} within {$timeout}s");
    }

    /**
     * The pulse: is it still there? Re-establishes when it is not. Returns
     * whether the daemon is running afterwards.
     */
    public function check(): bool
    {
        try {
            $this->discovery = $this->client->discovery();
            if ($this->status !== self::RUNNING) {
                $this->status = self::RUNNING;
                $this->why = null;
            }
        } catch (Unauthorized) {
            // The token rotated underneath us — another client may rotate it
            // at any time. The file is the truth: read it again and ask once
            // more now, rather than waiting a pulse or calling this "down".
            $this->readToken();
            try {
                $this->discovery = $this->client->discovery();
                $this->status = self::RUNNING;
                $this->why = null;
            } catch (Failure $e) {
                Log::info("token refused after re-reading ".Token::path().": {$e->getMessage()}");
            }
        } catch (Unreachable) {
            if ($this->status === self::DOWN) {
                return false;
            }
            Log::info('rheocles-core stopped answering');
            $this->status = self::LAUNCHING;
            $this->discovery = null;
            $this->establish();
        } catch (Failure $e) {
            $this->fail($e->getMessage());
        }

        return $this->status === self::RUNNING;
    }

    /**
     * The Relaunch button: forget the crash-loop count and try again. When
     * our core is running this is a restart — Screen Recording takes effect
     * on the daemon's next launch (PROTOCOL § GET /streams), and the nudge
     * under an empty Displays section offers exactly that. A shared daemon
     * is never restarted from here; the nudge says to relaunch it instead.
     */
    public function relaunch(): void
    {
        if ($this->ours && $this->status === self::RUNNING) {
            Log::info('restarting rheocles-core (ours)');
            ChildProcess::stop(self::ALIAS);
            $this->sleep(0.5);
        }
        $this->launches = [];
        $this->why = null;
        $this->status = self::LAUNCHING;
        $this->establish();
    }

    /** Stop the daemon if — and only if — it is ours. */
    public function shutdown(): void
    {
        $this->stopping = true;
        if (! $this->ours) {
            return;
        }
        Log::info('stopping rheocles-core (ours)');
        ChildProcess::stop(self::ALIAS);
    }

    // MARK: - the process

    /**
     * Launch the bundled core as a child. Returns false when it could not
     * even be started (missing binary, crash loop); `status` says why.
     */
    private function launch(): bool
    {
        if ($this->stopping) {
            return false;
        }
        $window = (int) config('rheocles.crash_window', 60);
        $this->launches = array_values(array_filter($this->launches, fn ($t) => $t > $this->now() - $window));
        if (count($this->launches) >= (int) config('rheocles.crash_limit', 3)) {
            $this->fail('rheocles-core exited three times in a minute; not relaunching');

            return false;
        }

        $binary = self::binary();
        if ($binary === null) {
            $this->fail('no rheocles-core beside the app');

            return false;
        }

        try {
            ($this->launcher ?? self::spawn(...))($binary, $this->arguments());
        } catch (\Throwable $e) {
            $this->fail("could not launch $binary: {$e->getMessage()}");

            return false;
        }

        $this->launches[] = $this->now();
        $this->ours = true;
        $this->status = self::LAUNCHING;
        Log::info("launched $binary");

        return true;
    }

    /**
     * The core as an Electron-managed child, both streams appended to one
     * log file so a crash's last words land next to the line that preceded
     * them. `exec` makes the shell *become* the core, so the process the
     * runtime signals at quit is the core itself, not a wrapper.
     */
    private static function spawn(string $binary, array $arguments): void
    {
        $log = self::logPath();
        ChildProcess::start(
            cmd: ['/bin/sh', '-c', 'exec "$0" "$@" >>"'.$log.'" 2>&1', $binary, ...$arguments],
            alias: self::ALIAS,
            cwd: Home::path(),
        );
    }

    /** Ports from config, so a test can put a core on a spare pair. */
    public function arguments(): array
    {
        $args = [
            '--http-port', (string) $this->client->port,
            '--ws-port', (string) config('rheocles.ws_port'),
        ];
        if (config('rheocles.token_file')) {
            $args[] = '--token-file';
            $args[] = config('rheocles.token_file');
        }

        return $args;
    }

    /** Whether our child is still running. */
    private function alive(): bool
    {
        if ($this->alive !== null) {
            return ($this->alive)();
        }

        return ChildProcess::get(self::ALIAS) !== null;
    }

    /**
     * `Contents/extras/rheocles-core` in the bundle — electron-builder copies
     * `extras/` there and the runtime hands PHP the path in
     * NATIVEPHP_EXTRAS_PATH; in development the same variable points at
     * `php/extras`, which bin/sync-sidecar.sh fills. One lookup for both.
     */
    public static function binary(): ?string
    {
        $configured = config('rheocles.core');
        if ($configured) {
            return is_executable($configured) ? $configured : null;
        }
        $extras = env('NATIVEPHP_EXTRAS_PATH') ?: base_path('extras');
        $path = rtrim($extras, '/').'/rheocles-core';

        return is_executable($path) ? $path : null;
    }

    /**
     * Where the core's output goes. Beside the Swift app's logs, under a
     * name of its own, so two front ends on one machine never write to one
     * file.
     */
    public static function logPath(): string
    {
        $dir = Home::path().'/Library/Logs/Rheocles';
        if (! is_dir($dir)) {
            @mkdir($dir, 0755, true);
        }

        return $dir.'/rheocles-core-php.log';
    }

    // MARK: - state, for the popover

    public static function stateFile(): string
    {
        return storage_path('app/daemon.json');
    }

    public function toArray(): array
    {
        return [
            'status' => $this->status,
            'why' => $this->why,
            'ours' => $this->ours,
            'discovery' => $this->discovery,
            'port' => $this->client->port,
            'log' => self::logPath(),
            'at' => date('c'),
        ];
    }

    /** Write the state where `GET /daemon` reads it. Atomic, like a manifest. */
    public function publish(): void
    {
        $file = self::stateFile();
        @mkdir(dirname($file), 0755, true);
        $tmp = $file.'.tmp';
        file_put_contents($tmp, json_encode($this->toArray(), JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES));
        rename($tmp, $file);
    }

    /** The published state, or "launching" when nothing has been written. */
    public static function published(): array
    {
        $file = self::stateFile();
        $state = is_readable($file) ? json_decode((string) file_get_contents($file), true) : null;

        return is_array($state) ? $state : ['status' => self::LAUNCHING, 'why' => null, 'ours' => false, 'discovery' => null];
    }

    // MARK: - helpers

    private function readToken(): void
    {
        $this->client->token = Token::read();
    }

    private function fail(string $why): void
    {
        Log::info("daemon down: $why");
        $this->why = $why;
        $this->discovery = null;
        $this->status = self::DOWN;
    }

    private function now(): float
    {
        return $this->now !== null ? ($this->now)() : microtime(true);
    }

    private function sleep(float $seconds): void
    {
        if ($this->sleep !== null) {
            ($this->sleep)($seconds);
        } else {
            usleep((int) ($seconds * 1_000_000));
        }
    }
}
