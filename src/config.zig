const std = @import("std");

/// Layout must match `DopplerScrubConfig` in include/doppler_scrub.h.
pub const Config = extern struct {
    sample_rate: u32 = 48000,
    fft_size: u32 = 8192,
    hop_size: u32 = 2048,
    track_f_min_hz: f32 = 40.0,
    track_f_max_hz: f32 = 200.0,
    max_harmonics: u32 = 4,
    mask_depth_db: f32 = 72.0,
    mask_half_width_hz: f32 = 18.0,
    wet: f32 = 1.0,
    max_tracks: u32 = 8,

    pub fn initDefaults(sample_rate: u32) Config {
        var c = Config{};
        c.sample_rate = sample_rate;
        c.fft_size = 8192;
        c.hop_size = c.fft_size / 4;
        return c;
    }

    pub fn validate(self: Config) !void {
        if (self.sample_rate < 8000) return error.InvalidSampleRate;
        if (!std.math.isPowerOfTwo(self.fft_size) or self.fft_size < 256) return error.InvalidFftSize;
        if (self.hop_size == 0 or self.hop_size > self.fft_size) return error.InvalidHopSize;
        if (self.track_f_min_hz <= 0 or self.track_f_max_hz <= self.track_f_min_hz) return error.InvalidTrackBand;
        if (self.max_harmonics == 0 or self.max_harmonics > 16) return error.InvalidHarmonics;
        if (self.max_tracks == 0 or self.max_tracks > 64) return error.InvalidMaxTracks;
        if (self.wet < 0.0 or self.wet > 1.0) return error.InvalidWet;
    }

    pub fn binHz(self: Config) f32 {
        return @as(f32, @floatFromInt(self.sample_rate)) / @as(f32, @floatFromInt(self.fft_size));
    }

    pub fn hzToBin(self: Config, hz: f32) usize {
        const b = hz / self.binHz();
        const max_bin = self.fft_size / 2;
        if (b <= 0) return 0;
        const rounded: usize = @intFromFloat(@round(b));
        return @min(rounded, max_bin);
    }
};
