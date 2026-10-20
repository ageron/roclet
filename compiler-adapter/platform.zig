//! Roclet host ABI. This owns observation policy; compiler internals are unmodified.
const std = @import("std");
const builtin = @import("builtin");
const is_wasm = builtin.cpu.arch == .wasm32;
const builtins = @import("builtins");
pub const host_abi = builtins.host_abi;
pub const RocStr = builtins.str.RocStr;
pub const RocList = builtins.list.RocList;
pub const platform_main_source = @embedFile("platform/main.roc");
pub const echo_module_source = @embedFile("platform/Echo.roc");
/// Receives `value`, `dbg`, `expect_failed`, `crashed` and `test_*` events for
/// one execution, attributed to the root that owns that execution.
pub const Observer = struct {
    ctx: *anyopaque,
    emit: *const fn (ctx: *anyopaque, kind: []const u8, message: []const u8, root: ?[]const u8) void,
    /// The notebook root this execution is attributed to.
    root: ?[]const u8 = null,

    pub fn observe(self: Observer, kind: []const u8, message: []const u8) void {
        self.emit(self.ctx, kind, message, self.root);
    }
    pub fn forRoot(self: Observer, root: ?[]const u8) Observer {
        var result = self;
        result.root = root;
        return result;
    }
};

pub const EchoEnv = struct {
    std_io: std.Io,
    /// Set to true the first time roc_expect_failed is invoked. Allows the
    /// host to exit with a non-zero status after running the program.
    inline_expect_failed: bool = false,
    /// Per-execution observer; null writes to stdout/stderr instead.
    observer: ?Observer = null,
};

/// The only process-wide mutable slot in the adapter besides the immutable
/// builtins. Hosted functions receive no RocOps or environment pointer (see
/// `host_abi.HostedFn`: natural C ABI on native, `(args, ret)` on wasm32), yet
/// `echoHostedFn` must decref its argument. The interpreter run that owns the
/// current RocOps publishes it here. It carries no attribution state: the
/// observer travels in `ops.env`. Single-threaded; never nested.
var active_roc_ops: ?*host_abi.RocOps = null;

pub fn enterRocOps(ops: *host_abi.RocOps) void {
    std.debug.assert(active_roc_ops == null);
    active_roc_ops = ops;
}
pub fn leaveRocOps(ops: *host_abi.RocOps) void {
    std.debug.assert(active_roc_ops == ops);
    active_roc_ops = null;
}
/// True while an interpreter run has published its RocOps (tests assert
/// that no run leaves it behind).
pub fn rocOpsActive() bool {
    return active_roc_ops != null;
}

/// Echo host function: reads a RocStr arg and writes it unchanged to stdout.
/// Ownership of `roc_str` transfers to this host function—the RC insertion
/// pass emits zero RC ops for hosted-call args (see test in `src/lir/arc.zig`
/// "RC hosted call transfers unused refcounted arg to host", and the test
/// platform host in `test/fx/platform/host.zig` which decrefs every RocStr
/// arg). Without this decref every `echo!` call leaks one heap RocStr.
pub fn echoHostedFn(str: RocStr) callconv(.c) void {
    const ops = active_roc_ops.?;
    var owned = str;
    defer owned.decref(ops);

    const message = owned.asSlice();
    const env: *EchoEnv = @ptrCast(@alignCast(ops.env));
    if (env.observer) |observer| {
        observer.observe("value", message);
        return;
    }

    if (comptime is_wasm) {
        const js = struct {
            extern "env" fn js_echo(ptr: [*]const u8, len: usize) void;
        };
        js.js_echo(message.ptr, message.len);
    } else {
        const stdout_file: std.Io.File = .stdout();
        stdout_file.writeStreamingAll(env.std_io, message) catch {};
    }
    // Returns {} (ZST)—no bytes to write to ret_bytes
}

/// wasm uniform-ABI entry for `Echo.line!`. On wasm32 the interpreter cannot
/// synthesize a dynamic-signature C call (see `host_trampoline.available`), so
/// it invokes hosted functions through a uniform `(args_buf, ret_buf)` ABI. The
/// interpreter packs `line!`'s single `Str` argument at offset 0 of `args` and
/// expects no return value, so this reads the RocStr back out and forwards to
/// `echoHostedFn`, which owns and decrefs it exactly as on native.
pub fn echoHostedFnWasm(args: [*]u8, _: [*]u8) callconv(.c) void {
    const str: *const RocStr = @ptrCast(@alignCast(args));
    echoHostedFn(str.*);
}

/// The hosted function pointer the echo platform registers for `Echo.line!`,
/// selected for the current target's hosted-call ABI: the natural-C-ABI
/// `echoHostedFn` on architectures with a register-image trampoline, or the
/// uniform-ABI `echoHostedFnWasm` shim where one is unavailable (wasm).
pub fn echoLineHostedFn() host_abi.HostedFn {
    return if (comptime is_wasm)
        host_abi.hostedFn(&echoHostedFnWasm)
    else
        host_abi.hostedFn(&echoHostedFn);
}

/// Create a minimal RocOps struct for default_app execution.
pub fn makeDefaultRocOps(env: *EchoEnv, hosted_fns: []host_abi.HostedFn) host_abi.RocOps {
    const fns = struct {
        const size_prefix = @sizeOf(usize);

        /// Allocate with a size prefix so realloc/dealloc can recover the old length.
        fn rocAlloc(_: *host_abi.RocOps, length: usize, alignment: usize) callconv(.c) *anyopaque {
            const alloc = if (comptime is_wasm) std.heap.wasm_allocator else std.heap.smp_allocator;
            const total = length + size_prefix;
            const align_enum = std.mem.Alignment.fromByteUnits(@max(alignment, @alignOf(usize)));
            const raw = alloc.rawAlloc(total, align_enum, @returnAddress()) orelse {
                if (comptime is_wasm) @trap() else {
                    std.debug.print("roc_alloc failed: OOM\n", .{});
                    std.process.exit(1);
                }
            };
            // Store the allocation length in the prefix
            const size_slot: *usize = @ptrCast(@alignCast(raw));
            size_slot.* = length;
            return @ptrCast(raw + size_prefix);
        }

        fn rocDealloc(_: *host_abi.RocOps, ptr: *anyopaque, alignment: usize) callconv(.c) void {
            const alloc = if (comptime is_wasm) std.heap.wasm_allocator else std.heap.smp_allocator;
            // Recover the length rocAlloc stored in the prefix, then free the whole block.
            const user_ptr: [*]u8 = @ptrCast(ptr);
            const raw = user_ptr - size_prefix;
            const length = @as(*const usize, @ptrCast(@alignCast(raw))).*;
            const align_enum = std.mem.Alignment.fromByteUnits(@max(alignment, @alignOf(usize)));
            alloc.rawFree(raw[0 .. length + size_prefix], align_enum, @returnAddress());
        }

        fn rocRealloc(_: *host_abi.RocOps, ptr: *anyopaque, new_length: usize, alignment: usize) callconv(.c) *anyopaque {
            const alloc = if (comptime is_wasm) std.heap.wasm_allocator else std.heap.smp_allocator;
            const align_enum = std.mem.Alignment.fromByteUnits(@max(alignment, @alignOf(usize)));

            // Read old size from prefix
            const old_ptr: [*]u8 = @ptrCast(ptr);
            const old_raw = old_ptr - size_prefix;
            const old_size: usize = @as(*const usize, @ptrCast(@alignCast(old_raw))).*;

            // Allocate new block with size prefix
            const new_total = new_length + size_prefix;
            const new_raw = alloc.rawAlloc(new_total, align_enum, @returnAddress()) orelse {
                if (comptime is_wasm) @trap() else {
                    std.debug.print("roc_realloc failed: OOM\n", .{});
                    std.process.exit(1);
                }
            };

            // Write new size prefix
            const new_size_slot: *usize = @ptrCast(@alignCast(new_raw));
            new_size_slot.* = new_length;
            const new_ptr = new_raw + size_prefix;

            // Copy old data (only up to the smaller of old/new sizes)
            const copy_len = @min(old_size, new_length);
            if (copy_len > 0) {
                @memcpy(new_ptr[0..copy_len], old_ptr[0..copy_len]);
            }

            // Free the old block now that its contents have been copied.
            alloc.rawFree(old_raw[0 .. old_size + size_prefix], align_enum, @returnAddress());

            return @ptrCast(new_ptr);
        }

        fn rocDbg(ops: *host_abi.RocOps, bytes: [*]const u8, len: usize) callconv(.c) void {
            const echo_env: *EchoEnv = @ptrCast(@alignCast(ops.env));
            if (echo_env.observer) |observer| {
                observer.observe("dbg", bytes[0..len]);
                return;
            }
            if (comptime is_wasm) {
                // No-op on wasm—no stderr available
            } else {
                const msg = bytes[0..len];
                const stderr_file: std.Io.File = .stderr();
                stderr_file.writeStreamingAll(echo_env.std_io, "[dbg] ") catch {};
                stderr_file.writeStreamingAll(echo_env.std_io, msg) catch {};
                stderr_file.writeStreamingAll(echo_env.std_io, "\n") catch {};
            }
        }
        fn rocExpectFailed(ops: *host_abi.RocOps, bytes: [*]const u8, len: usize) callconv(.c) void {
            const echo_env_for_flag: *EchoEnv = @ptrCast(@alignCast(ops.env));
            echo_env_for_flag.inline_expect_failed = true;
            if (echo_env_for_flag.observer) |observer| {
                observer.observe("expect_failed", bytes[0..len]);
                return;
            }
            if (comptime is_wasm) {
                // No-op on wasm—no stderr available
            } else {
                const echo_env: *EchoEnv = @ptrCast(@alignCast(ops.env));
                const msg = bytes[0..len];
                const stderr_file: std.Io.File = .stderr();
                stderr_file.writeStreamingAll(echo_env.std_io, "Expect failed: ") catch {};
                stderr_file.writeStreamingAll(echo_env.std_io, msg) catch {};
                stderr_file.writeStreamingAll(echo_env.std_io, "\n") catch {};
            }
        }
        fn rocCrashed(ops: *host_abi.RocOps, bytes: [*]const u8, len: usize) callconv(.c) void {
            if (comptime is_wasm) {
                @trap();
            } else {
                const echo_env: *EchoEnv = @ptrCast(@alignCast(ops.env));
                const msg = bytes[0..len];
                const stderr_file: std.Io.File = .stderr();
                stderr_file.writeStreamingAll(echo_env.std_io, "Roc application crashed with this message:\n\n\t") catch {};
                stderr_file.writeStreamingAll(echo_env.std_io, msg) catch {};
                stderr_file.writeStreamingAll(echo_env.std_io, "\n\n") catch {};
                std.process.exit(1);
            }
        }
    };

    return .{
        .env = @ptrCast(env),
        .roc_alloc = &fns.rocAlloc,
        .roc_dealloc = &fns.rocDealloc,
        .roc_realloc = &fns.rocRealloc,
        .roc_dbg = &fns.rocDbg,
        .roc_expect_failed = &fns.rocExpectFailed,
        .roc_crashed = &fns.rocCrashed,
        .hosted_fns = .{ .count = @intCast(hosted_fns.len), .fns = hosted_fns.ptr },
    };
}

pub fn buildCliArgs(args: []const []const u8, ops: *host_abi.RocOps) !RocList {
    const a = if (is_wasm) std.heap.wasm_allocator else std.heap.page_allocator;
    const strings = try a.alloc(RocStr, args.len);
    defer a.free(strings);
    for (args, strings) |arg, *str| str.* = RocStr.fromSlice(arg, ops);
    return RocList.fromSlice(RocStr, strings, true, ops);
}
