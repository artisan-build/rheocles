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
if ($path === '/streams') {
    echo json_encode(['streams' => [], 'permissions' => ['camera' => 'authorized', 'microphone' => 'authorized', 'screen' => 'authorized']]);
    exit;
}
if ($path === '/takes') {
    echo json_encode([]);
    exit;
}
http_response_code(404);
echo json_encode(['error' => 'no such route', 'code' => 'not_found']);
