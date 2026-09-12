<?php

use App\Rheocles\Client;
use App\Rheocles\Daemon;
use Native\Desktop\Facades\ChildProcess;
use Native\Desktop\Facades\Settings;
use Tests\Support\Server;

/*
 * Arming (spec §6), through the popover's route to a stub core: one POST
 * and the daemon's answer, in the daemon's words when it refuses. And the
 * app's own show-windows preference.
 */

beforeEach(function () {
    $this->port = Server::freePort();
    $this->tokenFile = tempnam(sys_get_temp_dir(), 'rheo-token-');
    file_put_contents($this->tokenFile, "stub-token\n");
    config(['rheocles.token_file' => $this->tokenFile, 'rheocles.http_port' => $this->port]);
    $this->stub = Server::stub($this->port, 'stub-token');
});

afterEach(function () {
    $this->stub->stop();
    @unlink($this->tokenFile);
});

it('arms and disarms a stream and answers the stream as it now is', function () {
    $this->postJson("/api/streams/microphone:stub/arm", ['armed' => true])
        ->assertOk()
        ->assertJson(['id' => 'microphone:stub', 'armed' => true, 'framesSeen' => 0]);

    // The list agrees: the daemon is the truth, and the next read says so.
    $list = (new Client('127.0.0.1', $this->port, 'stub-token'))->streams();
    $armed = array_column(array_filter($list['streams'], fn ($s) => $s['armed']), 'id');
    expect($armed)->toBe(['microphone:stub']);

    $this->postJson("/api/streams/microphone:stub/arm", ['armed' => false])
        ->assertOk()
        ->assertJson(['armed' => false])
        ->assertJsonMissing(['framesSeen' => 0]);
});

it('passes a refusal through in the protocol shape', function () {
    $this->postJson('/api/streams/camera:stub/arm', ['armed' => true])
        ->assertStatus(403)
        ->assertJson(['code' => 'permission_denied'])
        ->assertJsonPath('error', fn ($e) => str_contains($e, 'camera access denied'));

    $this->postJson('/api/streams/nope:1/arm', ['armed' => true])
        ->assertStatus(404)
        ->assertJson(['code' => 'not_found']);
});

it('reports an unreachable daemon as 503 unreachable', function () {
    $this->stub->stop();
    $this->postJson('/api/streams/microphone:stub/arm', ['armed' => true])
        ->assertStatus(503)
        ->assertJson(['code' => 'unreachable']);
});

it('keeps show windows and codec in NativePHP settings', function () {
    $store = new ArrayObject;
    Settings::shouldReceive('get')->andReturnUsing(fn ($k, $d = null) => $store[$k] ?? $d);
    Settings::shouldReceive('set')->andReturnUsing(function ($k, $v) use ($store) {
        $store[$k] = $v;
    });

    $this->getJson('/api/preferences')->assertOk()->assertExactJson(['showWindows' => false, 'codec' => 'hevc']);
    $this->postJson('/api/preferences', ['showWindows' => true, 'codec' => 'prores', 'other' => 'ignored'])
        ->assertOk()->assertExactJson(['showWindows' => true, 'codec' => 'prores']);
    $this->postJson('/api/preferences', ['codec' => 'mp3'])->assertOk()->assertJson(['codec' => 'prores']);
});

it('opens only the three Privacy panes', function () {
    Native\Desktop\Facades\Shell::shouldReceive('openExternal')->once()
        ->with('x-apple.systempreferences:com.apple.preference.security?Privacy_Camera');
    $this->postJson('/api/privacy', ['pane' => 'Privacy_Camera'])->assertOk();
    $this->postJson('/api/privacy', ['pane' => 'Privacy_Everything'])->assertStatus(422);
});

it('restarts our own core on relaunch, and never a shared one', function () {
    ChildProcess::fake();
    $daemon = new Daemon(new Client('127.0.0.1', $this->port), launcher: fn () => null, alive: fn () => true, sleep: fn () => null);
    $daemon->establish();
    expect($daemon->status)->toBe(Daemon::RUNNING)->and($daemon->ours)->toBeFalse();
    $daemon->relaunch();
    expect(fn () => ChildProcess::assertStop(fn () => true))->toThrow(PHPUnit\Framework\AssertionFailedError::class);
});
