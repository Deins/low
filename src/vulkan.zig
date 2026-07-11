//! Small Vulkan glue shared by `low` applications.
//!
//! `low` deliberately does not depend on a particular Vulkan binding.  Pass
//! the generated `vulkan-zig` module to these helpers so an application keeps
//! ownership of its Vulkan version and loader strategy.
const std = @import("std");
const builtin = @import("builtin");

/// The instance extensions required by the backend selected by `context`.
///
/// Create the context before creating the Vulkan instance; on Linux the
/// selected backend determines whether this contains the Wayland or Xlib
/// surface extension.
pub fn requiredInstanceExtensions(context: anytype) []const [*:0]const u8 {
    return context.requiredVulkanInstanceExtensions();
}

/// Creates a Vulkan surface for a `low.Window`.
///
/// `vk` is normally the `vulkan-zig` import.  It is explicit so `low` remains
/// a windowing-only package and does not impose a Vulkan binding dependency on
/// applications that do not need one.
pub fn createSurface(comptime vk: type, context: anytype, window: anytype, instance: anytype) !vk.SurfaceKHR {
    if (builtin.target.os.tag == .windows) {
        return instance.createWin32SurfaceKHR(&.{
            .hinstance = @ptrCast(window.nativeDisplay()),
            .hwnd = @ptrFromInt(window.nativeSurface()),
        }, null);
    }

    if (builtin.target.os.tag == .linux) {
        return switch (context.backendKind()) {
            .wayland => instance.createWaylandSurfaceKHR(&.{
                .display = @ptrCast(@alignCast(window.nativeDisplay())),
                .surface = @ptrFromInt(window.nativeSurface()),
            }, null),
            .x11 => instance.createXlibSurfaceKHR(&.{
                .dpy = @ptrCast(@alignCast(window.nativeDisplay())),
                .window = @intCast(window.nativeSurface()),
            }, null),
        };
    }

    @compileError("low.vulkan.createSurface is only implemented for Linux and Windows");
}

/// A process-wide Vulkan loader for a `vulkan-zig` binding module.
///
/// The loader is opened dynamically, matching `low`'s runtime-selected desktop
/// backends.  Call `init` before creating `vk.BaseWrapper`, keep it alive until
/// every Vulkan object is destroyed, then call `deinit`.
pub fn Loader(comptime vk: type) type {
    return struct {
        const Self = @This();
        const Library = switch (builtin.target.os.tag) {
            .linux => *anyopaque,
            .windows => std.os.windows.HMODULE,
            else => @compileError("low.vulkan.Loader is only implemented for Linux and Windows"),
        };

        pub const Error = error{VulkanLoaderUnavailable};

        var library: ?Library = null;
        var raw_get_instance_proc_addr: ?vk.PfnGetInstanceProcAddr = null;

        /// Opens the system Vulkan loader.  Repeated calls are harmless.
        pub fn init() Error!void {
            if (library != null) return;

            switch (builtin.target.os.tag) {
                .linux => {
                    library = @ptrCast(std.c.dlopen("libvulkan.so.1", .{ .LAZY = true }));
                    if (library == null) return error.VulkanLoaderUnavailable;
                },
                .windows => {
                    library = LoadLibraryExW(
                        std.unicode.utf8ToUtf16LeStringLiteral("vulkan-1.dll"),
                        null,
                        0,
                    ) orelse return error.VulkanLoaderUnavailable;
                },
                else => unreachable,
            }
        }

        /// Releases the loader.  Only call this after destroying every Vulkan
        /// instance, device, surface, and swapchain created from it.
        pub fn deinit() void {
            const handle = library orelse return;
            switch (builtin.target.os.tag) {
                .linux => _ = std.c.dlclose(handle),
                .windows => _ = FreeLibrary(handle),
                else => unreachable,
            }
            library = null;
            raw_get_instance_proc_addr = null;
        }

        /// Returns a loader suitable for `vk.BaseWrapper.load`.
        pub fn getInstanceProcAddr() Error!vk.PfnGetInstanceProcAddr {
            if (raw_get_instance_proc_addr == null) {
                raw_get_instance_proc_addr = rawLookup(vk.PfnGetInstanceProcAddr, "vkGetInstanceProcAddr") orelse
                    return error.VulkanLoaderUnavailable;
            }
            return &dispatchGetInstanceProcAddr;
        }

        fn dispatchGetInstanceProcAddr(
            instance: vk.Instance,
            name: [*:0]const u8,
        ) callconv(vk.vulkan_call_conv) vk.PfnVoidFunction {
            // Vulkan 1.2 permits querying this function with a null instance.
            // Some loaders return null in that case, while vulkan-zig needs to
            // resolve it when constructing dispatch tables.
            if (std.mem.eql(u8, std.mem.span(name), "vkGetInstanceProcAddr")) {
                return @ptrCast(&dispatchGetInstanceProcAddr);
            }
            return (raw_get_instance_proc_addr orelse return null)(instance, name);
        }

        fn rawLookup(comptime T: type, name: [:0]const u8) ?T {
            const handle = library orelse return null;
            return switch (builtin.target.os.tag) {
                .linux => @ptrCast(@alignCast(std.c.dlsym(handle, name) orelse return null)),
                .windows => @ptrCast(GetProcAddress(handle, name.ptr) orelse return null),
                else => null,
            };
        }

        extern "kernel32" fn LoadLibraryExW(
            file_name: [*:0]const u16,
            file: ?std.os.windows.HANDLE,
            flags: std.os.windows.DWORD,
        ) callconv(.winapi) ?std.os.windows.HMODULE;
        extern "kernel32" fn FreeLibrary(handle: std.os.windows.HMODULE) callconv(.winapi) std.os.windows.BOOL;
        extern "kernel32" fn GetProcAddress(
            module: std.os.windows.HMODULE,
            name: [*:0]const u8,
        ) callconv(.winapi) ?*anyopaque;
    };
}
