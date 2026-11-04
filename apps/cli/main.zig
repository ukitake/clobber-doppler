const std = @import("std");
const wav = @import("wav.zig");
const pipeline = @import("pipeline.zig");

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var in_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var gen_synthetic: bool = false;
    var wet: f32 = 1.0;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--in")) {
            in_path = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--out")) {
            out_path = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--wet")) {
            const v = args.next() orelse return usage();
            wet = try std.fmt.parseFloat(f32, v);
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
    const wrote = try pipeline.scrubFile(allocator, ip, op, wet);
    std.debug.print("wrote {s} ({d} frames, {d} ch @ {d} Hz)\n", .{ op, wrote.frames, wrote.channels, wrote.sample_rate });
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
        const u = (t - dur_s * 0.5) / (dur_s * 0.28);
        const s = std.math.tanh(u);
        const f0 = 220.0 + 150.0 * s;
        const f1 = 2.0 * f0;
        const f2 = 3.0 * f0;
        ph0 += 2.0 * std.math.pi * f0 / @as(f64, @floatFromInt(sr));
        ph1 += 2.0 * std.math.pi * f1 / @as(f64, @floatFromInt(sr));
        ph2 += 2.0 * std.math.pi * f2 / @as(f64, @floatFromInt(sr));
        const noise = (rand.float(f32) * 2.0 - 1.0) * 0.04;
        const fluff = 0.08 * @sin(2.0 * std.math.pi * 900.0 * t + 0.3 * @sin(2.0 * std.math.pi * 3.0 * t));
        samples[i] = @floatCast(0.55 * @sin(ph0) + 0.28 * @sin(ph1) + 0.12 * @sin(ph2) + fluff + noise);
    }

    const path = "testdata/synthetic/doppler_scurve_48k.wav";
    try wav.writeFile(path, sr, 1, samples);
    std.debug.print("wrote {s}\n", .{path});

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
        \\  doppler-cli --in <audio-or-video> --out <file> [--wet 0..1]
        \\  doppler-cli gen-synthetic
        \\
        \\WAV input is read directly. Other audio files, and video files, are decoded
        \\with ffmpeg (first audio stream, channels and sample rate kept). .wav output
        \\is PCM. Any other output extension is encoded with ffmpeg. Video outputs copy
        \\the picture and replace the audio. ffmpeg must be on PATH, or set FFMPEG.
        \\
    , .{});
}
