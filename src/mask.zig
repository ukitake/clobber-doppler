const std = @import("std");

/// Pass-through mask with a hard zero on `[f_min_hz, f_max_hz]`.
/// `mask_bins` covers the non-negative spectrum (`fft_size/2+1` bins).
pub fn fillBlankBand(
    mask_bins: []f32,
    sample_rate: u32,
    fft_size: u32,
    f_min_hz: f32,
    f_max_hz: f32,
) void {
    const n_bins = fft_size / 2 + 1;
    std.debug.assert(mask_bins.len >= n_bins);
    const bin_hz = @as(f32, @floatFromInt(sample_rate)) / @as(f32, @floatFromInt(fft_size));
    @memset(mask_bins[0..n_bins], 1.0);
    var i: usize = 0;
    while (i < n_bins) : (i += 1) {
        const f = @as(f32, @floatFromInt(i)) * bin_hz;
        if (f >= f_min_hz and f <= f_max_hz) mask_bins[i] = 0;
    }
}

/// Apply real mask to complex spectrum in-place, preserving phase.
/// `mask` length is fft_size/2+1; mirrored to negative freqs.
pub fn applyMaskPreservePhase(spectrum: []f32, fft_size: usize, mask: []const f32, wet: f32) void {
    const half = fft_size / 2 + 1;
    std.debug.assert(spectrum.len >= fft_size * 2);
    std.debug.assert(mask.len >= half);

    var i: usize = 0;
    while (i < half) : (i += 1) {
        const m = mask[i];
        const gain = 1.0 + wet * (m - 1.0); // wet blends toward mask
        spectrum[2 * i] *= gain;
        spectrum[2 * i + 1] *= gain;
        if (i > 0 and i < fft_size / 2) {
            const j = fft_size - i;
            spectrum[2 * j] *= gain;
            spectrum[2 * j + 1] *= gain;
        }
    }
}
