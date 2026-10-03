const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");
const android_glue = @import("android-glue");

const is_android = builtin.abi == .android or builtin.abi == .androideabi;

const Slider = struct {
	bounds: rl.Rectangle,
	value: f32,
	is_dragging: bool,
};

fn Loaded(comptime T: type) type {
	return switch (@typeInfo(T)) {
		.error_union => |eu| ?eu.payload,
		else => ?T,
	};
}
fn loaded(v: anytype) Loaded(@TypeOf(v)) {
	return if (@typeInfo(@TypeOf(v)) == .error_union) v catch null else v;
}

fn px(f: f32) i32 {
	return @trunc(f);
}

fn runGame() void {
	// Force native mobile scaling immediately by initializing with 0, 0 on Android
	if (is_android) {
		rl.initWindow(0, 0, "raylib Zig Sandbox (Android)");
	} else {
		rl.initWindow(800, 600, "raylib Zig Sandbox (Desktop)");
	}
	defer rl.closeWindow();

	rl.initAudioDevice();
	defer rl.closeAudioDevice();
	rl.setTargetFPS(60);

	// On Android, "assets/..." resolves inside app/src/main/assets.
	const sprite = loaded(rl.loadTexture("assets/sprite.png"));
	defer if (sprite) |t| rl.unloadTexture(t);
	const bgm = loaded(rl.loadMusicStream("assets/audio.ogg"));
	defer if (bgm) |m| rl.unloadMusicStream(m);

	var slider = Slider{
		.bounds = .{ .x = 0, .y = 0, .width = 200, .height = 30 },
		.value = 0.5,
		.is_dragging = false,
	};
	var ui_color: rl.Color = .lime;

	while (!rl.windowShouldClose()) {
		if (bgm) |m| rl.updateMusicStream(m);

		const sw: f32 = @floatFromInt(rl.getScreenWidth());
		const sh: f32 = @floatFromInt(rl.getScreenHeight());
		const input_pos = rl.getMousePosition();

		const btn_play = rl.Rectangle{ .x = sw * 0.5 - 110, .y = sh * 0.45, .width = 220, .height = 50 };
		const btn_hovered = rl.checkCollisionPointRec(input_pos, btn_play);

		slider.bounds = .{ .x = sw * 0.5 - 100, .y = sh * 0.60, .width = 200, .height = 25 };

		if (rl.isMouseButtonPressed(.left)) {
			if (btn_hovered) {
				if (bgm) |m| {
					if (rl.isMusicStreamPlaying(m)) rl.stopMusicStream(m);
					rl.playMusicStream(m);
				}
				ui_color = .maroon;
			}
			if (rl.checkCollisionPointRec(input_pos, slider.bounds)) {
				slider.is_dragging = true;
			}
		}

		if (rl.isMouseButtonDown(.left) and slider.is_dragging) {
			slider.value = (input_pos.x - slider.bounds.x) / slider.bounds.width;
			slider.value = @min(1.0, @max(0.0, slider.value));
			if (bgm) |m| rl.setMusicVolume(m, slider.value);
		}

		if (rl.isMouseButtonReleased(.left)) {
			slider.is_dragging = false;
		}

		rl.beginDrawing();
		defer rl.endDrawing();
		rl.clearBackground(.dark_gray);

		if (is_android) {
			rl.drawText("ENV: Android NDK Native View", 20, 20, 20, .green);
		} else {
			rl.drawText("ENV: Desktop Native Window", 20, 20, 20, .orange);
		}

		if (sprite) |t| {
			const tw: f32 = @floatFromInt(t.width);
			rl.drawTexture(t, px(sw * 0.5 - tw * 0.5), px(sh * 0.15), .white);
		} else {
			rl.drawRectangle(px(sw * 0.5 - 40), px(sh * 0.15), 80, 80, .light_gray);
			rl.drawText("Missing\n'assets/sprite.png'", px(sw * 0.5 - 75), px(sh * 0.15 + 25), 16, .red);
		}

		rl.drawRectangleRounded(btn_play, 0.2, 4, if (btn_hovered) .gray else ui_color);
		rl.drawText("PLAY AUDIO.OGG", px(btn_play.x + 25), px(btn_play.y + 15), 18, .white);

		rl.drawRectangleRec(slider.bounds, .light_gray);
		rl.drawRectangle(
			px(slider.bounds.x),
			px(slider.bounds.y),
			px(slider.bounds.width * slider.value),
			px(slider.bounds.height),
			.lime,
		);
		rl.drawRectangleLinesEx(slider.bounds, 2, .dark_gray);

		var buf: [32]u8 = undefined;
		const label: [:0]const u8 = std.fmt.bufPrintSentinel(&buf, "Volume: {d}%", .{px(slider.value * 100)}, 0) catch "Volume";
		rl.drawText(label, px(slider.bounds.x), px(slider.bounds.y + 35), 16, .ray_white);
	}
}

// Desktop entry point
pub fn main() void {
	runGame();
}

comptime {
	if (is_android) {
		_ = android_glue.AndroidGlue(runGame);
	}
}
