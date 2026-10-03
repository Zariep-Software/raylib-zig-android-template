const std = @import("std");
const builtin = @import("builtin");

//////
// Android glue
//
// raylib's android_main() calls the exported C `main` symbol, but zig can't
// pass `-Wl,--wrap=fopen` to the linker, so the equivalent is exported here:

// `fopen` forwards to raylib's __wrap_fopen (asset loading),
// and __real_fopen reaches libc's fopen via dlsym.
// (Same approach as zig-android-sdk)
//////

pub fn AndroidGlue(comptime runGame: fn () void) type {
	return struct {
		const is_android = builtin.abi == .android or builtin.abi == .androideabi;

		fn androidMain() callconv(.c) c_int {
			runGame();
			return 0;
		}

		fn fopen(filename: [*c]const u8, modes: [*c]const u8) callconv(.c) ?*anyopaque {
			return __wrap_fopen(filename, modes);
		}

		fn realFopen(filename: [*c]const u8, modes: [*c]const u8) callconv(.c) ?*anyopaque {
			const RTLD_NEXT = @as(?*anyopaque, @ptrFromInt(@as(usize, @bitCast(@as(isize, -1)))));
			const next = dlsym(RTLD_NEXT, "fopen") orelse return null;
			const c_fopen: *const fn ([*c]const u8, [*c]const u8) callconv(.c) ?*anyopaque = @ptrCast(@alignCast(next));
			return c_fopen(filename, modes);
		}

		extern "c" fn __wrap_fopen(filename: [*c]const u8, modes: [*c]const u8) callconv(.c) ?*anyopaque;
		extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*c]const u8) callconv(.c) ?*anyopaque;

		comptime {
			if (is_android) {
				@export(&androidMain, .{ .name = "main" });
				@export(&fopen, .{ .name = "fopen" });
				@export(&realFopen, .{ .name = "__real_fopen" });
			}
		}
	};
}