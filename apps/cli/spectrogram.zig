const std = @import("std");
const fft_mod = @import("doppler_scrub").fft;

/// Peak power in band (for shared before/after color scale).
pub fn peakPowerInBand(
    allocator: std.mem.Allocator,
    samples: []const f32,
    sample_rate: u32,
    fft_size: u32,
    hop_size: u32,
    f_min_hz: f32,
    f_max_hz: f32,
) !f32 {
    const n = fft_size;
    const hop = hop_size;
    if (samples.len < n) return error.TooShort;
    const n_frames = (samples.len - n) / hop + 1;
    const bin_hz = @as(f32, @floatFromInt(sample_rate)) / @as(f32, @floatFromInt(n));
    const b0: usize = @intFromFloat(@floor(f_min_hz / bin_hz));
    var b1: usize = @intFromFloat(@ceil(f_max_hz / bin_hz));
    const half = n / 2;
    if (b1 > half) b1 = half;
    if (b1 <= b0) return error.InvalidBand;

    var spectrum = try allocator.alloc(f32, n * 2);
    defer allocator.free(spectrum);
    var window = try allocator.alloc(f32, n);
    defer allocator.free(window);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
        window[i] = 0.5 - 0.5 * @cos(2.0 * std.math.pi * t);
    }

    var global_max: f32 = 1e-20;
    const frame_step = @max(@as(usize, 1), n_frames / @as(usize, 1200));
    var fi: usize = 0;
    while (fi < n_frames) : (fi += frame_step) {
        const start = fi * hop;
        @memset(spectrum, 0);
        i = 0;
        while (i < n) : (i += 1) {
            spectrum[2 * i] = samples[start + i] * window[i];
        }
        fft_mod.fft(spectrum, n, false);
        var b = b0;
        while (b <= b1) : (b += 1) {
            const re = spectrum[2 * b];
            const im = spectrum[2 * b + 1];
            const mag = re * re + im * im;
            if (mag > global_max) global_max = mag;
        }
    }
    return global_max;
}

/// Render a spectrogram PNG of mono float samples.
/// Pass `shared_peak_power` > 0 to lock color scale (fair before/after compare).
pub fn writeSpectrogramPng(
    allocator: std.mem.Allocator,
    path: []const u8,
    samples: []const f32,
    sample_rate: u32,
    fft_size: u32,
    hop_size: u32,
    f_min_hz: f32,
    f_max_hz: f32,
    width: u32,
    height: u32,
    shared_peak_power: f32,
) !void {
    const n = fft_size;
    const hop = hop_size;
    if (samples.len < n) return error.TooShort;

    const n_frames = (samples.len - n) / hop + 1;
    const bin_hz = @as(f32, @floatFromInt(sample_rate)) / @as(f32, @floatFromInt(n));
    const b0: usize = @intFromFloat(@floor(f_min_hz / bin_hz));
    var b1: usize = @intFromFloat(@ceil(f_max_hz / bin_hz));
    const half = n / 2;
    if (b1 > half) b1 = half;
    if (b1 <= b0) return error.InvalidBand;

    // Compute log-mag matrix [frame][bin_in_band] — but for large audio, subsample frames to width
    const pixels = try allocator.alloc(u8, @as(usize, width) * @as(usize, height) * 3);
    defer allocator.free(pixels);
    @memset(pixels, 0);

    var spectrum = try allocator.alloc(f32, n * 2);
    defer allocator.free(spectrum);
    var window = try allocator.alloc(f32, n);
    defer allocator.free(window);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
        window[i] = 0.5 - 0.5 * @cos(2.0 * std.math.pi * t);
    }

    const global_max = if (shared_peak_power > 0)
        shared_peak_power
    else
        try peakPowerInBand(allocator, samples, sample_rate, fft_size, hop_size, f_min_hz, f_max_hz);
    const log_max = @log10(global_max + 1e-20);

    // Second pass: render
    var x: u32 = 0;
    while (x < width) : (x += 1) {
        const frame_f = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(@max(width, 1) - 1));
        const frame_i: usize = @intFromFloat(frame_f * @as(f32, @floatFromInt(n_frames -| 1)));
        const start = frame_i * hop;
        if (start + n > samples.len) break;

        @memset(spectrum, 0);
        i = 0;
        while (i < n) : (i += 1) {
            spectrum[2 * i] = samples[start + i] * window[i];
        }
        fft_mod.fft(spectrum, n, false);

        var y: u32 = 0;
        while (y < height) : (y += 1) {
            // y=0 at top = f_max
            const fy = 1.0 - @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(@max(height, 1) - 1));
            const b = b0 + @as(usize, @intFromFloat(fy * @as(f32, @floatFromInt(b1 - b0))));
            const re = spectrum[2 * b];
            const im = spectrum[2 * b + 1];
            const mag = re * re + im * im;
            const db = @log10(mag + 1e-20);
            // Map ~80 dB range below peak
            const norm = std.math.clamp((db - (log_max - 4.0)) / 4.0, 0.0, 1.0);
            const rgb = magma(norm);
            const idx = (@as(usize, y) * @as(usize, width) + @as(usize, x)) * 3;
            pixels[idx] = rgb[0];
            pixels[idx + 1] = rgb[1];
            pixels[idx + 2] = rgb[2];
        }
    }

    try writePngRgb(allocator, path, width, height, pixels);
}

fn magma(t: f32) [3]u8 {
    // Compact magma-ish ramp
    const stops = [_][3]f32{
        .{ 0.0, 0.0, 0.02 },
        .{ 0.28, 0.05, 0.35 },
        .{ 0.70, 0.15, 0.40 },
        .{ 0.95, 0.45, 0.25 },
        .{ 0.99, 0.90, 0.55 },
        .{ 1.0, 1.0, 0.85 },
    };
    const pos = t * @as(f32, @floatFromInt(stops.len - 1));
    const i: usize = @intFromFloat(@floor(pos));
    const i_next = @min(i + 1, stops.len - 1);
    const f = pos - @as(f32, @floatFromInt(i));
    const a = stops[i];
    const b = stops[i_next];
    return .{
        @intFromFloat((a[0] + (b[0] - a[0]) * f) * 255.0),
        @intFromFloat((a[1] + (b[1] - a[1]) * f) * 255.0),
        @intFromFloat((a[2] + (b[2] - a[2]) * f) * 255.0),
    };
}

fn writePngRgb(allocator: std.mem.Allocator, path: []const u8, width: u32, height: u32, rgb: []const u8) !void {
    // Build raw image with filter byte 0 per row
    const row_bytes = 1 + width * 3;
    const raw = try allocator.alloc(u8, row_bytes * height);
    defer allocator.free(raw);
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const dst = y * row_bytes;
        raw[dst] = 0; // None filter
        const src = @as(usize, y) * @as(usize, width) * 3;
        @memcpy(raw[dst + 1 .. dst + row_bytes], rgb[src .. src + width * 3]);
    }

    var compressed = std.ArrayList(u8).init(allocator);
    defer compressed.deinit();
    {
        var in_stream = std.io.fixedBufferStream(raw);
        try std.compress.zlib.compress(in_stream.reader(), compressed.writer(), .{ .level = .level_6 });
    }

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    var buffered = std.io.bufferedWriter(file.writer());
    const w = buffered.writer();

    // PNG signature
    try w.writeAll(&[_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 });

    // IHDR
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 2; // RGB
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try writeChunk(w, "IHDR", &ihdr);

    try writeChunk(w, "IDAT", compressed.items);
    try writeChunk(w, "IEND", &[_]u8{});
    try buffered.flush();
}

fn writeChunk(w: anytype, ctype: *const [4]u8, data: []const u8) !void {
    try w.writeInt(u32, @intCast(data.len), .big);
    try w.writeAll(ctype);
    try w.writeAll(data);
    var crc = std.hash.crc.Crc32.init();
    crc.update(ctype);
    crc.update(data);
    try w.writeInt(u32, crc.final(), .big);
}
