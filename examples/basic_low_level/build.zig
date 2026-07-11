const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const low_dep = b.dependency("low", .{
        .target = target,
        .optimize = optimize,
        .x11 = b.option(bool, "x11", "Enable the X11 backend") orelse (target.result.os.tag == .linux),
        .wayland = b.option(bool, "wayland", "Enable the Wayland backend") orelse (target.result.os.tag == .linux),
    });
    const vk_registry = try vulkanRegistry(b);
    const vulkan_dep = b.dependency("vulkan", .{ .registry = vk_registry });

    const exe = b.addExecutable(.{
        .name = "basic_low_level",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("low", low_dep.module("low"));
    exe.root_module.addImport("vulkan", vulkan_dep.module("vulkan-zig"));
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Run the raw low plus Vulkan setup example");
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
    return headers.path("registry/vk.xml");
}
