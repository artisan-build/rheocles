# obs-websocket compatibility

**Deferred (spec §11, §17): neither designed in nor designed out.** Rheocles
speaks its own protocol (`docs/PROTOCOL.md`), HTTP+SSE and WebSocket, one
dispatcher. An obs-websocket-compatible surface — so tools that already drive
OBS could start/stop a Rheocles take — is a possible later addition.

**Shape it would take.** A second `Transport`/dispatcher adapter that maps
obs-websocket's 5.x request/event JSON onto the existing command table
(`StartRecord`/`StopRecord` → `/record` + `/takes/{id}/stop`, `GetRecordStatus`
→ the manifest, its Hello/Identify handshake → the bearer token). It reuses
the one command table by construction, so nothing in the engine changes; it
is purely a wire-format translation on its own port.

Not built. Only worth doing if a concrete tool needs it.
