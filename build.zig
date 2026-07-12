const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const linux_target = target.result.os.tag == .linux;
    const enable_x11 = b.option(bool, "x11", "Enable the X11 backend") orelse linux_target;
    const enable_wayland = b.option(bool, "wayland", "Enable the Wayland backend") orelse linux_target;
    const enable_vk_video = b.option(bool, "vk_video", "Enable Vulkan Video H.264/H.265/AV1 recording") orelse false;
    const enable_vk_extras = (b.option(bool, "vk_extras", "Expose optional Vulkan render-target helpers") orelse false) or enable_vk_video;

    if (linux_target and !enable_x11 and !enable_wayland) {
        @panic("low: at least one of -Dx11 and -Dwayland must be enabled");
    }

    const options = b.addOptions();
    options.addOption(bool, "x11", enable_x11);
    options.addOption(bool, "wayland", enable_wayland);
    options.addOption(bool, "vk_extras", enable_vk_extras);
    options.addOption(bool, "vk_video", enable_vk_video);

    const low = b.addModule("low", .{
        .root_source_file = b.path("src/low.zig"),
        .target = target,
        .optimize = optimize,
    });
    low.addOptions("build_options", options);

    const video_binding = if (enable_vk_video) addVulkanVideoBinding(b) else null;
    if (video_binding) |binding| low.addImport("_vk_video", binding);

    const low_platform_ready = addPlatformSupport(b, low, target, optimize, enable_wayland);

    const docs = b.addObject(.{
        .name = "docs",
        .root_module = low,
    });

    const test_module = b.addModule("low_tests", .{
        .root_source_file = b.path("src/low.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addOptions("build_options", options);
    if (video_binding) |binding| test_module.addImport("_vk_video", binding);
    const test_platform_ready = addPlatformSupport(b, test_module, target, optimize, enable_wayland);

    if ((enable_vk_video and video_binding == null) or !low_platform_ready or !test_platform_ready) return;

    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate documentation source");
    docs_step.dependOn(&install_docs.step);

    const tests = b.addTest(.{
        .root_module = test_module,
    });

    const compile_step = b.step("compile", "Compile low and its tests");
    compile_step.dependOn(&tests.step);

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run low tests");
    test_step.dependOn(&run_tests.step);

    addVideoShaderSteps(b);
}

fn addVideoShaderSteps(b: *Build) void {
    const source = b.path("src/vulkan/video/shaders/bgra_to_nv12.comp");
    const checked_in = b.path("src/vulkan/video/shaders/bgra_to_nv12.spv");

    const compile = b.addSystemCommand(&.{ "glslc", "--target-env=vulkan1.3", "-O", "-o" });
    const generated = compile.addOutputFileArg("bgra_to_nv12.spv");
    compile.addFileArg(source);
    const compare = b.addSystemCommand(&.{ "cmp", "--silent" });
    compare.addFileArg(checked_in);
    compare.addFileArg(generated);
    const check_step = b.step("check-vk-video-shader", "Regenerate and compare the checked-in Vulkan Video shader");
    check_step.dependOn(&compare.step);

    const regenerate = b.addSystemCommand(&.{ "glslc", "--target-env=vulkan1.3", "-O", "-o", "src/vulkan/video/shaders/bgra_to_nv12.spv" });
    regenerate.addFileArg(source);
    const regenerate_step = b.step("regenerate-vk-video-shader", "Regenerate the checked-in Vulkan Video shader");
    regenerate_step.dependOn(&regenerate.step);
}

fn addVulkanVideoBinding(b: *Build) ?*Build.Module {
    const headers = b.lazyDependency("vulkan_headers", .{}) orelse return null;
    const vulkan = b.lazyDependency("vulkan", .{
        .registry = headers.path("registry/vk.xml"),
        .video = headers.path("registry/video.xml"),
    }) orelse return null;
    return vulkan.module("vulkan-zig");
}

fn addPlatformSupport(
    b: *Build,
    module: *Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    enable_wayland: bool,
) bool {
    switch (target.result.os.tag) {
        .linux => return addLinuxSupport(b, module, target, optimize, enable_wayland),
        .windows => return addWindowsSupport(b, module),
        else => module.link_libc = true,
    }
    return true;
}

fn addWindowsSupport(b: *Build, module: *Build.Module) bool {
    const win32 = b.lazyDependency("win32", .{}) orelse return false;
    module.addImport("win32", win32.module("win32"));
    module.linkSystemLibrary("dwmapi", .{});
    module.link_libc = true;
    return true;
}

fn addLinuxSupport(
    b: *Build,
    module: *Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    enable_wayland: bool,
) bool {
    // Both the X11 and Wayland Linux backends use libc. X11-only test builds
    // still need this even though they do not generate Wayland bindings.
    module.link_libc = true;
    if (!enable_wayland) return true;

    const wayland = b.lazyImport(@This(), "wayland") orelse return false;
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
    module.addImport("wayland", wayland_mod);
    module.addImport("wayland_ffi", wayland_ffi);
    module.link_libc = true;
    return true;
}
