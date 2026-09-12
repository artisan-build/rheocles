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

/*
 * The one that matters (brief, rule 8): arm → record → stop against the
 * real binary, with the manifest on disk. The built-in microphone is the
 * device — present on every Mac this runs on, and the microphone grant is
 * the one a developer's shell already has. Skipped, not faked, when the
 * daemon says otherwise.
 */
it('arms the built-in microphone, records a take, and leaves a manifest and a file on disk', function () {
    $list = $this->client->streams();
    if (($list['permissions']['microphone'] ?? null) !== 'authorized') {
        $this->markTestSkipped('microphone not authorized for this shell: '.json_encode($list['permissions']));
    }
    $mic = collect($list['streams'])->firstWhere('id', 'microphone:BuiltInMicrophoneDevice');
    if (! $mic) {
        $this->markTestSkipped('no built-in microphone');
    }

    // Seen ~1 run in 2 with the step-6 core: arm or record never answers
    // and the daemon logs "SWIFT TASK CONTINUATION MISUSE … leaked its
    // continuation". That is the daemon's bug, not this client's; name it
    // rather than reporting a timeout.
    $hung = function (Unreachable $e) {
        $log = (string) @file_get_contents(sys_get_temp_dir()."/rheo-test-server-{$this->http}.log");
        $this->fail(str_contains($log, 'CONTINUATION MISUSE')
            ? "rheocles-core hung and leaked a continuation (Engine bug) — {$e->getMessage()}\n$log"
            : "the daemon did not answer: {$e->getMessage()}\n$log");
    };

    try {
        $armed = $this->client->arm($mic['id'], true);
    } catch (Unreachable $e) {
        $hung($e);
    }
    expect($armed['armed'])->toBeTrue()->and($armed)->toHaveKey('framesSeen');
    // Frames flow and are discarded while armed (spec §6); give it a moment.
    usleep(400_000);

    try {
        $created = $this->client->record(['name' => 'pest take', 'codec' => 'hevc']);
    } catch (Unreachable $e) {
        $hung($e);
    }
    $take = $created['take'];
    expect($take['state'])->toBe('recording')
        ->and($take['name'])->toBe('pest take')
        ->and($take['streams'])->toHaveCount(1)
        ->and($take['streams'][0]['codec'])->toBe('pcm_s24le')
        ->and($take['streams'][0]['events'][0])->toBe(['t' => 0, 'type' => 'join']);

    $marked = $this->client->mark($take['id'], 'slate');
    expect($marked['markers'][0]['label'])->toBe('slate')->and($marked['markers'][0]['t'])->toBeGreaterThanOrEqual(0);

    usleep(1_200_000);
    $final = $this->client->stop($take['id']);
    expect($final['state'])->toBe('complete')
        ->and($final['stopped'])->not->toBeNull()
        ->and($final['streams'][0]['framesWritten'])->toBeGreaterThan(0)
        ->and($final['streams'][0])->toHaveKeys(['timecode', 'timeReference']);

    // The manifest is the take (spec §2): on disk, under the output root,
    // agreeing with the answer; the file beside it.
    $folder = $this->dir.'/out/'.$final['destination'];
    $manifest = json_decode((string) file_get_contents("$folder/manifest.json"), true);
    expect($manifest['id'])->toBe($take['id'])
        ->and($manifest['state'])->toBe('complete')
        ->and($manifest['markers'][0]['label'])->toBe('slate')
        ->and(filesize("$folder/".$final['streams'][0]['path']))->toBeGreaterThan(44);  // more than a WAV header
    expect($this->client->take($take['id'])['state'])->toBe('complete')
        ->and($this->client->takes()[0]['id'])->toBe($take['id']);

    $this->client->arm($mic['id'], false);
});

it('reads and changes the daemon settings', function () {
    $before = $this->client->settings();
    expect($before)->toBe(['codec' => 'hevc', 'outputRoot' => $this->dir.'/out']);

    expect($this->client->updateSettings(['codec' => 'prores'])['codec'])->toBe('prores');
    $root = $this->dir.'/elsewhere';
    expect($this->client->updateSettings(['outputRoot' => $root])['outputRoot'])->toBe($root)
        ->and($this->client->discovery()['outputRoot'])->toBe($root);  // GET / reports the same root

    // A relative root is refused in the protocol's shape.
    expect(fn () => $this->client->updateSettings(['outputRoot' => 'relative']))->toThrow(Rejected::class);
});

it('rotates the token: the old one dies at once, the file has the new one', function () {
    $old = $this->token;
    $new = $this->client->rotateToken();
    expect($new)->not->toBe($old)->and(strlen($new))->toBe(64)
        ->and($this->client->token)->toBe($new)
        ->and(trim(file_get_contents($this->tokenFile)))->toBe($new);
    expect(fn () => (new Client('127.0.0.1', $this->http, $old))->discovery())->toThrow(Unauthorized::class);
    expect($this->client->discovery()['name'])->toBe('Rheocles');
});

/*
 * Preview, each kind on its own daemon: the current core leaks a Swift
 * continuation ("SWIFT TASK CONTINUATION MISUSE") and never answers when a
 * display preview follows a microphone preview, and sometimes on the first
 * device call after launch. Engine's bug; the third test names it.
 */
function hungPreview(Unreachable $e, int $port): never
{
    $log = (string) @file_get_contents(sys_get_temp_dir()."/rheo-test-server-$port.log");
    test()->fail(str_contains($log, 'CONTINUATION MISUSE')
        ? "rheocles-core hung on GET /preview and leaked a continuation (Engine bug) — {$e->getMessage()}\n$log"
        : "the daemon did not answer: {$e->getMessage()}\n$log");
}

it('previews video as one JPEG frame on demand', function () {
    $list = $this->client->streams();
    if (($list['permissions']['screen'] ?? null) !== 'authorized' || ! ($display = collect($list['streams'])->firstWhere('kind', 'display'))) {
        $this->markTestSkipped('needs a display and the Screen Recording grant');
    }
    try {
        $frame = $this->client->preview($display['id']);
    } catch (Unreachable $e) {
        hungPreview($e, $this->http);
    }
    expect($frame['contentType'])->toStartWith('image/jpeg')
        ->and(substr($frame['body'], 0, 3))->toBe("\xFF\xD8\xFF")
        ->and(strlen($frame['body']))->toBeGreaterThan(1000);
    expect(fn () => $this->client->preview('display:nope'))->toThrow(Rejected::class);
});

it('previews audio as a level', function () {
    $list = $this->client->streams();
    if (($list['permissions']['microphone'] ?? null) !== 'authorized' || ! ($mic = collect($list['streams'])->firstWhere('id', 'microphone:BuiltInMicrophoneDevice'))) {
        $this->markTestSkipped('needs the built-in microphone, authorized');
    }
    try {
        $sample = $this->client->preview($mic['id']);
    } catch (Unreachable $e) {
        hungPreview($e, $this->http);
    }
    expect($sample['contentType'])->toStartWith('application/json');
    $level = json_decode($sample['body'], true)['levelDb'] ?? null;
    expect($level)->toBeNumeric()->toBeLessThanOrEqual(0);  // silence is -120, an int
});

it('previews a display after a microphone (Engine: leaked continuation, 3 runs in 3)', function () {
    $list = $this->client->streams();
    $mic = collect($list['streams'])->firstWhere('id', 'microphone:BuiltInMicrophoneDevice');
    $display = collect($list['streams'])->firstWhere('kind', 'display');
    if (($list['permissions']['microphone'] ?? null) !== 'authorized' || ($list['permissions']['screen'] ?? null) !== 'authorized' || ! $mic || ! $display) {
        $this->markTestSkipped('needs the built-in microphone and a display, both authorized');
    }
    try {
        $this->client->preview($mic['id']);
        $frame = $this->client->preview($display['id']);
    } catch (Unreachable $e) {
        hungPreview($e, $this->http);
    }
    expect($frame['contentType'])->toStartWith('image/jpeg');
});

it('reads the event stream and yields null when the daemon is quiet', function () {
    $events = EventStream::read('127.0.0.1', $this->http, $this->token, idle: 0.3);
    $first = $events->current();  // `: connected` is a comment; nothing said → idle
    expect($first)->toBeNull();
});

it('refuses the event stream without a token', function () {
    expect(fn () => EventStream::read('127.0.0.1', $this->http, 'wrong')->current())->toThrow(Unauthorized::class);
});
