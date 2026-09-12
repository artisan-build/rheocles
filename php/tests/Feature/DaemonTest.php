<?php

use App\Rheocles\Client;
use App\Rheocles\Daemon;
use Native\Desktop\Facades\ChildProcess;
use Tests\Support\Server;

/*
 * The lifecycle (spec §3), against a stub core on a spare port: probe and
 * use what answers; launch when nothing does; give up after three exits in
 * a minute; and never kill a daemon we did not start.
 */

beforeEach(function () {
    $this->port = Server::freePort();
    $this->tokenFile = tempnam(sys_get_temp_dir(), 'rheo-token-');
    file_put_contents($this->tokenFile, "stub-token\n");
    config(['rheocles.token_file' => $this->tokenFile, 'rheocles.http_port' => $this->port, 'rheocles.launch_timeout' => 2]);
    $this->servers = [];
    $this->launches = 0;
    $this->clock = 1000.0;
});

afterEach(function () {
    foreach ($this->servers as $s) {
        $s->stop();
    }
    @unlink($this->tokenFile);
});

/** A Daemon whose launcher starts (or fails to start) the stub. */
function daemonUnderTest($test, ?Closure $launcher = null, ?Closure $alive = null): Daemon
{
    return new Daemon(
        new Client('127.0.0.1', $test->port),
        launcher: $launcher ?? function () use ($test) {
            $test->launches++;
            $test->servers[] = Server::stub($test->port, 'stub-token');
        },
        alive: $alive ?? fn () => true,
        sleep: fn (float $s) => $test->clock += $s,
        now: fn () => $test->clock,
    );
}

it('uses a daemon that is already answering and does not launch one', function () {
    $this->servers[] = Server::stub($this->port, 'stub-token');
    $daemon = daemonUnderTest($this);
    $daemon->establish();

    expect($daemon->status)->toBe(Daemon::RUNNING)
        ->and($daemon->ours)->toBeFalse()
        ->and($this->launches)->toBe(0)
        ->and($daemon->discovery['name'])->toBe('Rheocles')
        ->and($daemon->discovery['ports']['http'])->toBe($this->port);
});

it('launches the sidecar when nothing answers and waits for it', function () {
    $daemon = daemonUnderTest($this);
    $daemon->establish();

    expect($this->launches)->toBe(1)
        ->and($daemon->status)->toBe(Daemon::RUNNING)
        ->and($daemon->ours)->toBeTrue()
        ->and($daemon->why)->toBeNull();
});

it('reads the token from the file, and again after a launch', function () {
    file_put_contents($this->tokenFile, "wrong\n");
    $daemon = daemonUnderTest($this, launcher: function () {
        // The core writes its token on first launch; so does the stub's keeper.
        $this->launches++;
        file_put_contents($this->tokenFile, "stub-token\n");
        $this->servers[] = Server::stub($this->port, 'stub-token');
    });
    $daemon->establish();

    expect($daemon->status)->toBe(Daemon::RUNNING)
        ->and($daemon->client->token)->toBe('stub-token');
});

it('is down, not launching, when the port answers but refuses the token', function () {
    file_put_contents($this->tokenFile, "stale\n");
    $this->servers[] = Server::stub($this->port, 'stub-token');
    $daemon = daemonUnderTest($this);
    $daemon->establish();

    expect($daemon->status)->toBe(Daemon::DOWN)
        ->and($daemon->why)->toContain('refused the token')
        ->and($this->launches)->toBe(0);

    // The file catches up (the daemon that wrote it, or a rotation); the
    // next pulse reads it again and is running without a launch.
    file_put_contents($this->tokenFile, "stub-token\n");
    expect($daemon->check())->toBeTrue()->and($this->launches)->toBe(0);
});

it('re-reads the token when it is rotated underneath a running client', function () {
    $this->servers[] = Server::stub($this->port, 'stub-token');
    $daemon = daemonUnderTest($this);
    $daemon->establish();
    expect($daemon->status)->toBe(Daemon::RUNNING);

    // Another client rotates: the daemon now wants a new token and the file
    // already has it, but this client still holds the old one.
    $this->servers[0]->stop();
    $this->servers = [Server::stub($this->port, 'rotated')];
    file_put_contents($this->tokenFile, "rotated\n");
    expect($daemon->check())->toBeTrue()
        ->and($daemon->status)->toBe(Daemon::RUNNING)
        ->and($daemon->client->token)->toBe('rotated')
        ->and($this->launches)->toBe(0);
});

it('gives up after three exits in a minute, and relaunch lifts the guard', function () {
    $daemon = daemonUnderTest($this,
        launcher: function () {
            $this->launches++;
        },
        alive: fn () => false,  // exits before answering, every time
    );
    $daemon->establish();

    expect($daemon->status)->toBe(Daemon::DOWN)
        ->and($daemon->why)->toContain('three times in a minute')
        ->and($this->launches)->toBe(3);

    // Meanwhile a daemon appears (another front end launched one). The
    // pulse adopts it without launching.
    $this->servers[] = Server::stub($this->port, 'stub-token');
    $daemon->check();
    expect($daemon->status)->toBe(Daemon::RUNNING)->and($this->launches)->toBe(3);
});

it('is down when the sidecar never answers within the launch window', function () {
    $daemon = daemonUnderTest($this, launcher: function () {
        $this->launches++;  // starts nothing
    });
    $daemon->establish();

    expect($daemon->status)->toBe(Daemon::DOWN)
        ->and($daemon->why)->toContain('did not answer')
        ->and($this->launches)->toBe(1);
});

it('is down with a reason when there is no binary to launch', function () {
    config(['rheocles.core' => '/nonexistent/rheocles-core']);
    $daemon = daemonUnderTest($this);
    $daemon->establish();

    expect($daemon->status)->toBe(Daemon::DOWN)
        ->and($daemon->why)->toContain('no rheocles-core');
});

it('relaunches when the daemon stops answering, and reports the outage', function () {
    $daemon = daemonUnderTest($this);
    $daemon->establish();
    expect($daemon->ours)->toBeTrue()->and($this->launches)->toBe(1);

    $this->servers[0]->stop();
    $this->servers = [];
    expect($daemon->check())->toBeTrue()  // relaunched inside the pulse
        ->and($this->launches)->toBe(2)
        ->and($daemon->status)->toBe(Daemon::RUNNING);
});

it('quit only kills ours', function () {
    ChildProcess::fake();

    $this->servers[] = Server::stub($this->port, 'stub-token');
    $shared = daemonUnderTest($this);
    $shared->establish();
    $shared->shutdown();
    // Nothing stopped: the fake has no stop to match, so the assertion fails.
    expect(fn () => ChildProcess::assertStop(fn ($alias) => true))
        ->toThrow(PHPUnit\Framework\AssertionFailedError::class);

    $this->servers[0]->stop();
    $this->servers = [];
    $ours = daemonUnderTest($this);
    $ours->establish();
    expect($ours->ours)->toBeTrue();
    $ours->shutdown();
    ChildProcess::assertStop(Daemon::ALIAS);
});

it('publishes its state for the popover, atomically', function () {
    $this->servers[] = Server::stub($this->port, 'stub-token');
    $daemon = daemonUnderTest($this);
    $daemon->establish();
    $daemon->publish();

    $published = Daemon::published();
    expect($published['status'])->toBe('running')
        ->and($published['ours'])->toBeFalse()
        ->and($published['discovery']['hostname'])->toBe('stub.local')
        ->and(file_exists(Daemon::stateFile().'.tmp'))->toBeFalse();
    @unlink(Daemon::stateFile());
});
