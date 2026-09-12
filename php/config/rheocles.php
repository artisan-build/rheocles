<?php

/*
 * Where the daemon is and how it is launched. The app uses the defaults;
 * tests point these at a stub on a spare port (RHEOCLES_HTTP_PORT and
 * RHEOCLES_TOKEN_FILE), the way the Swift app's DaemonModel.Configuration is
 * overridden. Ports 7447/7448 are the protocol's (docs/PROTOCOL.md).
 */
return [
    'host' => '127.0.0.1',
    'http_port' => (int) env('RHEOCLES_HTTP_PORT', 7447),
    'ws_port' => (int) env('RHEOCLES_WS_PORT', 7448),

    // null → the daemon's own default path (see App\Rheocles\Token).
    'token_file' => env('RHEOCLES_TOKEN_FILE'),

    // null → the bundled sidecar (NATIVEPHP_EXTRAS_PATH/rheocles-core, or
    // php/extras/rheocles-core in development — see bin/sync-sidecar.sh).
    'core' => env('RHEOCLES_CORE'),

    // How long a launched core has to answer GET /, in seconds. A cold launch
    // answers well under one; ten is generous enough that a slow disk is not
    // reported as a crash.
    'launch_timeout' => (int) env('RHEOCLES_LAUNCH_TIMEOUT', 10),

    // Launches allowed within `crash_window` seconds before giving up.
    'crash_limit' => 3,
    'crash_window' => 60,

    // The pulse: how often the watcher re-probes while running, seconds.
    'pulse' => 3,
];
