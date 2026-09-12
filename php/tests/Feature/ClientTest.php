<?php

use App\Rheocles\Client;
use App\Rheocles\EventStream;
use App\Rheocles\Failure\Rejected;
use App\Rheocles\Failure\Unauthorized;
use App\Rheocles\Failure\Unreachable;
use Tests\Support\Server;

/*
 * The API client against the real rheocles-core binary (brief, rule 8), on
 * spare ports with its own token file and output root, so it shares nothing
 * with a daemon a front end may have running on 7447.
 */

beforeEach(function () {
    $this->http = Server::freePort();
    $this->ws = Server::freePort();
    $this->dir = sys_get_temp_dir().'/rheo-client-'.getmypid().'-'.bin2hex(random_bytes(3));
    mkdir($this->dir);
    $this->tokenFile = $this->dir.'/token';
    $this->core = Server::core($this->http, $this->ws, $this->tokenFile, $this->dir.'/out');
    // The daemon writes the token on launch; give it a moment past the port.
    $deadline = microtime(true) + 3;
    while (! is_file($this->tokenFile) && microtime(true) < $deadline) {
        usleep(20_000);
    }
    $this->token = trim(file_get_contents($this->tokenFile));
    $this->client = new Client('127.0.0.1', $this->http, $this->token);
});

afterEach(function () {
    $this->core->stop();
    exec('rm -rf '.escapeshellarg($this->dir));
});

it('provisions a token the client can read, mode 0600', function () {
    expect($this->token)->not->toBe('')
        ->and(substr(sprintf('%o', fileperms($this->tokenFile)), -4))->toBe('0600');
});

it('answers GET / with the discovery fields', function () {
    $d = $this->client->discovery();
    expect($d['name'])->toBe('Rheocles')
        ->and($d['auth'])->toBe('bearer')
        ->and($d['ports'])->toBe(['http' => $this->http, 'ws' => $this->ws])
        ->and($d['outputRoot'])->toBe($this->dir.'/out')
        ->and($d)->toHaveKeys(['version', 'hostname', 'machineId']);
});

it('refuses a wrong token as Unauthorized and no token likewise', function () {
    expect(fn () => (new Client('127.0.0.1', $this->http, 'wrong'))->discovery())->toThrow(Unauthorized::class)
        ->and(fn () => (new Client('127.0.0.1', $this->http))->discovery())->toThrow(Unauthorized::class);
});

it('reports a closed port as Unreachable', function () {
    expect(fn () => (new Client('127.0.0.1', Server::freePort(), $this->token))->discovery())->toThrow(Unreachable::class);
});

it('carries the protocol error shape on a refusal', function () {
    try {
        $this->client->take('no-such-take');
        $this->fail('expected a refusal');
    } catch (Rejected $e) {
        expect($e->status)->toBe(404)->and($e->reason)->toBe('not_found')->and($e->error)->not->toBe('');
    }
});

it('puts stream ids on the path verbatim — the daemon does not decode %3A', function () {
    try {
        $this->client->arm('display:nope', true);
        $this->fail('expected a refusal');
    } catch (Rejected $e) {
        expect($e->status)->toBe(404)->and($e->error)->toContain('display:nope')->not->toContain('%3A');
    }
});

it('lists streams with permissions, and recent takes', function () {
    $list = $this->client->streams();
    expect($list)->toHaveKeys(['streams', 'permissions'])
        ->and($list['permissions'])->toHaveKeys(['camera', 'microphone', 'screen']);
    expect($this->client->takes())->toBeArray();
})->skip(fn () => getenv('CI') !== false, 'raises the Screen Recording prompt on a fresh machine');

it('reads the event stream and yields null when the daemon is quiet', function () {
    $events = EventStream::read('127.0.0.1', $this->http, $this->token, idle: 0.3);
    $first = $events->current();  // `: connected` is a comment; nothing said → idle
    expect($first)->toBeNull();
});

it('refuses the event stream without a token', function () {
    expect(fn () => EventStream::read('127.0.0.1', $this->http, 'wrong')->current())->toThrow(Unauthorized::class);
});
