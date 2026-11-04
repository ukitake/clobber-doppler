# OBS audio filter (deferred)

Phase 1 ships the shared Zig DSP core and CLI proof only.

This directory is a placeholder for a future OBS Studio audio filter that links
`libdoppler_scrub` via the C ABI in `include/doppler_scrub.h`
(`doppler_scrub_create` / `process` / `flush` / `destroy`).

No OBS plugin code in Phase 1.
