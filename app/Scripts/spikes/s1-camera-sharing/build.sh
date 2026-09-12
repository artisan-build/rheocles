#!/bin/sh
# Builds the S1 spike as a bare executable with an embedded Info.plist, so the
# camera TCC prompt has a usage description to show even when no bundle is
# involved. Which process TCC actually attributes the request to depends on
# the host that launched it — see README.md.
set -eu
cd "$(dirname "$0")"
swiftc -O -o s1 main.swift \
  -framework AVFoundation -framework CoreMedia \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
echo "built ./s1"
