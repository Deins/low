const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const linux_target = target.result.os.tag == .linux;
    const enable_x11 = b.option(bool, "x11", "Enable the X11 backend") orelse linux_target;
    const enable_wayland = b.option(bool, "wayland", "Enable the Wayland backend") orelse linux_target;

    if (linux_target and !enable_x11 and !enable_wayland) {
        @panic("low: at least one of -Dx11 and -Dwayland must be enabled");
    }

    const options = b.addOptions();
    options.addOption(bool, "x11", enable_x11);
    options.addOption(bool, "wayland", enable_wayland);

    const low = b.addModule("low", .{
        .root_source_file = b.path("src/low.zig"),
        .target = target,
        .optimize = optimize,
    });
    low.addOptions("build_options", options);

    if (target.result.os.tag == .linux) {
        addLinuxWaylandSupport(b, low, target, optimize, enable_x11, enable_wayland);
    } else {
        low.link_libc = true;
    }

    const test_module = b.addModule("low_tests", .{
        .root_source_file = b.path("src/low.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (target.result.os.tag == .linux) {
        test_module.addOptions("build_options", options);
        addLinuxWaylandSupport(b, test_module, target, optimize, enable_x11, enable_wayland);
    } else {
        test_module.link_libc = true;
    }

    const tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run low tests");
    test_step.dependOn(&run_tests.step);
}

fn addLinuxWaylandSupport(
    b: *Build,
    module: *Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    enable_x11: bool,
    enable_wayland: bool,
) void {
    const wayland = b.lazyImport(@This(), "wayland") orelse
        @panic("low: wayland dependency unavailable");
    const scanner = wayland.Scanner.create(b, .{
        .wayland_xml = b.path("src/wayland/protocols/wayland.xml"),
        .wayland_protocols = b.path("src/wayland/protocols"),
    });
    scanner.addCustomProtocol(b.path("src/wayland/protocols/xdg-shell.xml"));
    scanner.addCustomProtocol(b.path("src/wayland/protocols/xdg-decoration-unstable-v1.xml"));
    scanner.addCustomProtocol(b.path("src/wayland/protocols/cursor-shape-v1.xml"));
    scanner.addCustomProtocol(b.path("src/wayland/protocols/tablet-v2.xml"));
    scanner.generate("wl_compositor", 5);
    scanner.generate("wl_seat", 5);
    scanner.generate("wl_output", 4);
    scanner.generate("xdg_wm_base", 6);
    scanner.generate("zxdg_decoration_manager_v1", 2);
    scanner.generate("wp_cursor_shape_manager_v1", 1);

    const wayland_mod = b.createModule(.{
        .root_source_file = scanner.result,
        .target = target,
        .optimize = optimize,
    });
    module.addImport("wayland", wayland_mod);
    module.link_libc = true;
    // The current Linux implementation keeps both native backends in one
    // module, so both native libraries must remain linkable whenever the low
    // backend is built. The options still control which backend may be
    // selected at runtime; splitting the implementation is required before
    // these dependencies can be eliminated from the link entirely.
    if (enable_x11 or enable_wayland) module.linkSystemLibrary("wayland-client", .{});
    if (enable_x11 or enable_wayland) module.linkSystemLibrary("xkbcommon", .{});
    if (enable_x11 or enable_wayland) module.linkSystemLibrary("X11", .{});
}
