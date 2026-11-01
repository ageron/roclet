//! Lightweight entry point; native evaluation remains in its companion engine.
const std = @import("std");
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len == 1 or (!std.mem.eql(u8, args[1], "run") and !std.mem.eql(u8, args[1], "check") and !std.mem.eql(u8, args[1], "parse") and !std.mem.eql(u8, args[1], "convert") and !std.mem.eql(u8, args[1], "--bridge"))) {
        try @import("serve.zig").main(init);
        if (args.len == 1 or std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))
            try std.Io.File.stdout().writeStreamingAll(init.io, "\nAlso available in this build: roclet run|check|parse|convert FILE [OPTIONS]\n");
        return;
    }
    const dir = try std.process.executableDirPathAlloc(init.io, a);
    const engine = try std.fs.path.join(a, &.{ dir, "roclet-native" });
    var command: std.ArrayList([]const u8) = .empty;
    try command.append(a, engine);
    try command.appendSlice(a, args[1..]);
    var child = try std.process.spawn(init.io, .{ .argv = command.items });
    const term = try child.wait(init.io);
    switch (term) {
        .exited => |code| std.process.exit(code),
        else => std.process.exit(1),
    }
}
