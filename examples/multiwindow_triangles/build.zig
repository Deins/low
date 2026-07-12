const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const enable_video = b.option(bool, "vk_video", "Compile Vulkan Video recording support") orelse true;

    const low_dep = b.dependency("low", .{
        .target = target,
        .optimize = optimize,
        .vk_extras = true,
        .vk_video = enable_video,
        .x11 = b.option(bool, "x11", "Enable the X11 backend") orelse (target.result.os.tag == .linux),
        .wayland = b.option(bool, "wayland", "Enable the Wayland backend") orelse (target.result.os.tag == .linux),
    });
    const vk_registry = try vulkanRegistry(b);
    const vulkan_dep = if (enable_video)
        b.dependency("vulkan", .{ .registry = vk_registry, .video = try vulkanVideoRegistry(b) })
    else
        b.dependency("vulkan", .{ .registry = vk_registry });

    const exe = b.addExecutable(.{
        .name = "multiwindow_triangles",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("low", low_dep.module("low"));
    exe.root_module.addImport("vulkan", vulkan_dep.module("vulkan-zig"));
    const options = b.addOptions();
    options.addOption(bool, "vk_video", enable_video);
    exe.root_module.addOptions("example_options", options);
    addShader(b, exe, "triangle_vert", "shaders/triangle.vert");
    addShader(b, exe, "triangle_frag", "shaders/triangle.frag");

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Run the multi-window Vulkan triangle demo");
    run_step.dependOn(&run.step);
}

fn vulkanVideoRegistry(b: *Build) !Build.LazyPath {
    if (b.option([]const u8, "vk_video_registry", "Path to Vulkan Video registry/video.xml")) |path| {
        return .{ .cwd_relative = path };
    }
    if (b.graph.environ_map.get("VULKAN_SDK")) |sdk| {
        return .{ .cwd_relative = b.pathJoin(&.{ sdk, "share", "vulkan", "registry", "video.xml" }) };
    }
    const headers = b.lazyDependency("vulkan_headers", .{}) orelse
        return error.VulkanVideoRegistryUnavailable;
    return headers.path("registry/video.xml");
}

fn vulkanRegistry(b: *Build) !Build.LazyPath {
    if (b.option([]const u8, "vk_registry", "Path to Vulkan-Headers registry/vk.xml")) |path| {
        return .{ .cwd_relative = path };
    }
    if (b.graph.environ_map.get("VULKAN_SDK")) |sdk| {
        return .{ .cwd_relative = b.pathJoin(&.{ sdk, "share", "vulkan", "registry", "vk.xml" }) };
    }
    const headers = b.lazyDependency("vulkan_headers", .{}) orelse
        return error.VulkanRegistryUnavailable;
    std.log.info("VULKAN_SDK is unset; using the lazy vulkan_headers dependency", .{});
    return headers.path("registry/vk.xml");
}

fn addShader(b: *Build, exe: *Build.Step.Compile, name: []const u8, source: []const u8) void {
    const compile = b.addSystemCommand(&.{ "glslc", "--target-env=vulkan1.3", "-o" });
    const output = compile.addOutputFileArg(b.fmt("{s}.spv", .{name}));
    compile.addFileArg(b.path(source));
    exe.root_module.addAnonymousImport(name, .{ .root_source_file = output });
    exe.step.dependOn(&compile.step);
}
