<?php

use Native\Desktop\Facades\Clipboard;
use Native\Desktop\Facades\Settings;
use Tests\Support\Server;

/*
 * The daemon's settings and the pairing code (spec §12), through the
 * popover's routes to the stub core. The output root and the codec are the
 * daemon's; show windows stays the app's.
 */

beforeEach(function () {
    $this->port = Server::freePort();
    $this->tokenFile = tempnam(sys_get_temp_dir(), 'rheo-token-');
    file_put_contents($this->tokenFile, "stub-token\n");
    config(['rheocles.token_file' => $this->tokenFile, 'rheocles.http_port' => $this->port]);
    $this->stub = Server::stub($this->port, 'stub-token', $this->tokenFile);
    Settings::shouldReceive('get')->andReturnUsing(fn ($k, $d = null) => $d);
});

afterEach(function () {
    $this->stub->stop();
    @unlink($this->tokenFile);
});

it('reads and changes the daemon settings, and passes a refusal through', function () {
    $this->getJson('/api/settings')->assertOk()->assertExactJson(['outputRoot' => '/tmp/rheocles-stub', 'codec' => 'hevc', 'combine' => false]);

    $this->patchJson('/api/settings', ['codec' => 'prores', 'other' => 'ignored'])
        ->assertOk()->assertJson(['codec' => 'prores', 'outputRoot' => '/tmp/rheocles-stub']);
    $this->patchJson('/api/settings', ['outputRoot' => '/Volumes/SSD/Takes'])
        ->assertOk()->assertJson(['outputRoot' => '/Volumes/SSD/Takes', 'codec' => 'prores']);
    $this->patchJson('/api/settings', ['codec' => 'mp3'])->assertStatus(400)->assertJson(['code' => 'bad_request']);

    // The root cannot move under an active take: the daemon's 409, verbatim.
    $this->postJson('/api/streams/microphone:stub/arm', ['armed' => true])->assertOk();
    $this->postJson('/api/record')->assertStatus(201);
    $this->patchJson('/api/settings', ['outputRoot' => '/elsewhere'])
        ->assertStatus(409)->assertJson(['code' => 'conflict']);
});

it('records without a codec, so the daemon default applies', function () {
    $this->patchJson('/api/settings', ['codec' => 'prores'])->assertOk();
    $this->postJson('/api/streams/microphone:stub/arm', ['armed' => true])->assertOk();
    $this->postJson('/api/record', ['name' => 'x'])->assertStatus(201)->assertJsonPath('take.settings.codec', 'prores');
});

it('copies the token to the native clipboard', function () {
    Clipboard::shouldReceive('text')->once()->with('stub-token');
    $this->postJson('/api/token/copy')->assertOk()->assertJson(['copied' => true]);
});

it('rotates the token: the file is rewritten and the next request uses it', function () {
    $r = $this->postJson('/api/token/rotate')->assertOk();
    $new = $r->json('token');
    expect(strlen($new))->toBe(64)
        ->and(trim(file_get_contents($this->tokenFile)))->toBe($new);

    // The page and every route read the file afresh: still paired.
    $this->getJson('/api/settings')->assertOk();
    $this->get('/')->assertOk()->assertSee(substr($new, 0, 6));
});
