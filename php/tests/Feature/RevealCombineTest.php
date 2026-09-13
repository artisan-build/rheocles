<?php

use Native\Desktop\Facades\Settings;
use Tests\Support\Server;

/*
 * Open in Finder and the single file (feature brief §1, §2, addendum),
 * through the popover's routes to the stub core. The daemon reveals and
 * the daemon muxes; PHP carries the click and the exact body the protocol
 * names, and the daemon's words back on a refusal.
 */

function stubWith(array $env = []): void
{
    test()->port = Server::freePort();
    test()->tokenFile = tempnam(sys_get_temp_dir(), 'rheo-token-');
    file_put_contents(test()->tokenFile, "stub-token\n");
    config(['rheocles.token_file' => test()->tokenFile, 'rheocles.http_port' => test()->port]);
    test()->stub = Server::stub(test()->port, 'stub-token', null, $env);
    Settings::shouldReceive('get')->andReturnUsing(fn ($k, $d = null) => $d);
}

/**
 * `GET /takes` as the page reads it — from the daemon directly, not through
 * PHP (brief, rule 2): the summaries, newest first.
 */
function summaries(): array
{
    return \App\Rheocles\Client::fromConfig()->takes();
}

/** The bodies the stub saw on `$path`, verbatim, in order. */
function bodiesSent(string $path): array
{
    return array_values(array_map(fn ($r) => $r['body'],
        array_filter(test()->stub->requests(), fn ($r) => $r['path'] === $path && $r['method'] === 'POST')));
}

afterEach(function () {
    $this->stub->stop();
    @unlink($this->tokenFile);
});

describe('reveal', function () {
    beforeEach(fn () => stubWith());

    it('reveals the output root and a path under it: POST /reveal with the path, 204 through', function () {
        $this->postJson('/api/reveal', ['path' => ''])->assertNoContent();
        $this->postJson('/api/reveal')->assertNoContent();
        expect(bodiesSent('/reveal'))->toBe(['{"path":""}', '{"path":""}']);

        $this->postJson('/api/reveal', ['path' => 'nowhere/at/all'])
            ->assertStatus(404)->assertJson(['code' => 'not_found', 'error' => 'no such path under the output root']);
        $this->postJson('/api/reveal', ['path' => '../escape'])->assertStatus(404);
        $this->postJson('/api/reveal', ['path' => '/etc'])->assertStatus(404);
    });

    it('reveals a take folder with an empty body, and a file in it with { path }', function () {
        $this->postJson('/api/streams/microphone:stub/arm', ['armed' => true])->assertOk();
        $id = $this->postJson('/api/record', ['name' => 'ep'])->assertStatus(201)->json('take.id');
        $this->postJson("/api/takes/$id/stop")->assertOk();

        $this->postJson("/api/takes/$id/reveal")->assertNoContent();
        $this->postJson("/api/takes/$id/reveal", ['path' => ''])->assertNoContent();   // an empty path is the folder
        $this->postJson("/api/takes/$id/reveal", ['path' => 'stub-mic.wav'])->assertNoContent();
        expect(bodiesSent("/takes/$id/reveal"))->toBe(['{}', '{}', '{"path":"stub-mic.wav"}']);

        // The take's own destination is a path under the root too.
        $this->postJson('/api/reveal', ['path' => 'takes/stub'])->assertNoContent();

        $this->postJson("/api/takes/$id/reveal", ['path' => 'missing.mov'])
            ->assertStatus(404)->assertJson(['code' => 'not_found', 'error' => "no such path in take $id"]);
        $this->postJson('/api/takes/nope/reveal')
            ->assertStatus(404)->assertJson(['code' => 'not_found', 'error' => 'no such take: nope']);
    });

    it('passes an old daemon\'s "no such route" through verbatim, so the page can say "update Rheocles"', function () {
        // The stub has the route; what an older core answers is the
        // dispatcher's default 404, the same shape — here from a route the
        // stub does not have, standing in for a daemon that has neither.
        config(['rheocles.http_port' => $this->port]);
        $r = \App\Rheocles\Client::fromConfig();
        try {
            $r->post('/takes/x/no-such-verb', (object) []);
            $this->fail('expected a 404');
        } catch (\App\Rheocles\Failure\Rejected $e) {
            expect($e->status)->toBe(404)->and($e->reason)->toBe('not_found')->and($e->error)->toBe('no such route');
        }
    });
});

describe('combine', function () {
    it('reads and sets settings.combine, and only a boolean', function () {
        stubWith();
        $this->getJson('/api/settings')->assertOk()->assertJsonPath('combine', false);
        $this->patchJson('/api/settings', ['combine' => true])
            ->assertOk()->assertExactJson(['outputRoot' => '/tmp/rheocles-stub', 'codec' => 'hevc', 'combine' => true]);
        expect(bodiesSent('/settings'))->toBe([]);   // PATCH, not POST
        $patches = array_values(array_filter($this->stub->requests(), fn ($r) => $r['method'] === 'PATCH'));
        expect(array_map(fn ($r) => $r['body'], $patches))->toBe(['{"combine":true}']);
        $this->patchJson('/api/settings', ['combine' => 'yes'])->assertStatus(400)->assertJson(['code' => 'bad_request']);
        $this->getJson('/api/settings')->assertJsonPath('combine', true);
    });

    it('records with the default on: combined pending, then complete after stop, and in the summary', function () {
        stubWith();
        $this->patchJson('/api/settings', ['combine' => true])->assertOk();
        $this->postJson('/api/streams/microphone:stub/arm', ['armed' => true])->assertOk();
        $this->postJson('/api/streams/display:STUB-1/arm', ['armed' => true])->assertOk();

        $r = $this->postJson('/api/record', ['name' => 'loom'])->assertStatus(201)
            ->assertJsonPath('take.combined.path', 'combined.mov')
            ->assertJsonPath('take.combined.state', 'pending');
        $id = $r->json('take.id');
        // No `combine` in the body: the daemon's default applies (one setting for both front ends).
        expect(bodiesSent('/record'))->toBe(['{"name":"loom"}']);

        $this->postJson("/api/takes/$id/stop")->assertOk()
            ->assertJsonPath('state', 'complete')
            ->assertJsonPath('combined.state', 'complete')
            ->assertJsonMissingPath('combined.reason');
        expect(summaries()[0]['id'])->toBe($id)
            ->and(summaries()[0]['combined'])->toBe(['path' => 'combined.mov', 'state' => 'complete']);

        // The combined file is one of the take's paths now.
        $this->postJson("/api/takes/$id/reveal", ['path' => 'combined.mov'])->assertNoContent();
        expect(bodiesSent("/takes/$id/reveal"))->toBe(['{"path":"combined.mov"}']);
    });

    it('records with the default off: no combined block at all', function () {
        stubWith();
        $this->postJson('/api/streams/microphone:stub/arm', ['armed' => true])->assertOk();
        $id = $this->postJson('/api/record')->assertStatus(201)->assertJsonMissingPath('take.combined')->json('take.id');
        $this->postJson("/api/takes/$id/stop")->assertOk()->assertJsonMissingPath('combined');
        expect(summaries()[0])->not->toHaveKey('combined');
        // The combined file is not there to reveal.
        $this->postJson("/api/takes/$id/reveal", ['path' => 'combined.mov'])->assertStatus(404);
    });

    it('is refused with two videos armed, in the daemon\'s words', function () {
        stubWith();
        $this->patchJson('/api/settings', ['combine' => true])->assertOk();
        $this->postJson('/api/streams/display:STUB-1/arm', ['armed' => true])->assertOk();
        $this->postJson('/api/streams/window:stub/arm', ['armed' => true])->assertOk();
        $this->postJson('/api/record')->assertStatus(400)->assertJson(['code' => 'combine_requires_single_video']);
    });

    it('carries a failed mux with the daemon\'s reason; the take itself stays complete', function () {
        stubWith(['STUB_COMBINE' => 'failed']);
        $this->patchJson('/api/settings', ['combine' => true])->assertOk();
        $this->postJson('/api/streams/microphone:stub/arm', ['armed' => true])->assertOk();
        $id = $this->postJson('/api/record')->assertStatus(201)->json('take.id');
        $this->postJson("/api/takes/$id/stop")->assertOk()
            ->assertJsonPath('state', 'complete')
            ->assertJsonPath('combined.state', 'failed')
            ->assertJsonPath('combined.reason', 'export failed: the video track could not be read');
        expect(summaries()[0]['combined']['state'])->toBe('failed');
    });

    it('carries a mux still pending after stop, as the real daemon answers', function () {
        stubWith(['STUB_COMBINE' => 'pending']);
        $this->patchJson('/api/settings', ['combine' => true])->assertOk();
        $this->postJson('/api/streams/microphone:stub/arm', ['armed' => true])->assertOk();
        $id = $this->postJson('/api/record')->assertStatus(201)->json('take.id');
        $this->postJson("/api/takes/$id/stop")->assertOk()->assertJsonPath('combined.state', 'pending');
        // Pending is not a file yet: nothing to reveal.
        $this->postJson("/api/takes/$id/reveal", ['path' => 'combined.mov'])->assertStatus(404);
    });
});

describe('combine now', function () {
    it('muxes a finished take after the fact: pending back, complete next, an empty body on the wire', function () {
        stubWith();
        $this->postJson('/api/streams/microphone:stub/arm', ['armed' => true])->assertOk();
        $this->postJson('/api/streams/display:STUB-1/arm', ['armed' => true])->assertOk();
        $id = $this->postJson('/api/record')->assertStatus(201)->json('take.id');

        // Not while recording.
        $this->postJson("/api/takes/$id/combine")->assertStatus(409)->assertJson(['code' => 'conflict']);
        $this->postJson("/api/takes/$id/stop")->assertOk()->assertJsonMissingPath('combined');

        $this->postJson("/api/takes/$id/combine")->assertOk()
            ->assertJsonPath('id', $id)->assertJsonPath('combined.state', 'pending');
        expect(bodiesSent("/takes/$id/combine"))->toBe(['{}', '{}']);
        expect(summaries()[0]['combined']['state'])->toBe('complete');
        $this->postJson('/api/takes/nope/combine')->assertStatus(404)->assertJson(['code' => 'not_found']);
    });

    it('is refused for a take with two videos, in the daemon\'s words', function () {
        stubWith();
        $this->postJson('/api/streams/display:STUB-1/arm', ['armed' => true])->assertOk();
        $this->postJson('/api/streams/window:stub/arm', ['armed' => true])->assertOk();
        $id = $this->postJson('/api/record')->assertStatus(201)->json('take.id');
        $this->postJson("/api/takes/$id/stop")->assertOk();
        $this->postJson("/api/takes/$id/combine")->assertStatus(400)->assertJson(['code' => 'combine_requires_single_video']);
    });
});
