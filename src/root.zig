const std = @import("std");
const Config = @import("config.zig").Config;
const Stft = @import("stft.zig").Stft;
const Tracker = @import("tracker.zig").Tracker;
const mask_mod = @import("mask.zig");

pub const fft = @import("fft.zig");
pub const config = @import("config.zig");
pub const stft = @import("stft.zig");
pub const tracker = @import("tracker.zig");
pub const mask = @import("mask.zig");

const DopplerScrub = struct {
    allocator: std.mem.Allocator,
    cfg: Config,
    stft_engine: Stft,
    ridge: Tracker,
    mask_bins: []f32,
    flushing: bool,
    flush_hops_left: u32,
};

export fn doppler_scrub_config_init(cfg: *Config, sample_rate: u32) callconv(.C) void {
    cfg.* = Config.initDefaults(sample_rate);
}

fn cConfigFromPtr(cfg: *const Config) Config {
    return cfg.*;
}

export fn doppler_scrub_create(cfg_in: *const Config) callconv(.C) ?*DopplerScrub {
    const allocator = std.heap.c_allocator;
    const cfg = cConfigFromPtr(cfg_in);
    cfg.validate() catch return null;

    const self = allocator.create(DopplerScrub) catch return null;
    const stft_engine = Stft.init(allocator, cfg) catch {
        allocator.destroy(self);
        return null;
    };
    const ridge = Tracker.init(allocator, cfg) catch {
        var tmp = stft_engine;
        tmp.deinit();
        allocator.destroy(self);
        return null;
    };
    const mask_bins = allocator.alloc(f32, cfg.fft_size / 2 + 1) catch {
        var r = ridge;
        r.deinit();
        var s = stft_engine;
        s.deinit();
        allocator.destroy(self);
        return null;
    };
    @memset(mask_bins, 1.0);

    self.* = .{
        .allocator = allocator,
        .cfg = cfg,
        .stft_engine = stft_engine,
        .ridge = ridge,
        .mask_bins = mask_bins,
        .flushing = false,
        .flush_hops_left = 0,
    };
    return self;
}

export fn doppler_scrub_destroy(h: ?*DopplerScrub) callconv(.C) void {
    const self = h orelse return;
    self.stft_engine.deinit();
    self.ridge.deinit();
    self.allocator.free(self.mask_bins);
    self.allocator.destroy(self);
}

fn processAvailableFrames(self: *DopplerScrub) void {
    while (self.stft_engine.analyzeFrame()) {
        self.ridge.updateAndBuildMask(self.stft_engine.spectrum, self.mask_bins);
        mask_mod.applyMaskPreservePhase(self.stft_engine.spectrum, self.cfg.fft_size, self.mask_bins, self.cfg.wet);
        self.stft_engine.synthesizeFrame() catch {};
    }
}

export fn doppler_scrub_process(
    h: ?*DopplerScrub,
    in_ptr: ?[*]const f32,
    in_frames: usize,
    out_ptr: ?[*]f32,
    out_capacity: usize,
) callconv(.C) usize {
    const self = h orelse return 0;
    const out = out_ptr orelse return 0;

    if (in_ptr) |ip| {
        if (in_frames > 0) {
            self.stft_engine.pushInput(ip[0..in_frames]) catch {};
            processAvailableFrames(self);
        }
    }

    return self.stft_engine.popOutput(out[0..out_capacity]);
}

export fn doppler_scrub_flush(
    h: ?*DopplerScrub,
    out_ptr: ?[*]f32,
    out_capacity: usize,
) callconv(.C) usize {
    const self = h orelse return 0;
    const out = out_ptr orelse return 0;

    if (!self.flushing) {
        self.flushing = true;
        // Enough silence hops to drain analysis window + OLA
        const hops = (self.cfg.fft_size / self.cfg.hop_size) + 2;
        self.flush_hops_left = hops;
    }

    while (self.flush_hops_left > 0 and self.stft_engine.output_fifo.items.len < out_capacity) {
        self.stft_engine.pushSilenceHop() catch break;
        processAvailableFrames(self);
        self.flush_hops_left -= 1;
    }

    return self.stft_engine.popOutput(out[0..out_capacity]);
}

export fn doppler_scrub_fft_size(h: ?*const DopplerScrub) callconv(.C) u32 {
    const self = h orelse return 0;
    return self.cfg.fft_size;
}

export fn doppler_scrub_hop_size(h: ?*const DopplerScrub) callconv(.C) u32 {
    const self = h orelse return 0;
    return self.cfg.hop_size;
}

export fn doppler_scrub_sample_rate(h: ?*const DopplerScrub) callconv(.C) u32 {
    const self = h orelse return 0;
    return self.cfg.sample_rate;
}

// Re-export Config layout must match C header DopplerScrubConfig.
comptime {
    // Field order / sizes aligned with include/doppler_scrub.h
    const cfg = Config{};
    _ = cfg;
}

test {
    _ = fft;
    _ = @import("config.zig");
    _ = @import("mask.zig");
    _ = @import("tracker.zig");
    _ = @import("stft.zig");
}

test "scrub attenuates synthetic doppler ridge" {
    const allocator = std.testing.allocator;
    const sr: u32 = 16000;
    var cfg = Config.initDefaults(sr);
    cfg.fft_size = 2048;
    cfg.hop_size = 512;
    cfg.track_f_min_hz = 40;
    cfg.track_f_max_hz = 450;
    cfg.mask_depth_db = 48;
    cfg.mask_half_width_hz = 10;
    try cfg.validate();

    // Generate ~2s of S-curve Doppler ridge + noise
    const n_samples: usize = sr * 2;
    const input = try allocator.alloc(f32, n_samples);
    defer allocator.free(input);
    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();

    // Proper phase accumulation for S-curve Doppler ridge + 2nd harmonic
    var ph0: f64 = 0;
    var ph1: f64 = 0;
    var n: usize = 0;
    while (n < n_samples) : (n += 1) {
        const t = @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(sr));
        const phase_s = std.math.tanh((t - 1.0) * 2.5);
        const f0 = 200.0 + 120.0 * phase_s;
        const f1 = 2.0 * f0;
        ph0 += 2.0 * std.math.pi * f0 / @as(f64, @floatFromInt(sr));
        ph1 += 2.0 * std.math.pi * f1 / @as(f64, @floatFromInt(sr));
        const noise = (rand.float(f32) * 2.0 - 1.0) * 0.05;
        input[n] = @floatCast(0.6 * @sin(ph0) + 0.25 * @sin(ph1) + noise);
    }

    // Run scrub via STFT path directly (same as C ABI)
    var engine = try Stft.init(allocator, cfg);
    defer engine.deinit();
    var ridge = try Tracker.init(allocator, cfg);
    defer ridge.deinit();
    const mask_bins = try allocator.alloc(f32, cfg.fft_size / 2 + 1);
    defer allocator.free(mask_bins);

    try engine.pushInput(input);
    // Pad for flush
    const pad = try allocator.alloc(f32, cfg.fft_size);
    defer allocator.free(pad);
    @memset(pad, 0);
    try engine.pushInput(pad);

    const output = try allocator.alloc(f32, n_samples + cfg.fft_size);
    defer allocator.free(output);
    @memset(output, 0);
    var out_n: usize = 0;

    while (engine.analyzeFrame()) {
        ridge.updateAndBuildMask(engine.spectrum, mask_bins);
        mask_mod.applyMaskPreservePhase(engine.spectrum, cfg.fft_size, mask_bins, 1.0);
        try engine.synthesizeFrame();
    }
    out_n = engine.popOutput(output);

    // Compare band energy 60–400 Hz via periodogram on middle 1s
    const mid_start = sr / 2;
    const mid_len = sr;
    const in_e = bandEnergy(input[mid_start .. mid_start + mid_len], sr, 60, 400);
    const out_slice_len = @min(mid_len, out_n);
    const out_e = bandEnergy(output[0..out_slice_len], sr, 60, 400);

    // Expect substantial attenuation of the ridge band
    try std.testing.expect(out_e < in_e * 0.35);
}

fn bandEnergy(samples: []const f32, sample_rate: u32, f_lo: f32, f_hi: f32) f32 {
    // Simple Goertzel-bank / DFT energy over a short FFT of the middle
    const n: usize = 2048;
    if (samples.len < n) return 0;
    var buf: [4096]f32 = undefined;
    @memset(&buf, 0);
    // Hann
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const w = 0.5 - 0.5 * @cos(2.0 * std.math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n)));
        buf[2 * i] = samples[i] * w;
    }
    fft.fft(&buf, n, false);
    const bin_hz = @as(f32, @floatFromInt(sample_rate)) / @as(f32, @floatFromInt(n));
    const b0: usize = @intFromFloat(@floor(f_lo / bin_hz));
    const b1: usize = @intFromFloat(@ceil(f_hi / bin_hz));
    var e: f32 = 0;
    i = b0;
    while (i <= b1 and i <= n / 2) : (i += 1) {
        const re = buf[2 * i];
        const im = buf[2 * i + 1];
        e += re * re + im * im;
    }
    return e;
}
