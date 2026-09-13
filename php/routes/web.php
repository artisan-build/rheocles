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
use Native\Desktop\Facades\Clipboard;
use Native\Desktop\Dialog;
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
$forward = function (\Closure $call, int $status = 200) {
    try {
        return response()->json($call(Client::fromConfig()), $status);
    } catch (Failure $e) {
        // Not `App\Rheocles\…` unqualified: `use …\Facades\App` above makes
        // that resolve under the facade's namespace, silently and to nothing.
        $status = $e instanceof Rejected ? $e->status : ($e instanceof Unauthorized ? 401 : 503);
        $code = $e instanceof Rejected ? $e->reason : ($e instanceof Unauthorized ? 'unauthorized' : 'unreachable');
        // The daemon's own words, not "404 not_found: …" twice over: the
        // page prefixes the status and code itself.
        $error = $e instanceof Rejected ? $e->error : $e->getMessage();

        return response()->json(['error' => $error, 'code' => $code], $status);
    }
};

Route::get('/api/discovery', fn () => $forward(fn (Client $c) => $c->discovery()));

/* Arm or disarm one stream (spec §6): device live or not, never a write. */
Route::post('/api/streams/{id}/arm', fn (Request $request, string $id) => $forward(
    fn (Client $c) => $c->arm($id, $request->boolean('armed'))
));

/*
 * Record: create and start in one — the popover's one button (spec §7).
 * The name is the user's; the codec is the daemon's default (its settings),
 * so no codec is sent — one setting for both front ends.
 */
Route::post('/api/record', fn (Request $request) => $forward(function (Client $c) use ($request) {
    $name = trim((string) $request->input('name', ''));

    return $c->record($name === '' ? [] : ['name' => $name]);
}, 201));

Route::post('/api/takes/{id}/stop', fn (string $id) => $forward(fn (Client $c) => $c->stop($id)));

/* Combine now: the single-file mux after the fact on a finished take (feature brief addendum). */
Route::post('/api/takes/{id}/combine', fn (string $id) => $forward(fn (Client $c) => $c->combine($id)));

/*
 * A marker is a label and the daemon's clock (spec §10): Rheocles knows
 * when, the client knows what. An empty label is named for its number.
 */
Route::post('/api/takes/{id}/markers', fn (Request $request, string $id) => $forward(function (Client $c) use ($request, $id) {
    $label = trim((string) $request->input('label', ''));
    if ($label === '') {
        $label = 'marker '.((int) $request->input('count', 0) + 1);
    }

    return $c->mark($id, $label);
}));

/*
 * Open in Finder (feature brief §1): the daemon reveals, never the app —
 * a browser front end cannot open the Finder, and two native front ends
 * should not do it twice. The take's folder with no `path`; one of its
 * files with `path`; the output root, or a path under it, from /api/reveal.
 * `204` through, as the daemon answers; a refusal in the daemon's words —
 * and a daemon too old to have the route says `no such route`, which the
 * page reads as "update Rheocles", not as a missing file.
 */
$reveal = fn (\Closure $call) => $forward(function (Client $c) use ($call) {
    $call($c);

    return [];
}, 204);
Route::post('/api/takes/{id}/reveal', fn (Request $request, string $id) => $reveal(function (Client $c) use ($request, $id) {
    $path = $request->input('path');
    $c->revealTake($id, is_string($path) && $path !== '' ? $path : null);
}));
Route::post('/api/reveal', fn (Request $request) => $reveal(function (Client $c) use ($request) {
    $path = $request->input('path');
    $c->reveal(is_string($path) ? $path : '');
}));

/* The daemon's settings (spec §12): output root, default codec, default combine. */
Route::get('/api/settings', fn () => $forward(fn (Client $c) => $c->settings()));
Route::patch('/api/settings', fn (Request $request) => $forward(
    fn (Client $c) => $c->updateSettings(array_intersect_key($request->all(), ['outputRoot' => 1, 'codec' => 1, 'combine' => 1]))
));

/* Change… : a native folder chooser, then PATCH. Cancel changes nothing. */
Route::post('/api/settings/choose-root', function () use ($forward) {
    $dialog = Dialog::new()->title('Output root')->button('Use as output root')->folders();
    $current = Client::fromConfig()->settings()['outputRoot'] ?? null;
    if (is_string($current)) {
        $dialog = $dialog->defaultPath($current);
    }
    $chosen = $dialog->open();
    $path = is_array($chosen) ? ($chosen[0] ?? null) : $chosen;
    if (! is_string($path) || $path === '') {
        return response()->json(['chosen' => null]);
    }

    return $forward(fn (Client $c) => $c->updateSettings(['outputRoot' => $path]));
});

/*
 * The pairing code. Copy goes through the native clipboard; rotate is the
 * daemon's call — it rewrites the file and the old token dies at once, for
 * every client including this one, which reads the file again on its next
 * page (the page reloads) and in the watcher on its next 401.
 */
Route::post('/api/token/copy', function () {
    $token = Token::read();
    abort_unless($token !== null, 503);
    Clipboard::text($token);

    return response()->json(['copied' => true]);
});
Route::post('/api/token/rotate', fn () => $forward(fn (Client $c) => ['token' => $c->rotateToken()]));

/* The app's own settings: show windows. */
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
