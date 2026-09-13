<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="csrf-token" content="{{ csrf_token() }}">
<title>Rheocles</title>
<link rel="stylesheet" href="{{ asset('popover.css') }}">
</head>
<body>
{{-- Header, a centre panel with exactly one state showing, controls beneath — the Swift popover's grid. --}}
<div class="top-rule"></div>

<header>
  {{-- The mark: strokes struck from one bar. site/src/components/Mark.astro's geometry, verbatim. --}}
  <svg class="mark" id="mark" viewBox="0 0 32 32" fill="none" stroke="currentColor" stroke-width="3.4" stroke-linecap="round" aria-hidden="true">
    <path id="mark-bar" d="M5 4 V28" />
    <circle id="mark-dot" cx="5" cy="30.2" r="2.3" fill="currentColor" stroke="none" hidden />
    <path class="stroke" d="M5 8.5 C 12 8, 20 9.2, 28 8.5" data-late="M13 8.5 C 18 8.3, 22 9.2, 28 8.5" data-cue="M5 8.5 C 12 8, 20 9.2, 28 8.5" />
    <path class="stroke" d="M5 14 C 11 13.6, 17 14.6, 22 14" data-late="M13 14 C 16 13.8, 19 14.6, 22 14" data-cue="M5 14 C 11 13.6, 17 14.6, 22 14" />
    <path class="stroke" d="M5 19.5 C 13 19, 19 20.2, 26 19.5" data-late="M13 19.5 C 17 19.2, 21 20.2, 26 19.5" data-cue="M5 19.5 C 13 19, 19 20.2, 26 19.5" />
    <path class="stroke" d="M5 25 C 10 24.7, 14 25.4, 18 25" data-late="M13 25 C 15 24.9, 16.5 25.4, 18 25" data-cue="M5 25 C 10 24.7, 14 25.4, 18 25" />
  </svg>
  <span class="wordmark">Rheocles</span>
  <span class="say">REE-oh-kleez</span>
  <span class="spacer"></span>
  <span class="pill" id="state" data-tone="launching"><i></i><span id="state-label">Launching</span></span>
  <button class="gear" id="gear" aria-label="Settings" aria-pressed="false">
    <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/></svg>
  </button>
</header>
<div class="rule"></div>

<main id="centre">
  {{-- Launching: nothing answered, the bundled core is being started. --}}
  <section class="panel" data-state="launching" id="panel-launching" hidden>
    <div class="kicker-row"><span class="kicker">daemon</span><span class="word" data-tone="launching">launching</span></div>
    <div class="pulse"><i></i><i></i><i></i></div>
    <p class="prose">Nothing answered on :{{ $port }}, so the bundled rheocles-core is being started.</p>
  </section>

  {{-- Down: not answering, not being relaunched, and why. --}}
  <section class="panel" data-state="down" id="panel-down" hidden>
    <div class="kicker-row"><span class="kicker">daemon</span><span class="word" data-tone="down">down</span></div>
    <p class="prose why" id="why"></p>
    <div class="down-foot">
      <button class="btn filled" id="relaunch">Relaunch</button>
      <span class="path" id="log-path"></span>
    </div>
  </section>

  {{-- Running: every stream with its arm switch, or the settings in its place; the take bar; GET / as a strip. --}}
  <section id="panel-running" hidden>
    <div class="streams" id="streams"></div>
    <div class="settings" id="settings" hidden></div>
    <div class="rule"></div>
    {{-- Record or Stop, the take's name, and the time since the cue (spec §12); markers while recording. --}}
    <div class="takebar" id="takebar">
      <div class="take-controls">
        <button class="btn oxide" id="record" disabled><i class="dot"></i>Record</button>
        <button class="btn oxide filled" id="stop" hidden><i class="square"></i>Stop</button>
        <span class="prose script" id="takebar-note" hidden>Arm a stream to record.</span>
        <input class="field" id="take-name" type="text" placeholder="take name" autocomplete="off" spellcheck="false" hidden>
        <span class="live" id="live" hidden>
          <span class="take-name" id="live-name">··</span>
          <span class="elapsed" id="live-elapsed">··:··</span>
          <span class="writing" id="live-writing">0 writing</span>
        </span>
        <span class="finished" id="finished" hidden><i class="dot"></i><span id="finished-text"></span></span>
        {{-- Beside the outcome: Open in Finder, the daemon's (POST /takes/{id}/reveal, the folder). --}}
        <span class="spacer" id="finished-spacer" hidden></span>
        <button class="finder" id="finished-finder" aria-label="Open in Finder" title="Open in Finder" hidden>@include('finder')</button>
      </div>
      <div class="take-markers" id="markers" hidden>
        <input class="field" id="marker-label" type="text" placeholder="marker label" autocomplete="off" spellcheck="false">
        <button class="btn" id="mark-button"><svg viewBox="0 0 24 24" fill="currentColor" width="8" height="8" aria-hidden="true"><path d="M4 2v20h2v-8h13l-3-5 3-5H6V2z"/></svg>Mark</button>
        <span class="spacer"></span>
        <span class="count" id="marker-count">no markers</span>
      </div>
      {{-- "Also save a single file": the daemon's settings.combine, shown only while at most one video stream is armed (feature brief §2). --}}
      <label class="check combine" id="combine-row" hidden>
        <input type="checkbox" id="combine"><span class="box"></span>
        <span class="text">Also save a single file</span>
        <span class="hint">combined.mov · no re-encode</span>
      </label>
      {{-- The single file after stop, from manifest.combined: pending, complete with its own Open in Finder, or failed with the
           reason — or, on a finished take with none that qualifies, the offer to write one now (POST /takes/{id}/combine). --}}
      <div class="combined" id="combined" hidden>
        <span class="pulse small" id="combined-pulse" hidden><i></i><i></i><i></i></span>
        <i class="dot" id="combined-dot"></i>
        <span class="text" id="combined-text"></span>
        <span class="note" id="combined-note"></span>
        <span class="spacer"></span>
        <button class="btn small" id="combine-now" hidden>Combine now</button>
        <button class="finder" id="combined-finder" aria-label="Open in Finder" title="Open in Finder" hidden>@include('finder')</button>
      </div>
      {{-- Recent takes, newest first, folded under the bar; each with the daemon's Open in Finder. --}}
      <div class="recent" id="recent" hidden>
        <button class="fold" id="recent-toggle" aria-expanded="false">
          <svg class="chevron" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9 6l6 6-6 6"/></svg>
          <span class="kicker">Recent takes</span>
          <span class="count" id="recent-count"></span>
        </button>
        <div class="recent-rows" id="recent-rows" hidden></div>
      </div>
    </div>
    <div class="strip">
      <div class="row"><i class="dot"></i><span class="bone" id="strip-version">rheocles-core ··</span><span>·</span><span id="strip-owner">··</span><span>·</span><span id="strip-free" class="absent">free ··</span></div>
      <div class="row root"><span>→</span><span id="strip-root">··</span></div>
    </div>
  </section>
</main>
<div class="rule"></div>

<footer>
  <div class="error" id="error"></div>
  <div class="foot-row">
    <span class="wire">http :{{ $port }} · loopback · bearer</span>
    <span class="spacer"></span>
    <button class="btn" id="quit">Quit</button>
  </div>
</footer>

<script>
  // What the page needs from PHP once: where the daemon is, and the token
  // for the event stream — loopback only, same user, the same thing the
  // pairing code shows in settings.
  window.RHEO = {
    base: @json($base),
    events: @json($events),
    token: @json($token),
    tokenFile: @json($tokenFile),
    daemon: @json($daemon),
    preferences: @json($preferences),
    home: @json(\App\Rheocles\Home::path()),
  };
</script>
<script type="module" src="{{ asset('js/popover.js') }}"></script>
</body>
</html>
