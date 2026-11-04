const std = @import("std");
const builtin = @import("builtin");
const wav = @import("wav.zig");

const video_exts = [_][]const u8{ "mp4", "m4v", "mov", "mkv", "webm", "avi", "mpg", "mpeg", "ts", "m2ts", "wmv", "flv", "3gp" };

/// Load audio from a WAV, or from any ffmpeg-readable audio or video file.
/// Channel count and sample rate are preserved. Video pictures are not loaded.
pub fn load(allocator: std.mem.Allocator, path: []const u8) !wav.Wav {
    if (hasExt(path, &.{ "wav", "wave" })) {
        if (wav.readFile(allocator, path)) |audio| {
            return audio;
        } else |err| switch (err) {
            error.InvalidWav, error.UnsupportedFormat, error.MissingData => {},
            else => return err,
        }
    }
    if (!fileExists(path)) return error.FileNotFound;
    return decodeToWav(allocator, path);
}

/// Write scrubbed samples. `.wav` stays PCM. Any other extension is encoded
/// with ffmpeg. Video containers keep the source picture and replace the audio.
pub fn writeOutput(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    out_path: []const u8,
    sample_rate: u32,
    channels: u16,
    samples: []const f32,
) !void {
    if (std.fs.path.dirname(out_path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }
    if (hasExt(out_path, &.{ "wav", "wave" })) {
        try wav.writeFile(out_path, sample_rate, channels, samples);
        return;
    }

    const tmp = try tempWavPath(allocator);
    defer allocator.free(tmp);
    errdefer std.fs.deleteFileAbsolute(tmp) catch {};
    try wav.writeFile(tmp, sample_rate, channels, samples);
    defer std.fs.deleteFileAbsolute(tmp) catch {};

    const abs_out = try absolutePath(allocator, out_path);
    defer allocator.free(abs_out);
    const dest = try partialPath(allocator, abs_out);
    defer allocator.free(dest);
    errdefer std.fs.deleteFileAbsolute(dest) catch {};

    if (hasExt(out_path, &video_exts)) {
        std.debug.print("muxing scrubbed audio into {s}\n", .{out_path});
        try muxVideo(allocator, source_path, tmp, dest, out_path);
    } else {
        std.debug.print("encoding {s}\n", .{out_path});
        try encodeAudio(allocator, tmp, dest, out_path);
    }

    std.fs.deleteFileAbsolute(abs_out) catch {};
    try std.fs.renameAbsolute(dest, abs_out);
}

fn decodeToWav(allocator: std.mem.Allocator, path: []const u8) !wav.Wav {
    const tmp = try tempWavPath(allocator);
    defer allocator.free(tmp);
    defer std.fs.deleteFileAbsolute(tmp) catch {};
    std.debug.print("decoding {s}\n", .{path});
    try runFfmpeg(allocator, &.{
        "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
        "-i",         path,
        "-vn",        "-map",        "0:a:0",
        "-c:a",       "pcm_s16le",   tmp,
    });
    return wav.readFile(allocator, tmp);
}

fn muxVideo(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    scrubbed_wav: []const u8,
    dest: []const u8,
    out_path: []const u8,
) !void {
    const codec = videoAudioCodec(out_path);
    var args: std.ArrayList([]const u8) = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();
    try args.appendSlice(&.{
        "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
        "-i",           source_path,
        "-i",           scrubbed_wav,
        "-map",         "0:v?",
        "-map",         "1:a:0",
        "-c:v",         "copy",
        "-c:a",         codec,
    });
    try appendBitrate(&args, codec);
    try args.append(dest);
    try runFfmpeg(allocator, args.items);
}

fn encodeAudio(
    allocator: std.mem.Allocator,
    scrubbed_wav: []const u8,
    dest: []const u8,
    out_path: []const u8,
) !void {
    var args: std.ArrayList([]const u8) = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();
    try args.appendSlice(&.{
        "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
        "-i",           scrubbed_wav,
    });
    try appendAudioCodec(&args, out_path);
    try args.append(dest);
    try runFfmpeg(allocator, args.items);
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

fn runFfmpeg(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const ffmpeg = resolveFfmpeg(allocator) catch |err| {
        std.debug.print("ffmpeg was not found. Install it, put it on PATH, or set FFMPEG to the executable.\n", .{});
        return err;
    };
    defer allocator.free(ffmpeg);

    var argv: std.ArrayList([]const u8) = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append(ffmpeg);
    try argv.appendSlice(args);

    var child = std.process.Child.init(argv.items, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;
    const term = child.spawnAndWait() catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("could not start {s}\n", .{ffmpeg});
            return error.FfmpegNotFound;
        }
        return err;
    };
    switch (term) {
        .Exited => |code| if (code != 0) {
            std.debug.print("ffmpeg exited with status {d}\n", .{code});
            return error.FfmpegFailed;
        },
        else => {
            std.debug.print("ffmpeg did not exit cleanly\n", .{});
            return error.FfmpegFailed;
        },
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

fn tempWavPath(allocator: std.mem.Allocator) ![]u8 {
    const dir = try tempDir(allocator);
    defer allocator.free(dir);
    const name = try std.fmt.allocPrint(allocator, "doppler-{d}-{d}.wav", .{
        std.time.milliTimestamp(),
        tempSeq(),
    });
    defer allocator.free(name);
    return std.fs.path.join(allocator, &.{ dir, name });
}

var temp_seq: u32 = 0;
fn tempSeq() u32 {
    temp_seq += 1;
    return temp_seq;
}

fn tempDir(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "TEMP")) |p| {
        return p;
    } else |_| {}
    if (std.process.getEnvVarOwned(allocator, "TMPDIR")) |p| {
        return p;
    } else |_| {}
    return std.fs.cwd().realpathAlloc(allocator, ".");
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
