//! GitHub release archives only. Original hashes are verified before caching.
const std = @import("std");
const A = std.mem.Allocator;
pub const prefix = "/api/packages/";
pub const limit = 32 * 1024 * 1024;
const alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
pub const Package = struct { url: []const u8, hash: [32]u8 };
pub fn parse(a: A, target: []const u8) !Package {
    if (!std.mem.startsWith(u8, target, prefix) or target.len > 2048) return error.InvalidPackage;
    const path = target[prefix.len..];
    var parts = std.mem.splitScalar(u8, path, '/');
    var segments: [4][]const u8 = undefined;
    for (&segments) |*segment| {
        segment.* = parts.next() orelse return error.InvalidPackage;
        if (segment.len == 0 or std.mem.eql(u8, segment.*, ".") or std.mem.eql(u8, segment.*, "..")) return error.InvalidPackage;
        for (segment.*) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.' and c != '+') return error.InvalidPackage;
    }
    if (parts.next() != null) return error.InvalidPackage;
    const name = segments[3];
    if (!std.mem.endsWith(u8, name, ".tar.zst")) return error.InvalidPackage;
    const stem = name[0 .. name.len - ".tar.zst".len];
    var start = stem.len;
    while (start > 0 and std.mem.findScalar(u8, alphabet, stem[start - 1]) != null) start -= 1;
    const encoded = stem[start..];
    if (encoded.len < 32 or encoded.len > 44) return error.InvalidPackage;
    var hash: [32]u8 = @splat(0);
    for (encoded) |c| {
        var carry: u32 = @intCast(std.mem.findScalar(u8, alphabet, c).?);
        var i: usize = hash.len;
        while (i > 0) {
            i -= 1;
            carry += @as(u32, hash[i]) * 58;
            hash[i] = @truncate(carry);
            carry >>= 8;
        }
        if (carry != 0) return error.InvalidPackage;
    }
    var leading: usize = 0;
    while (leading < encoded.len and encoded[leading] == '1') leading += 1;
    var zero_bytes: usize = 0;
    while (zero_bytes < hash.len and hash[zero_bytes] == 0) zero_bytes += 1;
    if (leading + hash.len - zero_bytes != hash.len) return error.InvalidPackage;
    return .{ .url = try std.fmt.allocPrint(a, "https://github.com/{s}/{s}/releases/download/{s}/{s}", .{ segments[0], segments[1], segments[2], segments[3] }), .hash = hash };
}
pub fn allowedRedirect(uri: std.Uri) bool {
    if (!std.mem.eql(u8, uri.scheme, "https") or uri.user != null or uri.password != null or uri.port != null) return false;
    const host = if (uri.host) |h| h.percent_encoded else return false;
    for ([_][]const u8{ "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com" }) |allowed| if (std.mem.eql(u8, host, allowed)) return true;
    return false;
}
pub fn verify(bytes: []const u8, expected: [32]u8) !void {
    if (bytes.len > limit) return error.PackageTooLarge;
    var actual: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(bytes, &actual, .{});
    if (!std.mem.eql(u8, &actual, &expected)) return error.HashMismatch;
}
pub fn download(a: A, io: std.Io, package: Package) ![]u8 {
    const Outcome = union(enum) { bytes: anyerror![]u8, timeout: std.Io.Cancelable!void };
    var buffer: [2]Outcome = undefined;
    var select: std.Io.Select(Outcome) = .init(io, &buffer);
    defer _ = select.cancel();
    try select.concurrent(.timeout, downloadTimeout, .{io});
    try select.concurrent(.bytes, downloadInner, .{ a, io, package });
    switch (try select.await()) {
        .bytes => |result| return result,
        .timeout => |result| {
            try result;
            return error.DownloadTimedOut;
        },
    }
}
fn downloadTimeout(io: std.Io) std.Io.Cancelable!void {
    try std.Io.sleep(io, .fromSeconds(30), .awake);
}
fn downloadInner(a: A, io: std.Io, package: Package) ![]u8 {
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    var uri = try std.Uri.parse(package.url);
    var redirects: usize = 0;
    while (true) {
        if (!allowedRedirect(uri)) return error.InvalidRedirect;
        var request = try client.request(.GET, uri, .{ .redirect_behavior = .unhandled });
        defer request.deinit();
        try request.sendBodiless();
        var head_buffer: [16 * 1024]u8 = undefined;
        var response = try request.receiveHead(&head_buffer);
        if (response.head.status.class() == .redirect) {
            if (redirects == 3) return error.TooManyRedirects;
            const location = response.head.location orelse return error.InvalidRedirect;
            const current = try std.fmt.allocPrint(a, "{f}", .{std.Uri.fmt(&uri, .all)});
            const buffer = try a.alloc(u8, current.len + location.len + 1);
            @memcpy(buffer[0..location.len], location);
            var remaining = buffer;
            uri = try uri.resolveInPlace(location.len, &remaining);
            redirects += 1;
            continue;
        }
        if (response.head.status != .ok) return error.UpstreamFailed;
        if (response.head.content_length) |size| if (size > limit) return error.PackageTooLarge;
        if (response.head.content_encoding != .identity) return error.UnexpectedEncoding;
        const bytes = try response.reader(&.{}).allocRemaining(a, .limited(limit));
        try verify(bytes, package.hash);
        return bytes;
    }
}
pub const Cache = struct {
    const Entry = struct { hash: [32]u8, bytes: []u8, used: u64 };
    mutex: std.Io.Mutex = .init,
    active: std.atomic.Value(u32) = .init(0),
    entries: std.ArrayList(Entry) = .empty,
    size: usize = 0,
    clock: u64 = 0,
    pub fn deinit(self: *Cache) void {
        for (self.entries.items) |entry| std.heap.page_allocator.free(entry.bytes);
        self.entries.deinit(std.heap.page_allocator);
    }
    pub fn get(self: *Cache, a: A, io: std.Io, hash: [32]u8) !?[]u8 {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        self.clock += 1;
        for (self.entries.items) |*entry| if (std.mem.eql(u8, &entry.hash, &hash)) {
            entry.used = self.clock;
            return try a.dupe(u8, entry.bytes);
        };
        return null;
    }
    pub fn put(self: *Cache, io: std.Io, hash: [32]u8, bytes: []const u8) !void {
        try verify(bytes, hash);
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        for (self.entries.items) |entry| if (std.mem.eql(u8, &entry.hash, &hash)) return;
        const a = std.heap.page_allocator;
        while (self.entries.items.len >= 8 or self.size + bytes.len > 64 * 1024 * 1024) {
            var oldest: usize = 0;
            for (self.entries.items, 0..) |entry, i| if (entry.used < self.entries.items[oldest].used) {
                oldest = i;
            };
            const entry = self.entries.swapRemove(oldest);
            self.size -= entry.bytes.len;
            a.free(entry.bytes);
        }
        const owned = try a.dupe(u8, bytes);
        errdefer a.free(owned);
        self.clock += 1;
        try self.entries.append(a, .{ .hash = hash, .bytes = owned, .used = self.clock });
        self.size += owned.len;
    }
};
test "proxy accepts prefixed release hashes and rejects arbitrary destinations" {
    const a = std.testing.allocator;
    const result = try parse(a, prefix ++ "lukewilliamboswell/roc-time/0.2.0/roc-time-7QH5VBiCwDLu3UkizpgB3FESJitahxR82Vgg2bWkJvHL.tar.zst");
    defer a.free(result.url);
    try std.testing.expect(std.mem.startsWith(u8, result.url, "https://github.com/lukewilliamboswell/roc-time/releases/download/0.2.0/"));
    for ([_][]const u8{ prefix ++ "https://example.com/x", prefix ++ "../r/v/hash.tar.zst", prefix ++ "a/b/v/file.zip", prefix ++ "a/b/v/hash.tar.zst?url=https://evil.invalid", prefix ++ "a/b/v/x%2fy.tar.zst" }) |target| try std.testing.expectError(error.InvalidPackage, parse(a, target));
    try std.testing.expect(!allowedRedirect(try std.Uri.parse("http://github.com/x")));
    try std.testing.expect(!allowedRedirect(try std.Uri.parse("https://127.0.0.1/x")));
    try std.testing.expect(!allowedRedirect(try std.Uri.parse("https://github.com.evil.invalid/x")));
    try std.testing.expect(allowedRedirect(try std.Uri.parse("https://release-assets.githubusercontent.com/x?signature=public")));
    try std.testing.expectError(error.HashMismatch, verify("wrong archive", result.hash));
}
test "verified package cache rejects corruption, deduplicates and evicts least recently used entries" {
    var cache: Cache = .{};
    defer cache.deinit();
    const a = std.testing.allocator;
    const io = std.testing.io;
    var hashes: [9][32]u8 = undefined;
    for (&hashes, 0..) |*hash, i| {
        const bytes = [_]u8{@intCast(i)};
        std.crypto.hash.Blake3.hash(&bytes, hash, .{});
        if (i < 8) try cache.put(io, hash.*, &bytes);
    }
    const first = (try cache.get(a, io, hashes[0])).?;
    defer a.free(first);
    try cache.put(io, hashes[0], &.{0});
    try std.testing.expectEqual(@as(usize, 8), cache.entries.items.len);
    try std.testing.expectError(error.HashMismatch, cache.put(io, hashes[0], "corrupt"));
    try cache.put(io, hashes[8], &.{8});
    try std.testing.expect((try cache.get(a, io, hashes[1])) == null);
    const restored = (try cache.get(a, io, hashes[0])).?;
    defer a.free(restored);
    try std.testing.expectEqualSlices(u8, &.{0}, restored);
    try std.testing.expectEqual(@as(usize, 8), cache.size);
}
