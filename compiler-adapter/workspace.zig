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
const File = struct { bytes: []u8, dirty: bool = false, used: u64 = 0 };
pub const Workspace = struct {
    files: std.StringHashMapUnmanaged(File) = .{},
    std_io: std.Io = .failing,
    native_files: ?CoreCtx = null,
    required: std.ArrayList(RequiredPackage) = .empty,
    fingerprint: ?[64]u8 = null,
    cache_bytes: usize = 0,
    cache_entries: usize = 0,
    cache_limit: usize = 24 * 1024 * 1024,
    clock: u64 = 0,
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
            hashField(&hash, name);
            hashField(&hash, self.files.get(name).?.bytes);
        }
        var digest: [32]u8 = undefined;
        hash.final(&digest);
        self.fingerprint = std.fmt.bytesToHex(digest, .lower);
        return a.dupe(u8, &self.fingerprint.?);
    }
    pub fn put(self: *Workspace, path: []const u8, bytes: []const u8, dirty: bool) !void {
        if (path.len == 0 or path[0] != '/' or path.len > 4096 or std.mem.findScalar(u8, path, 0) != null) return error.InvalidPath;
        const normalized = try std.fs.path.resolve(gpa, &.{path});
        defer gpa.free(normalized);
        if (self.files.get(normalized)) |existing| if (std.mem.eql(u8, existing.bytes, bytes)) return;
        const data = try gpa.dupe(u8, bytes);
        errdefer gpa.free(data);
        const owned_path = try gpa.dupe(u8, normalized);
        errdefer gpa.free(owned_path);
        const slot = try self.files.getOrPut(gpa, owned_path);
        if (slot.found_existing) {
            if (isStoredArtifact(normalized)) {
                self.cache_bytes -= slot.value_ptr.bytes.len;
                self.cache_entries -= 1;
            }
            gpa.free(owned_path);
            gpa.free(slot.value_ptr.bytes);
        } else slot.key_ptr.* = owned_path;
        self.clock +%= 1;
        slot.value_ptr.* = .{ .bytes = data, .dirty = dirty, .used = self.clock };
        if (isStoredArtifact(normalized)) {
            self.cache_bytes += data.len;
            self.cache_entries += 1;
        }
        if (!std.mem.startsWith(u8, normalized, "/cache/")) self.fingerprint = null;
        self.evict();
    }
    fn evict(self: *Workspace) void {
        while (self.cache_bytes > self.cache_limit or self.cache_entries > 512) {
            var oldest: ?[]const u8 = null;
            var age: u64 = std.math.maxInt(u64);
            var it = self.files.iterator();
            while (it.next()) |e| if (isStoredArtifact(e.key_ptr.*) and e.value_ptr.used <= age) {
                oldest = e.key_ptr.*;
                age = e.value_ptr.used;
            };
            const removed = self.files.fetchRemove(oldest orelse break).?;
            self.cache_bytes -= removed.value.bytes.len;
            self.cache_entries -= 1;
            gpa.free(removed.key);
            gpa.free(removed.value.bytes);
        }
    }
    pub fn drop(self: *Workspace, path: []const u8) void {
        const normalized = std.fs.path.resolve(gpa, &.{path}) catch return;
        defer gpa.free(normalized);
        if (self.files.fetchRemove(normalized)) |removed| {
            if (isStoredArtifact(normalized)) {
                self.cache_bytes -= removed.value.bytes.len;
                self.cache_entries -= 1;
            }
            if (!std.mem.startsWith(u8, normalized, "/cache/")) self.fingerprint = null;
            gpa.free(removed.key);
            gpa.free(removed.value.bytes);
        }
    }
    pub fn io(self: *Workspace, a: A) CoreCtx {
        var result = CoreCtx.default(a, a, self.std_io);
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
        result.vtable.copyFile = copy;
        result.vtable.deleteFile = remove;
        result.vtable.deleteTree = removeTree;
        result.vtable.deleteDir = removeTree;
        result.vtable.timestampNow = now;
        return result;
    }
    pub fn deinit(self: *Workspace) void {
        self.clearRequired();
        self.required.deinit(gpa);
        var it = self.files.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            gpa.free(e.value_ptr.bytes);
        }
        self.files.deinit(gpa);
        self.* = .{};
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
            if (!isArtifact(e.path) or std.mem.find(u8, e.path, "..") != null or std.mem.findScalar(u8, e.path, 0) != null or !std.unicode.utf8ValidateSlice(e.path)) return error.InvalidCache;
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
            if (!e.value_ptr.dirty or !isArtifact(e.key_ptr.*) or std.mem.endsWith(u8, e.key_ptr.*, ".tmp")) continue;
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
fn isArtifact(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/cache/compat-");
}
fn isStoredArtifact(path: []const u8) bool {
    return isArtifact(path) and !std.mem.endsWith(u8, path, ".tmp");
}
fn ctx(p: ?*anyopaque) *Workspace {
    return @ptrCast(@alignCast(p.?));
}
fn read(p: ?*anyopaque, _: std.Io, path: []const u8, a: A) CoreCtx.ReadError![]u8 {
    if (ctx(p).files.getPtr(path)) |file| {
        ctx(p).clock +%= 1;
        file.used = ctx(p).clock;
        return a.dupe(u8, file.bytes);
    }
    if (ctx(p).native_files) |native| return native.readFile(path, a);
    return error.FileNotFound;
}
fn readInto(p: ?*anyopaque, _: std.Io, path: []const u8, buf: []u8) CoreCtx.ReadError!usize {
    const data = if (ctx(p).files.getPtr(path)) |file| blk: {
        ctx(p).clock +%= 1;
        file.used = ctx(p).clock;
        break :blk file.bytes;
    } else {
        if (ctx(p).native_files) |native| return native.readFileInto(path, buf);
        return error.FileNotFound;
    };
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
    if (ctx(p).native_files) |native| return native.fileExists(path);
    return false;
}
fn child(dir: []const u8, path: []const u8) bool {
    return path.len > dir.len and std.mem.startsWith(u8, path, dir) and (std.mem.endsWith(u8, dir, "/") or path[dir.len] == '/');
}
fn stat(p: ?*anyopaque, io_: std.Io, path: []const u8) CoreCtx.StatError!CoreCtx.FileInfo {
    if (ctx(p).files.get(path)) |f| return .{ .kind = .file, .size = f.bytes.len, .mtime_ns = null };
    _ = io_;
    var it = ctx(p).files.keyIterator();
    while (it.next()) |key| if (child(path, key.*)) return .{ .kind = .directory, .size = 0, .mtime_ns = null };
    if (ctx(p).native_files) |native| return native.stat(path);
    return error.FileNotFound;
}
fn list(p: ?*anyopaque, _: std.Io, path: []const u8, a: A) CoreCtx.ListError![]CoreCtx.FileEntry {
    var out: std.ArrayList(CoreCtx.FileEntry) = .empty;
    var it = ctx(p).files.keyIterator();
    while (it.next()) |key| if (child(path, key.*)) {
        try out.append(a, .{ .path = try a.dupe(u8, key.*), .kind = .file });
    };
    if (out.items.len == 0 and !std.mem.startsWith(u8, path, "/bundles/") and !std.mem.startsWith(u8, path, "/packages/") and !std.mem.startsWith(u8, path, "/cache/")) if (ctx(p).native_files) |native| return native.listDir(path, a);
    return out.toOwnedSlice(a);
}
fn listTop(p: ?*anyopaque, _: std.Io, path: []const u8, a: A) CoreCtx.ListError![]CoreCtx.FileEntry {
    var out: std.ArrayList(CoreCtx.FileEntry) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .{};
    defer seen.deinit(a);
    var it = ctx(p).files.keyIterator();
    while (it.next()) |key| if (child(path, key.*)) {
        const start = path.len + @intFromBool(!std.mem.endsWith(u8, path, "/"));
        const slash = std.mem.findScalarPos(u8, key.*, start, '/');
        const name = key.*[0 .. slash orelse key.len];
        if (seen.contains(name)) continue;
        const owned = try a.dupe(u8, name);
        try seen.put(a, owned, {});
        try out.append(a, .{ .path = owned, .kind = if (slash == null) .file else .directory });
    };
    return out.toOwnedSlice(a);
}
fn canonicalize(p: ?*anyopaque, _: std.Io, path: []const u8, a: A) CoreCtx.CanonicalizeError![]const u8 {
    if (ctx(p).native_files) |native| if (!ctx(p).files.contains(path) and !std.mem.startsWith(u8, path, "/packages/") and !std.mem.startsWith(u8, path, "/cache/") and !std.mem.startsWith(u8, path, "/bundles/") and !std.mem.startsWith(u8, path, "/internal/")) {
        if (native.fileExists(path)) return native.canonicalize(path, a);
    };
    return std.fs.path.resolve(a, &.{ "/workspace", path });
}
fn makePath(_: ?*anyopaque, _: std.Io, _: []const u8) CoreCtx.MakePathError!void {}
fn env(_: ?*anyopaque, _: std.Io, key: []const u8, a: A) CoreCtx.GetEnvVarError![]u8 {
    if (std.mem.eql(u8, key, "ROC_CACHE_DIR")) return a.dupe(u8, "/cache");
    return error.EnvironmentVariableMissing;
}
fn rename(p: ?*anyopaque, _: std.Io, old: []const u8, new: []const u8) CoreCtx.RenameError!void {
    const self = ctx(p);
    if (std.mem.eql(u8, old, new)) return;
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
fn copy(p: ?*anyopaque, _: std.Io, source: []const u8, destination: []const u8) CoreCtx.CopyError!void {
    const data = read(p, .failing, source, gpa) catch return error.FileNotFound;
    defer gpa.free(data);
    ctx(p).put(destination, data, false) catch return error.IoError;
}
fn now(_: ?*anyopaque, _: std.Io) i128 {
    return 0;
}
fn fetch(p: ?*anyopaque, _: std.Io, a: A, url: []const u8, dest: []const u8, max: ?u64) CoreCtx.FetchUrlError!u64 {
    const self = ctx(p);
    const parsed = unbundle.download.validateUrl(url) catch return error.DownloadFailed;
    const base = std.fmt.allocPrint(a, "/bundles/{s}", .{parsed.hash}) catch return error.OutOfMemory;
    defer a.free(base);
    var files = list(p, .failing, base, a) catch return error.DownloadFailed;
    defer {
        for (files) |f| a.free(f.path);
        a.free(files);
    }
    if (files.len == 0 and self.native_files != null) {
        if (comptime @import("builtin").cpu.arch != .wasm32) {
            try downloadNativePackage(self, url, parsed.hash, max);
            a.free(files);
            files = list(p, .failing, base, a) catch return error.DownloadFailed;
        }
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

test "compiler artifact envelopes roundtrip without source files" {
    var source: Workspace = .{};
    defer source.deinit();
    try source.put("/workspace/Geometry.roc", "module [area]\narea = 1", false);
    try source.put("/cache/compat-test/can/aa/example.bin", "opaque-canonicalized-module", true);
    const stream = try source.takeUpdates();
    defer gpa.free(stream);
    var restored: Workspace = .{};
    defer restored.deinit();
    try restored.importCache(stream);
    try std.testing.expectEqualStrings("opaque-canonicalized-module", restored.files.get("/cache/compat-test/can/aa/example.bin").?.bytes);
    try std.testing.expect(!restored.files.contains("/workspace/Geometry.roc"));
    const empty = try source.takeUpdates();
    defer gpa.free(empty);
    try std.testing.expectEqualStrings("RLC1", empty);
    try std.testing.expectError(error.InvalidCache, restored.importCache("RLC1\x01\x00\x00\x00"));
}

test "workspace content identity ignores compiler artifacts and detects imported source changes" {
    var fs: Workspace = .{};
    defer fs.deinit();
    try fs.put("/workspace/Geometry.roc", "module [area]\narea = 1", false);
    const before = try fs.contentIdentity(gpa);
    defer gpa.free(before);
    try fs.put("/cache/compat-test/mod/00/entry.bin", "checked-artifact", true);
    const after_cache = try fs.contentIdentity(gpa);
    defer gpa.free(after_cache);
    try std.testing.expectEqualStrings(before, after_cache);
    try fs.put("/workspace/Geometry.roc", "module [area]\narea = 2", false);
    const after_edit = try fs.contentIdentity(gpa);
    defer gpa.free(after_edit);
    try std.testing.expect(!std.mem.eql(u8, before, after_edit));
}

test "package extraction verifies content hashes before publishing" {
    var fs: Workspace = .{};
    defer fs.deinit();
    const fixture = unbundle.test_support;
    const bytes = try fixture.archive(gpa, &.{ .{ .name = "main.roc", .data = "package [Geometry] {}\n" }, .{ .name = "Geometry.roc", .data = "module [answer]\nanswer = 42\n" } });
    defer gpa.free(bytes);
    var hash_buffer: [44]u8 = undefined;
    const hash = fixture.hashName(bytes, &hash_buffer);
    const url = try std.fmt.allocPrint(gpa, "https://packages.example.test/{s}.tar.zst", .{hash});
    defer gpa.free(url);
    try fs.installPackage(url, bytes);
    const file = try std.fmt.allocPrint(gpa, "/bundles/{s}/Geometry.roc", .{hash});
    defer gpa.free(file);
    try std.testing.expectEqualStrings("module [answer]\nanswer = 42\n", fs.files.get(file).?.bytes);
    bytes[bytes.len - 1] ^= 1;
    try std.testing.expectError(error.HashMismatch, fs.installPackage(url, bytes));
}

test "compiler cache evicts least recently read artifacts and retains workspace inputs" {
    var fs: Workspace = .{ .cache_limit = 100 };
    defer fs.deinit();
    const value: [40]u8 = @splat('x');
    try fs.put("/workspace/Keep.roc", &value, false);
    try fs.put("/bundles/hash/main.roc", &value, false);
    try fs.put("/cache/compat-test/mod/00/a.bin", &value, true);
    try fs.put("/cache/compat-test/mod/00/b.bin", &value, true);
    const cached = try fs.io(gpa).readFile("/cache/compat-test/mod/00/a.bin", gpa);
    defer gpa.free(cached);
    try fs.put("/cache/compat-test/mod/00/c.bin", &value, true);
    try std.testing.expect(fs.files.contains("/cache/compat-test/mod/00/a.bin"));
    try std.testing.expect(!fs.files.contains("/cache/compat-test/mod/00/b.bin"));
    try std.testing.expect(fs.files.contains("/cache/compat-test/mod/00/c.bin"));
    try std.testing.expect(fs.files.contains("/workspace/Keep.roc"));
    try std.testing.expect(fs.files.contains("/bundles/hash/main.roc"));
    try std.testing.expectEqual(@as(usize, 80), fs.cache_bytes);
}

fn downloadNativePackage(self: *Workspace, url: []const u8, hash: []const u8, max: ?u64) CoreCtx.FetchUrlError!void {
    const native = self.native_files.?;
    const cache_root = native.getEnvVar("XDG_CACHE_HOME", gpa) catch blk: {
        const home = native.getEnvVar("HOME", gpa) catch return error.DownloadFailed;
        defer gpa.free(home);
        break :blk std.fs.path.join(gpa, &.{ home, ".cache" }) catch return error.OutOfMemory;
    };
    defer gpa.free(cache_root);
    const package = std.fs.path.join(gpa, &.{ cache_root, "roclet", "packages", hash }) catch return error.OutOfMemory;
    defer gpa.free(package);
    const main = std.fs.path.join(gpa, &.{ package, "main.roc" }) catch return error.OutOfMemory;
    defer gpa.free(main);
    if (!native.fileExists(main)) {
        var nonce: [8]u8 = undefined;
        self.std_io.random(&nonce);
        const staging = std.fmt.allocPrint(gpa, "{s}.{s}.tmp", .{ package, std.fmt.bytesToHex(nonce, .lower) }) catch return error.OutOfMemory;
        defer gpa.free(staging);
        native.makePath(staging) catch return error.DownloadFailed;
        defer native.deleteTree(staging) catch {};
        var allocator = gpa;
        _ = unbundle.downloadAndExtract(&allocator, self.std_io, url, staging, .{ .max_expanded_bytes = max }) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.ExpandedSizeLimitExceeded => error.ExpandedSizeLimitExceeded,
            else => error.DownloadFailed,
        };
        native.rename(staging, package) catch {
            if (!native.fileExists(main)) return error.DownloadFailed;
        };
    }
    const entries = native.listDir(package, gpa) catch return error.DownloadFailed;
    defer {
        for (entries) |item| gpa.free(item.path);
        gpa.free(entries);
    }
    for (entries) |item| {
        if (item.kind != .file) continue;
        const bytes = native.readFile(item.path, gpa) catch return error.DownloadFailed;
        defer gpa.free(bytes);
        const path = std.fmt.allocPrint(gpa, "/bundles/{s}{s}", .{ hash, item.path[package.len..] }) catch return error.OutOfMemory;
        defer gpa.free(path);
        self.put(path, bytes, false) catch return error.OutOfMemory;
    }
}

pub fn hashField(hash: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    var size: [8]u8 = undefined;
    std.mem.writeInt(u64, &size, bytes.len, .little);
    hash.update(&size);
    hash.update(bytes);
}
