const std = @import("std");
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    var tar: std.Io.Writer.Allocating = .init(a);
    var writer = std.tar.Writer{ .underlying_writer = &tar.writer };
    try writer.writeFileBytes("main.roc", "package [Geometry] {}\n", .{ .mtime = 0 });
    try writer.writeFileBytes("Geometry.roc", "module [answer]\nanswer = 42\n", .{ .mtime = 0 });
    try writer.finishPedantically();
    const payload = tar.written();
    const frame = try a.alloc(u8, 12 + payload.len);
    @memcpy(frame[0..4], "\x28\xb5\x2f\xfd");
    frame[4] = 0xa0;
    std.mem.writeInt(u32, frame[5..9], @intCast(payload.len), .little);
    std.mem.writeInt(u24, frame[9..12], (@as(u24, @intCast(payload.len)) << 3) | 1, .little);
    @memcpy(frame[12..], payload);
    var hash: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(frame, &hash, .{});
    var digits: [44]u32 = @splat(0);
    var len: usize = 1;
    for (hash) |byte| {
        var carry: u32 = byte;
        for (digits[0..len]) |*digit| {
            const n = digit.* * 256 + carry;
            digit.* = n % 58;
            carry = n / 58;
        }
        while (carry != 0) {
            digits[len] = carry % 58;
            len += 1;
            carry /= 58;
        }
    }
    var name: [44]u8 = undefined;
    for (0..len) |i| name[i] = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"[digits[len - i - 1]];
    const path = try std.fmt.allocPrint(a, "artifacts/{s}.tar.zst", .{name[0..len]});
    try std.Io.Dir.cwd().createDirPath(init.io, "artifacts");
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = frame });
    try std.Io.File.stdout().writeStreamingAll(init.io, path);
}
