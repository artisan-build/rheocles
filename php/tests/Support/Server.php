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

    private function __construct(public readonly int $port, $process)
    {
        $this->process = $process;
    }

    public static function freePort(): int
    {
        $socket = stream_socket_server('tcp://127.0.0.1:0', $errno, $error);
        $port = (int) explode(':', stream_socket_get_name($socket, false))[1];
        fclose($socket);

        return $port;
    }

    /** The stub, expecting `$token`. */
    public static function stub(int $port, string $token): self
    {
        $state = sys_get_temp_dir()."/rheo-stub-state-$port-".getmypid().'.json';
        @unlink($state);

        return self::spawn($port, [PHP_BINARY, '-S', "127.0.0.1:$port", __DIR__.'/../stubs/core.php'],
            ['STUB_TOKEN' => $token, 'STUB_STATE' => $state]);
    }

    /** The real daemon, on spare ports, with its own token file and output root. */
    public static function core(int $httpPort, int $wsPort, string $tokenFile, string $outputRoot): self
    {
        $binary = self::coreBinary();
        if ($binary === null) {
            test()->markTestSkipped('no rheocles-core: run swift build --package-path app -c release && php/bin/sync-sidecar.sh');
        }

        return self::spawn($httpPort, [
            $binary, '--http-port', (string) $httpPort, '--ws-port', (string) $wsPort,
            '--token-file', $tokenFile, '--output-root', $outputRoot,
        ]);
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
        $process = proc_open($cmd, [0 => ['file', '/dev/null', 'r'], 1 => ['file', '/dev/null', 'w'], 2 => ['file', '/dev/null', 'w']], $pipes, null, $env + getenv());
        if (! is_resource($process)) {
            throw new \RuntimeException('could not start '.implode(' ', $cmd));
        }
        $server = new self($port, $process);
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
        $this->stop();
        throw new \RuntimeException("nothing listening on :{$this->port} after {$timeout}s");
    }

    public function running(): bool
    {
        return is_resource($this->process) && proc_get_status($this->process)['running'];
    }

    public function stop(): void
    {
        if (is_resource($this->process)) {
            proc_terminate($this->process, 15);
            proc_close($this->process);
        }
    }

    public function __destruct()
    {
        $this->stop();
    }
}
