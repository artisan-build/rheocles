<?php

use App\Rheocles\Daemon;

/*
 * The popover's routes: the page and the daemon's published state. What
 * the page shows comes from GET /; PHP hands it the daemon's address, the
 * token for the event stream, and the watcher's word on the lifecycle.
 */

afterEach(fn () => @unlink(Daemon::stateFile()));

it('renders the popover with the daemon address and the event stream URL', function () {
    $tokenFile = tempnam(sys_get_temp_dir(), 'rheo-');
    file_put_contents($tokenFile, "abc123\n");
    config(['rheocles.token_file' => $tokenFile, 'rheocles.http_port' => 17447]);

    $this->get('/')
        ->assertOk()
        ->assertSee('Rheocles')
        ->assertSee('REE-oh-kleez')
        ->assertSee('http :17447 · loopback · bearer', false)
        ->assertSee('127.0.0.1:17447\\/events?access_token=abc123', false)
        ->assertSee('rheocles-core is being started');
    unlink($tokenFile);
});

it('reports launching until the watcher has published anything', function () {
    $this->getJson('/daemon')->assertOk()->assertJson(['status' => 'launching', 'ours' => false]);
});

it('reports what the watcher published', function () {
    @mkdir(dirname(Daemon::stateFile()), 0755, true);
    file_put_contents(Daemon::stateFile(), json_encode(['status' => 'down', 'why' => 'no rheocles-core beside the app', 'ours' => false, 'discovery' => null]));
    $this->getJson('/daemon')->assertOk()->assertJson(['status' => 'down', 'why' => 'no rheocles-core beside the app']);
});

it('leaves a relaunch flag for the watcher', function () {
    $this->postJson('/daemon/relaunch')->assertOk()->assertJson(['requested' => true]);
    expect(file_exists(App\Console\Commands\Watch::relaunchFlag()))->toBeTrue();
    unlink(App\Console\Commands\Watch::relaunchFlag());
});
