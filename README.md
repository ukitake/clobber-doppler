# clobber-doppler

Strip aircraft Doppler ridges from audio so geolocation tools like DOPPLERGEIST fail.

**Phase 1:** Zig DSP core + C ABI + CLI that scrubs static audio and video files.
OBS and Android apps are deferred placeholders.

## Quick start

```bash
zig build
zig build test
./zig-out/bin/doppler-cli gen-synthetic
./zig-out/bin/doppler-cli \
  --in testdata/synthetic/doppler_scurve_48k.wav \
  --out out/synthetic-scrubbed.wav
```

See [docs/phase1.md](docs/phase1.md) for the showcase YouTube clip workflow.

## Layout

| Path | Role |
|------|------|
| `include/doppler_scrub.h` | C ABI |
| `src/` | STFT, FFT, ridge tracker, mask, OLA |
| `apps/cli/` | File scrubber |
| `apps/obs/` | Deferred |
| `apps/android/` | Deferred |
| `testdata/synthetic/` | Generated unit fixtures |
| `testdata/real/` | Gitignored real media |
| `out/` | Gitignored scrubbed audio |
| `third_party/pffft/` | Vendored FFTPACK-licensed FFT |
