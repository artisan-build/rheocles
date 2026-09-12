# `release.yml` gates notarization on the .p8 alone

"Check for signing secrets" sets `notary=true` when `APPLE_API_KEY_P8` is
non-empty and ignores `APPLE_API_KEY_ID` / `APPLE_API_ISSUER_ID`. With the key
present and either ID missing, the run gets as far as `notarytool submit` and
fails there rather than skipping cleanly with a warning like the cert path
does. Inherited from Sonocles; low priority because all three are set in both
repos, but the check is three lines.
