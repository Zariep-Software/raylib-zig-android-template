const std = @import("std");
const builtin = @import("builtin");
const Build = std.Build;
const Io = std.Io;
const Environ = std.process.Environ;
const List = std.ArrayList;

const api_level = 29; // Older Android fails (native TLS / missing symbols)
const api_str = "29";

const host_tag = switch (builtin.os.tag) {
	.linux => "linux-x86_64",
	.macos => "darwin-x86_64",
	else => @compileError("Unsupported host OS for this script."),
};

const EM_ARM = 40;
const EM_X86_64 = 62;
const EM_AARCH64 = 183;

pub const Options = struct {
	abi: []const u8,
	root_source_file: []const u8,
	optimize: std.builtin.OptimizeMode,
	extra_imports: []const std.Build.Module.Import = &.{},
};

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
	std.debug.print("error: " ++ fmt ++ "\n", args);
	std.process.exit(1);
}

// ENV //

const Env = struct {
	all: Environ.Map, // process env + asetup.sh
	file: Environ.Map, // only what asetup.sh set (forwarded to apostbuild.sh)
};

fn copyMap(a: std.mem.Allocator, src: anytype) !Environ.Map {
	var m = Environ.Map.init(a);
	for (src.keys(), src.values()) |k, v| try m.put(k, v);
	return m;
}

fn expandEnvVars(a: std.mem.Allocator, env: *const Environ.Map, in: []const u8) ![]const u8 {
	if (in.len == 0) return in;
	var value = in;
	if (std.mem.eql(u8, value, "~") or std.mem.startsWith(u8, value, "~/")) {
		value = try std.fmt.allocPrint(a, "{s}{s}", .{ env.get("HOME") orelse "", value[1..] });
	}
	var out: List(u8) = .empty;
	var i: usize = 0;
	while (i < value.len) {
		if (value[i] == '$' and i + 1 < value.len) {
			if (value[i + 1] == '{') {
				if (std.mem.findScalarPos(u8, value, i + 2, '}')) |close| {
					try out.appendSlice(a, env.get(value[i + 2 .. close]) orelse "");
					i = close + 1;
					continue;
				}
			} else if (std.ascii.isAlphabetic(value[i + 1]) or value[i + 1] == '_') {
				var j = i + 1;
				while (j < value.len and (std.ascii.isAlphanumeric(value[j]) or value[j] == '_')) j += 1;
				// unresolved bare $VAR stays literal, ${VAR} becomes empty (as before)
				try out.appendSlice(a, env.get(value[i + 1 .. j]) orelse value[i..j]);
				i = j;
				continue;
			}
		}
		try out.append(a, value[i]);
		i += 1;
	}
	return out.items;
}

fn loadEnv(b: *Build) !Env {
	const a = b.allocator;
	const io = b.graph.io;
	var env = Env{ .all = try copyMap(a, b.graph.environ_map), .file = Environ.Map.init(a) };

	const text = Io.Dir.cwd().readFileAlloc(io, "asetup.sh", a, .limited(1 << 20)) catch |e| switch (e) {
		error.FileNotFound => return env,
		else => return e,
	};

	var lines = std.mem.splitScalar(u8, text, '\n');
	while (lines.next()) |raw| {
		var line = std.mem.trim(u8, raw, " \t\r");
		if (line.len == 0 or line[0] == '#') continue;
		if (std.mem.startsWith(u8, line, "export ")) line = std.mem.trim(u8, line["export ".len..], " \t");

		const eq = std.mem.findScalar(u8, line, '=') orelse continue;
		const key = std.mem.trim(u8, line[0..eq], " \t");
		var val = std.mem.trim(u8, line[eq + 1 ..], " \t");
		if (val.len >= 2 and ((val[0] == '"' and val[val.len - 1] == '"') or
			(val[0] == '\'' and val[val.len - 1] == '\'')))
		{
			val = val[1 .. val.len - 1];
		}
		const expanded = try expandEnvVars(a, &env.all, val);
		try env.all.put(key, expanded);
		try env.file.put(key, expanded);
	}
	return env;
}

fn requireEnv(env: *const Environ.Map, name: []const u8, hint: []const u8) []const u8 {
	const v = env.get(name) orelse "";
	if (v.len == 0) fatal("Set {s} ({s})", .{ name, hint });
	return v;
}

fn envOr(env: *const Environ.Map, name: []const u8, dflt: []const u8) []const u8 {
	return env.get(name) orelse dflt;
}

// ABI //

const AbiConfig = struct {
	abi: []const u8, // canonical Android ABI name
	triple: []const u8, // NDK clang triple
	sysroot_lib_triple: []const u8, // dir under <sysroot>/usr/lib (differs on armv7)
	elf_machine: u16,
	query: std.Target.Query,
};

fn anyOf(s: []const u8, options: []const []const u8) bool {
	for (options) |o| if (std.mem.eql(u8, s, o)) return true;
	return false;
}

pub fn resolveAbiQuery(abi: []const u8) std.Target.Query {
	return resolveAbi(abi).query;
}

fn resolveAbi(requested_abi: []const u8) AbiConfig {
	if (anyOf(requested_abi, &.{ "arm64-v8a", "armv8", "aarch64", "arm64" })) return .{
		.abi = "arm64-v8a",
		.triple = "aarch64-linux-android",
		.sysroot_lib_triple = "aarch64-linux-android",
		.elf_machine = EM_AARCH64,
		.query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .android },
	};
	if (anyOf(requested_abi, &.{ "x86_64", "amd64" })) return .{
		.abi = "x86_64",
		.triple = "x86_64-linux-android",
		.sysroot_lib_triple = "x86_64-linux-android",
		.elf_machine = EM_X86_64,
		.query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .android },
	};
	if (anyOf(requested_abi, &.{ "armeabi-v7a", "armv7", "arm", "arm32" })) return .{
		.abi = "armeabi-v7a",
		.triple = "armv7a-linux-androideabi",
		// NDK sysroot uses "arm-linux-androideabi" instead of armv7a
		.sysroot_lib_triple = "arm-linux-androideabi",
		.elf_machine = EM_ARM,
		.query = .{
			.cpu_arch = .arm,
			.os_tag = .linux,
			.abi = .androideabi,
			.cpu_model = .{ .explicit = &std.Target.arm.cpu.generic },
			.cpu_features_add = std.Target.arm.featureSet(&.{.v7a}),
		},
	};
	fatal("Unsupported ABI: {s}", .{requested_abi});
}

fn machineName(m: u16) []const u8 {
	return switch (m) {
		EM_ARM => "ARM (32-bit)",
		EM_AARCH64 => "AArch64",
		EM_X86_64 => "x86-64",
		else => "unknown",
	};
}

fn elfMachine(io: Io, path: []const u8) !u16 {
	var hdr: [20]u8 = undefined;
	const got = try Io.Dir.cwd().readFile(io, path, &hdr);
	if (got.len != 20 or !std.mem.eql(u8, got[0..4], "\x7fELF")) return error.NotElf;
	return std.mem.readInt(u16, got[0x12..0x14], .little);
}

// flags //

const Flags = struct {
	a: std.mem.Allocator,
	objects: List([]const u8) = .empty,
	libs: List([]const u8) = .empty,
	lib_dirs: List([]const u8) = .empty,
	wraps: List([]const u8) = .empty,

	fn parse(f: *Flags, s: []const u8) !void {
		var it = std.mem.tokenizeAny(u8, s, " \t");
		while (it.next()) |tok| {
			if (std.mem.endsWith(u8, tok, ".o")) {
				try f.objects.append(f.a, if (std.mem.startsWith(u8, tok, "-L")) tok[2..] else tok);
			} else if (std.mem.find(u8, tok, "--wrap=")) |idx| {
				try f.wraps.append(f.a, tok[idx + "--wrap=".len ..]);
			} else if (std.mem.startsWith(u8, tok, "-L-l")) {
				try f.libs.append(f.a, tok[4..]);
			} else if (std.mem.startsWith(u8, tok, "-L-L")) {
				try f.lib_dirs.append(f.a, tok[4..]);
			} else if (std.mem.startsWith(u8, tok, "-l")) {
				try f.libs.append(f.a, tok[2..]);
			} else if (std.mem.startsWith(u8, tok, "-L")) {
				try f.lib_dirs.append(f.a, tok[2..]);
			} else {
				std.debug.print("warning: ignoring unsupported flag '{s}'\n", .{tok});
			}
		}
	}
};

fn appendFlag(a: std.mem.Allocator, existing: []const u8, extra: []const u8) ![]const u8 {
	if (extra.len == 0) return existing;
	if (existing.len == 0) return extra;
	return std.fmt.allocPrint(a, "{s} {s}", .{ existing, extra });
}

// HOOKS //

const HookResult = struct {
	cflags: []const u8 = "",
	ldflags: []const u8 = "",
	dflags: []const u8 = "",
};

const HookState = enum { missing, not_executable, ok };

fn hookState(io: Io, script: []const u8) HookState {
	const cwd = Io.Dir.cwd();
	cwd.access(io, script, .{}) catch return .missing;
	cwd.access(io, script, .{ .execute = true }) catch {
		std.debug.print("== Skipping {s} (found but not executable; run: chmod +x {s})\n", .{ script, script });
		return .not_executable;
	};
	return .ok;
}

/// Exit code if the process exited normally.
fn exitCode(term: anytype) ?u8 {
	switch (term) {
		inline else => |payload, tag| {
			if (comptime std.ascii.eqlIgnoreCase(@tagName(tag), "exited")) return payload;
			return null;
		},
	}
}

fn runHook(
	b: *Build,
	env: *const Environ.Map,
	script: []const u8,
	args: []const []const u8,
	extra_env: []const [2][]const u8,
) !HookResult {
	const a = b.allocator;
	const io = b.graph.io;
	if (hookState(io, script) != .ok) return .{};

	var child_env = try copyMap(a, env);
	for (extra_env) |kv| try child_env.put(kv[0], kv[1]);

	var argv: List([]const u8) = .empty;
	try argv.append(a, try std.fmt.allocPrint(a, "./{s}", .{script}));
	try argv.appendSlice(a, args);

	std.debug.print("== Running {s}\n", .{script});
	const result = std.process.run(a, io, .{
		.argv = argv.items,
		.environ_map = &child_env,
		.stdout_limit = .limited(16 << 20),
	}) catch |e| fatal("could not run {s}: {s}", .{ script, @errorName(e) });

	if (result.stderr.len > 0) std.debug.print("{s}", .{result.stderr}); // hooks log to stderr
	const code = exitCode(result.term) orelse fatal("{s} terminated abnormally", .{script});
	if (code != 0) fatal("{s} failed with exit code {d}", .{ script, code });

	var c: List([]const u8) = .empty;
	var l: List([]const u8) = .empty;
	var d: List([]const u8) = .empty;
	var lines = std.mem.splitScalar(u8, result.stdout, '\n');
	while (lines.next()) |raw| {
		const line = std.mem.trim(u8, raw, " \t\r");
		if (line.len == 0) continue;
		std.debug.print("   [{s}] {s}\n", .{ script, line });
		if (std.mem.startsWith(u8, line, "EXTRA_CFLAGS=")) {
			try c.append(a, std.mem.trim(u8, line["EXTRA_CFLAGS=".len..], " \t"));
		} else if (std.mem.startsWith(u8, line, "EXTRA_LDFLAGS=")) {
			try l.append(a, std.mem.trim(u8, line["EXTRA_LDFLAGS=".len..], " \t"));
		} else if (std.mem.startsWith(u8, line, "EXTRA_DFLAGS=")) {
			try d.append(a, std.mem.trim(u8, line["EXTRA_DFLAGS=".len..], " \t"));
		}
	}
	return .{
		.cflags = try std.mem.join(a, " ", c.items),
		.ldflags = try std.mem.join(a, " ", l.items),
		.dflags = try std.mem.join(a, " ", d.items),
	};
}

// BUILD //

pub fn add(b: *Build, android_step: *Build.Step, opts: Options) !void {
	const a = b.allocator;
	const io = b.graph.io;
	const cwd = Io.Dir.cwd();
	var env = try loadEnv(b);

	const cfg = resolveAbi(opts.abi);

	const ndk_home = requireEnv(&env.all, "ANDROID_NDK_HOME", "NDK root directory");
	const tc = b.pathJoin(&.{ ndk_home, "toolchains", "llvm", "prebuilt", host_tag });
	const tc_bin = b.pathJoin(&.{ tc, "bin" });
	const sysroot = b.pathJoin(&.{ tc, "sysroot" });
	const sysroot_api_lib = b.pathJoin(&.{ sysroot, "usr", "lib", cfg.sysroot_lib_triple, api_str });
	// Zig links by itself, but hooks still get the NDK clang wrapper for compiling C/asm.
	const ndk_clang = b.pathJoin(&.{ tc_bin, b.fmt("{s}{d}-clang", .{ cfg.triple, api_level }) });

	cwd.access(io, ndk_clang, .{}) catch fatal("Expected NDK clang wrapper not found: {s}", .{ndk_clang});
	cwd.access(io, sysroot_api_lib, .{}) catch fatal("Expected NDK sysroot lib dir not found: {s}", .{sysroot_api_lib});

	const raylib_dir = requireEnv(&env.all, "RAYLIB_LIB_DIR", "dir containing <abi>/libraylib.a");
	const raylib_a = b.pathJoin(&.{ raylib_dir, cfg.abi, "libraylib.a" });
	cwd.access(io, raylib_a, .{}) catch fatal("raylib not found: {s}", .{raylib_a});

	const android_output_dir = try b.root.joinString(a, envOr(&env.all, "ANDROID_OUTPUT_DIR", "android/app/src/main"),);
	const out_dir = b.pathJoin(&.{ android_output_dir, "jniLibs", cfg.abi });
	try cwd.createDirPath(io, out_dir);
	const dest_lib = b.pathJoin(&.{ out_dir, "libmain.so" });

	std.debug.print("== Building Zig sources for {s} ({s}, API {d}) ==\n", .{ cfg.abi, cfg.triple, api_level });
	std.debug.print(" using sysroot libs from: {s}\n", .{sysroot_api_lib});

	// prebuild
	const pre = try runHook(b, &env.all, "aprebuild.sh", &.{ cfg.abi, cfg.triple, api_str, sysroot, out_dir }, &.{
		.{ "NDK_CLANG", ndk_clang },
		.{ "SYSROOT", sysroot },
		.{ "OUT_DIR", out_dir },
		.{ "ABI", cfg.abi },
		.{ "LDC_TRIPLE", cfg.triple }, // name kept for hook compatibility
		.{ "API_LEVEL", api_str },
	});

	const extra_c = try appendFlag(a, envOr(&env.all, "EXTRA_CFLAGS", ""), pre.cflags);
	const extra_ld = try appendFlag(a, envOr(&env.all, "EXTRA_LDFLAGS", ""), pre.ldflags);
	const extra_d = try appendFlag(a, envOr(&env.all, "EXTRA_DFLAGS", ""), pre.dflags);
	if (extra_c.len > 0) std.debug.print("note: EXTRA_CFLAGS is ignored (no C sources are compiled by this build): {s}\n", .{extra_c});

	var flags: Flags = .{ .a = a };
	try flags.parse(extra_d);
	try flags.parse(extra_ld);

	// Fail early if any extra .o has the wrong architecture.
	for (flags.objects.items) |p| {
		const m = elfMachine(io, p) catch |e| fatal("Cannot read extra object {s}: {s}", .{ p, @errorName(e) });
		if (m != cfg.elf_machine) fatal(
			"{s} is built for {s} but target {s} needs {s}. Fix aprebuild.sh to compile it with $NDK_CLANG.",
			.{ p, machineName(m), cfg.abi, machineName(cfg.elf_machine) },
		);
		std.debug.print("   ok: {s} is {s}\n", .{ p, machineName(m) });
	}

	// the shared library
	const target = b.resolveTargetQuery(cfg.query);

	// raylib's build.zig panics for Android targets ("Target is not supported
	// with this platform"), so instantiate the dependency for the HOST (nothing
	// gets built, only its files are needed) and compile its Zig bindings
	// for the Android target. The C library is the prebuilt libraylib.a below.
	const raylib_dep = b.dependency("raylib_zig", .{ .target = b.graph.host, .optimize = opts.optimize });
	const raylib_bindings = b.createModule(.{
		.root_source_file = raylib_dep.path("lib/raylib.zig"),
		.target = target,
		.optimize = opts.optimize,
		.link_libc = true,
	});

	const mod = b.createModule(.{
		.root_source_file = b.path(opts.root_source_file),
		.target = target,
		.optimize = opts.optimize,
		.link_libc = true,
		.strip = true, // replaces llvm-strip --strip-unneeded
		.imports = blk: {
			const imports = b.allocator.alloc(std.Build.Module.Import, 1 + opts.extra_imports.len) catch @panic("OOM");
			imports[0] = .{ .name = "raylib", .module = raylib_bindings };
			@memcpy(imports[1..], opts.extra_imports);
			break :blk imports;
		},
	});
	mod.addLibraryPath(.{ .cwd_relative = sysroot_api_lib });

	// Point Zig at the NDK's bionic instead of its own libc.
	// NOTE: create the WriteFile step before addLibrary so the compile step
	// can declare a dependency on it.
	const libc_txt = b.fmt(
		\\include_dir={s}/usr/include
		\\sys_include_dir={s}/usr/include/{s}
		\\crt_dir={s}
		\\msvc_lib_dir=
		\\kernel32_lib_dir=
		\\cc_dir={s}
		\\darwin_sdk_dir=
		\\
	, .{ sysroot, sysroot, cfg.sysroot_lib_triple, sysroot_api_lib, sysroot_api_lib });
	var write_files = b.addWriteFiles();
	const libc_file = write_files.add("android-libc.txt", libc_txt);

	const lib = b.addLibrary(.{ .linkage = .dynamic, .name = "main", .root_module = mod });
	lib.libc_file = libc_file;
	lib.step.dependOn(&write_files.step); // ensure the .txt is generated first

	// --wrap=fopen can't be passed through Zig's build API. The equivalent
	// (exporting fopen/__real_fopen) lives in src/main.zig's Android glue.
	if (flags.wraps.items.len > 0)
		std.debug.print("note: --wrap flags are handled in src/main.zig (fopen glue), not at link time\n", .{});
	mod.addObjectFile(.{ .cwd_relative = raylib_a });

	for (flags.objects.items) |o| mod.addObjectFile(.{ .cwd_relative = o });
	for (flags.lib_dirs.items) |d| mod.addLibraryPath(.{ .cwd_relative = d });
	for (flags.libs.items) |l| mod.linkSystemLibrary(l, .{ .use_pkg_config = .no });
	for ([_][]const u8{ "EGL", "GLESv2", "android", "log" }) |l|
		mod.linkSystemLibrary(l, .{ .use_pkg_config = .no });

	// -Wl,-u,ANativeActivity_onCreate  (pulls it out of the raylib archive)
	if (@hasField(Build.Step.Compile, "force_undefined_symbols")) {
		lib.force_undefined_symbols.put(a, "ANativeActivity_onCreate", {}) catch @panic("OOM");
	} else if (@hasDecl(Build.Step.Compile, "forceUndefinedSymbol")) {
		lib.forceUndefinedSymbol("ANativeActivity_onCreate");
	} else {
		@compileError("This Zig version has no way to force an undefined symbol; see build-android.zig");
	}
	if (std.mem.eql(u8, envOr(&env.all, "VERBOSE_LINK", ""), "1")) lib.verbose_link = true;

	// copy to <ANDROID_OUTPUT_DIR>/jniLibs/<abi>/libmain.so
	const copy = b.addUpdateSourceFiles();
	copy.addCopyFileToSource(lib.getEmittedBin(), dest_lib);
	android_step.dependOn(&copy.step);
	const done = b.addSystemCommand(&.{ "printf", "DONE: \"\x1b[32m%s\x1b[0m\"\n", dest_lib });
	done.step.dependOn(&copy.step);
	android_step.dependOn(&done.step);

	// post-build
	if (hookState(io, "apostbuild.sh") == .ok) {
		const post = b.addSystemCommand(&.{ "./apostbuild.sh", dest_lib });
		// forward asetup.sh values
		for (env.file.keys(), env.file.values()) |k, v| post.setEnvironmentVariable(k, v);
		post.setEnvironmentVariable("OUT_DIR", out_dir);
		post.setEnvironmentVariable("ABI", cfg.abi);
		post.step.dependOn(&copy.step);
		android_step.dependOn(&post.step);
	}
}
