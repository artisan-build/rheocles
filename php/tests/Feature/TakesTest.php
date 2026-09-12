<?php

use Native\Desktop\Facades\Settings;
use Tests\Support\Server;

/*
 * Record, stop and mark (spec §7, §10), through the popover's routes to
 * the stub core: one POST each, the manifest back, the daemon's words on
 * a refusal. The codec rides along from the app's preference.
 */

beforeEach(function () {
    $this->port = Server::freePort();
    $this->tokenFile = tempnam(sys_get_temp_dir(), 'rheo-token-');
    file_put_contents($this->tokenFile, "stub-token\n");
    config(['rheocles.token_file' => $this->tokenFile, 'rheocles.http_port' => $this->port]);
    $this->stub = Server::stub($this->port, 'stub-token');
    Settings::shouldReceive('get')->andReturnUsing(fn ($k, $d = null) => $d);
});

afterEach(function () {
    $this->stub->stop();
    @unlink($this->tokenFile);
});

it('refuses to record with nothing armed, in the daemon words', function () {
    $this->postJson('/api/record', ['name' => 'ep12'])
        ->assertStatus(400)
        ->assertJson(['code' => 'bad_request']);
});

it('records, marks and stops a take, with the name and the daemon default codec', function () {
    $this->postJson('/api/streams/microphone:stub/arm', ['armed' => true])->assertOk();

    $r = $this->postJson('/api/record', ['name' => '  Episode 12 '])
        ->assertStatus(201)
        ->assertJsonPath('take.state', 'recording')
        ->assertJsonPath('take.name', 'Episode 12')
        ->assertJsonPath('take.settings.codec', 'hevc')
        ->assertJsonPath('take.streams.0.id', 'microphone:stub')
        ->assertJsonPath('take.streams.0.codec', 'pcm_s24le');
    $id = $r->json('take.id');

    // A second Record while one is recording is the daemon's 409.
    $this->postJson('/api/record')->assertStatus(409)->assertJson(['code' => 'take_active']);

    $this->postJson("/api/takes/$id/markers", ['label' => 'chapter 1'])
        ->assertOk()
        ->assertJsonPath('markers.0.label', 'chapter 1')
        ->assertJsonPath('markers.0.t', 0.5);
    // An empty label is named for its number, never refused.
    $this->postJson("/api/takes/$id/markers", ['label' => '  ', 'count' => 1])
        ->assertOk()
        ->assertJsonPath('markers.1.label', 'marker 2');

    $this->postJson("/api/takes/$id/stop")
        ->assertOk()
        ->assertJsonPath('state', 'complete')
        ->assertJsonPath('streams.0.events.1.type', 'leave');

    // Stopped twice is a conflict, and marking a finished take likewise.
    $this->postJson("/api/takes/$id/stop")->assertStatus(409)->assertJson(['code' => 'conflict']);
    $this->postJson("/api/takes/$id/markers", ['label' => 'late'])->assertStatus(409);
});

it('sends no name when the field is empty, so the daemon names the take', function () {
    $this->postJson('/api/streams/microphone:stub/arm', ['armed' => true])->assertOk();
    $this->postJson('/api/record', ['name' => ''])
        ->assertStatus(201)
        ->assertJsonMissingPath('take.name');
});
