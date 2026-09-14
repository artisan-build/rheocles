<?php

namespace Tests\Support;

/**
 * A process on a loopback port for a test to talk to: the stub core
 * (tests/stubs/core.php on PHP's built-in server) or the real
 * `rheocles-core` binary. Started, waited for, and killed with the test.
 */
final class Server
{
    /** @var resource */
    private $process;

    /** The stub's state file, when this is the stub: its request log lives there. */
    public ?string $stateFile = null;

    /** The process's output, one file per port; read on a failed start, gone with the server. */
    private string $log;

    private function __construct(public readonly int $port, $process)
    {
        $this->process = $process;
    }

    /**
     * What the stub was asked, in order: `[{ method, path, body }]`, the
     * body verbatim — for a test that cares exactly what went on the wire.
     */
    public function requests(): array
    {
        if ($this->stateFile === null || ! is_file($this->stateFile)) {
            return [];
        }

        return (json_decode((string) file_get_contents($this->stateFile), true) ?: [])['__requests'] ?? [];
    }

    public static function freePort(): int
    {
        $socket = stream_socket_server('tcp://127.0.0.1:0', $errno, $error);
        $port = (int) explode(':', stream_socket_get_name($socket, false))[1];
        fclose($socket);

        return $port;
    }

    /** The stub, expecting `$token`; `$env` adds knobs (`STUB_COMBINE`: complete | failed | pending). */
    public static function stub(int $port, string $token, ?string $tokenFile = null, array $env = []): self
    {
        $state = sys_get_temp_dir()."/rheo-stub-state-$port-".getmypid().'.json';
        @unlink($state);

        $server = self::spawn($port, [PHP_BINARY, '-S', "127.0.0.1:$port", __DIR__.'/../stubs/core.php'],
            $env + ['STUB_TOKEN' => $token, 'STUB_STATE' => $state, 'STUB_TOKEN_FILE' => $tokenFile ?? '']);
        $server->stateFile = $state;

        return $server;
    }

    /** The real daemon, on spare ports, with its own token file and output root. */
    public static function core(int $httpPort, int $wsPort, string $tokenFile, string $outputRoot, bool $immediate = false): self
    {
        $binary = self::coreBinary();
        if ($binary === null) {
            test()->markTestSkipped('no rheocles-core: run swift build --package-path app -c release && php/bin/sync-sidecar.sh');
        }

        // Its own settings file too: --output-root is persisted to the
        // settings file (PROTOCOL § Settings), and without this the default
        // ~/Library/Application Support/Rheocles/settings.json — the user's
        // real one, which every front end's daemon reads — would come away
        // pointing at a test's temp directory.
        $server = self::spawn($httpPort, [
            $binary, '--http-port', (string) $httpPort, '--ws-port', (string) $wsPort,
            '--token-file', $tokenFile, '--output-root', $outputRoot,
            '--settings-file', dirname($tokenFile).'/settings.json',
        ]);
        // The port answers before CoreAudio has settled: a device call in
        // the first second leaks a continuation in the daemon about one run
        // in three (see ClientTest "hangs"). The tests of this client wait;
        // the one test of that bug does not.
        if (! $immediate) {
            usleep(1_500_000);
        }

        return $server;
    }

    public static function coreBinary(): ?string
    {
        foreach ([base_path('extras/rheocles-core'), base_path('../app/.build/release/rheocles-core')] as $path) {
            if (is_executable($path)) {
                return realpath($path);
            }
        }

        return null;
    }

    private static function spawn(int $port, array $cmd, array $env = []): self
    {
        // Output to a file per port, so a server that does not come up can
        // say why (the message names it).
        $log = sys_get_temp_dir()."/rheo-test-server-$port.log";
        $process = proc_open($cmd, [0 => ['file', '/dev/null', 'r'], 1 => ['file', $log, 'a'], 2 => ['file', $log, 'a']], $pipes, null, $env + getenv());
        if (! is_resource($process)) {
            @unlink($log);
            throw new \RuntimeException('could not start '.implode(' ', $cmd));
        }
        $server = new self($port, $process);
        $server->log = $log;
        $server->waitForPort();

        return $server;
    }

    /** Block until something accepts on the port, or fail after five seconds. */
    public function waitForPort(float $timeout = 5): void
    {
        $deadline = microtime(true) + $timeout;
        while (microtime(true) < $deadline) {
            $socket = @stream_socket_client("tcp://127.0.0.1:{$this->port}", $errno, $error, 0.2);
            if ($socket !== false) {
                fclose($socket);

                return;
            }
            usleep(50_000);
        }
        $why = trim((string) @file_get_contents($this->log));
        $this->stop();
        throw new \RuntimeException("nothing listening on :{$this->port} after {$timeout}s — $why");
    }

    public function running(): bool
    {
        return is_resource($this->process) && proc_get_status($this->process)['running'];
    }

    /** The process's output so far — for a test that reads what the daemon said. */
    public function output(): string
    {
        return (string) @file_get_contents($this->log);
    }

    /** Stop the process and take its files with it: nothing of a test stays in $TMPDIR. */
    public function stop(): void
    {
        if (is_resource($this->process)) {
            proc_terminate($this->process, 15);
            proc_close($this->process);
        }
        @unlink($this->log);
        if ($this->stateFile !== null) {
            @unlink($this->stateFile);
        }
    }

    public function __destruct()
    {
        $this->stop();
    }
}
