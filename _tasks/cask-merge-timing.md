# Merge the tap PR only when the first release is imminent

`artisan-build/homebrew-tap#1` adds `Casks/rheocles.rb` at 0.0.0 with an
all-zero sha256. Once merged, `brew install --cask artisan-build/tap/rheocles`
fails with a URL/checksum error instead of "no cask found" — a worse message
for anyone who finds the tap early. Merge it right before the first `v*` tag,
so `bump-cask.sh` has a target and the broken window is minutes, not weeks.
