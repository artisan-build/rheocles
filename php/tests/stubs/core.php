<?php
/*
 * A stub rheocles-core for the lifecycle tests: PHP's built-in server
 * answering GET / the way the daemon does (docs/PROTOCOL.md § GET /), with
 * the bearer check and the one error shape. Everything else is 404. The
 * token it expects is in the STUB_TOKEN environment variable.
 */
header('Connection: close');
header('Access-Control-Allow-Origin: *');
$stateFile = getenv('STUB_STATE') ?: sys_get_temp_dir().'/rheo-stub-state.json';
$armed = is_file($stateFile) ? (json_decode((string) file_get_contents($stateFile), true) ?: []) : [];
$expected = $armed['__token'] ?? (getenv('STUB_TOKEN') ?: 'stub-token');
$given = $_SERVER['HTTP_AUTHORIZATION'] ?? '';
$path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);

if ($given !== "Bearer $expected") {
    http_response_code(401);
    header('WWW-Authenticate: Bearer realm="Rheocles"');
    header('Content-Type: application/json');
    echo json_encode(['error' => 'missing or invalid bearer token', 'code' => 'unauthorized']);
    exit;
}

header('Content-Type: application/json');
if ($path === '/') {
    echo json_encode([
        'name' => 'Rheocles', 'version' => 'stub', 'hostname' => 'stub.local',
        'machineId' => '00000000-0000-0000-0000-000000000000',
        'outputRoot' => '/tmp/rheocles-stub', 'freeBytes' => 123456789,
        'auth' => 'bearer', 'ports' => ['http' => (int) $_SERVER['SERVER_PORT'], 'ws' => 0],
    ]);
    exit;
}
/*
 * Streams, with armed state kept in STUB_STATE (a JSON file) so a POST
 * changes what the next GET says — the built-in server is one process per
 * request. Three streams, one per shape: a display, a camera the stub
 * refuses (403, as macOS would), a microphone.
 */
$streams = [
    ['id' => 'display:STUB-1', 'kind' => 'display', 'name' => 'Stub Display', 'model' => 'vendor 1 model 1',
        'capabilities' => ['video' => ['width' => 1920, 'height' => 1080, 'maxFrameRate' => 60]]],
    ['id' => 'camera:stub', 'kind' => 'camera', 'name' => 'Stub Camera', 'model' => 'UVC Stub',
        'capabilities' => ['video' => ['width' => 1280, 'height' => 720, 'maxFrameRate' => 30]]],
    ['id' => 'microphone:stub', 'kind' => 'microphone', 'name' => 'Stub Mic', 'model' => 'Stub:1:1',
        'capabilities' => ['audio' => ['sampleRate' => 48000, 'channels' => 2]]],
];
$withState = function (array $s) use (&$armed) {
    $s['armed'] = (bool) ($armed[$s['id']] ?? false);
    if (! is_bool($s['armed'])) {
        $s['armed'] = false;
    }
    if ($s['armed']) {
        $s['active'] = $s['capabilities'];
        $s['framesSeen'] = 0;
    }

    return $s;
};
if ($path === '/streams') {
    echo json_encode(['streams' => array_map($withState, $streams),
        'permissions' => ['camera' => 'denied', 'microphone' => 'authorized', 'screen' => 'authorized']]);
    exit;
}
if (preg_match('~^/streams/([^/]+)/arm$~', $path, $m) && $_SERVER['REQUEST_METHOD'] === 'POST') {
    $id = rawurldecode($m[1]);
    $body = json_decode((string) file_get_contents('php://input'), true);
    if (! is_array($body) || ! array_key_exists('armed', $body) || ! is_bool($body['armed'])) {
        http_response_code(400);
        echo json_encode(['error' => 'body must be { "armed": true|false }', 'code' => 'bad_request']);
        exit;
    }
    $found = array_values(array_filter($streams, fn ($s) => $s['id'] === $id));
    if ($found === []) {
        http_response_code(404);
        echo json_encode(['error' => "no such stream: $id", 'code' => 'not_found']);
        exit;
    }
    if ($id === 'camera:stub' && $body['armed']) {
        http_response_code(403);
        echo json_encode(['error' => 'camera access denied by macOS', 'code' => 'permission_denied']);
        exit;
    }
    $armed[$id] = $body['armed'];
    file_put_contents($stateFile, json_encode($armed));
    echo json_encode($withState($found[0]));
    exit;
}
/*
 * Takes: one at a time, kept in the same state file. /record snapshots the
 * armed set and answers a manifest that is recording; /stop completes it;
 * /markers appends { t, label }. Enough shape for the popover's routes and
 * the icon; the real thing is exercised against the binary in ClientTest.
 */
$take = $armed['__take'] ?? null;
$settings = $armed['__settings'] ?? ['outputRoot' => '/tmp/rheocles-stub', 'codec' => 'hevc'];
$saveTake = function (?array $t) use (&$armed, $stateFile) {
    $armed['__take'] = $t;
    file_put_contents($stateFile, json_encode($armed));
};
$manifest = fn (array $t) => $t;
if ($path === '/record' && $_SERVER['REQUEST_METHOD'] === 'POST') {
    $body = json_decode((string) file_get_contents('php://input'), true) ?: [];
    if ($take && $take['state'] === 'recording') {
        http_response_code(409);
        echo json_encode(['error' => "a take is recording: {$take['id']}", 'code' => 'take_active']);
        exit;
    }
    $set = array_values(array_filter(array_map($withState, $streams), fn ($s) => $s['armed'] && $s['id'] !== '__take'));
    if ($set === []) {
        http_response_code(400);
        echo json_encode(['error' => 'no streams are armed', 'code' => 'bad_request']);
        exit;
    }
    $now = gmdate('Y-m-d\TH:i:s').'.000Z';
    $take = [
        'id' => gmdate('Ymd\THis').'-stub', 'state' => 'recording', 'created' => $now, 'started' => $now,
        'outputRoot' => '/tmp/rheocles-stub', 'destination' => 'takes/stub', 'version' => 'stub',
        'machine' => ['hostname' => 'stub.local', 'machineId' => '00000000-0000-0000-0000-000000000000'],
        'streams' => array_map(fn ($s) => [
            'id' => $s['id'], 'kind' => $s['kind'], 'name' => $s['name'], 'model' => $s['model'],
            'path' => strtolower(str_replace(' ', '-', $s['name'])).(isset($s['capabilities']['video']) ? '.mov' : '.wav'),
            'codec' => isset($s['capabilities']['video']) ? ($body['codec'] ?? $settings['codec']) : 'pcm_s24le',
            'format' => $s['capabilities'], 'started' => $now, 'framesWritten' => 0,
            'events' => [['t' => 0, 'type' => 'join']],
        ], $set),
        'markers' => [], 'settings' => ['codec' => $body['codec'] ?? $settings['codec']],
    ];
    if (isset($body['name'])) {
        $take['name'] = $body['name'];
    }
    $saveTake($take);
    http_response_code(201);
    echo json_encode(['take' => $take, 'warnings' => []]);
    exit;
}
if (preg_match('~^/takes/([^/]+)/(stop|markers)$~', $path, $m) && $_SERVER['REQUEST_METHOD'] === 'POST') {
    if (! $take || $take['id'] !== rawurldecode($m[1])) {
        http_response_code(404);
        echo json_encode(['error' => 'no such take', 'code' => 'not_found']);
        exit;
    }
    if ($take['state'] !== 'recording') {
        http_response_code(409);
        echo json_encode(['error' => 'the take is not recording', 'code' => 'conflict']);
        exit;
    }
    if ($m[2] === 'markers') {
        $body = json_decode((string) file_get_contents('php://input'), true) ?: [];
        if (trim((string) ($body['label'] ?? '')) === '') {
            http_response_code(400);
            echo json_encode(['error' => 'label required', 'code' => 'bad_request']);
            exit;
        }
        $take['markers'][] = ['t' => round(count($take['markers']) * 1.5 + 0.5, 3), 'label' => $body['label']];
    } else {
        $take['state'] = 'complete';
        $take['stopped'] = gmdate('Y-m-d\TH:i:s').'.000Z';
        foreach ($take['streams'] as &$s) {
            $s['stopped'] = $take['stopped'];
            $s['framesWritten'] = 96000;
            $s['events'][] = ['t' => 2, 'type' => 'leave'];
        }
        unset($s);
    }
    $saveTake($take);
    echo json_encode($take);
    exit;
}
if (preg_match('~^/takes/([^/]+)$~', $path, $m)) {
    if (! $take || $take['id'] !== rawurldecode($m[1])) {
        http_response_code(404);
        echo json_encode(['error' => 'no such take', 'code' => 'not_found']);
        exit;
    }
    echo json_encode($take);
    exit;
}
/*
 * Settings, token rotation and preview (PROTOCOL § Settings, § Token
 * rotation, § Preview). The rotated token goes into the state file and the
 * token file the test names in STUB_TOKEN_FILE, as the daemon rewrites its own.
 */
if ($path === '/settings') {
    if ($_SERVER['REQUEST_METHOD'] === 'PATCH') {
        $body = json_decode((string) file_get_contents('php://input'), true) ?: [];
        if (isset($body['outputRoot'])) {
            if ($take && in_array($take['state'], ['created', 'recording'], true)) {
                http_response_code(409);
                echo json_encode(['error' => 'the output root cannot move while a take is active', 'code' => 'conflict']);
                exit;
            }
            if (! str_starts_with((string) $body['outputRoot'], '/')) {
                http_response_code(400);
                echo json_encode(['error' => 'outputRoot must be absolute', 'code' => 'bad_request']);
                exit;
            }
            $settings['outputRoot'] = $body['outputRoot'];
        }
        if (isset($body['codec'])) {
            if (! in_array($body['codec'], ['hevc', 'prores'], true)) {
                http_response_code(400);
                echo json_encode(['error' => 'codec must be hevc or prores', 'code' => 'bad_request']);
                exit;
            }
            $settings['codec'] = $body['codec'];
        }
        $armed['__settings'] = $settings;
        file_put_contents($stateFile, json_encode($armed));
    }
    echo json_encode($settings);
    exit;
}
if ($path === '/token/rotate' && $_SERVER['REQUEST_METHOD'] === 'POST') {
    $new = bin2hex(random_bytes(32));
    $armed['__token'] = $new;
    file_put_contents($stateFile, json_encode($armed));
    if ($f = getenv('STUB_TOKEN_FILE')) {
        file_put_contents($f, $new."\n");
    }
    echo json_encode(['token' => $new]);
    exit;
}
if (preg_match('~^/preview/([^/]+)$~', $path, $m)) {
    $id = rawurldecode($m[1]);
    $found = array_values(array_filter($streams, fn ($s) => $s['id'] === $id));
    if ($found === []) {
        http_response_code(404);
        echo json_encode(['error' => "no such stream: $id", 'code' => 'not_found']);
        exit;
    }
    if (isset($found[0]['capabilities']['audio'])) {
        echo json_encode(['levelDb' => -18.3]);
        exit;
    }
    if ($id === 'camera:stub') {
        http_response_code(503);
        echo json_encode(['error' => 'the device delivered no frame', 'code' => 'no_frame']);
        exit;
    }
    header('Content-Type: image/jpeg');
    // The smallest JPEG that decodes: 1×1, from a well-known minimal encoding.
    echo base64_decode('/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=');
    exit;
}
if ($path === '/takes') {
    echo json_encode($take ? [['id' => $take['id'], 'name' => $take['name'] ?? null, 'state' => $take['state'],
        'created' => $take['created'], 'destination' => $take['destination'], 'streams' => count($take['streams'])]] : []);
    exit;
}
http_response_code(404);
echo json_encode(['error' => 'no such route', 'code' => 'not_found']);
