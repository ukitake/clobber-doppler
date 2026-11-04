const std = @import("std");

/// Apply a real mask to a packed pffft spectrum, preserving phase.
/// Spectrum layout is `[DC, Nyquist, re1, im1, ...]`, length `fft_size`.
/// `mask` length is `fft_size/2+1` (1 = pass).
pub fn applyMaskPreservePhase(spectrum: []f32, fft_size: usize, mask: []const f32, wet: f32) void {
    const nyquist = fft_size / 2;
    std.debug.assert(spectrum.len >= fft_size);
    std.debug.assert(mask.len >= nyquist + 1);

    spectrum[0] *= 1.0 + wet * (mask[0] - 1.0);
    spectrum[1] *= 1.0 + wet * (mask[nyquist] - 1.0);

    var k: usize = 1;
    while (k < nyquist) : (k += 1) {
        const gain = 1.0 + wet * (mask[k] - 1.0);
        spectrum[2 * k] *= gain;
        spectrum[2 * k + 1] *= gain;
    }
}
