const std = @import("std");
const doppler = @import("doppler_scrub");
const media = @import("media.zig");

const Config = doppler.config.Config;

pub const default_chunk_seconds: f32 = 20;

const Result = struct {
    index: usize,
    channel: usize,
    samples: []f32,
    origin: usize,
    region_start: usize,
    region_end: usize,
    is_last: bool,
};

const Shared = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    results: std.ArrayList(Result),
    read: usize = 0,
    in_flight: usize = 0,
    err: ?anyerror = null,

    fn deinit(self: *Shared) void {
        for (self.results.items[self.read..]) |result| {
            self.results.allocator.free(result.samples);
        }
        self.results.deinit();
    }

    fn inc(self: *Shared) void {
        self.mutex.lock();
        self.in_flight += 1;
        self.mutex.unlock();
    }

    fn inFlight(self: *Shared) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.in_flight;
    }

    fn post(self: *Shared, result: Result) void {
        self.mutex.lock();
        self.results.append(result) catch {
            if (self.err == null) self.err = error.OutOfMemory;
            self.results.allocator.free(result.samples);
        };
        self.in_flight -= 1;
        self.mutex.unlock();
        self.cond.signal();
    }

    fn fail(self: *Shared, err: anyerror) void {
        self.mutex.lock();
        if (self.err == null) self.err = err;
        self.in_flight -= 1;
        self.mutex.unlock();
        self.cond.signal();
    }

    fn waitResult(self: *Shared) ?Result {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.read == self.results.items.len) {
            if (self.in_flight == 0) return null;
            self.cond.wait(&self.mutex);
        }
        const result = self.results.items[self.read];
        self.read += 1;
        if (self.read > 32 and self.read == self.results.items.len) {
            self.results.clearRetainingCapacity();
            self.read = 0;
        }
        return result;
    }
};

const Job = struct {
    index: usize,
    channel: usize,
    input: []f32,
    origin: usize,
    region_start: usize,
    region_end: usize,
    is_last: bool,
    cfg: Config,
    allocator: std.mem.Allocator,
    shared: *Shared,
};

fn runJob(job: *Job) void {
    const allocator = job.allocator;
    defer allocator.destroy(job);
    const samples = allocator.alloc(f32, job.input.len) catch {
        allocator.free(job.input);
        job.shared.fail(error.OutOfMemory);
        return;
    };
    doppler.scrub.scrubMono(allocator, job.input, job.cfg, samples) catch |err| {
        allocator.free(samples);
        allocator.free(job.input);
        job.shared.fail(err);
        return;
    };
    allocator.free(job.input);
    job.shared.post(.{
        .index = job.index,
        .channel = job.channel,
        .samples = samples,
        .origin = job.origin,
        .region_start = job.region_start,
        .region_end = job.region_end,
        .is_last = job.is_last,
    });
}

pub fn scrubFile(allocator: std.mem.Allocator, in_path: []const u8, out_path: []const u8, wet: f32) !struct { frames: u64, channels: u16, sample_rate: u32 } {
    var input = try media.openInput(allocator, in_path);
    defer input.close();

    var cfg = Config.initDefaults(input.stream.format.sample_rate);
    cfg.wet = wet;
    try cfg.validate();

    var output = try media.openOutput(
        allocator,
        in_path,
        out_path,
        input.stream.format.sample_rate,
        input.stream.format.channels,
    );
    defer output.close();

    const frames = try processStream(
        allocator,
        cfg,
        input.stream.format.channels,
        &input,
        &output,
        default_chunk_seconds,
        std.Thread.getCpuCount() catch 1,
    );
    try input.finish();
    try output.finish();
    return .{
        .frames = frames,
        .channels = input.stream.format.channels,
        .sample_rate = input.stream.format.sample_rate,
    };
}

pub fn processStream(
    allocator: std.mem.Allocator,
    cfg: Config,
    channels: u16,
    reader: anytype,
    writer: anytype,
    chunk_seconds: f32,
    workers_in: usize,
) !u64 {
    const ch_count: usize = channels;
    if (ch_count == 0) return error.InvalidChannelCount;

    const workers: usize = @max(workers_in, 1);
    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = allocator, .n_jobs = @intCast(@min(workers, @as(usize, std.math.maxInt(u32)))) });

    var shared = Shared{ .results = std.ArrayList(Result).init(allocator) };
    defer {
        while (shared.inFlight() > 0 or sharedHasResults(&shared)) {
            if (shared.waitResult()) |result| {
                allocator.free(result.samples);
            } else break;
        }
        shared.deinit();
        pool.deinit();
    }

    var carry = std.ArrayList(f32).init(allocator);
    defer carry.deinit();
    const read_buf = try allocator.alloc(f32, @max(8192, ch_count));
    defer allocator.free(read_buf);

    const block_frames: usize = 1024;
    const block = try allocator.alloc(f32, block_frames * ch_count);
    defer allocator.free(block);

    var pending = std.ArrayList(?Slot).init(allocator);
    defer {
        for (pending.items) |slot| {
            if (slot) |s| {
                for (s.got) |item| if (item) |result| allocator.free(result.samples);
                allocator.free(s.got);
            }
        }
        pending.deinit();
    }

    var prev: ?[]Result = null;
    defer if (prev) |results| freeResults(allocator, results);

    var region_start: usize = 0;
    var next_spawn: usize = 0;
    var next_stitch: usize = 0;
    var eof = false;
    var written: u64 = 0;

    const max_in_flight = @max(workers, ch_count);

    while (true) {
        if (shared.err) |err| return err;
        const room = shared.inFlight() + ch_count <= max_in_flight;
        if (!eof and room) {
            const step = try pullAndSpawn(
                allocator,
                &pool,
                &shared,
                cfg,
                ch_count,
                reader,
                read_buf,
                &carry,
                &region_start,
                &next_spawn,
                &eof,
                chunk_seconds,
            );
            if (step == .spawned) continue;
        }
        if (shared.inFlight() == 0 and !sharedHasResults(&shared)) break;
        const result = shared.waitResult() orelse break;
        written += try acceptResult(
            allocator,
            channels,
            writer,
            block,
            &pending,
            &prev,
            &next_stitch,
            result,
            cfg.hop_size,
        );
    }
    if (shared.err) |err| return err;
    if (prev) |results| {
        const end = results[0].region_end;
        const start = if (results[0].region_start == 0) 0 else results[0].region_end - @min(cfg.hop_size, results[0].region_end - results[0].region_start);
        // Leftover tail if the last chunk was not marked. Write from the unwritten fade point.
        _ = start;
        _ = end;
        freeResults(allocator, results);
        prev = null;
    }
    return written;
}

const Step = enum { spawned, idle };

const Slot = struct {
    got: []?Result,
    n: usize = 0,
};

fn pullAndSpawn(
    allocator: std.mem.Allocator,
    pool: *std.Thread.Pool,
    shared: *Shared,
    cfg: Config,
    channels: usize,
    reader: anytype,
    read_buf: []f32,
    carry: *std.ArrayList(f32),
    region_start: *usize,
    next_spawn: *usize,
    eof: *bool,
    chunk_seconds: f32,
) !Step {
    const hop: usize = cfg.hop_size;
    const fade = hop;
    const kept = alignUp(@max(@as(usize, @intFromFloat(chunk_seconds * @as(f32, @floatFromInt(cfg.sample_rate)))), hop), hop);
    const warmup = alignUp(cfg.sample_rate, hop);
    const left = if (region_start.* == 0) 0 else @min(region_start.*, warmup + fade);
    const need_frames = left + kept + fade + cfg.fft_size;
    const need_samples = need_frames * channels;

    while (!eof.* and carry.items.len < need_samples) {
        const frames = try reader.readFrames(read_buf);
        if (frames == 0) {
            eof.* = true;
            break;
        }
        try carry.appendSlice(read_buf[0 .. frames * channels]);
    }
    if (!eof.* and carry.items.len >= need_samples) {
        const frames = try reader.readFrames(read_buf);
        if (frames == 0) eof.* = true else try carry.appendSlice(read_buf[0 .. frames * channels]);
    }

    const frames_have = carry.items.len / channels;
    if (frames_have <= left) return .idle;

    const is_last = eof.*;
    const region_len = if (is_last) frames_have - left else kept;
    const region_end = region_start.* + region_len;
    const input_frames = if (is_last) frames_have else left + region_len + fade + cfg.fft_size;
    const origin = region_start.* - left;

    for (0..channels) |ch| {
        const mono = try allocator.alloc(f32, input_frames);
        errdefer allocator.free(mono);
        var i: usize = 0;
        while (i < input_frames) : (i += 1) {
            mono[i] = carry.items[i * channels + ch];
        }
        const job = try allocator.create(Job);
        errdefer allocator.destroy(job);
        job.* = .{
            .index = next_spawn.*,
            .channel = ch,
            .input = mono,
            .origin = origin,
            .region_start = region_start.*,
            .region_end = region_end,
            .is_last = is_last,
            .cfg = cfg,
            .allocator = allocator,
            .shared = shared,
        };
        shared.inc();
        pool.spawn(runJob, .{job}) catch |err| {
            shared.fail(err);
            return err;
        };
    }

    if (is_last) {
        carry.clearRetainingCapacity();
        eof.* = true;
        next_spawn.* += 1;
        return .spawned;
    }

    const next_left = @min(region_end, warmup + fade);
    const keep_abs = region_end - next_left;
    const drop_frames = keep_abs - origin;
    const drop_samples = drop_frames * channels;
    const rest = carry.items.len - drop_samples;
    std.mem.copyForwards(f32, carry.items[0..rest], carry.items[drop_samples..]);
    carry.shrinkRetainingCapacity(rest);
    region_start.* = region_end;
    next_spawn.* += 1;
    return .spawned;
}

fn acceptResult(
    allocator: std.mem.Allocator,
    channels: u16,
    writer: anytype,
    block: []f32,
    pending: *std.ArrayList(?Slot),
    prev: *?[]Result,
    next_stitch: *usize,
    result: Result,
    hop: usize,
) !u64 {
    while (pending.items.len <= result.index) try pending.append(null);
    if (pending.items[result.index] == null) {
        const got = try allocator.alloc(?Result, channels);
        @memset(got, null);
        pending.items[result.index] = .{ .got = got };
    }
    {
        const slot = &pending.items[result.index].?;
        if (slot.got[result.channel] == null) {
            slot.got[result.channel] = result;
            slot.n += 1;
        } else {
            allocator.free(result.samples);
        }
    }

    var written: u64 = 0;
    while (next_stitch.* < pending.items.len) {
        const slot = pending.items[next_stitch.*] orelse break;
        if (slot.n < channels) break;
        const owned = try allocator.alloc(Result, channels);
        for (slot.got, 0..) |item, i| owned[i] = item.?;
        allocator.free(slot.got);
        pending.items[next_stitch.*] = null;
        next_stitch.* += 1;
        written += try stitchChunk(allocator, channels, writer, block, prev, owned, hop);
    }
    return written;
}

fn stitchChunk(
    allocator: std.mem.Allocator,
    channels: u16,
    writer: anytype,
    block: []f32,
    prev: *?[]Result,
    owned: []Result,
    hop: usize,
) !u64 {
    var written: u64 = 0;
    if (prev.*) |previous| {
        const boundary = owned[0].region_start;
        const prev_len = previous[0].region_end - previous[0].region_start;
        const next_len = owned[0].region_end - boundary;
        const fade = @min(hop, prev_len, next_len);
        written += try blend(channels, writer, block, previous, owned, boundary, fade);
        freeResults(allocator, previous);
        if (owned[0].is_last) {
            written += try writeRange(channels, writer, block, owned, boundary + fade, owned[0].region_end);
            freeResults(allocator, owned);
            prev.* = null;
        } else {
            const tail_fade = @min(hop, owned[0].region_end - (boundary + fade));
            written += try writeRange(channels, writer, block, owned, boundary + fade, owned[0].region_end - tail_fade);
            prev.* = owned;
        }
    } else if (owned[0].is_last) {
        written += try writeRange(channels, writer, block, owned, owned[0].region_start, owned[0].region_end);
        freeResults(allocator, owned);
    } else {
        const fade = @min(hop, owned[0].region_end - owned[0].region_start);
        written += try writeRange(channels, writer, block, owned, owned[0].region_start, owned[0].region_end - fade);
        prev.* = owned;
    }
    return written;
}

fn writeRange(
    channels: u16,
    writer: anytype,
    block: []f32,
    results: []const Result,
    start: usize,
    end: usize,
) !u64 {
    if (end <= start) return 0;
    const ch: usize = channels;
    const block_frames = block.len / ch;
    var abs = start;
    while (abs < end) {
        const n = @min(block_frames, end - abs);
        var f: usize = 0;
        while (f < n) : (f += 1) {
            for (results, 0..) |result, c| {
                block[f * ch + c] = result.samples[abs + f - result.origin];
            }
        }
        try writer.writeFrames(block[0 .. n * ch]);
        abs += n;
    }
    return end - start;
}

fn blend(
    channels: u16,
    writer: anytype,
    block: []f32,
    previous: []const Result,
    next: []const Result,
    boundary: usize,
    fade: usize,
) !u64 {
    if (fade == 0) return 0;
    const ch: usize = channels;
    const span = fade * 2;
    const start = boundary - fade;
    const block_frames = block.len / ch;
    var i: usize = 0;
    while (i < span) {
        const n = @min(block_frames, span - i);
        var f: usize = 0;
        while (f < n) : (f += 1) {
            const t = (@as(f32, @floatFromInt(i + f)) + 0.5) / @as(f32, @floatFromInt(span));
            const abs = start + i + f;
            for (previous, next, 0..) |before, after, c| {
                const a = before.samples[abs - before.origin];
                const b = after.samples[abs - after.origin];
                block[f * ch + c] = a * (1.0 - t) + b * t;
            }
        }
        try writer.writeFrames(block[0 .. n * ch]);
        i += n;
    }
    return span;
}

fn freeResults(allocator: std.mem.Allocator, results: []Result) void {
    for (results) |result| allocator.free(result.samples);
    allocator.free(results);
}

fn sharedHasResults(shared: *Shared) bool {
    shared.mutex.lock();
    defer shared.mutex.unlock();
    return shared.read < shared.results.items.len;
}

fn alignUp(n: usize, m: usize) usize {
    if (m == 0) return n;
    return (n + m - 1) / m * m;
}

const MemReader = struct {
    samples: []const f32,
    channels: usize,
    pos: usize = 0,

    fn readFrames(self: *MemReader, dest: []f32) !usize {
        const left = (self.samples.len / self.channels) - self.pos;
        const n = @min(left, dest.len / self.channels);
        const start = self.pos * self.channels;
        @memcpy(dest[0 .. n * self.channels], self.samples[start .. start + n * self.channels]);
        self.pos += n;
        return n;
    }
};

const MemWriter = struct {
    list: *std.ArrayList(f32),

    fn writeFrames(self: *MemWriter, samples: []const f32) !void {
        try self.list.appendSlice(samples);
    }
};

test "wet zero chunk seam stays near the source" {
    const allocator = std.heap.c_allocator;
    const sr: u32 = 16000;
    var cfg = Config.initDefaults(sr);
    cfg.fft_size = 2048;
    cfg.hop_size = 512;
    cfg.wet = 0;
    try cfg.validate();

    const channels: u16 = 2;
    const frames: usize = sr * 4;
    const input = try allocator.alloc(f32, frames * channels);
    defer allocator.free(input);
    var i: usize = 0;
    while (i < frames) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sr));
        const s = 0.35 * @sin(2.0 * std.math.pi * 440.0 * t);
        input[i * 2] = s;
        input[i * 2 + 1] = s * 0.5;
    }

    var output = std.ArrayList(f32).init(allocator);
    defer output.deinit();
    var reader = MemReader{ .samples = input, .channels = channels };
    var writer = MemWriter{ .list = &output };
    const n = try processStream(allocator, cfg, channels, &reader, &writer, 2.0, 2);
    try std.testing.expectEqual(frames, n);
    try std.testing.expectEqual(input.len, output.items.len);

    const margin: usize = cfg.fft_size;
    var worst: f32 = 0;
    var frame: usize = margin;
    while (frame + margin < frames) : (frame += 1) {
        worst = @max(worst, @abs(output.items[frame * 2] - input[frame * 2]));
        worst = @max(worst, @abs(output.items[frame * 2 + 1] - input[frame * 2 + 1]));
    }
    try std.testing.expect(worst < 1.0e-3);
}

test "wav stream out grows with every frame" {
    const wav = @import("wav.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &dir_buf);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "stream.wav" });
    defer std.testing.allocator.free(path);

    const channels: u16 = 2;
    const frames: usize = 3000;
    var out = try wav.StreamOut.create(std.testing.allocator, path, 48000, channels);
    defer out.deinit();
    const samples = try std.testing.allocator.alloc(f32, frames * channels);
    defer std.testing.allocator.free(samples);
    for (samples, 0..) |*sample, i| {
        sample.* = @sin(@as(f32, @floatFromInt(i)) * 0.02) * 0.4;
    }
    try out.writeFrames(samples);
    try out.finish();

    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    try std.testing.expectEqual(@as(u64, 44 + frames * channels * 2), try file.getEndPos());
}
