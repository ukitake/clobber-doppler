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

pub const PcmFormat = struct {
    sample_rate: u32,
    channels: u16,
    audio_format: u16,
    bits: u16,

    pub fn bytesPerFrame(self: PcmFormat) usize {
        return @as(usize, self.channels) * @as(usize, self.bits / 8);
    }
};

pub const StreamIn = struct {
    readFn: *const fn (*anyopaque, []u8) anyerror!usize,
    ctx: *anyopaque,
    format: PcmFormat,
    data_left: ?u64,
    pending: std.ArrayList(u8),
    eof: bool = false,

    pub fn deinit(self: *StreamIn) void {
        self.pending.deinit();
    }

    /// Read up to `dest.len / channels` interleaved frames. Returns the frame count.
    pub fn readFrames(self: *StreamIn, dest: []f32) !usize {
        const channels: usize = self.format.channels;
        if (channels == 0 or dest.len < channels) return 0;
        const frame_bytes = self.format.bytesPerFrame();
        if (frame_bytes == 0) return error.UnsupportedFormat;
        const want_frames = dest.len / channels;
        const want_bytes = want_frames * frame_bytes;

        while (self.pending.items.len < want_bytes and !self.eof) {
            var tmp: [16 * 1024]u8 = undefined;
            var to_read: usize = tmp.len;
            if (self.data_left) |left| {
                if (left == 0) {
                    self.eof = true;
                    break;
                }
                to_read = @min(to_read, @as(usize, @intCast(@min(left, tmp.len))));
            }
            const n = try self.readFn(self.ctx, tmp[0..to_read]);
            if (n == 0) {
                self.eof = true;
                break;
            }
            if (self.data_left) |*left| left.* -= n;
            try self.pending.appendSlice(tmp[0..n]);
        }

        const frames = @min(want_frames, self.pending.items.len / frame_bytes);
        if (frames == 0) return 0;
        const use_bytes = frames * frame_bytes;
        convertPcm(self.format, self.pending.items[0..use_bytes], dest[0 .. frames * channels]);
        const rest = self.pending.items.len - use_bytes;
        std.mem.copyForwards(u8, self.pending.items[0..rest], self.pending.items[use_bytes..]);
        self.pending.shrinkRetainingCapacity(rest);
        return frames;
    }
};

pub fn openStream(
    allocator: std.mem.Allocator,
    readFn: *const fn (*anyopaque, []u8) anyerror!usize,
    ctx: *anyopaque,
) !StreamIn {
    var acc = std.ArrayList(u8).init(allocator);
    defer acc.deinit();
    var tmp: [4096]u8 = undefined;
    var parsed: ?ParsedHeader = null;
    while (parsed == null) {
        if (acc.items.len > 1024 * 1024) return error.InvalidWav;
        const n = try readFn(ctx, &tmp);
        if (n == 0) return error.InvalidWav;
        try acc.appendSlice(tmp[0..n]);
        parsed = try tryParseHeader(acc.items);
    }
    const header = parsed.?;
    var pending = std.ArrayList(u8).init(allocator);
    errdefer pending.deinit();
    const already = acc.items.len - header.data_pos;
    const take: usize = if (header.data_bytes) |size|
        @intCast(@min(size, @as(u64, already)))
    else
        already;
    try pending.appendSlice(acc.items[header.data_pos .. header.data_pos + take]);
    const data_left: ?u64 = if (header.data_bytes) |size| size - @as(u64, take) else null;
    return .{
        .readFn = readFn,
        .ctx = ctx,
        .format = header.format,
        .data_left = data_left,
        .pending = pending,
    };
}

const ParsedHeader = struct {
    format: PcmFormat,
    data_pos: usize,
    /// Null when the data chunk size is unknown (0xFFFFFFFF, typical of a pipe).
    data_bytes: ?u64,
};

fn tryParseHeader(data: []const u8) !?ParsedHeader {
    if (data.len < 12) return null;
    if (!std.mem.eql(u8, data[0..4], "RIFF") or !std.mem.eql(u8, data[8..12], "WAVE"))
        return error.InvalidWav;

    var offset: usize = 12;
    var format: ?PcmFormat = null;
    while (true) {
        if (offset + 8 > data.len) return null;
        const id = data[offset .. offset + 4];
        const size = std.mem.readInt(u32, data[offset + 4 .. offset + 8][0..4], .little);
        const body = offset + 8;
        if (std.mem.eql(u8, id, "data")) {
            const fmt = format orelse return error.InvalidWav;
            try validateFormat(fmt);
            const data_bytes: ?u64 = if (size == 0xFFFFFFFF) null else size;
            return .{
                .format = fmt,
                .data_pos = body,
                .data_bytes = data_bytes,
            };
        }
        if (body + size > data.len) return null;
        if (std.mem.eql(u8, id, "fmt ")) {
            if (size < 16) return error.InvalidWav;
            format = .{
                .audio_format = std.mem.readInt(u16, data[body .. body + 2][0..2], .little),
                .channels = std.mem.readInt(u16, data[body + 2 .. body + 4][0..2], .little),
                .sample_rate = std.mem.readInt(u32, data[body + 4 .. body + 8][0..4], .little),
                .bits = std.mem.readInt(u16, data[body + 14 .. body + 16][0..2], .little),
            };
        }
        offset = body + size;
        if (size % 2 == 1) offset += 1;
    }
}

fn validateFormat(fmt: PcmFormat) !void {
    if (fmt.channels == 0 or fmt.sample_rate == 0) return error.InvalidWav;
    const ok = (fmt.audio_format == 1 and (fmt.bits == 8 or fmt.bits == 16 or fmt.bits == 32)) or
        (fmt.audio_format == 3 and fmt.bits == 32);
    if (!ok) return error.UnsupportedFormat;
}

fn convertPcm(fmt: PcmFormat, bytes: []const u8, dest: []f32) void {
    var i: usize = 0;
    if (fmt.audio_format == 3) {
        @memcpy(std.mem.sliceAsBytes(dest), bytes[0 .. dest.len * 4]);
        return;
    }
    if (fmt.bits == 16) {
        while (i < dest.len) : (i += 1) {
            const s = std.mem.readInt(i16, bytes[i * 2 .. i * 2 + 2][0..2], .little);
            dest[i] = @as(f32, @floatFromInt(s)) / 32768.0;
        }
    } else if (fmt.bits == 32) {
        while (i < dest.len) : (i += 1) {
            const s = std.mem.readInt(i32, bytes[i * 4 .. i * 4 + 4][0..4], .little);
            dest[i] = @as(f32, @floatFromInt(s)) / 2147483648.0;
        }
    } else {
        while (i < dest.len) : (i += 1) {
            dest[i] = (@as(f32, @floatFromInt(bytes[i])) - 128.0) / 128.0;
        }
    }
}

pub const StreamOut = struct {
    file: std.fs.File,
    allocator: std.mem.Allocator,
    channels: u16,
    sample_rate: u32,
    frames: u64 = 0,

    pub fn create(allocator: std.mem.Allocator, path: []const u8, sample_rate: u32, channels: u16) !StreamOut {
        const file = try std.fs.cwd().createFile(path, .{});
        errdefer file.close();
        try writeHeader(file, sample_rate, channels, 0);
        return .{
            .file = file,
            .allocator = allocator,
            .channels = channels,
            .sample_rate = sample_rate,
        };
    }

    pub fn deinit(self: *StreamOut) void {
        self.file.close();
    }

    pub fn writeFrames(self: *StreamOut, samples: []const f32) !void {
        const channels: usize = self.channels;
        if (channels == 0 or samples.len % channels != 0) return error.InvalidChannelCount;
        const frames = samples.len / channels;
        const new_frames = self.frames + frames;
        const data_bytes = new_frames * channels * 2;
        if (data_bytes > @as(u64, std.math.maxInt(u32)) - 36) return error.WavTooLarge;

        var offset: usize = 0;
        var raw: [4096]u8 = undefined;
        const batch: usize = raw.len / 2;
        while (offset < samples.len) {
            // @min's result is only wide enough for its inputs. Widen before
            // `n * 2`, or ReleaseFast wraps that byte count to 0.
            const n: usize = @min(batch, samples.len - offset);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const clipped = std.math.clamp(samples[offset + i], -1.0, 1.0);
                const v: i16 = @intFromFloat(@round(clipped * 32767.0));
                std.mem.writeInt(i16, raw[i * 2 .. i * 2 + 2][0..2], v, .little);
            }
            try self.file.writeAll(raw[0 .. n * 2]);
            offset += n;
        }
        self.frames = new_frames;
    }

    pub fn finish(self: *StreamOut) !void {
        const data_bytes_u64 = self.frames * self.channels * 2;
        if (data_bytes_u64 > @as(u64, std.math.maxInt(u32)) - 36) return error.WavTooLarge;
        try self.file.seekTo(0);
        try writeHeader(self.file, self.sample_rate, self.channels, @intCast(data_bytes_u64));
    }
};

fn writeHeader(file: std.fs.File, sample_rate: u32, channels: u16, data_bytes: u32) !void {
    var hdr: [44]u8 = undefined;
    @memcpy(hdr[0..4], "RIFF");
    std.mem.writeInt(u32, hdr[4..8], 36 + data_bytes, .little);
    @memcpy(hdr[8..12], "WAVE");
    @memcpy(hdr[12..16], "fmt ");
    std.mem.writeInt(u32, hdr[16..20], 16, .little);
    std.mem.writeInt(u16, hdr[20..22], 1, .little);
    std.mem.writeInt(u16, hdr[22..24], channels, .little);
    std.mem.writeInt(u32, hdr[24..28], sample_rate, .little);
    std.mem.writeInt(u32, hdr[28..32], sample_rate * @as(u32, channels) * 2, .little);
    std.mem.writeInt(u16, hdr[32..34], channels * 2, .little);
    std.mem.writeInt(u16, hdr[34..36], 16, .little);
    @memcpy(hdr[36..40], "data");
    std.mem.writeInt(u32, hdr[40..44], data_bytes, .little);
    try file.writeAll(&hdr);
}
