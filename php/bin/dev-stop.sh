#!/usr/bin/env bash
# Stop a `native:run` app the way Quit does — through Electron — so its child
# processes (the watcher, and the core if it is ours) go with it and nothing
# is orphaned on the port. Killing `native:run` itself instead leaves Electron
# running with a closed stdout: every write is an EPIPE, and each one used to
# be a modal "JavaScript error" dialog, then a stack trace in Rheocles-php.log
# (2 GB of them, once); src/main/index.js now notes it once and goes quiet.
set -euo pipefail
osascript -e 'tell application "System Events" to (every process whose name is "Electron")' >/dev/null 2>&1 || true
# Electron in development is not a named app, so signal the main process
# directly; SIGTERM lets Electron run its will-quit handlers, which stop the
# child processes. The npm/native:run parents exit when it does.
pgrep -f 'nativephp/electron/node_modules/electron/dist/Electron.app/Contents/MacOS/Electron' | xargs -r kill -TERM 2>/dev/null || true
for _ in $(seq 1 20); do
  pgrep -f 'nativephp/electron/node_modules/electron/dist/Electron.app/Contents/MacOS/Electron' >/dev/null || break
  sleep 0.5
done
pkill -f 'artisan native:run' 2>/dev/null || true
if pgrep -fl 'rheocles-core --http-port' ; then
  echo "a core is still running (above); it was not ours to stop, or Electron did not get to it" >&2
fi
echo stopped
