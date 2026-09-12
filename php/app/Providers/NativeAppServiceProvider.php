<?php

namespace App\Providers;

use Native\Desktop\Contracts\ProvidesPhpIni;
use Native\Desktop\Facades\ChildProcess;
use Native\Desktop\Facades\MenuBar;

class NativeAppServiceProvider implements ProvidesPhpIni
{
    /**
     * Executed once the native application has been booted.
     */
    public function boot(): void
    {
        // The daemon's keeper (app/Console/Commands/Watch.php): finds or
        // launches rheocles-core, follows its events, and keeps the menu bar
        // icon true while the popover is closed. One process, for the life
        // of the app; the runtime restarts it if it dies. Started before the
        // menu bar so the icon's first state is the daemon's, not a default.
        ChildProcess::artisan('rheo:watch', alias: 'rheo-watch', persistent: true);

        // No ->showDockIcon(), and that is the point: a menu bar app without
        // it hides the Dock icon, which is what LSUIElement buys the Swift
        // build (and the plist declares LSUIElement too, so the icon is never
        // shown and then withdrawn).
        //
        // The icon is a `...Template.png`: Electron reads only its alpha and
        // tints it for a light or dark menu bar, so it cannot render as the
        // wrong colour — including the wrong colour of "none at all", which
        // is the bug Sonocles' Swift app shipped. Idle is the mark at 40 %.
        MenuBar::create()
            ->icon(resource_path('menubar/rheoIdleTemplate.png'))
            ->tooltip('Rheocles')
            ->width(344)
            ->height(560)
            ->resizable(false)
            ->backgroundColor('#FAF2E4')
            ->url(url('/'));
    }

    /**
     * Return an array of php.ini directives to be set.
     */
    public function phpIni(): array
    {
        return [];
    }
}
