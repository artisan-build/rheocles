<?php

use App\Console\Commands\Watch;
use App\Rheocles\Client;
use App\Rheocles\Daemon;
use App\Rheocles\Failure\Failure;
use App\Rheocles\Token;
use Illuminate\Support\Facades\Route;
use Native\Desktop\Facades\App;

/*
 * The popover, and the clicks behind it.
 *
 * Note what is absent: any route carrying events or frames. The page holds
 * GET /events itself (brief, rule 2), and reads GET / from the daemon
 * directly on its pulse. PHP is here for what a person clicks and for the
 * one thing the page cannot see on its own — the daemon's lifecycle, which
 * rheo:watch publishes to a file.
 */

Route::get('/', function () {
    $client = Client::fromConfig();

    return view('menubar', [
        'daemon' => Daemon::published(),
        'base' => $client->base(),
        'events' => $client->eventsUrl(),
        'token' => $client->token,
        'tokenMasked' => Token::masked($client->token),
        'tokenFile' => Token::path(),
        'port' => $client->port,
    ]);
});

/* The daemon's condition, as the watcher last published it. */
Route::get('/daemon', fn () => response()->json(Daemon::published()));

/* The Relaunch button: lift the crash guard and try again. */
Route::post('/daemon/relaunch', function () {
    touch(Watch::relaunchFlag());

    return response()->json(['requested' => true]);
});

/*
 * Commands, one per protocol route, answered in the protocol's own shape
 * (status and { error, code }) so the page shows the daemon's words.
 */
$forward = function (\Closure $call) {
    try {
        return response()->json($call(Client::fromConfig()));
    } catch (Failure $e) {
        $status = $e instanceof App\Rheocles\Failure\Rejected ? $e->status
            : ($e instanceof App\Rheocles\Failure\Unauthorized ? 401 : 503);
        $code = $e instanceof App\Rheocles\Failure\Rejected ? $e->reason
            : ($e instanceof App\Rheocles\Failure\Unauthorized ? 'unauthorized' : 'unreachable');

        return response()->json(['error' => $e->getMessage(), 'code' => $code], $status);
    }
};

Route::get('/api/discovery', fn () => $forward(fn (Client $c) => $c->discovery()));

Route::post('/quit', function () {
    App::quit();

    return response()->json(['quitting' => true]);
});
