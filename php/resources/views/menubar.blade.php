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
    <path d="M5 4 V28" />
    <path d="M5 8.5 C 12 8, 20 9.2, 28 8.5" />
    <path d="M5 14 C 11 13.6, 17 14.6, 22 14" />
    <path d="M5 19.5 C 13 19, 19 20.2, 26 19.5" />
    <path d="M5 25 C 10 24.7, 14 25.4, 18 25" />
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

  {{-- Running: GET / as a list (task 1); the stream list takes this place in task 2. --}}
  <section id="panel-running" hidden>
    <div class="discovery" id="discovery"></div>
    <div class="rule"></div>
    <div class="takebar"><span class="prose" style="color:var(--script)">Arm a stream to record.</span></div>
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
    daemon: @json($daemon),
    home: @json(\App\Rheocles\Home::path()),
  };
</script>
<script type="module" src="{{ asset('js/popover.js') }}"></script>
</body>
</html>
