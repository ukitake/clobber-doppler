const std = @import("std");

pub const Wav = struct {
    sample_rate: u32,
    channels: u16,
    samples: []f32, // interleaved float32, normalized [-1,1]
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Wav) void {
        self.allocator.free(self.samples);
    }
};

pub fn readFile(allocator: std.mem.Allocator, path: []const u8) !Wav {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const data = try file.readToEndAlloc(allocator, 1024 * 1024 * 1024);
    defer allocator.free(data);
    return try parse(allocator, data);
}

pub fn parse(allocator: std.mem.Allocator, data: []const u8) !Wav {
    if (data.len < 44) return error.InvalidWav;
    if (!std.mem.eql(u8, data[0..4], "RIFF") or !std.mem.eql(u8, data[8..12], "WAVE"))
        return error.InvalidWav;

    var offset: usize = 12;
    var sample_rate: u32 = 0;
    var channels: u16 = 0;
    var bits: u16 = 0;
    var audio_format: u16 = 0;
    var pcm_data: ?[]const u8 = null;

    while (offset + 8 <= data.len) {
        const id = data[offset .. offset + 4];
        const size = std.mem.readInt(u32, data[offset + 4 .. offset + 8][0..4], .little);
        offset += 8;
        if (offset + size > data.len) return error.InvalidWav;

        if (std.mem.eql(u8, id, "fmt ")) {
            if (size < 16) return error.InvalidWav;
            audio_format = std.mem.readInt(u16, data[offset .. offset + 2][0..2], .little);
            channels = std.mem.readInt(u16, data[offset + 2 .. offset + 4][0..2], .little);
            sample_rate = std.mem.readInt(u32, data[offset + 4 .. offset + 8][0..4], .little);
            bits = std.mem.readInt(u16, data[offset + 14 .. offset + 16][0..2], .little);
        } else if (std.mem.eql(u8, id, "data")) {
            pcm_data = data[offset .. offset + size];
        }
        offset += size;
        if (size % 2 == 1) offset += 1; // word align
    }

    const raw = pcm_data orelse return error.MissingData;
    if (channels == 0 or sample_rate == 0) return error.InvalidWav;

    var samples: []f32 = undefined;
    if (audio_format == 1 and bits == 16) {
        const n = raw.len / 2;
        samples = try allocator.alloc(f32, n);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const s = std.mem.readInt(i16, raw[i * 2 .. i * 2 + 2][0..2], .little);
            samples[i] = @as(f32, @floatFromInt(s)) / 32768.0;
        }
    } else if (audio_format == 1 and bits == 32) {
        const n = raw.len / 4;
        samples = try allocator.alloc(f32, n);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const s = std.mem.readInt(i32, raw[i * 4 .. i * 4 + 4][0..4], .little);
            samples[i] = @as(f32, @floatFromInt(s)) / 2147483648.0;
        }
    } else if (audio_format == 3 and bits == 32) {
        const n = raw.len / 4;
        samples = try allocator.alloc(f32, n);
        @memcpy(std.mem.sliceAsBytes(samples), raw[0 .. n * 4]);
    } else if (audio_format == 1 and bits == 8) {
        const n = raw.len;
        samples = try allocator.alloc(f32, n);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            samples[i] = (@as(f32, @floatFromInt(raw[i])) - 128.0) / 128.0;
        }
    } else {
        return error.UnsupportedFormat;
    }

    return .{
        .sample_rate = sample_rate,
        .channels = channels,
        .samples = samples,
        .allocator = allocator,
    };
}

pub fn writeFile(path: []const u8, sample_rate: u32, channels: u16, samples: []const f32) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    var buffered = std.io.bufferedWriter(file.writer());
    const w = buffered.writer();

    const n_frames = samples.len / channels;
    const data_bytes: u32 = @intCast(n_frames * channels * 2); // int16
    const fmt_chunk: u32 = 16;
    const riff_size: u32 = 36 + data_bytes;

    try w.writeAll("RIFF");
    try w.writeInt(u32, riff_size, .little);
    try w.writeAll("WAVE");
    try w.writeAll("fmt ");
    try w.writeInt(u32, fmt_chunk, .little);
    try w.writeInt(u16, 1, .little); // PCM
    try w.writeInt(u16, channels, .little);
    try w.writeInt(u32, sample_rate, .little);
    const byte_rate: u32 = sample_rate * channels * 2;
    try w.writeInt(u32, byte_rate, .little);
    try w.writeInt(u16, channels * 2, .little);
    try w.writeInt(u16, 16, .little);
    try w.writeAll("data");
    try w.writeInt(u32, data_bytes, .little);

    for (samples) |s| {
        const clipped = std.math.clamp(s, -1.0, 1.0);
        const v: i16 = @intFromFloat(@round(clipped * 32767.0));
        try w.writeInt(i16, v, .little);
    }
    try buffered.flush();
}

/// Split interleaved frames into one buffer per channel.
pub fn deinterleave(allocator: std.mem.Allocator, samples: []const f32, channels: u16) ![][]f32 {
    const ch_count: usize = channels;
    if (ch_count == 0) return error.InvalidChannelCount;
    const frames = samples.len / ch_count;
    const planar = try allocator.alloc([]f32, ch_count);
    errdefer allocator.free(planar);
    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) allocator.free(planar[i]);
    }

    var c: usize = 0;
    while (c < ch_count) : (c += 1) {
        const ch = try allocator.alloc(f32, frames);
        var i: usize = 0;
        while (i < frames) : (i += 1) {
            ch[i] = samples[i * ch_count + c];
        }
        planar[c] = ch;
        filled += 1;
    }
    return planar;
}

/// Interleave channel buffers. Uses the shortest channel if lengths differ.
pub fn interleave(allocator: std.mem.Allocator, planar: []const []f32) ![]f32 {
    if (planar.len == 0) return error.InvalidChannelCount;
    var frames = planar[0].len;
    for (planar) |ch| frames = @min(frames, ch.len);
    const out = try allocator.alloc(f32, frames * planar.len);
    var i: usize = 0;
    while (i < frames) : (i += 1) {
        var c: usize = 0;
        while (c < planar.len) : (c += 1) {
            out[i * planar.len + c] = planar[c][i];
        }
    }
    return out;
}

/// Downmix interleaved to mono (allocated).
pub fn toMono(allocator: std.mem.Allocator, samples: []const f32, channels: u16) ![]f32 {
    if (channels == 1) {
        return try allocator.dupe(f32, samples);
    }
    const frames = samples.len / channels;
    const out = try allocator.alloc(f32, frames);
    var i: usize = 0;
    while (i < frames) : (i += 1) {
        var sum: f32 = 0;
        var c: u16 = 0;
        while (c < channels) : (c += 1) {
            sum += samples[i * channels + c];
        }
        out[i] = sum / @as(f32, @floatFromInt(channels));
    }
    return out;
}
