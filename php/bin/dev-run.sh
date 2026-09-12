#!/usr/bin/env bash
# Run the app on the desktop from php/, in the background, output to a file.
#
# Clears compiled views first: NativePHP copies storage/ into the app's data
# directory at every launch, so a view compiled here (by anything run from
# this directory) shadows a newer source until it is deleted. Tests compile
# elsewhere (phpunit.xml, VIEW_COMPILED_PATH) for the same reason.
#
# `-v` is not optional: without it native:run swallows Electron's and PHP's
# output entirely. Stop with bin/dev-stop.sh, not pkill (see that script).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
log="${1:-/tmp/rheocles-php-native-run.log}"
rm -f storage/framework/views/*.php
nohup php artisan native:run --no-interaction -v > "$log" 2>&1 &
echo "native:run → $log (pid $!)"
