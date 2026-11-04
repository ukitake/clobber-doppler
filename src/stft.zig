const std = @import("std");
const fft = @import("fft.zig");
const Config = @import("config.zig").Config;

pub const Stft = struct {
    cfg: Config,
    allocator: std.mem.Allocator,
    window: []f32,
    analysis: []f32, // time-domain windowed frame
    spectrum: []f32, // interleaved complex
    ola: []f32, // overlap-add buffer
    input_fifo: std.ArrayList(f32),
    output_fifo: std.ArrayList(f32),
    ola_pos: usize,
    frames_pushed: usize,

    pub fn init(allocator: std.mem.Allocator, cfg: Config) !Stft {
        const n = cfg.fft_size;
        const window = try allocator.alloc(f32, n);
        // Hann window (periodic) with COLA-friendly scale for 75% overlap (hop=n/4)
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
            window[i] = 0.5 - 0.5 * @cos(2.0 * std.math.pi * t);
        }
        // For hop = n/4, Hann COLA sum ≈ 1.5; normalize synthesis by hop coherency later.
        const analysis = try allocator.alloc(f32, n);
        @memset(analysis, 0);
        const spectrum = try allocator.alloc(f32, n * 2);
        @memset(spectrum, 0);
        const ola = try allocator.alloc(f32, n);
        @memset(ola, 0);

        var input_fifo = std.ArrayList(f32).init(allocator);
        try input_fifo.ensureTotalCapacity(n * 2);
        var output_fifo = std.ArrayList(f32).init(allocator);
        try output_fifo.ensureTotalCapacity(n * 2);

        return .{
            .cfg = cfg,
            .allocator = allocator,
            .window = window,
            .analysis = analysis,
            .spectrum = spectrum,
            .ola = ola,
            .input_fifo = input_fifo,
            .output_fifo = output_fifo,
            .ola_pos = 0,
            .frames_pushed = 0,
        };
    }

    pub fn deinit(self: *Stft) void {
        self.allocator.free(self.window);
        self.allocator.free(self.analysis);
        self.allocator.free(self.spectrum);
        self.allocator.free(self.ola);
        self.input_fifo.deinit();
        self.output_fifo.deinit();
    }

    pub fn pushInput(self: *Stft, samples: []const f32) !void {
        try self.input_fifo.appendSlice(samples);
    }

    pub fn framesReady(self: *const Stft) bool {
        return self.input_fifo.items.len >= self.cfg.fft_size;
    }

    /// Analyze next hop: window → FFT into self.spectrum. Returns false if not enough input.
    pub fn analyzeFrame(self: *Stft) bool {
        const n = self.cfg.fft_size;
        const hop = self.cfg.hop_size;
        if (self.input_fifo.items.len < n) return false;

        @memcpy(self.analysis[0..n], self.input_fifo.items[0..n]);
        // Advance hop
        const remain = self.input_fifo.items.len - hop;
        std.mem.copyForwards(f32, self.input_fifo.items[0..remain], self.input_fifo.items[hop..]);
        self.input_fifo.shrinkRetainingCapacity(remain);

        @memset(self.spectrum, 0);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            self.spectrum[2 * i] = self.analysis[i] * self.window[i];
            self.spectrum[2 * i + 1] = 0;
        }
        fft.fft(self.spectrum, n, false);
        self.frames_pushed += 1;
        return true;
    }

    /// After mask applied to spectrum, IFFT + OLA into output fifo.
    pub fn synthesizeFrame(self: *Stft) !void {
        const n = self.cfg.fft_size;
        const hop = self.cfg.hop_size;
        fft.fft(self.spectrum, n, true);

        // Window again (WOLA) and normalize for hop=n/4 Hann (COLA ≈ 1.5)
        const cola_norm: f32 = 1.5;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const s = self.spectrum[2 * i] * self.window[i] / cola_norm;
            self.ola[i] += s;
        }

        // Emit hop samples from front of OLA
        try self.output_fifo.appendSlice(self.ola[0..hop]);
        // Shift OLA left by hop
        const remain = n - hop;
        std.mem.copyForwards(f32, self.ola[0..remain], self.ola[hop..n]);
        @memset(self.ola[remain..n], 0);
    }

    pub fn popOutput(self: *Stft, dest: []f32) usize {
        const n = @min(dest.len, self.output_fifo.items.len);
        if (n == 0) return 0;
        @memcpy(dest[0..n], self.output_fifo.items[0..n]);
        const remain = self.output_fifo.items.len - n;
        std.mem.copyForwards(f32, self.output_fifo.items[0..remain], self.output_fifo.items[n..]);
        self.output_fifo.shrinkRetainingCapacity(remain);
        return n;
    }

    /// Push silence hops to drain OLA (for flush).
    pub fn pushSilenceHop(self: *Stft) !void {
        const zeros = try self.allocator.alloc(f32, self.cfg.hop_size);
        defer self.allocator.free(zeros);
        @memset(zeros, 0);
        try self.pushInput(zeros);
    }
};
