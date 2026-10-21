//! Flat LIR image ownership. A lowered program is copied (copy mode,
//! `ByteContract.mapped`) into one contiguous, adaptively sized buffer that
//! the revision owns; compiler scratch and lowering output stay in ordinary
//! reclaimable allocators and are freed once the copy exists.
const std = @import("std");
const builtin = @import("builtin");
const lir = @import("lir");
const base = @import("base");
const LirImage = lir.LirImage;
/// `zig build -Dimage-initial-bytes=N` overrides the first buffer size, so
/// test runs can force the retry path on every real workload.
const initial_override: ?u64 = @import("roclet_options").image_initial_bytes;

pub const Limits = struct {
    /// First buffer size tried; doubled after each exhausted attempt.
    initial_bytes: usize,
    /// Fail with `error.ImageTooLarge` once a buffer this size is exhausted.
    max_bytes: usize,
};

const mib = 1024 * 1024;

/// Measured images (native, 2026-10-20): Wall Area 5 KiB, the roc-time
/// calendar notebook (demos/04-meeting-windows.roc) 461 KiB. WASM linear
/// memory never shrinks, so start at 1 MiB there; native pages are committed
/// only when touched, so a larger first buffer costs nothing. Powers of two
/// match the WASM allocator's big size classes.
pub const default_limits: Limits = limits: {
    const platform: Limits = if (builtin.cpu.arch == .wasm32)
        .{ .initial_bytes = 1 * mib, .max_bytes = 512 * mib }
    else
        .{ .initial_bytes = 64 * mib, .max_bytes = 2048 * mib };
    const initial = initial_override orelse break :limits platform;
    if (!std.math.isPowerOfTwo(initial) or initial > platform.max_bytes) @compileError("-Dimage-initial-bytes must be a power of two no larger than the image cap");
    break :limits .{ .initial_bytes = initial, .max_bytes = platform.max_bytes };
};

pub const Error = LirImage.CopyError || error{ImageTooLarge};

/// A copied LIR image. The header is the first allocation in `buffer`, the
/// buffer never moves, and every view borrows it.
pub const Image = struct {
    buffer: []align(16) u8,
    header: *LirImage.Header,
    /// Bytes used, recorded as `header.image_size`.
    size: usize,
    /// Buffers tried: one plus the number of doublings.
    attempts: u8,

    pub fn deinit(self: *Image, gpa: std.mem.Allocator) void {
        freeBuffer(gpa, self.buffer);
        self.* = undefined;
    }

    pub fn view(self: *const Image, target_usize: base.target.TargetUsize, scratch: std.mem.Allocator) LirImage.ViewError!LirImage.ProgramView {
        return LirImage.viewMappedImageWithAllocator(self.header, self.buffer.ptr, self.size, target_usize, scratch);
    }
};

/// Copy `program`, its entrypoints and its frozen static data into a flat
/// buffer owned by `gpa`. The inputs may be freed as soon as this returns.
pub fn build(
    gpa: std.mem.Allocator,
    program: *const lir.Program.Result,
    entrypoints: []const LirImage.PlatformEntrypoint,
    static_data: []const lir.Program.StaticDataExport,
    limits: Limits,
) Error!Image {
    const Source = struct {
        program: *const lir.Program.Result,
        entrypoints: []const LirImage.PlatformEntrypoint,
        static_data: []const lir.Program.StaticDataExport,
        fn copy(self: @This(), a: std.mem.Allocator, buffer: []align(16) u8) LirImage.CopyError!LirImage.CopiedProgram {
            return LirImage.copyProgramWithStaticDataIntoBuffer(a, buffer.ptr, buffer.len, .mapped, self.program, self.entrypoints, self.static_data);
        }
    };
    return buildWith(gpa, limits, Source{ .program = program, .entrypoints = entrypoints, .static_data = static_data });
}

/// The retry policy, generic over the copy so tests can stub it. An exhausted
/// buffer (`error.OutOfMemory` from the image allocator) is discarded whole
/// and retried at twice the size; any other error is returned unchanged.
fn buildWith(gpa: std.mem.Allocator, limits: Limits, source: anytype) Error!Image {
    std.debug.assert(limits.initial_bytes > 0 and limits.initial_bytes <= limits.max_bytes);
    var capacity = limits.initial_bytes;
    var attempts: u8 = 0;
    while (true) {
        attempts += 1;
        const buffer = try allocBuffer(gpa, capacity);
        var fba = std.heap.FixedBufferAllocator.init(buffer);
        const header, const program = copyInto(&fba, buffer, source) catch |err| {
            freeBuffer(gpa, buffer);
            switch (err) {
                error.OutOfMemory => {
                    if (capacity >= limits.max_bytes) return error.ImageTooLarge;
                    capacity = @min(limits.max_bytes, capacity *| 2);
                    continue;
                },
                else => |other| return other,
            }
        };
        program.fillHeader(header, fba.end_index) catch |err| {
            freeBuffer(gpa, buffer);
            return err;
        };
        return .{ .buffer = buffer, .header = header, .size = fba.end_index, .attempts = attempts };
    }
}

// Raw calls skip the safe-mode `undefined` fill on alloc and free, which
// would touch, and natively commit, every page of a buffer the image may use
// only part of.
fn allocBuffer(gpa: std.mem.Allocator, len: usize) error{OutOfMemory}![]align(16) u8 {
    const ptr = gpa.rawAlloc(len, .@"16", @returnAddress()) orelse return error.OutOfMemory;
    return @alignCast(ptr[0..len]);
}

fn freeBuffer(gpa: std.mem.Allocator, buffer: []align(16) u8) void {
    gpa.rawFree(buffer, .@"16", @returnAddress());
}

/// The header comes first, as in the compiler's own `publishLirImage`.
fn copyInto(fba: *std.heap.FixedBufferAllocator, buffer: []align(16) u8, source: anytype) LirImage.CopyError!struct { *LirImage.Header, CopyResult(@TypeOf(source)) } {
    const a = fba.allocator();
    const header = try a.create(LirImage.Header);
    return .{ header, try source.copy(a, buffer) };
}

fn CopyResult(comptime Source: type) type {
    return @typeInfo(@typeInfo(@TypeOf(Source.copy)).@"fn".return_type.?).error_union.payload;
}

const Stub = struct {
    /// Bytes the stub copy allocates after the header.
    need: usize,
    fail: ?LirImage.ImageError = null,
    calls: *usize,
    const Copied = struct {
        fn fillHeader(_: Copied, header: *LirImage.Header, image_size: usize) LirImage.ImageError!void {
            header.image_size = image_size;
        }
    };
    fn copy(self: Stub, a: std.mem.Allocator, _: []align(16) u8) LirImage.CopyError!Copied {
        self.calls.* += 1;
        if (self.fail) |err| return err;
        _ = try a.alloc(u8, self.need);
        return .{};
    }
};

test "an exhausted image buffer is retried at twice the size" {
    var calls: usize = 0;
    const limits: Limits = .{ .initial_bytes = 4096, .max_bytes = 1 << 20 };
    // 20000 bytes needs 32 KiB: 4 KiB, 8 KiB and 16 KiB attempts fail first.
    var image = try buildWith(std.testing.allocator, limits, Stub{ .need = 20000, .calls = &calls });
    defer image.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 4), image.attempts);
    try std.testing.expectEqual(@as(usize, 32768), image.buffer.len);
    try std.testing.expectEqual(@as(usize, 20000 + @sizeOf(LirImage.Header)), image.size);
    try std.testing.expectEqual(@as(u64, image.size), image.header.image_size);
    try std.testing.expectEqual(@intFromPtr(image.buffer.ptr), @intFromPtr(image.header));
}

test "a first buffer that fits is used once" {
    var calls: usize = 0;
    var image = try buildWith(std.testing.allocator, .{ .initial_bytes = 1 << 16, .max_bytes = 1 << 16 }, Stub{ .need = 100, .calls = &calls });
    defer image.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 1), image.attempts);
    try std.testing.expectEqual(@as(usize, 1), calls);
}

test "an image larger than the cap fails after the capped attempt" {
    var calls: usize = 0;
    // 4 KiB, 8 KiB, then the 10000-byte cap; none holds 20000 bytes.
    const limits: Limits = .{ .initial_bytes = 4096, .max_bytes = 10000 };
    try std.testing.expectError(error.ImageTooLarge, buildWith(std.testing.allocator, limits, Stub{ .need = 20000, .calls = &calls }));
    try std.testing.expectEqual(@as(usize, 3), calls);
}

test "a buffer too small for the header is retried" {
    var calls: usize = 0;
    var image = try buildWith(std.testing.allocator, .{ .initial_bytes = 16, .max_bytes = 1 << 20 }, Stub{ .need = 0, .calls = &calls });
    defer image.deinit(std.testing.allocator);
    try std.testing.expect(image.attempts > 1);
    try std.testing.expect(image.buffer.len >= @sizeOf(LirImage.Header));
}

test "an invalid image is not retried" {
    var calls: usize = 0;
    try std.testing.expectError(error.InvalidLirImage, buildWith(std.testing.allocator, .{ .initial_bytes = 4096, .max_bytes = 1 << 20 }, Stub{ .need = 0, .fail = error.InvalidLirImage, .calls = &calls }));
    try std.testing.expectEqual(@as(usize, 1), calls);
}
