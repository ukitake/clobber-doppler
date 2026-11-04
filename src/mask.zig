const std = @import("std");

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
