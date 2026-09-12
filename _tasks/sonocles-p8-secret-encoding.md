# Check Sonocles' `APPLE_API_KEY_P8` is base64, not the raw key

`release.yml` (both repos) decodes the secret with `echo "$APPLE_API_KEY_P8" |
base64 --decode`, and its header says "base64 of an App Store Connect .p8".
The Rheo Infra brief's task table said to pipe the raw file
(`gh secret set … < AuthKey.p8`). Rheocles was set base64-encoded to match the
workflow; the brief's table was wrong.

Open question: how was Sonocles' copy set? If raw, its notarize step fails at
`base64 --decode` on the next release. Verify before Sonocles' next `v*` tag —
the secret cannot be read back, so re-set it from
`sonocles/.signing/AuthKey_U6TKF5694F.p8` with `base64 -i … | tr -d '\n'`.
