//! Lightweight entry point; native evaluation remains in its companion engine.
const std = @import("std");
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len > 1 and std.mem.eql(u8, args[1], "serve")) return @import("serve.zig").serveProject(init, args[2..]);
    if (args.len == 1 or std.mem.eql(u8, args[1], "--help")) {
        try std.Io.File.stdout().writeStreamingAll(init.io, "Usage: roclet serve [DIRECTORY|NOTEBOOK.roc|NOTEBOOK.md] [--port 4173] [--no-browser]\n" ++
            "       roclet run|check|parse|convert FILE [OPTIONS]\n\n" ++
            "serve opens the current directory by default. --assets DIR selects the web distribution.\n" ++
            "Native commands are forwarded to roclet-native.\n");
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
