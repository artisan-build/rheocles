<?php
/*
 * A stub rheocles-core for the lifecycle tests: PHP's built-in server
 * answering GET / the way the daemon does (docs/PROTOCOL.md § GET /), with
 * the bearer check and the one error shape. Everything else is 404. The
 * token it expects is in the STUB_TOKEN environment variable.
 */
header('Connection: close');
header('Access-Control-Allow-Origin: *');
$expected = getenv('STUB_TOKEN') ?: 'stub-token';
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
$stateFile = getenv('STUB_STATE') ?: sys_get_temp_dir().'/rheo-stub-state.json';
$armed = is_file($stateFile) ? (json_decode((string) file_get_contents($stateFile), true) ?: []) : [];
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
            'codec' => isset($s['capabilities']['video']) ? ($body['codec'] ?? 'hevc') : 'pcm_s24le',
            'format' => $s['capabilities'], 'started' => $now, 'framesWritten' => 0,
            'events' => [['t' => 0, 'type' => 'join']],
        ], $set),
        'markers' => [], 'settings' => ['codec' => $body['codec'] ?? 'hevc'],
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
if ($path === '/takes') {
    echo json_encode($take ? [['id' => $take['id'], 'name' => $take['name'] ?? null, 'state' => $take['state'],
        'created' => $take['created'], 'destination' => $take['destination'], 'streams' => count($take['streams'])]] : []);
    exit;
}
http_response_code(404);
echo json_encode(['error' => 'no such route', 'code' => 'not_found']);
