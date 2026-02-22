const std = @import("std");

pub const bzip2 = @import("bzip2.zig");

pub const version = struct {
	pub const major: u32 = 0;
	pub const minor: u32 = 1;
	pub const patch: u32 = 0;

	pub fn string() []const u8 {
		return "0.1.0";
	}
};

pub fn getVersion() []const u8 {
	return version.string();
}

test "version" {
	const v = getVersion();
	try std.testing.expectEqualStrings("0.1.0", v);
}

test {
	_ = @import("bzip2_test.zig");
}
