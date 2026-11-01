//! Runtime assets shared by native and browser engines; never compiled into either.
const std = @import("std");
pub const Assets = struct {
    schema: u32,
    url: []const u8,
    display: []const u8,
    input: []const u8,
    input_values: []const u8,

    pub fn validate(self: Assets) !void {
        if (self.schema != 1 or !std.mem.startsWith(u8, self.url, "https://") or
            self.display.len == 0 or self.input.len == 0 or self.input_values.len == 0)
            return error.InvalidDisplayAssets;
    }
};
