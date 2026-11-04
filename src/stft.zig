const std = @import("std");
const fft = @import("fft.zig");
const Config = @import("config.zig").Config;

pub const Stft = struct {
    cfg: Config,
    allocator: std.mem.Allocator,
    real: fft.RealFft,
    window: []f32,
    time: []align(32) f32,
    /// Packed real spectrum: [DC, Nyquist, re1, im1, ...], length fft_size.
    spectrum: []align(32) f32,
    work: []align(32) f32,
    ola: []f32,
    silence: []f32,
    input_fifo: std.ArrayList(f32),
    input_read: usize,
    output_fifo: std.ArrayList(f32),
    output_read: usize,
    ola_pos: usize,
    frames_pushed: usize,

    pub fn init(allocator: std.mem.Allocator, cfg: Config) !Stft {
        const n: usize = cfg.fft_size;
        const hop: usize = cfg.hop_size;
        var real = try fft.RealFft.init(n);
        errdefer real.deinit();

        const window = try allocator.alloc(f32, n);
        errdefer allocator.free(window);
        // Hann window (periodic). Synthesis divides by the hop=n/4 COLA gain.
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
            window[i] = 0.5 - 0.5 * @cos(2.0 * std.math.pi * t);
        }

        const time = try allocator.alignedAlloc(f32, 32, n);
        errdefer allocator.free(time);
        const spectrum = try allocator.alignedAlloc(f32, 32, n);
        errdefer allocator.free(spectrum);
        const work = try allocator.alignedAlloc(f32, 32, n);
        errdefer allocator.free(work);
        @memset(time, 0);
        @memset(spectrum, 0);
        @memset(work, 0);

        const ola = try allocator.alloc(f32, n);
        errdefer allocator.free(ola);
        @memset(ola, 0);

        const silence = try allocator.alloc(f32, hop);
        errdefer allocator.free(silence);
        @memset(silence, 0);

        var input_fifo = std.ArrayList(f32).init(allocator);
        errdefer input_fifo.deinit();
        try input_fifo.ensureTotalCapacity(n * 2);
        var output_fifo = std.ArrayList(f32).init(allocator);
        errdefer output_fifo.deinit();
        try output_fifo.ensureTotalCapacity(n * 2);

        return .{
            .cfg = cfg,
            .allocator = allocator,
            .real = real,
            .window = window,
            .time = time,
            .spectrum = spectrum,
            .work = work,
            .ola = ola,
            .silence = silence,
            .input_fifo = input_fifo,
            .input_read = 0,
            .output_fifo = output_fifo,
            .output_read = 0,
            .ola_pos = 0,
            .frames_pushed = 0,
        };
    }

    pub fn deinit(self: *Stft) void {
        self.real.deinit();
        self.allocator.free(self.window);
        self.allocator.free(self.time);
        self.allocator.free(self.spectrum);
        self.allocator.free(self.work);
        self.allocator.free(self.ola);
        self.allocator.free(self.silence);
        self.input_fifo.deinit();
        self.output_fifo.deinit();
    }

    pub fn pushInput(self: *Stft, samples: []const f32) !void {
        self.compactInput();
        try self.input_fifo.appendSlice(samples);
    }

    pub fn framesReady(self: *const Stft) bool {
        return self.inputAvailable() >= self.cfg.fft_size;
    }

    pub fn inputAvailable(self: *const Stft) usize {
        return self.input_fifo.items.len - self.input_read;
    }

    pub fn outputAvailable(self: *const Stft) usize {
        return self.output_fifo.items.len - self.output_read;
    }

    /// Analyze next hop: window → real FFT into self.spectrum. Returns false if not enough input.
    pub fn analyzeFrame(self: *Stft) bool {
        const n = self.cfg.fft_size;
        const hop = self.cfg.hop_size;
        if (self.inputAvailable() < n) return false;

        const src = self.input_fifo.items[self.input_read..][0..n];
        var i: usize = 0;
        while (i < n) : (i += 1) {
            self.time[i] = src[i] * self.window[i];
        }
        self.input_read += hop;
        self.real.forward(self.time, self.spectrum, self.work);
        self.frames_pushed += 1;
        return true;
    }

    /// After the mask is applied to spectrum, inverse FFT + OLA into the output fifo.
    pub fn synthesizeFrame(self: *Stft) !void {
        const n = self.cfg.fft_size;
        const hop = self.cfg.hop_size;
        self.real.backward(self.spectrum, self.time, self.work);

        // WOLA. pffft is unnormalized (backward = n * forward), and Hann at hop n/4 sums to 1.5.
        const scale = 1.0 / (@as(f32, @floatFromInt(n)) * 1.5);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            self.ola[i] += self.time[i] * self.window[i] * scale;
        }

        try self.output_fifo.appendSlice(self.ola[0..hop]);
        const remain = n - hop;
        std.mem.copyForwards(f32, self.ola[0..remain], self.ola[hop..n]);
        @memset(self.ola[remain..n], 0);
    }

    pub fn popOutput(self: *Stft, dest: []f32) usize {
        const n = @min(dest.len, self.outputAvailable());
        if (n == 0) return 0;
        @memcpy(dest[0..n], self.output_fifo.items[self.output_read..][0..n]);
        self.output_read += n;
        self.compactOutput();
        return n;
    }

    /// Push one hop of silence to drain the OLA (for flush).
    pub fn pushSilenceHop(self: *Stft) !void {
        try self.pushInput(self.silence);
    }

    fn compactInput(self: *Stft) void {
        if (self.input_read < self.cfg.fft_size) return;
        const remain = self.input_fifo.items.len - self.input_read;
        std.mem.copyForwards(f32, self.input_fifo.items[0..remain], self.input_fifo.items[self.input_read..]);
        self.input_fifo.shrinkRetainingCapacity(remain);
        self.input_read = 0;
    }

    fn compactOutput(self: *Stft) void {
        if (self.output_read < self.cfg.fft_size) return;
        const remain = self.output_fifo.items.len - self.output_read;
        std.mem.copyForwards(f32, self.output_fifo.items[0..remain], self.output_fifo.items[self.output_read..]);
        self.output_fifo.shrinkRetainingCapacity(remain);
        self.output_read = 0;
    }
};
