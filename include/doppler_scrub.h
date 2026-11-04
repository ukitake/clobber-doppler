#ifndef DOPPLER_SCRUB_H
#define DOPPLER_SCRUB_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DopplerScrub DopplerScrub;

typedef struct DopplerScrubConfig {
    uint32_t sample_rate;      /* Hz, e.g. 48000 */
    uint32_t fft_size;         /* power of two, default 8192 */
    uint32_t hop_size;         /* default fft_size/4 */
    float track_f_min_hz;      /* default 40 */
    float track_f_max_hz;      /* default 450 */
    uint32_t max_harmonics;    /* default 4 (fundamental + 3) */
    float mask_depth_db;       /* attenuation at ridge center, default 72 */
    float mask_half_width_hz;  /* notch half-width, default 18 */
    float wet;                 /* 0=dry 1=full scrub, default 1 */
    uint32_t max_tracks;       /* default 8 */
} DopplerScrubConfig;

/* Fill config with recommended Phase-1 defaults for sample_rate. */
void doppler_scrub_config_init(DopplerScrubConfig *cfg, uint32_t sample_rate);

DopplerScrub *doppler_scrub_create(const DopplerScrubConfig *cfg);
void doppler_scrub_destroy(DopplerScrub *h);

/*
 * Process interleaved mono float32 samples.
 * Consumes up to `in_frames` from `in`, writes up to `out_capacity` to `out`.
 * Returns number of output frames written. May buffer internally (STFT latency).
 */
size_t doppler_scrub_process(
    DopplerScrub *h,
    const float *in,
    size_t in_frames,
    float *out,
    size_t out_capacity);

/* Drain remaining OLA tail. Returns frames written. Call until returns 0. */
size_t doppler_scrub_flush(DopplerScrub *h, float *out, size_t out_capacity);

/* Introspection for hosts and tests. */
uint32_t doppler_scrub_fft_size(const DopplerScrub *h);
uint32_t doppler_scrub_hop_size(const DopplerScrub *h);
uint32_t doppler_scrub_sample_rate(const DopplerScrub *h);

#ifdef __cplusplus
}
#endif

#endif /* DOPPLER_SCRUB_H */
