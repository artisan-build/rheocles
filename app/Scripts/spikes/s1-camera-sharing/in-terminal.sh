#!/bin/sh
# Launches a command in a new Apple Terminal window and returns at once.
# The spike must run under Terminal, not under the agent's own host: camera
# TCC attributes a bare executable to the process that launched it, and
# Terminal carries NSCameraUsageDescription (and was granted) while the
# agent host does not. Output goes to the given log file; callers poll it.
# osascript -> System Events, on the other hand, needs Accessibility, which
# Terminal lacks and the agent host has — so QuickTime is driven from the
# caller, not from inside the Terminal window.
set -eu
cmd="$1"; logfile="$2"
rm -f "$logfile"
osascript -e "tell application \"Terminal\" to do script \"cd $(pwd) && $cmd 2>&1 | tee $logfile; exit\"" >/dev/null
