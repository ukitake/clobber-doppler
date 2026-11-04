# Phase 1 — CLI Doppler scrub proof

Prove STFT Doppler-ridge scrubbing on static files with before/after spectrograms.

## Build

```bash
zig build
zig build test
```

Artifacts land in `zig-out/bin/doppler-cli` and `zig-out/lib/`.

## Synthetic fixtures

```bash
./zig-out/bin/doppler-cli gen-synthetic
./zig-out/bin/doppler-cli \
  --in testdata/synthetic/doppler_scurve_48k.wav \
  --out out/synthetic-scrubbed.wav \
  --spectrogram-dir out \
  --stem synthetic
```

## Showcase clip (gitignored media)

Primary YouTube source: `https://www.youtube.com/watch?v=4CxVxuMVkMc` (`4CxVxuMVkMc`).
Full download is ~1 hour; Phase 1 proof uses a 120 s mono 48 kHz excerpt around
the strongest ~40–450 Hz energy (`ffmpeg -ss 660 -t 120`).

```bash
# If yt-dlp hits YouTube bot-check, use a browser downloader then convert:
ffmpeg -y -i testdata/real/4CxVxuMVkMc.wav -ac 1 -ar 48000 testdata/real/full.wav
ffmpeg -y -ss 660 -t 120 -i testdata/real/full.wav testdata/real/showcase.wav

./zig-out/bin/doppler-cli \
  --in testdata/real/showcase.wav \
  --out out/showcase-scrubbed.wav \
  --spectrogram-dir out \
  --stem showcase
```

Do **not** commit anything under `testdata/real/` or `out/`.

## Core API

See `include/doppler_scrub.h`. Chunked real-time STFT with causal ridge tracking
(~40–450 Hz + harmonics), spectral mask, OLA reconstruct, phase preserved.
