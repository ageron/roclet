//! Persistent virtual files and the compiler's content-addressed artifact store.
//! No Roc values or source JSON are serialized into this cache by Roclet.
const std = @import("std");
const CoreCtx = @import("ctx").CoreCtx;
const unbundle = @import("unbundle");
const A = std.mem.Allocator;
const gpa = if (@import("builtin").cpu.arch == .wasm32) std.heap.wasm_allocator else std.heap.page_allocator;
pub const identity = "roclet-cache-v1/" ++ @import("build_options").compiler_compatibility_id;
pub var global: Workspace = .{};
pub const RequiredPackage = struct { url: []const u8, destination: []const u8 };
const File = struct { bytes: []u8, dirty: bool = false };
pub const Workspace = struct {
    files: std.StringHashMapUnmanaged(File) = .{},
    required: std.ArrayList(RequiredPackage) = .empty,
    fingerprint: ?[64]u8 = null,
    pub fn contentIdentity(self: *Workspace, a: A) ![]const u8 {
        if (self.fingerprint) |hash| return a.dupe(u8, &hash);
        const names = try a.alloc([]const u8, self.files.count());
        defer a.free(names);
        var count: usize = 0;
        var it = self.files.keyIterator();
        while (it.next()) |name| if (std.mem.startsWith(u8, name.*, "/workspace/") or std.mem.startsWith(u8, name.*, "/bundles/")) {
            names[count] = name.*;
            count += 1;
        };
        std.mem.sort([]const u8, names[0..count], {}, struct {
            fn less(_: void, lhs: []const u8, rhs: []const u8) bool {
                return std.mem.lessThan(u8, lhs, rhs);
            }
        }.less);
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        for (names[0..count]) |name| {
            hash.update(name);
            hash.update(&.{0});
            hash.update(self.files.get(name).?.bytes);
            hash.update(&.{0});
        }
        var digest: [32]u8 = undefined;
        hash.final(&digest);
        self.fingerprint = std.fmt.bytesToHex(digest, .lower);
        return a.dupe(u8, &self.fingerprint.?);
    }
    pub fn put(self: *Workspace, path: []const u8, bytes: []const u8, dirty: bool) !void {
        if (path.len == 0 or path[0] != '/' or path.len > 4096 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
        if (!std.mem.startsWith(u8, path, "/cache/")) self.fingerprint = null;
        const data = try gpa.dupe(u8, bytes);
        errdefer gpa.free(data);
        const entry = try self.files.getOrPut(gpa, path);
        if (entry.found_existing) {
            if (std.mem.eql(u8, entry.value_ptr.bytes, bytes)) {
                gpa.free(data);
                return;
            }
            gpa.free(entry.value_ptr.bytes);
        } else entry.key_ptr.* = try gpa.dupe(u8, path);
        entry.value_ptr.* = .{ .bytes = data, .dirty = dirty };
    }
    pub fn drop(self: *Workspace, path: []const u8) void {
        if (!std.mem.startsWith(u8, path, "/cache/")) self.fingerprint = null;
        if (self.files.fetchRemove(path)) |entry| {
            gpa.free(entry.key);
            gpa.free(entry.value.bytes);
        }
    }
    pub fn io(self: *Workspace, a: A) CoreCtx {
        var result = CoreCtx.testing(a, a);
        result.ctx = self;
        result.vtable.readFile = read;
        result.vtable.readFileInto = readInto;
        result.vtable.writeFile = write;
        result.vtable.writeFileStream = writeStream;
        result.vtable.fileExists = exists;
        result.vtable.stat = stat;
        result.vtable.listDir = list;
        result.vtable.listDirTop = listTop;
        result.vtable.canonicalize = canonicalize;
        result.vtable.makePath = makePath;
        result.vtable.createDir = makePath;
        result.vtable.rename = rename;
        result.vtable.getEnvVar = env;
        result.vtable.fetchUrl = fetch;
        result.vtable.deleteFile = remove;
        result.vtable.deleteTree = removeTree;
        result.vtable.deleteDir = removeTree;
        result.vtable.timestampNow = now;
        return result;
    }
    pub fn clearRequired(self: *Workspace) void {
        for (self.required.items) |item| {
            gpa.free(item.url);
            gpa.free(item.destination);
        }
        self.required.clearRetainingCapacity();
    }
    pub fn importCache(self: *Workspace, bytes: []const u8) !void {
        if (!std.mem.startsWith(u8, bytes, "RLC1")) return error.InvalidCache;
        var at: usize = 4;
        // Validate the complete envelope before mutating the live store.
        while (at < bytes.len) {
            const e = try decodeEntry(bytes, &at);
            if (!std.mem.startsWith(u8, e.path, "/cache/") or std.mem.indexOf(u8, e.path, "..") != null) return error.InvalidCache;
        }
        at = 4;
        while (at < bytes.len) {
            const e = try decodeEntry(bytes, &at);
            try self.put(e.path, e.data, false);
        }
    }
    pub fn takeUpdates(self: *Workspace) ![]u8 {
        var w: std.Io.Writer.Allocating = .init(gpa);
        errdefer w.deinit();
        try w.writer.writeAll("RLC1");
        var it = self.files.iterator();
        while (it.next()) |e| {
            if (!e.value_ptr.dirty or !std.mem.startsWith(u8, e.key_ptr.*, "/cache/") or std.mem.endsWith(u8, e.key_ptr.*, ".tmp")) continue;
            try w.writer.writeInt(u32, @intCast(e.key_ptr.len), .little);
            try w.writer.writeInt(u32, @intCast(e.value_ptr.bytes.len), .little);
            try w.writer.writeAll(e.key_ptr.*);
            try w.writer.writeAll(e.value_ptr.bytes);
        }
        // Only acknowledge after the owned result allocation succeeds.
        const bytes = try w.toOwnedSlice();
        it = self.files.iterator();
        while (it.next()) |e| e.value_ptr.dirty = false;
        return bytes;
    }
    pub fn installPackage(self: *Workspace, url: []const u8, bytes: []const u8) !void {
        const parsed = try unbundle.download.validateUrl(url);
        const hash = (try unbundle.validateBase58Hash(parsed.hash)) orelse return error.InvalidHash;
        var writer = unbundle.BufferExtractWriter.init(gpa);
        defer writer.deinit();
        var reader: std.Io.Reader = .fixed(bytes);
        _ = try unbundle.unbundleStream(gpa, &reader, writer.extractWriter(), &hash, null, .{ .max_expanded_bytes = 64 * 1024 * 1024 });
        if (!writer.files.contains("main.roc")) return error.MissingMain;
        var it = writer.files.iterator();
        while (it.next()) |e| {
            const path = try std.fmt.allocPrint(gpa, "/bundles/{s}/{s}", .{ parsed.hash, e.key_ptr.* });
            defer gpa.free(path);
            try self.put(path, e.value_ptr.items, false);
        }
    }
};
const CacheEntry = struct { path: []const u8, data: []const u8 };
fn decodeEntry(bytes: []const u8, at: *usize) !CacheEntry {
    if (bytes.len - at.* < 8) return error.InvalidCache;
    const p: usize = std.mem.readInt(u32, bytes[at.*..][0..4], .little);
    const d: usize = std.mem.readInt(u32, bytes[at.* + 4 ..][0..4], .little);
    at.* += 8;
    if (p == 0 or p > 4096 or p > bytes.len - at.* or d > bytes.len - at.* - p) return error.InvalidCache;
    const result: CacheEntry = .{ .path = bytes[at.* .. at.* + p], .data = bytes[at.* + p .. at.* + p + d] };
    at.* += p + d;
    return result;
}
fn ctx(p: ?*anyopaque) *Workspace {
    return @ptrCast(@alignCast(p.?));
}
fn read(p: ?*anyopaque, _: std.Io, path: []const u8, a: A) CoreCtx.ReadError![]u8 {
    return a.dupe(u8, (ctx(p).files.get(path) orelse return error.FileNotFound).bytes);
}
fn readInto(p: ?*anyopaque, _: std.Io, path: []const u8, buf: []u8) CoreCtx.ReadError!usize {
    const data = (ctx(p).files.get(path) orelse return error.FileNotFound).bytes;
    if (data.len > buf.len) return error.StreamTooLong;
    @memcpy(buf[0..data.len], data);
    return data.len;
}
fn write(p: ?*anyopaque, _: std.Io, path: []const u8, bytes: []const u8) CoreCtx.WriteError!void {
    ctx(p).put(path, bytes, true) catch return error.OutOfMemory;
}
fn writeStream(p: ?*anyopaque, io_: std.Io, path: []const u8, stream: CoreCtx.FileStream) CoreCtx.WriteError!void {
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    stream.write(stream.context, &w.writer) catch return error.IoError;
    return write(p, io_, path, w.written());
}
fn exists(p: ?*anyopaque, _: std.Io, path: []const u8) bool {
    if (ctx(p).files.contains(path)) return true;
    var it = ctx(p).files.keyIterator();
    while (it.next()) |key| if (child(path, key.*)) return true;
    return false;
}
fn child(dir: []const u8, path: []const u8) bool {
    return path.len > dir.len and std.mem.startsWith(u8, path, dir) and (std.mem.endsWith(u8, dir, "/") or path[dir.len] == '/');
}
fn stat(p: ?*anyopaque, io_: std.Io, path: []const u8) CoreCtx.StatError!CoreCtx.FileInfo {
    if (ctx(p).files.get(path)) |f| return .{ .kind = .file, .size = f.bytes.len, .mtime_ns = null };
    if (exists(p, io_, path)) return .{ .kind = .directory, .size = 0, .mtime_ns = null };
    return error.FileNotFound;
}
fn list(p: ?*anyopaque, _: std.Io, path: []const u8, a: A) CoreCtx.ListError![]CoreCtx.FileEntry {
    var out: std.ArrayList(CoreCtx.FileEntry) = .empty;
    var it = ctx(p).files.keyIterator();
    while (it.next()) |key| if (child(path, key.*)) {
        try out.append(a, .{ .path = try a.dupe(u8, key.*), .kind = .file });
    };
    return out.toOwnedSlice(a);
}
fn listTop(p: ?*anyopaque, io_: std.Io, path: []const u8, a: A) CoreCtx.ListError![]CoreCtx.FileEntry {
    return list(p, io_, path, a);
}
fn canonicalize(_: ?*anyopaque, _: std.Io, path: []const u8, a: A) CoreCtx.CanonicalizeError![]const u8 {
    return std.fs.path.resolve(a, &.{ "/workspace", path });
}
fn makePath(_: ?*anyopaque, _: std.Io, _: []const u8) CoreCtx.MakePathError!void {}
fn env(_: ?*anyopaque, _: std.Io, key: []const u8, a: A) CoreCtx.GetEnvVarError![]u8 {
    if (std.mem.eql(u8, key, "ROC_CACHE_DIR")) return a.dupe(u8, "/cache");
    return error.EnvironmentVariableMissing;
}
fn rename(p: ?*anyopaque, _: std.Io, old: []const u8, new: []const u8) CoreCtx.RenameError!void {
    const self = ctx(p);
    if (self.files.get(old)) |f| {
        self.put(new, f.bytes, true) catch return error.IoError;
        self.drop(old);
        return;
    }
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var it = self.files.keyIterator();
    while (it.next()) |key| if (child(old, key.*)) {
        names.append(gpa, gpa.dupe(u8, key.*) catch return error.IoError) catch return error.IoError;
    };
    for (names.items) |name| {
        const dest = std.mem.concat(gpa, u8, &.{ new, name[old.len..] }) catch return error.IoError;
        defer gpa.free(dest);
        self.put(dest, self.files.get(name).?.bytes, true) catch return error.IoError;
        self.drop(name);
    }
}
fn remove(p: ?*anyopaque, _: std.Io, path: []const u8) CoreCtx.DeleteError!void {
    ctx(p).drop(path);
}
fn removeTree(p: ?*anyopaque, io_: std.Io, path: []const u8) CoreCtx.DeleteError!void {
    const files = list(p, io_, path, gpa) catch return error.IoError;
    defer gpa.free(files);
    for (files) |f| {
        ctx(p).drop(f.path);
        gpa.free(f.path);
    }
}
fn now(_: ?*anyopaque, _: std.Io) i128 {
    return 0;
}
fn fetch(p: ?*anyopaque, _: std.Io, a: A, url: []const u8, dest: []const u8, max: ?u64) CoreCtx.FetchUrlError!u64 {
    const self = ctx(p);
    const parsed = unbundle.download.validateUrl(url) catch return error.DownloadFailed;
    const base = std.fmt.allocPrint(a, "/bundles/{s}", .{parsed.hash}) catch return error.OutOfMemory;
    defer a.free(base);
    const files = list(p, .failing, base, a) catch return error.DownloadFailed;
    defer {
        for (files) |f| a.free(f.path);
        a.free(files);
    }
    if (files.len == 0) {
        self.required.append(gpa, .{ .url = gpa.dupe(u8, url) catch return error.OutOfMemory, .destination = gpa.dupe(u8, dest) catch return error.OutOfMemory }) catch return error.OutOfMemory;
        return error.DownloadFailed;
    }
    var size: u64 = 0;
    for (files) |f| {
        const bytes = self.files.get(f.path).?.bytes;
        size += bytes.len;
        if (max) |limit| if (size > limit) return error.ExpandedSizeLimitExceeded;
        const path = std.mem.concat(a, u8, &.{ dest, f.path[base.len..] }) catch return error.OutOfMemory;
        defer a.free(path);
        self.put(path, bytes, false) catch return error.OutOfMemory;
    }
    return size;
}
