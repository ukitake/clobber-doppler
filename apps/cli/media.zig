const std = @import("std");
const builtin = @import("builtin");
const wav = @import("wav.zig");

const video_exts = [_][]const u8{ "mp4", "m4v", "mov", "mkv", "webm", "avi", "mpg", "mpeg", "ts", "m2ts", "wmv", "flv", "3gp" };

pub const Input = struct {
    allocator: std.mem.Allocator,
    stream: wav.StreamIn,
    /// Heap file for a direct WAV read. Null when ffmpeg owns the handle.
    file: ?*std.fs.File = null,
    child: ?*std.process.Child = null,
    ffmpeg_path: ?[]u8 = null,

    pub fn readFrames(self: *Input, dest: []f32) !usize {
        return self.stream.readFrames(dest);
    }

    /// Reap a decoder after the caller has read to EOF. A direct WAV file is a no-op.
    pub fn finish(self: *Input) !void {
        const child = self.child orelse return;
        const term = try child.wait();
        switch (term) {
            .Exited => |code| if (code != 0) return error.FfmpegFailed,
            else => return error.FfmpegFailed,
        }
    }

    pub fn close(self: *Input) void {
        self.stream.deinit();
        if (self.child) |child| {
            if (child.term == null) {
                _ = child.kill() catch |err| switch (err) {
                    error.AlreadyTerminated => _ = child.wait() catch {},
                    else => {},
                };
            }
            self.allocator.destroy(child);
            self.child = null;
        }
        if (self.file) |file| {
            file.close();
            self.allocator.destroy(file);
            self.file = null;
        }
        if (self.ffmpeg_path) |path| self.allocator.free(path);
    }
};

pub const Output = struct {
    allocator: std.mem.Allocator,
    partial: []u8,
    final_path: []u8,
    wav: ?wav.StreamOut = null,
    child: ?*std.process.Child = null,
    ffmpeg_path: ?[]u8 = null,
    owned_argv: ?[][]const u8 = null,
    owned_rate: ?[]u8 = null,
    owned_channels: ?[]u8 = null,
    finished: bool = false,

    pub fn writeFrames(self: *Output, samples: []const f32) !void {
        if (self.wav) |*out| {
            try out.writeFrames(samples);
            return;
        }
        const child = self.child orelse return error.BadPathName;
        const file = child.stdin orelse return error.BrokenPipe;
        try writeAll(file, std.mem.sliceAsBytes(samples));
    }

    pub fn finish(self: *Output) !void {
        if (self.wav) |*out| {
            try out.finish();
        } else if (self.child) |child| {
            if (child.stdin) |in| {
                in.close();
                child.stdin = null;
            }
            const term = try child.wait();
            switch (term) {
                .Exited => |code| if (code != 0) return error.FfmpegFailed,
                else => return error.FfmpegFailed,
            }
        }
        std.fs.deleteFileAbsolute(self.final_path) catch {};
        try std.fs.renameAbsolute(self.partial, self.final_path);
        self.finished = true;
    }

    pub fn close(self: *Output) void {
        if (self.wav) |*out| {
            out.deinit();
            self.wav = null;
        }
        if (self.child) |child| {
            if (child.term == null) {
                if (child.stdin) |in| {
                    in.close();
                    child.stdin = null;
                }
                _ = child.kill() catch |err| switch (err) {
                    error.AlreadyTerminated => _ = child.wait() catch {},
                    else => {},
                };
            }
            self.allocator.destroy(child);
            self.child = null;
        }
        if (!self.finished) std.fs.deleteFileAbsolute(self.partial) catch {};
        self.allocator.free(self.partial);
        self.allocator.free(self.final_path);
        if (self.ffmpeg_path) |path| self.allocator.free(path);
        if (self.owned_argv) |argv| self.allocator.free(argv);
        if (self.owned_rate) |rate| self.allocator.free(rate);
        if (self.owned_channels) |ch| self.allocator.free(ch);
    }
};

pub fn openInput(allocator: std.mem.Allocator, path: []const u8) !Input {
    if (hasExt(path, &.{ "wav", "wave" })) {
        if (openWavInput(allocator, path)) |input| {
            return input;
        } else |err| switch (err) {
            error.InvalidWav, error.UnsupportedFormat, error.MissingData => {},
            else => return err,
        }
    }
    if (!fileExists(path)) return error.FileNotFound;
    return openFfmpegInput(allocator, path);
}

fn openWavInput(allocator: std.mem.Allocator, path: []const u8) !Input {
    const file = try std.fs.cwd().openFile(path, .{});
    const slot = try allocator.create(std.fs.File);
    slot.* = file;
    const stream = wav.openStream(allocator, readHandle, slot) catch |err| {
        slot.close();
        allocator.destroy(slot);
        return err;
    };
    return .{
        .allocator = allocator,
        .stream = stream,
        .file = slot,
    };
}

fn openFfmpegInput(allocator: std.mem.Allocator, path: []const u8) !Input {
    const ffmpeg = try resolveFfmpeg(allocator);
    const child = try allocator.create(std.process.Child);
    child.* = std.process.Child.init(&.{
        ffmpeg,
        "-hide_banner",
        "-loglevel",
        "error",
        "-nostdin",
        "-i",
        path,
        "-vn",
        "-map",
        "0:a:0",
        "-c:a",
        "pcm_f32le",
        "-f",
        "wav",
        "pipe:1",
    }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    child.spawn() catch |err| {
        allocator.destroy(child);
        allocator.free(ffmpeg);
        if (err == error.FileNotFound) return error.FfmpegNotFound;
        return err;
    };
    std.debug.print("decoding {s}\n", .{path});
    const stream = wav.openStream(allocator, readChildStdout, child) catch |err| {
        _ = child.kill() catch {};
        allocator.destroy(child);
        allocator.free(ffmpeg);
        return err;
    };
    return .{
        .allocator = allocator,
        .stream = stream,
        .child = child,
        .ffmpeg_path = ffmpeg,
    };
}

pub fn openOutput(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    out_path: []const u8,
    sample_rate: u32,
    channels: u16,
) !Output {
    if (std.fs.path.dirname(out_path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }
    const abs_out = try absolutePath(allocator, out_path);
    errdefer allocator.free(abs_out);
    const partial = try partialPath(allocator, abs_out);
    errdefer allocator.free(partial);

    if (hasExt(out_path, &.{ "wav", "wave" })) {
        const stream = wav.StreamOut.create(allocator, partial, sample_rate, channels) catch |err| {
            std.fs.deleteFileAbsolute(partial) catch {};
            return err;
        };
        return .{
            .allocator = allocator,
            .partial = partial,
            .final_path = abs_out,
            .wav = stream,
        };
    }

    const ffmpeg = try resolveFfmpeg(allocator);
    const video = hasExt(out_path, &video_exts);
    if (video) {
        std.debug.print("muxing scrubbed audio into {s}\n", .{out_path});
    } else {
        std.debug.print("encoding {s}\n", .{out_path});
    }
    return spawnEncoder(allocator, ffmpeg, abs_out, partial, source_path, sample_rate, channels, video);
}

fn spawnEncoder(
    allocator: std.mem.Allocator,
    ffmpeg: []u8,
    abs_out: []u8,
    partial: []u8,
    source_path: []const u8,
    sample_rate: u32,
    channels: u16,
    video: bool,
) !Output {
    errdefer allocator.free(ffmpeg);
    const rate = try std.fmt.allocPrint(allocator, "{d}", .{sample_rate});
    errdefer allocator.free(rate);
    const ch_s = try std.fmt.allocPrint(allocator, "{d}", .{channels});
    errdefer allocator.free(ch_s);

    var args: std.ArrayList([]const u8) = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();
    if (video) {
        const codec = videoAudioCodec(partial);
        try args.appendSlice(&.{
            ffmpeg,
            "-hide_banner", "-loglevel", "error", "-y",
            "-i",           source_path,
            "-f",           "f32le",
            "-ar",          rate,
            "-ac",          ch_s,
            "-i",           "pipe:0",
            "-map",         "0:v?",
            "-map",         "1:a:0",
            "-c:v",         "copy",
            "-c:a",         codec,
        });
        try appendBitrate(&args, codec);
    } else {
        try args.appendSlice(&.{
            ffmpeg,
            "-hide_banner", "-loglevel", "error", "-y",
            "-f",           "f32le",
            "-ar",          rate,
            "-ac",          ch_s,
            "-i",           "pipe:0",
        });
        try appendAudioCodec(&args, partial);
    }
    try args.append(partial);

    // Child.init does not copy argv. Duplicate the list into memory owned by the child allocator
    // and keep rate/ch_s alive for the process lifetime by leaking them into the same allocation
    // strategy: store them beside the child and free in close().
    const argv = try allocator.alloc([]const u8, args.items.len);
    errdefer allocator.free(argv);
    @memcpy(argv, args.items);

    const child = try allocator.create(std.process.Child);
    child.* = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;
    child.spawn() catch |err| {
        allocator.destroy(child);
        std.fs.deleteFileAbsolute(partial) catch {};
        if (err == error.FileNotFound) return error.FfmpegNotFound;
        return err;
    };

    return .{
        .allocator = allocator,
        .partial = partial,
        .final_path = abs_out,
        .child = child,
        .ffmpeg_path = ffmpeg,
        // rate, ch_s, and argv must stay alive. Stash them by appending to a side channel
        // stored in the child argv (already pointing at argv). Free argv, rate, and ch_s in close.
        .owned_argv = argv,
        .owned_rate = rate,
        .owned_channels = ch_s,
    };
}

fn readHandle(ctx: *anyopaque, buf: []u8) anyerror!usize {
    const file: *std.fs.File = @ptrCast(@alignCast(ctx));
    return file.read(buf);
}

fn readChildStdout(ctx: *anyopaque, buf: []u8) anyerror!usize {
    const child: *std.process.Child = @ptrCast(@alignCast(ctx));
    const file = child.stdout orelse return error.Closed;
    return file.read(buf);
}

fn writeAll(file: std.fs.File, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = try file.write(bytes[off..]);
        if (n == 0) return error.BrokenPipe;
        off += n;
    }
}

fn appendAudioCodec(args: *std.ArrayList([]const u8), out_path: []const u8) !void {
    const ext = extension(out_path);
    if (eql(ext, "mp3")) {
        try args.appendSlice(&.{ "-c:a", "libmp3lame", "-q:a", "2" });
    } else if (eql(ext, "m4a") or eql(ext, "aac")) {
        try args.appendSlice(&.{ "-c:a", "aac", "-b:a", "192k" });
    } else if (eql(ext, "ogg") or eql(ext, "oga")) {
        try args.appendSlice(&.{ "-c:a", "libvorbis", "-q:a", "5" });
    } else if (eql(ext, "opus")) {
        try args.appendSlice(&.{ "-c:a", "libopus", "-b:a", "128k" });
    } else if (eql(ext, "flac")) {
        try args.appendSlice(&.{ "-c:a", "flac" });
    } else if (eql(ext, "wma")) {
        try args.appendSlice(&.{ "-c:a", "wmav2", "-b:a", "192k" });
    } else if (eql(ext, "aiff") or eql(ext, "aif")) {
        try args.appendSlice(&.{ "-c:a", "pcm_s16be" });
    }
}

fn videoAudioCodec(out_path: []const u8) []const u8 {
    const ext = extension(out_path);
    if (eql(ext, "webm")) return "libopus";
    if (eql(ext, "avi")) return "pcm_s16le";
    if (eql(ext, "mpg") or eql(ext, "mpeg")) return "mp2";
    if (eql(ext, "wmv")) return "wmav2";
    return "aac";
}

fn appendBitrate(args: *std.ArrayList([]const u8), codec: []const u8) !void {
    if (std.mem.eql(u8, codec, "aac") or std.mem.eql(u8, codec, "mp2") or std.mem.eql(u8, codec, "wmav2")) {
        try args.appendSlice(&.{ "-b:a", "192k" });
    } else if (std.mem.eql(u8, codec, "libopus")) {
        try args.appendSlice(&.{ "-b:a", "160k" });
    }
}

fn resolveFfmpeg(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "FFMPEG")) |from_env| {
        if (fileExists(from_env)) return from_env;
        allocator.free(from_env);
    } else |_| {}

    const names: []const []const u8 = if (builtin.os.tag == .windows)
        &.{ "ffmpeg.exe", "ffmpeg" }
    else
        &.{"ffmpeg"};
    if (try findOnPath(allocator, names)) |found| return found;

    if (builtin.os.tag == .windows) {
        if (try findUnderLocalAppData(allocator, &.{ "Microsoft", "WinGet", "Packages" }, "ffmpeg.exe")) |found| return found;
        if (try findProgramFiles(allocator)) |found| return found;
    }
    std.debug.print("ffmpeg was not found. Install it, put it on PATH, or set FFMPEG to the executable.\n", .{});
    return error.FfmpegNotFound;
}

fn findOnPath(allocator: std.mem.Allocator, names: []const []const u8) !?[]u8 {
    const path_env = std.process.getEnvVarOwned(allocator, "PATH") catch return null;
    defer allocator.free(path_env);
    const sep: u8 = if (builtin.os.tag == .windows) ';' else ':';
    var it = std.mem.tokenizeScalar(u8, path_env, sep);
    while (it.next()) |dir| {
        for (names) |name| {
            const candidate = std.fs.path.join(allocator, &.{ dir, name }) catch continue;
            if (fileExists(candidate)) return candidate;
            allocator.free(candidate);
        }
    }
    return null;
}

fn findUnderLocalAppData(allocator: std.mem.Allocator, rel: []const []const u8, exe_name: []const u8) !?[]u8 {
    const local = std.process.getEnvVarOwned(allocator, "LOCALAPPDATA") catch return null;
    defer allocator.free(local);
    const parts = try allocator.alloc([]const u8, rel.len + 1);
    defer allocator.free(parts);
    parts[0] = local;
    for (rel, 0..) |p, i| parts[i + 1] = p;
    const root = try std.fs.path.join(allocator, parts);
    defer allocator.free(root);

    var dir = std.fs.openDirAbsolute(root, .{ .iterate = true }) catch return null;
    defer dir.close();
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, entry.basename, exe_name)) continue;
        const rel_path = try allocator.dupe(u8, entry.path);
        defer allocator.free(rel_path);
        return try std.fs.path.join(allocator, &.{ root, rel_path });
    }
    return null;
}

fn findProgramFiles(allocator: std.mem.Allocator) !?[]u8 {
    const roots = [_][]const u8{ "ProgramFiles", "ProgramFiles(x86)" };
    for (roots) |key| {
        const root = std.process.getEnvVarOwned(allocator, key) catch continue;
        defer allocator.free(root);
        const candidate = try std.fs.path.join(allocator, &.{ root, "ffmpeg", "bin", "ffmpeg.exe" });
        if (fileExists(candidate)) return candidate;
        allocator.free(candidate);
    }
    return null;
}

fn partialPath(allocator: std.mem.Allocator, abs_out: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(abs_out) orelse return error.BadPathName;
    const base = std.fs.path.basename(abs_out);
    const ext = extension(base);
    const stem = if (ext.len == 0) base else base[0 .. base.len - ext.len - 1];
    const name = if (ext.len == 0)
        try std.fmt.allocPrint(allocator, "{s}.doppler-partial", .{stem})
    else
        try std.fmt.allocPrint(allocator, "{s}.doppler-partial.{s}", .{ stem, ext });
    defer allocator.free(name);
    return std.fs.path.join(allocator, &.{ dir, name });
}

fn absolutePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return try allocator.dupe(u8, path);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.fs.cwd().realpath(".", &buf);
    return std.fs.path.join(allocator, &.{ cwd, path });
}

fn extension(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return "";
    if (dot + 1 >= base.len) return "";
    return base[dot + 1 ..];
}

fn hasExt(path: []const u8, exts: []const []const u8) bool {
    const ext = extension(path);
    for (exts) |e| {
        if (eql(ext, e)) return true;
    }
    return false;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn fileExists(path: []const u8) bool {
    const file = if (std.fs.path.isAbsolute(path))
        std.fs.openFileAbsolute(path, .{}) catch return false
    else
        std.fs.cwd().openFile(path, .{}) catch return false;
    file.close();
    return true;
}
