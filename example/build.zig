const std = @import("std");
const android = @import("vendor/raylib-zig-android/build-android.zig");

pub fn build(b: *std.Build) !void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.standardOptimizeOption(.{});

	// Desktop
	const raylib_dep = b.dependency("raylib_zig", .{
		.target = target,
		.optimize = optimize,
	});

	const exe = b.addExecutable(.{
		.name = "my-game",
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/main.zig"),
			.target = target,
			.optimize = optimize,
			.imports = &.{
				.{ .name = "raylib", .module = raylib_dep.module("raylib") },
			},
		}),
	});
	exe.root_module.linkLibrary(raylib_dep.artifact("raylib"));
	b.installArtifact(exe);

	const run_cmd = b.addRunArtifact(exe);
	run_cmd.step.dependOn(b.getInstallStep());
	b.step("run", "Run desktop build").dependOn(&run_cmd.step);

	// Android
	const android_step = b.step("android", "Build libmain.so (needs -Dabi=...)");
	const abi = b.option([]const u8, "abi", "Android ABI");

	if (abi) |abi_name| {
		// Glue module compiled for the Android target
		const glue_module = b.createModule(.{
			.root_source_file = b.path("vendor/raylib-zig-android/vendor/raylib-zig-android/android-glue.zig"),
			.target = b.resolveTargetQuery(android.resolveAbiQuery(abi_name)),
			.optimize = optimize,
			.link_libc = true,
		});

		try android.add(b, android_step, .{
			.abi = abi_name,
			.root_source_file = "src/main.zig",
			.optimize = optimize,
			.extra_imports = &.{
				.{ .name = "android-glue", .module = glue_module },
			},
		});
	} else {
		const fail = b.addFail("pass -Dabi=<arm64-v8a|x86_64|armeabi-v7a>");
		android_step.dependOn(&fail.step);
	}
}
