const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const low_dep = b.dependency("low", .{
        .target = target,
        .optimize = optimize,
        .vk_extras = true,
    });
    const vk_registry = try vulkanRegistry(b);
    const vulkan_dep = b.dependency("vulkan", .{ .registry = vk_registry });

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
    addShader(b, exe, "triangle_vert", "shaders/triangle.vert");
    addShader(b, exe, "triangle_frag", "shaders/triangle.frag");

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Run the multi-window Vulkan triangle demo");
    run_step.dependOn(&run.step);
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
