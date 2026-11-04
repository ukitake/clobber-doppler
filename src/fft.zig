const std = @import("std");
const math = std.math;

/// In-place radix-2 Cooley–Tukey FFT. `n` must be a power of two.
/// Layout: interleaved re/im pairs in `buf` of length `2*n`.
pub fn fft(buf: []f32, n: usize, inverse: bool) void {
    std.debug.assert(math.isPowerOfTwo(n));
    std.debug.assert(buf.len >= n * 2);

    // Bit-reverse permutation
    var i: usize = 1;
    var j: usize = 0;
    while (i < n) : (i += 1) {
        var bit = n >> 1;
        while (j & bit != 0) : (bit >>= 1) {
            j ^= bit;
        }
        j ^= bit;
        if (i < j) {
            const re_i = buf[2 * i];
            const im_i = buf[2 * i + 1];
            buf[2 * i] = buf[2 * j];
            buf[2 * i + 1] = buf[2 * j + 1];
            buf[2 * j] = re_i;
            buf[2 * j + 1] = im_i;
        }
    }

    var len: usize = 2;
    while (len <= n) : (len <<= 1) {
        const sign: f32 = if (inverse) 1.0 else -1.0;
        const ang = sign * 2.0 * math.pi / @as(f32, @floatFromInt(len));
        const wlen_re = @cos(ang);
        const wlen_im = @sin(ang);
        var k: usize = 0;
        while (k < n) : (k += len) {
            var w_re: f32 = 1.0;
            var w_im: f32 = 0.0;
            var half: usize = 0;
            while (half < len / 2) : (half += 1) {
                const u_re = buf[2 * (k + half)];
                const u_im = buf[2 * (k + half) + 1];
                const v_re = buf[2 * (k + half + len / 2)] * w_re - buf[2 * (k + half + len / 2) + 1] * w_im;
                const v_im = buf[2 * (k + half + len / 2)] * w_im + buf[2 * (k + half + len / 2) + 1] * w_re;
                buf[2 * (k + half)] = u_re + v_re;
                buf[2 * (k + half) + 1] = u_im + v_im;
                buf[2 * (k + half + len / 2)] = u_re - v_re;
                buf[2 * (k + half + len / 2) + 1] = u_im - v_im;
                const next_w_re = w_re * wlen_re - w_im * wlen_im;
                const next_w_im = w_re * wlen_im + w_im * wlen_re;
                w_re = next_w_re;
                w_im = next_w_im;
            }
        }
    }

    if (inverse) {
        const scale = 1.0 / @as(f32, @floatFromInt(n));
        i = 0;
        while (i < n) : (i += 1) {
            buf[2 * i] *= scale;
            buf[2 * i + 1] *= scale;
        }
    }
}

test "fft impulse roundtrip" {
    var buf = [_]f32{0} ** 32;
    buf[0] = 1.0;
    fft(buf[0..], 16, false);
    fft(buf[0..], 16, true);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), buf[0], 1e-5);
    var t: usize = 1;
    while (t < 16) : (t += 1) {
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), buf[2 * t], 1e-5);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), buf[2 * t + 1], 1e-5);
    }
}
