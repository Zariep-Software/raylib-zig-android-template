const std = @import("std");

pub fn build(b: *std.Build) !void {
	// Consumers should NOT use this file,  copy example/ instead.
	const example_build = b.path("example/build.zig");
	_ = example_build;

	const fail = b.addFail("This is a library. Use the example: cd example && zig build run");
	b.default_step.dependOn(&fail.step);
}