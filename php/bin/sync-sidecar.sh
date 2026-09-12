#!/usr/bin/env bash
# Put a freshly built rheocles-core where the app expects to find it.
#
# electron-builder copies `extras/` into Rheocles.app/Contents/extras, and the
# runtime hands PHP that location in NATIVEPHP_EXTRAS_PATH. In development the
# same variable points here, so one directory serves both and
# App\Rheocles\Daemon::binary() needs only one lookup.
#
# The binary is a build product and is not committed — see php/.gitignore.
# Build it with: swift build --package-path app -c release
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
built="$root/app/.build/release/rheocles-core"

if [[ ! -x "$built" ]]; then
  echo "no core at $built — run: swift build --package-path app -c release" >&2
  exit 1
fi

mkdir -p "$root/php/extras"
cp "$built" "$root/php/extras/rheocles-core"
echo "synced $(du -h "$root/php/extras/rheocles-core" | cut -f1) → php/extras/rheocles-core ($("$built" --version 2>/dev/null || echo 'version unknown'))"
