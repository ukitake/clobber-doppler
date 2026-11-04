const std = @import("std");
const doppler = @import("doppler_scrub");
const wav = @import("wav.zig");
const spectrogram = @import("spectrogram.zig");

const Config = doppler.config.Config;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // argv0

    var in_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var spectrogram_dir: ?[]const u8 = null;
    var gen_synthetic: bool = false;
    var wet: f32 = 1.0;
    var fullband: bool = true;
    var stem_override: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--in")) {
            in_path = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--out")) {
            out_path = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--spectrogram-dir")) {
            spectrogram_dir = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--wet")) {
            const v = args.next() orelse return usage();
            wet = try std.fmt.parseFloat(f32, v);
        } else if (std.mem.eql(u8, arg, "--no-fullband")) {
            fullband = false;
        } else if (std.mem.eql(u8, arg, "--stem")) {
            stem_override = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "gen-synthetic")) {
            gen_synthetic = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return usage();
        } else {
            std.debug.print("unknown arg: {s}\n", .{arg});
            return usage();
        }
    }

    if (gen_synthetic) {
        try generateSynthetic(allocator);
        return;
    }

    const ip = in_path orelse return usage();
    const op = out_path orelse return usage();

    var audio = try wav.readFile(allocator, ip);
    defer audio.deinit();

    const mono = try wav.toMono(allocator, audio.samples, audio.channels);
    defer allocator.free(mono);

    var cfg = Config.initDefaults(audio.sample_rate);
    cfg.wet = wet;
    try cfg.validate();

    // Scrub via Zig API (same path as C ABI)
    const scrubbed = try scrubMono(allocator, mono, cfg);
    defer allocator.free(scrubbed);

    // Ensure out dir exists
    if (std.fs.path.dirname(op)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }
    try wav.writeFile(op, audio.sample_rate, 1, scrubbed);
    std.debug.print("wrote {s} ({d} samples @ {d} Hz)\n", .{ op, scrubbed.len, audio.sample_rate });

    if (spectrogram_dir) |sdir| {
        try std.fs.cwd().makePath(sdir);
        const stem = stem_override orelse blk: {
            const base = std.fs.path.basename(ip);
            if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| {
                break :blk base[0..dot];
            }
            break :blk base;
        };

        const before_zoom = try std.fmt.allocPrint(allocator, "{s}/{s}-before.png", .{ sdir, stem });
        defer allocator.free(before_zoom);
        const after_zoom = try std.fmt.allocPrint(allocator, "{s}/{s}-after.png", .{ sdir, stem });
        defer allocator.free(after_zoom);

        const fft_size = cfg.fft_size;
        const hop = cfg.hop_size;

        std.debug.print("spectrogram zoom 40-450 Hz...\n", .{});
        const peak_zoom = try spectrogram.peakPowerInBand(allocator, mono, audio.sample_rate, fft_size, hop, 40, 450);
        try spectrogram.writeSpectrogramPng(allocator, before_zoom, mono, audio.sample_rate, fft_size, hop, 40, 450, 1200, 480, peak_zoom);
        try spectrogram.writeSpectrogramPng(allocator, after_zoom, scrubbed, audio.sample_rate, fft_size, hop, 40, 450, 1200, 480, peak_zoom);
        std.debug.print("wrote {s}\nwrote {s}\n", .{ before_zoom, after_zoom });

        if (fullband) {
            const nyquist = @as(f32, @floatFromInt(audio.sample_rate)) * 0.5;
            const before_full = try std.fmt.allocPrint(allocator, "{s}/{s}-before-fullband.png", .{ sdir, stem });
            defer allocator.free(before_full);
            const after_full = try std.fmt.allocPrint(allocator, "{s}/{s}-after-fullband.png", .{ sdir, stem });
            defer allocator.free(after_full);
            const peak_full = try spectrogram.peakPowerInBand(allocator, mono, audio.sample_rate, fft_size, hop, 0, nyquist);
            try spectrogram.writeSpectrogramPng(allocator, before_full, mono, audio.sample_rate, fft_size, hop, 0, nyquist, 1200, 600, peak_full);
            try spectrogram.writeSpectrogramPng(allocator, after_full, scrubbed, audio.sample_rate, fft_size, hop, 0, nyquist, 1200, 600, peak_full);
            std.debug.print("wrote {s}\nwrote {s}\n", .{ before_full, after_full });
        }
    }
}

fn scrubMono(allocator: std.mem.Allocator, mono: []const f32, cfg: Config) ![]f32 {
    var engine = try doppler.stft.Stft.init(allocator, cfg);
    defer engine.deinit();
    var ridge = try doppler.tracker.Tracker.init(allocator, cfg);
    defer ridge.deinit();
    const mask_bins = try allocator.alloc(f32, cfg.fft_size / 2 + 1);
    defer allocator.free(mask_bins);

    // Stream in chunks to exercise chunked path
    const chunk: usize = cfg.hop_size;
    var offset: usize = 0;
    while (offset < mono.len) {
        const end = @min(offset + chunk, mono.len);
        try engine.pushInput(mono[offset..end]);
        while (engine.analyzeFrame()) {
            ridge.updateAndBuildMask(engine.spectrum, mask_bins);
            doppler.mask.applyMaskPreservePhase(engine.spectrum, cfg.fft_size, mask_bins, cfg.wet);
            try engine.synthesizeFrame();
        }
        offset = end;
    }
    // Flush
    var h: u32 = 0;
    const flush_hops = (cfg.fft_size / cfg.hop_size) + 2;
    while (h < flush_hops) : (h += 1) {
        try engine.pushSilenceHop();
        while (engine.analyzeFrame()) {
            ridge.updateAndBuildMask(engine.spectrum, mask_bins);
            doppler.mask.applyMaskPreservePhase(engine.spectrum, cfg.fft_size, mask_bins, cfg.wet);
            try engine.synthesizeFrame();
        }
    }

    const out_len = engine.output_fifo.items.len;
    const out = try allocator.alloc(f32, out_len);
    _ = engine.popOutput(out);
    // Trim to input length (drop STFT latency head approx by aligning)
    // Latency ≈ fft_size - hop; take first mono.len samples if available
    if (out.len <= mono.len) return out;
    const trimmed = try allocator.alloc(f32, mono.len);
    // Skip latency samples for better time align
    const latency = cfg.fft_size - cfg.hop_size;
    if (out.len > latency + mono.len) {
        @memcpy(trimmed, out[latency .. latency + mono.len]);
    } else if (out.len >= mono.len) {
        @memcpy(trimmed, out[0..mono.len]);
    } else {
        @memcpy(trimmed[0..out.len], out);
        @memset(trimmed[out.len..], 0);
    }
    allocator.free(out);
    return trimmed;
}

fn generateSynthetic(allocator: std.mem.Allocator) !void {
    try std.fs.cwd().makePath("testdata/synthetic");
    const sr: u32 = 48000;
    const dur_s: f32 = 4.0;
    const n: usize = @intFromFloat(dur_s * @as(f32, @floatFromInt(sr)));
    const samples = try allocator.alloc(f32, n);
    defer allocator.free(samples);

    var prng = std.Random.DefaultPrng.init(0xd0ff91e);
    const rand = prng.random();
    var ph0: f64 = 0;
    var ph1: f64 = 0;
    var ph2: f64 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(sr));
        // Aircraft-like slow Doppler S-curve through ~70–380 Hz
        const u = (t - dur_s * 0.5) / (dur_s * 0.28);
        const s = std.math.tanh(u);
        const f0 = 220.0 + 150.0 * s;
        const f1 = 2.0 * f0;
        const f2 = 3.0 * f0;
        ph0 += 2.0 * std.math.pi * f0 / @as(f64, @floatFromInt(sr));
        ph1 += 2.0 * std.math.pi * f1 / @as(f64, @floatFromInt(sr));
        ph2 += 2.0 * std.math.pi * f2 / @as(f64, @floatFromInt(sr));
        const noise = (rand.float(f32) * 2.0 - 1.0) * 0.04;
        // Mild speech-ish midband fluff
        const fluff = 0.08 * @sin(2.0 * std.math.pi * 900.0 * t + 0.3 * @sin(2.0 * std.math.pi * 3.0 * t));
        samples[i] = @floatCast(0.55 * @sin(ph0) + 0.28 * @sin(ph1) + 0.12 * @sin(ph2) + fluff + noise);
    }

    const path = "testdata/synthetic/doppler_scurve_48k.wav";
    try wav.writeFile(path, sr, 1, samples);
    std.debug.print("wrote {s}\n", .{path});

    // Also a quieter noise-only control
    i = 0;
    while (i < n) : (i += 1) {
        samples[i] = (rand.float(f32) * 2.0 - 1.0) * 0.05;
    }
    const path2 = "testdata/synthetic/noise_only_48k.wav";
    try wav.writeFile(path2, sr, 1, samples);
    std.debug.print("wrote {s}\n", .{path2});
}

fn usage() void {
    std.debug.print(
        \\doppler-cli — Phase 1 Doppler ridge scrubber
        \\
        \\Usage:
        \\  doppler-cli --in <wav> --out <wav> [--spectrogram-dir <dir>] [--wet 0..1] [--stem name]
        \\  doppler-cli gen-synthetic
        \\
    , .{});
}
