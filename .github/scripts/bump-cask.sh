#!/usr/bin/env bash
# Rewrite the version and sha256 of a Homebrew cask in place.
#
# The cask is hand-written rather than generated: it is one artifact with a
# zap stanza and caveats worth reading, and a generator would obscure that for
# no gain. Only two lines change per release, so only two lines are touched —
# and both are asserted afterwards, because a silent no-op here ships a cask
# that installs the previous version with a checksum that no longer matches.
set -euo pipefail

VERSION="${1:?usage: bump-cask.sh <version> <sha256> <cask-path>}"
SHA="${2:?missing sha256}"
CASK="${3:?missing cask path}"

VERSION="${VERSION#v}"

[ -f "$CASK" ] || { echo "bump-cask: no such cask: $CASK" >&2; exit 1; }
case "$SHA" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
  *) echo "bump-cask: sha256 does not look like a hex digest: $SHA" >&2; exit 1 ;;
esac
[ "${#SHA}" -eq 64 ] || { echo "bump-cask: sha256 must be 64 chars, got ${#SHA}" >&2; exit 1; }

perl -pi -e "s/^  version \"[^\"]*\"\$/  version \"$VERSION\"/" "$CASK"
perl -pi -e "s/^  sha256 \"[^\"]*\"\$/  sha256 \"$SHA\"/" "$CASK"

grep -qx "  version \"$VERSION\"" "$CASK" || { echo "bump-cask: version did not update" >&2; exit 1; }
grep -qx "  sha256 \"$SHA\"" "$CASK" || { echo "bump-cask: sha256 did not update" >&2; exit 1; }

echo "bump-cask: $CASK now at $VERSION / $SHA"
