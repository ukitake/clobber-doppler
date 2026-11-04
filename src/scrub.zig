const std = @import("std");
const Config = @import("config.zig").Config;
const Stft = @import("stft.zig").Stft;
const Tracker = @import("tracker.zig").Tracker;
const mask_mod = @import("mask.zig");

/// Scrub one mono buffer. `dest.len` must equal `input.len`.
/// Output is latency-aligned to the input: `dest[i]` corresponds to `input[i]`.
pub fn scrubMono(allocator: std.mem.Allocator, input: []const f32, cfg: Config, dest: []f32) !void {
    std.debug.assert(dest.len == input.len);
    var engine = try Stft.init(allocator, cfg);
    defer engine.deinit();
    var ridge = try Tracker.init(allocator, cfg);
    defer ridge.deinit();
    const mask_bins = try allocator.alloc(f32, cfg.fft_size / 2 + 1);
    defer allocator.free(mask_bins);

    const hop: usize = cfg.hop_size;
    const hop_buf = try allocator.alloc(f32, hop);
    defer allocator.free(hop_buf);

    try engine.pushInput(input);

    // This OLA writes sample k at the same index as input k. The first and last
    // fft_size samples are the overlap fade; flush supplies the tail.
    var filled: usize = 0;
    while (engine.analyzeFrame()) {
        ridge.updateAndBuildMask(engine.spectrum, mask_bins);
        mask_mod.applyMaskPreservePhase(engine.spectrum, cfg.fft_size, mask_bins, cfg.wet);
        try engine.synthesizeFrame();
        filled = drain(&engine, hop_buf, dest, filled);
    }

    var h: u32 = 0;
    const flush_hops = (cfg.fft_size / cfg.hop_size) + 2;
    while (h < flush_hops and filled < dest.len) : (h += 1) {
        try engine.pushSilenceHop();
        while (engine.analyzeFrame()) {
            ridge.updateAndBuildMask(engine.spectrum, mask_bins);
            mask_mod.applyMaskPreservePhase(engine.spectrum, cfg.fft_size, mask_bins, cfg.wet);
            try engine.synthesizeFrame();
            filled = drain(&engine, hop_buf, dest, filled);
        }
    }
    if (filled < dest.len) @memset(dest[filled..], 0);
}

fn drain(engine: *Stft, hop_buf: []f32, dest: []f32, filled_in: usize) usize {
    var filled = filled_in;
    while (engine.outputAvailable() > 0) {
        const n = engine.popOutput(hop_buf);
        var i: usize = 0;
        while (i < n and filled < dest.len) : (i += 1) {
            dest[filled] = hop_buf[i];
            filled += 1;
        }
    }
    return filled;
}

test "wet zero reconstructs a tone" {
    const allocator = std.testing.allocator;
    const sr: u32 = 16000;
    var cfg = Config.initDefaults(sr);
    cfg.fft_size = 2048;
    cfg.hop_size = 512;
    cfg.wet = 0;
    try cfg.validate();

    const n: usize = sr;
    const input = try allocator.alloc(f32, n);
    defer allocator.free(input);
    for (input, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sr));
        s.* = 0.4 * @sin(2.0 * std.math.pi * 220.0 * t);
    }
    const output = try allocator.alloc(f32, n);
    defer allocator.free(output);
    try scrubMono(allocator, input, cfg, output);

    const margin = cfg.fft_size;
    var i: usize = margin;
    var worst: f32 = 0;
    while (i + margin < n) : (i += 1) {
        worst = @max(worst, @abs(output[i] - input[i]));
    }
    try std.testing.expect(worst < 1.0e-3);
}
