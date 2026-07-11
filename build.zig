const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const linux_target = target.result.os.tag == .linux;
    const enable_x11 = b.option(bool, "x11", "Enable the X11 backend") orelse linux_target;
    const enable_wayland = b.option(bool, "wayland", "Enable the Wayland backend") orelse linux_target;
    const enable_vk_extras = b.option(bool, "vk_extras", "Expose optional Vulkan render-target helpers") orelse false;

    if (linux_target and !enable_x11 and !enable_wayland) {
        @panic("low: at least one of -Dx11 and -Dwayland must be enabled");
    }

    const options = b.addOptions();
    options.addOption(bool, "x11", enable_x11);
    options.addOption(bool, "wayland", enable_wayland);
    options.addOption(bool, "vk_extras", enable_vk_extras);

    const low = b.addModule("low", .{
        .root_source_file = b.path("src/low.zig"),
        .target = target,
        .optimize = optimize,
    });
    low.addOptions("build_options", options);

    if (target.result.os.tag == .linux) {
        addLinuxWaylandSupport(b, low, target, optimize);
    } else if (target.result.os.tag == .windows) {
        addWindowsSupport(b, low);
    } else {
        low.link_libc = true;
    }

    const test_module = b.addModule("low_tests", .{
        .root_source_file = b.path("src/low.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addOptions("build_options", options);
    if (target.result.os.tag == .linux) {
        addLinuxWaylandSupport(b, test_module, target, optimize);
    } else if (target.result.os.tag == .windows) {
        addWindowsSupport(b, test_module);
    } else {
        test_module.link_libc = true;
    }

    const tests = b.addTest(.{
        .root_module = test_module,
    });

    const compile_step = b.step("compile", "Compile low and its tests");
    compile_step.dependOn(&tests.step);

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run low tests");
    test_step.dependOn(&run_tests.step);
}

fn addWindowsSupport(b: *Build, module: *Build.Module) void {
    const win32 = b.lazyDependency("win32", .{}) orelse
        @panic("low: win32 dependency unavailable");
    module.addImport("win32", win32.module("win32"));
    module.link_libc = true;
}

fn addLinuxWaylandSupport(
    b: *Build,
    module: *Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const wayland = b.lazyImport(@This(), "wayland") orelse
        @panic("low: wayland dependency unavailable");
    const scanner = wayland.Scanner.create(b, .{
        .wayland_xml = b.path("src/wayland/protocols/wayland.xml"),
        .wayland_protocols = b.path("src/wayland/protocols"),
        // Keep libwayland-client out of the executable's DT_NEEDED entries.
        // The imported module supplies the scanner's FFI through dlopen after
        // the Wayland backend has been selected at runtime.
        .ffi_import = "wayland_ffi",
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

    const runtime_loader = b.createModule(.{
        .root_source_file = b.path("src/linux/runtime_loader.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const wayland_ffi = b.createModule(.{
        .root_source_file = b.path("src/linux/wayland_ffi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const wayland_mod = b.createModule(.{
        .root_source_file = scanner.result,
        .target = target,
        .optimize = optimize,
    });
    // This intentional import cycle is the extension point provided by
    // zig-wayland's Scanner.Options.ffi_import: the generated API owns the
    // protocol types, while the FFI module owns runtime-loaded function
    // pointers using those types.
    wayland_mod.addImport("wayland_ffi", wayland_ffi);
    wayland_ffi.addImport("wayland", wayland_mod);
    wayland_ffi.addImport("runtime_loader", runtime_loader);
    module.addImport("wayland", wayland_mod);
    module.addImport("wayland_ffi", wayland_ffi);
    module.addImport("runtime_loader", runtime_loader);
    module.link_libc = true;
}
