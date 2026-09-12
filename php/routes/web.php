<?php

use App\Console\Commands\Watch;
use App\Rheocles\Client;
use App\Rheocles\Daemon;
use App\Rheocles\Failure\Failure;
use App\Rheocles\Failure\Rejected;
use App\Rheocles\Failure\Unauthorized;
use App\Rheocles\Preferences;
use App\Rheocles\Token;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Route;
use Native\Desktop\Facades\App;
use Native\Desktop\Facades\MenuBar;
use Native\Desktop\Facades\Shell;

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
        'preferences' => Preferences::all(),
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
        // Not `App\Rheocles\…` unqualified: `use …\Facades\App` above makes
        // that resolve under the facade's namespace, silently and to nothing.
        $status = $e instanceof Rejected ? $e->status : ($e instanceof Unauthorized ? 401 : 503);
        $code = $e instanceof Rejected ? $e->reason : ($e instanceof Unauthorized ? 'unauthorized' : 'unreachable');

        return response()->json(['error' => $e->getMessage(), 'code' => $code], $status);
    }
};

Route::get('/api/discovery', fn () => $forward(fn (Client $c) => $c->discovery()));

/* Arm or disarm one stream (spec §6): device live or not, never a write. */
Route::post('/api/streams/{id}/arm', fn (Request $request, string $id) => $forward(
    fn (Client $c) => $c->arm($id, $request->boolean('armed'))
));

/* The app's own settings: show windows now, codec with the takes. */
Route::get('/api/preferences', fn () => response()->json(Preferences::all()));
Route::post('/api/preferences', fn (Request $request) => response()->json(Preferences::update($request->all())));

/*
 * The popover is content-sized, as the Swift one is: the page measures
 * itself and asks for the window to fit, up to the Swift popover's cap.
 */
Route::post('/api/resize', function (Request $request) {
    $height = max(160, min(720, (int) $request->input('height')));
    MenuBar::resize(344, $height);

    return response()->json(['height' => $height]);
});

/* A grant that is missing, and the one click that fixes it. */
Route::post('/api/privacy', function (Request $request) {
    $pane = $request->input('pane');
    abort_unless(in_array($pane, ['Privacy_ScreenCapture', 'Privacy_Camera', 'Privacy_Microphone'], true), 422);
    Shell::openExternal("x-apple.systempreferences:com.apple.preference.security?$pane");

    return response()->json(['opened' => $pane]);
});

Route::post('/quit', function () {
    App::quit();

    return response()->json(['quitting' => true]);
});
