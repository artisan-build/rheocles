<?php

use App\Rheocles\IconState;

/*
 * The icon speaks for the daemon (spec §12): the same derivation as the
 * Swift app's MenuBarIcon.State.derive, so both menu bars agree.
 */

it('is idle unless the daemon is running', function () {
    expect(IconState::derive('launching', null, 3)->kind)->toBe(IconState::IDLE)
        ->and(IconState::derive('down', ['state' => 'recording'], 3)->kind)->toBe(IconState::IDLE);
});

it('is idle with nothing armed, armed with anything armed', function () {
    expect(IconState::derive('running', null, 0)->kind)->toBe(IconState::IDLE)
        ->and(IconState::derive('running', null, 1)->kind)->toBe(IconState::ARMED)
        ->and(IconState::derive('running', ['state' => 'complete'], 2)->kind)->toBe(IconState::ARMED);
});

it('does not believe a recording manifest with nothing armed — a dead daemon left it', function () {
    expect(IconState::derive('running', ['state' => 'recording', 'streams' => []], 0)->kind)->toBe(IconState::IDLE);
});

it('is recording when the daemon says a take is recording', function () {
    $state = IconState::derive('running', ['state' => 'recording', 'started' => '2026-09-12T04:04:33.347Z', 'streams' => []], 1);
    expect($state->kind)->toBe(IconState::RECORDING)
        ->and($state->lateJoined)->toBe([])
        ->and($state->name())->toBe('rheoRecording0000Template');
});

it('marks streams that joined more than a second after the cue as late', function () {
    $take = [
        'state' => 'recording',
        'started' => '2026-09-12T04:04:33.347Z',
        'streams' => [
            ['id' => 'a', 'started' => '2026-09-12T04:04:33.400Z'],  // on the cue
            ['id' => 'b', 'started' => '2026-09-12T04:08:33.347Z'],  // four minutes in
            ['id' => 'c'],                                             // never started
            ['id' => 'd', 'started' => '2026-09-12T04:04:35.000Z'],  // 1.65 s: late
            ['id' => 'e', 'started' => '2026-09-12T05:04:33.347Z'],  // fifth stream: no stroke
        ],
    ];
    $state = IconState::derive('running', $take, 5);
    expect($state->lateJoined)->toBe([1, 3])
        ->and($state->mask())->toBe('0101')
        ->and($state->name())->toBe('rheoRecording0101Template');
});

it('names one rendered file per state', function () {
    expect(IconState::idle()->name())->toBe('rheoIdleTemplate')
        ->and(IconState::armed()->name())->toBe('rheoArmedTemplate')
        ->and(IconState::recording([3, 0, 0, 9])->name())->toBe('rheoRecording1001Template');
    foreach ([IconState::idle(), IconState::armed(), IconState::recording([2])] as $state) {
        expect(file_exists(__DIR__.'/../../resources/menubar/'.$state->name().'.png'))->toBeTrue($state->name())
            ->and(file_exists(__DIR__.'/../../resources/menubar/'.$state->name().'@2x.png'))->toBeTrue();
    }
});

it('compares by kind and late set', function () {
    expect(IconState::recording([1])->equals(IconState::recording([1])))->toBeTrue()
        ->and(IconState::recording([1])->equals(IconState::recording([2])))->toBeFalse()
        ->and(IconState::armed()->equals(IconState::idle()))->toBeFalse();
});
