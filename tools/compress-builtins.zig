//! Host build tool for the compiler's existing compressed-builtins ABI.
const std = @import("std");
extern fn ZSTD_compressBound(usize) usize;
extern fn ZSTD_compress(?*anyopaque, usize, ?*const anyopaque, usize, c_int) usize;
extern fn ZSTD_isError(usize) c_uint;

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 3) return error.ExpectedInputAndOutput;
    const input = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], a, .unlimited);
    const output = try a.alloc(u8, ZSTD_compressBound(input.len));
    const size = ZSTD_compress(output.ptr, output.len, input.ptr, input.len, 9);
    if (ZSTD_isError(size) != 0) return error.CompressionFailed;
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[2], .data = output[0..size] });
}
