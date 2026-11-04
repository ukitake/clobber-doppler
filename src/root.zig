const std = @import("std");
const Config = @import("config.zig").Config;
const Stft = @import("stft.zig").Stft;
const mask_mod = @import("mask.zig");

pub const fft = @import("fft.zig");
pub const config = @import("config.zig");
pub const stft = @import("stft.zig");
pub const mask = @import("mask.zig");

const DopplerScrub = struct {
    allocator: std.mem.Allocator,
    cfg: Config,
    stft_engine: Stft,
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
    const mask_bins = allocator.alloc(f32, cfg.fft_size / 2 + 1) catch {
        var s = stft_engine;
        s.deinit();
        allocator.destroy(self);
        return null;
    };
    mask_mod.fillBlankBand(mask_bins, cfg.sample_rate, cfg.fft_size, cfg.track_f_min_hz, cfg.track_f_max_hz);

    self.* = .{
        .allocator = allocator,
        .cfg = cfg,
        .stft_engine = stft_engine,
        .mask_bins = mask_bins,
        .flushing = false,
        .flush_hops_left = 0,
    };
    return self;
}

export fn doppler_scrub_destroy(h: ?*DopplerScrub) callconv(.C) void {
    const self = h orelse return;
    self.stft_engine.deinit();
    self.allocator.free(self.mask_bins);
    self.allocator.destroy(self);
}

fn processAvailableFrames(self: *DopplerScrub) void {
    while (self.stft_engine.analyzeFrame()) {
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
    _ = @import("stft.zig");
}

test "blank band removes 40-200 Hz and keeps a higher tone" {
    const allocator = std.testing.allocator;
    const sr: u32 = 16000;
    var cfg = Config.initDefaults(sr);
    cfg.fft_size = 2048;
    cfg.hop_size = 512;
    cfg.track_f_min_hz = 40;
    cfg.track_f_max_hz = 200;
    try cfg.validate();

    // Steady in-band tone plus a tone well above the blank.
    const n_samples: usize = sr * 2;
    const input = try allocator.alloc(f32, n_samples);
    defer allocator.free(input);
    var n: usize = 0;
    while (n < n_samples) : (n += 1) {
        const t = @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(sr));
        input[n] = @floatCast(0.6 * @sin(2.0 * std.math.pi * 120.0 * t) + 0.4 * @sin(2.0 * std.math.pi * 1000.0 * t));
    }

    var engine = try Stft.init(allocator, cfg);
    defer engine.deinit();
    const mask_bins = try allocator.alloc(f32, cfg.fft_size / 2 + 1);
    defer allocator.free(mask_bins);
    mask_mod.fillBlankBand(mask_bins, cfg.sample_rate, cfg.fft_size, cfg.track_f_min_hz, cfg.track_f_max_hz);

    try engine.pushInput(input);
    const pad = try allocator.alloc(f32, cfg.fft_size);
    defer allocator.free(pad);
    @memset(pad, 0);
    try engine.pushInput(pad);

    const output = try allocator.alloc(f32, n_samples + cfg.fft_size);
    defer allocator.free(output);
    @memset(output, 0);

    while (engine.analyzeFrame()) {
        mask_mod.applyMaskPreservePhase(engine.spectrum, cfg.fft_size, mask_bins, 1.0);
        try engine.synthesizeFrame();
    }
    const out_n = engine.popOutput(output);

    const latency = cfg.fft_size - cfg.hop_size;
    const region = sr / 2;
    try std.testing.expect(out_n > latency + region + 2048);
    const out_aligned = output[latency..];

    const in_lo = bandEnergy(input[region..], sr, 80, 160);
    const out_lo = bandEnergy(out_aligned[region..], sr, 80, 160);
    const in_hi = bandEnergy(input[region..], sr, 800, 1200);
    const out_hi = bandEnergy(out_aligned[region..], sr, 800, 1200);

    try std.testing.expect(out_lo < in_lo * 0.05);
    try std.testing.expect(out_hi > in_hi * 0.5);
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
