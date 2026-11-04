const std = @import("std");
const Config = @import("config.zig").Config;

pub const Track = struct {
    freq_hz: f32 = 0,
    vel_hz: f32 = 0, // Hz per frame (causal estimate)
    mag: f32 = 0,
    age: u32 = 0,
    missed: u32 = 0,
    active: bool = false,
};

pub const Tracker = struct {
    cfg: Config,
    tracks: []Track,
    allocator: std.mem.Allocator,
    /// Squared bin power in the track band, reused each frame.
    scratch_mag: []f32,

    pub fn init(allocator: std.mem.Allocator, cfg: Config) !Tracker {
        const tracks = try allocator.alloc(Track, cfg.max_tracks);
        @memset(tracks, .{});
        const scratch_mag = try allocator.alloc(f32, cfg.fft_size / 2 + 1);
        @memset(scratch_mag, 0);
        return .{
            .cfg = cfg,
            .tracks = tracks,
            .allocator = allocator,
            .scratch_mag = scratch_mag,
        };
    }

    pub fn deinit(self: *Tracker) void {
        self.allocator.free(self.tracks);
        self.allocator.free(self.scratch_mag);
    }

    /// Update tracks from a packed real spectrum (`[DC, Nyquist, re1, im1, ...]`, length fft_size).
    /// Fills `mask_bins` (same length as half-spectrum) with attenuation gains in [gain_floor, 1].
    pub fn updateAndBuildMask(self: *Tracker, spectrum: []const f32, mask_bins: []f32) void {
        const n = self.cfg.fft_size;
        const half = n / 2 + 1;
        std.debug.assert(spectrum.len >= n);
        std.debug.assert(mask_bins.len >= half);

        const bin_hz = self.cfg.binHz();
        const b_lo = self.cfg.hzToBin(self.cfg.track_f_min_hz);
        const b_hi = @min(self.cfg.hzToBin(self.cfg.track_f_max_hz), half - 1);

        // Power in the track band, plus one bin either side so peak tests can read neighbors.
        const fill_lo = if (b_lo == 0) 0 else b_lo - 1;
        const fill_hi = @min(b_hi + 1, half - 1);
        var bin: usize = fill_lo;
        while (bin <= fill_hi) : (bin += 1) {
            self.scratch_mag[bin] = binPower(spectrum, n, bin);
        }

        var floor_acc: f32 = 0;
        var floor_n: f32 = 0;
        var i: usize = b_lo;
        while (i <= b_hi) : (i += 1) {
            floor_acc += self.scratch_mag[i];
            floor_n += 1;
        }
        const mean_mag = if (floor_n > 0) floor_acc / floor_n else 0.0;
        // Use a conservative peak threshold relative to band mean.
        const peak_thresh = mean_mag * 2.5 + 1e-8;

        // Collect local peaks in band
        var peak_bins: [32]usize = undefined;
        var peak_mags: [32]f32 = undefined;
        var n_peaks: usize = 0;
        i = @max(b_lo, 1);
        const i_end = @min(b_hi, half - 2);
        while (i <= i_end) : (i += 1) {
            const m = self.scratch_mag[i];
            if (m >= peak_thresh and m >= self.scratch_mag[i - 1] and m >= self.scratch_mag[i + 1]) {
                if (n_peaks < peak_bins.len) {
                    peak_bins[n_peaks] = i;
                    peak_mags[n_peaks] = m;
                    n_peaks += 1;
                } else {
                    // Replace weakest if stronger
                    var weakest: usize = 0;
                    var wmag = peak_mags[0];
                    var p: usize = 1;
                    while (p < peak_bins.len) : (p += 1) {
                        if (peak_mags[p] < wmag) {
                            wmag = peak_mags[p];
                            weakest = p;
                        }
                    }
                    if (m > wmag) {
                        peak_bins[weakest] = i;
                        peak_mags[weakest] = m;
                    }
                }
            }
        }

        // Associate peaks to existing tracks (greedy nearest with velocity prediction)
        var used_peaks = [_]bool{false} ** 32;
        const assoc_tol_hz: f32 = 18.0;

        for (self.tracks) |*tr| {
            if (!tr.active) continue;
            const pred = tr.freq_hz + tr.vel_hz;
            var best: ?usize = null;
            var best_dist: f32 = assoc_tol_hz;
            var p: usize = 0;
            while (p < n_peaks) : (p += 1) {
                if (used_peaks[p]) continue;
                const f = @as(f32, @floatFromInt(peak_bins[p])) * bin_hz;
                const d = @abs(f - pred);
                if (d < best_dist) {
                    best_dist = d;
                    best = p;
                }
            }
            if (best) |bp| {
                used_peaks[bp] = true;
                const f = @as(f32, @floatFromInt(peak_bins[bp])) * bin_hz;
                const new_vel = f - tr.freq_hz;
                // Smooth velocity (causal EMA)
                tr.vel_hz = 0.7 * tr.vel_hz + 0.3 * new_vel;
                tr.freq_hz = f;
                tr.mag = 0.6 * tr.mag + 0.4 * peak_mags[bp];
                tr.age += 1;
                tr.missed = 0;
            } else {
                // Coast with last velocity
                tr.freq_hz += tr.vel_hz;
                tr.missed += 1;
                tr.mag *= 0.85;
                if (tr.missed > 8 or tr.freq_hz < self.cfg.track_f_min_hz * 0.8 or tr.freq_hz > self.cfg.track_f_max_hz * 1.2) {
                    tr.* = .{};
                }
            }
        }

        // Spawn tracks for unmatched strong peaks
        var p: usize = 0;
        while (p < n_peaks) : (p += 1) {
            if (used_peaks[p]) continue;
            // Prefer peaks that look like fundamentals (not near 2x of existing)
            const f = @as(f32, @floatFromInt(peak_bins[p])) * bin_hz;
            var harmonic_of_existing = false;
            for (self.tracks) |tr| {
                if (!tr.active) continue;
                var h: u32 = 2;
                while (h <= self.cfg.max_harmonics) : (h += 1) {
                    const hf = tr.freq_hz * @as(f32, @floatFromInt(h));
                    if (@abs(f - hf) < assoc_tol_hz) {
                        harmonic_of_existing = true;
                        break;
                    }
                }
                if (harmonic_of_existing) break;
            }
            if (harmonic_of_existing) continue;

            var slot: ?usize = null;
            for (self.tracks, 0..) |tr, ti| {
                if (!tr.active) {
                    slot = ti;
                    break;
                }
            }
            // Or replace weakest young track
            if (slot == null) {
                var weakest_i: usize = 0;
                var weakest_mag = self.tracks[0].mag;
                for (self.tracks, 0..) |tr, ti| {
                    if (tr.mag < weakest_mag) {
                        weakest_mag = tr.mag;
                        weakest_i = ti;
                    }
                }
                if (peak_mags[p] > weakest_mag * 1.2) slot = weakest_i;
            }
            if (slot) |si| {
                self.tracks[si] = .{
                    .freq_hz = f,
                    .vel_hz = 0,
                    .mag = peak_mags[p],
                    .age = 1,
                    .missed = 0,
                    .active = true,
                };
            }
        }

        // Build soft spectral mask (1 = pass, gain_floor = max atten).
        // Flat-bottom raised-cosine notch: strong kill near center, soft edges.
        const depth_lin = std.math.pow(f32, 10.0, -self.cfg.mask_depth_db / 20.0);
        const half_w = self.cfg.mask_half_width_hz;
        @memset(mask_bins[0..half], 1.0);

        for (self.tracks) |tr| {
            if (!tr.active or tr.age < 1) continue;
            var harm: u32 = 1;
            while (harm <= self.cfg.max_harmonics) : (harm += 1) {
                const f0 = tr.freq_hz * @as(f32, @floatFromInt(harm));
                if (f0 > @as(f32, @floatFromInt(self.cfg.sample_rate)) * 0.48) break;
                applyNotch(mask_bins[0..half], f0 / bin_hz, half_w / bin_hz, depth_lin);
            }
        }

        // Fallback: suppress strong local peaks in-band (+ their harmonics).
        i = @max(b_lo, 1);
        while (i <= i_end) : (i += 1) {
            const m = self.scratch_mag[i];
            if (m >= peak_thresh and m >= self.scratch_mag[i - 1] and m >= self.scratch_mag[i + 1]) {
                // Parabolic interpolation for sub-bin center
                const ym1 = self.scratch_mag[i - 1];
                const y0 = self.scratch_mag[i];
                const yp1 = self.scratch_mag[i + 1];
                const denom = ym1 - 2.0 * y0 + yp1;
                const delta: f32 = if (@abs(denom) > 1e-12) 0.5 * (ym1 - yp1) / denom else 0.0;
                const center = @as(f32, @floatFromInt(i)) + std.math.clamp(delta, -0.5, 0.5);
                var harm: u32 = 1;
                while (harm <= self.cfg.max_harmonics) : (harm += 1) {
                    const c = center * @as(f32, @floatFromInt(harm));
                    if (c > @as(f32, @floatFromInt(half - 1))) break;
                    applyNotch(mask_bins[0..half], c, half_w / bin_hz, depth_lin);
                }
            }
        }
    }
};

fn binPower(spectrum: []const f32, fft_size: usize, bin: usize) f32 {
    if (bin == 0) {
        const re = spectrum[0];
        return re * re;
    }
    if (bin == fft_size / 2) {
        const re = spectrum[1];
        return re * re;
    }
    const re = spectrum[2 * bin];
    const im = spectrum[2 * bin + 1];
    return re * re + im * im;
}

fn applyNotch(mask_bins: []f32, center_bin: f32, half_width_bins: f32, depth_lin: f32) void {
    const flat = @max(half_width_bins * 0.55, 1.0); // bins at full depth
    const taper = @max(half_width_bins * 0.9, 1.5); // additional soft edge
    const r = @as(usize, @intFromFloat(@ceil(flat + taper)));
    const c_i: i32 = @intFromFloat(@round(center_bin));
    var di: i32 = -@as(i32, @intCast(r));
    while (di <= @as(i32, @intCast(r))) : (di += 1) {
        const bi = c_i + di;
        if (bi < 0 or bi >= @as(i32, @intCast(mask_bins.len))) continue;
        const bu: usize = @intCast(bi);
        const dist = @abs(@as(f32, @floatFromInt(bi)) - center_bin);
        var g: f32 = 1.0;
        if (dist <= flat) {
            g = depth_lin;
        } else if (dist < flat + taper) {
            const t = (dist - flat) / taper; // 0..1
            // Raised-cosine from depth → 1
            const fade = 0.5 - 0.5 * @cos(std.math.pi * t);
            g = depth_lin + (1.0 - depth_lin) * fade;
        }
        mask_bins[bu] = @min(mask_bins[bu], g);
    }
}
