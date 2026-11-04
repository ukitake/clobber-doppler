const std = @import("std");
const math = std.math;

/// Minimum length pffft accepts: N = 2^a * 3^b * 5^c with a >= 5.
pub const min_size: usize = 32;

const pffft_forward: c_int = 0;
const pffft_backward: c_int = 1;
const pffft_real: c_int = 0;
const pffft_complex: c_int = 1;

extern fn pffft_new_setup(N: c_int, transform: c_int) ?*anyopaque;
extern fn pffft_destroy_setup(setup: ?*anyopaque) void;
extern fn pffft_transform_ordered(setup: *anyopaque, input: [*]const f32, output: [*]f32, work: [*]f32, direction: c_int) void;
extern fn pffft_aligned_malloc(nb_bytes: usize) ?*anyopaque;
extern fn pffft_aligned_free(ptr: ?*anyopaque) void;

/// Real packed FFT. Ordered spectrum is `[DC, Nyquist, re1, im1, ...]`, length `n`.
/// `backward` is unnormalized: `backward(forward(x)) = n * x`.
pub const RealFft = struct {
    setup: *anyopaque,
    n: usize,

    pub fn init(n: usize) !RealFft {
        if (!math.isPowerOfTwo(n) or n < min_size) return error.InvalidFftSize;
        const setup = pffft_new_setup(@intCast(n), pffft_real) orelse return error.InvalidFftSize;
        return .{ .setup = setup, .n = n };
    }

    pub fn deinit(self: *RealFft) void {
        pffft_destroy_setup(self.setup);
    }

    pub fn forward(self: RealFft, input: []const f32, output: []f32, work: []f32) void {
        std.debug.assert(input.len >= self.n and output.len >= self.n and work.len >= self.n);
        pffft_transform_ordered(self.setup, input.ptr, output.ptr, work.ptr, pffft_forward);
    }

    pub fn backward(self: RealFft, input: []const f32, output: []f32, work: []f32) void {
        std.debug.assert(input.len >= self.n and output.len >= self.n and work.len >= self.n);
        pffft_transform_ordered(self.setup, input.ptr, output.ptr, work.ptr, pffft_backward);
    }
};

/// In-place complex FFT. `n` complex bins, interleaved re/im in `buf` (length >= 2*n).
/// Inverse is scaled by 1/n so a forward/back pair round-trips.
pub fn fft(buf: []f32, n: usize, inverse: bool) void {
    std.debug.assert(math.isPowerOfTwo(n));
    std.debug.assert(n >= min_size);
    std.debug.assert(buf.len >= n * 2);

    const setup = pffft_new_setup(@intCast(n), pffft_complex) orelse unreachable;
    defer pffft_destroy_setup(setup);

    const samples = n * 2;
    const bytes = samples * @sizeOf(f32);
    const tmp = pffft_aligned_malloc(bytes) orelse unreachable;
    defer pffft_aligned_free(tmp);
    const work = pffft_aligned_malloc(bytes) orelse unreachable;
    defer pffft_aligned_free(work);

    const tmp_f: [*]f32 = @ptrCast(@alignCast(tmp));
    const work_f: [*]f32 = @ptrCast(@alignCast(work));
    @memcpy(tmp_f[0..samples], buf[0..samples]);
    const dir: c_int = if (inverse) pffft_backward else pffft_forward;
    pffft_transform_ordered(setup, tmp_f, tmp_f, work_f, dir);
    if (inverse) {
        const scale = 1.0 / @as(f32, @floatFromInt(n));
        for (tmp_f[0..samples]) |*s| s.* *= scale;
    }
    @memcpy(buf[0..samples], tmp_f[0..samples]);
}

test "fft impulse roundtrip" {
    var buf = [_]f32{0} ** 64;
    buf[0] = 1.0;
    fft(buf[0..], 32, false);
    fft(buf[0..], 32, true);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), buf[0], 1e-4);
    var t: usize = 1;
    while (t < 32) : (t += 1) {
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), buf[2 * t], 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), buf[2 * t + 1], 1e-4);
    }
}

test "real fft roundtrip" {
    const n: usize = 64;
    var input: [64]f32 align(32) = undefined;
    var freq: [64]f32 align(32) = undefined;
    var output: [64]f32 align(32) = undefined;
    var work: [64]f32 align(32) = undefined;
    for (&input, 0..) |*s, i| {
        s.* = @sin(@as(f32, @floatFromInt(i)) * 0.17);
    }
    var real = try RealFft.init(n);
    defer real.deinit();
    real.forward(&input, &freq, &work);
    real.backward(&freq, &output, &work);
    const scale = 1.0 / @as(f32, @floatFromInt(n));
    for (output, input) |got, expect| {
        try std.testing.expectApproxEqAbs(expect, got * scale, 1e-4);
    }
}
