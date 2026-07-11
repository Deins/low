//! Small Vulkan glue shared by low applications.
//!
//! The library owns only the ABI and dispatch needed by its render-target
//! helpers. Applications may use any Vulkan binding for the rest of their
//! renderer.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
pub const api = @import("vulkan/api.zig");

pub const Loader = struct {
    const Self = @This();
    pub const Error = error{ VulkanLoaderUnavailable, VulkanFunctionUnavailable };

    library: ?*anyopaque,
    get_instance_proc_addr: api.PfnGetInstanceProcAddr,

    /// Opens the system Vulkan loader and resolves vkGetInstanceProcAddr.
    pub fn init() Error!Self {
        var self: Self = undefined;
        self.library = switch (builtin.target.os.tag) {
            .linux => @ptrCast(std.c.dlopen("libvulkan.so.1", .{ .LAZY = true }) orelse
                return error.VulkanLoaderUnavailable),
            .windows => @ptrCast(LoadLibraryExW(
                std.unicode.utf8ToUtf16LeStringLiteral("vulkan-1.dll"),
                null,
                0,
            ) orelse return error.VulkanLoaderUnavailable),
            else => return error.VulkanLoaderUnavailable,
        };
        self.get_instance_proc_addr = rawLookup(api.PfnGetInstanceProcAddr, self.library.?, "vkGetInstanceProcAddr") orelse {
            self.deinit();
            return error.VulkanLoaderUnavailable;
        };
        return self;
    }

    /// Releases the loader. All Vulkan objects created from it must already
    /// have been destroyed.
    pub fn deinit(self: *Self) void {
        const library = self.library orelse return;
        switch (builtin.target.os.tag) {
            .linux => _ = std.c.dlclose(library),
            .windows => _ = FreeLibrary(@ptrCast(library)),
            else => {},
        }
        self.library = null;
    }

    fn loadInstance(self: *const Self, instance: api.InstanceHandle, comptime T: type, name: [:0]const u8) Error!T {
        return loadProc(T, self.get_instance_proc_addr(instance, name));
    }

    pub fn loadInstanceApi(self: *const Self, instance_handle: api.InstanceHandle) Error!Instance {
        return Instance.init(self, instance_handle);
    }

    fn rawLookup(comptime T: type, library: *anyopaque, name: [:0]const u8) ?T {
        const raw: ?*const anyopaque = switch (builtin.target.os.tag) {
            .linux => @ptrCast(std.c.dlsym(library, name) orelse return null),
            .windows => @ptrCast(GetProcAddress(@ptrCast(library), name.ptr) orelse return null),
            else => return null,
        };
        return if (raw) |value| @ptrCast(@alignCast(value)) else null;
    }

    extern "kernel32" fn LoadLibraryExW(
        file_name: [*:0]const u16,
        file: ?*anyopaque,
        flags: u32,
    ) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn FreeLibrary(handle: *anyopaque) callconv(.winapi) u32;
    extern "kernel32" fn GetProcAddress(
        module: *anyopaque,
        name: [*:0]const u8,
    ) callconv(.winapi) ?*anyopaque;
};

pub const Instance = struct {
    const Self = @This();

    pub const Dispatch = struct {
        get_device_proc_addr: api.PfnGetDeviceProcAddr,
        destroy_instance: api.PfnDestroyInstance,
        destroy_surface_khr: ?api.PfnDestroySurfaceKHR,
        get_physical_device_surface_support_khr: ?api.PfnGetPhysicalDeviceSurfaceSupportKHR,
        get_physical_device_surface_capabilities_khr: ?api.PfnGetPhysicalDeviceSurfaceCapabilitiesKHR,
        get_physical_device_surface_formats_khr: ?api.PfnGetPhysicalDeviceSurfaceFormatsKHR,
        create_win32_surface_khr: ?api.PfnCreateWin32SurfaceKHR = null,
        create_wayland_surface_khr: ?api.PfnCreateWaylandSurfaceKHR = null,
        create_xlib_surface_khr: ?api.PfnCreateXlibSurfaceKHR = null,
    };

    handle: api.InstanceHandle,
    dispatch: Dispatch,

    fn init(loader: *const Loader, handle: api.InstanceHandle) Loader.Error!Self {
        return .{
            .handle = handle,
            .dispatch = .{
                .get_device_proc_addr = try loader.loadInstance(handle, api.PfnGetDeviceProcAddr, "vkGetDeviceProcAddr"),
                .destroy_instance = try loader.loadInstance(handle, api.PfnDestroyInstance, "vkDestroyInstance"),
                .destroy_surface_khr = loadOptionalInstance(loader, handle, api.PfnDestroySurfaceKHR, "vkDestroySurfaceKHR"),
                .get_physical_device_surface_support_khr = loadOptionalInstance(loader, handle, api.PfnGetPhysicalDeviceSurfaceSupportKHR, "vkGetPhysicalDeviceSurfaceSupportKHR"),
                .get_physical_device_surface_capabilities_khr = loadOptionalInstance(loader, handle, api.PfnGetPhysicalDeviceSurfaceCapabilitiesKHR, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR"),
                .get_physical_device_surface_formats_khr = loadOptionalInstance(loader, handle, api.PfnGetPhysicalDeviceSurfaceFormatsKHR, "vkGetPhysicalDeviceSurfaceFormatsKHR"),
                .create_win32_surface_khr = loadOptionalInstance(loader, handle, api.PfnCreateWin32SurfaceKHR, "vkCreateWin32SurfaceKHR"),
                .create_wayland_surface_khr = loadOptionalInstance(loader, handle, api.PfnCreateWaylandSurfaceKHR, "vkCreateWaylandSurfaceKHR"),
                .create_xlib_surface_khr = loadOptionalInstance(loader, handle, api.PfnCreateXlibSurfaceKHR, "vkCreateXlibSurfaceKHR"),
            },
        };
    }

    pub fn getPhysicalDeviceSurfaceSupportKHR(self: *const Self, physical_device: api.PhysicalDevice, queue_family: u32, surface: api.SurfaceKHR) !api.Bool32 {
        var supported: api.Bool32 = api.FALSE;
        const function = self.dispatch.get_physical_device_surface_support_khr orelse return error.VulkanFunctionUnavailable;
        try check(function(physical_device, queue_family, surface, &supported));
        return supported;
    }

    pub fn getPhysicalDeviceSurfaceCapabilitiesKHR(self: *const Self, physical_device: api.PhysicalDevice, surface: api.SurfaceKHR) !api.SurfaceCapabilitiesKHR {
        var capabilities: api.SurfaceCapabilitiesKHR = undefined;
        const function = self.dispatch.get_physical_device_surface_capabilities_khr orelse return error.VulkanFunctionUnavailable;
        try check(function(physical_device, surface, &capabilities));
        return capabilities;
    }

    pub fn getPhysicalDeviceSurfaceFormatsAllocKHR(self: *const Self, physical_device: api.PhysicalDevice, surface: api.SurfaceKHR, allocator: std.mem.Allocator) ![]api.SurfaceFormatKHR {
        const function = self.dispatch.get_physical_device_surface_formats_khr orelse return error.VulkanFunctionUnavailable;
        while (true) {
            var count: u32 = 0;
            try check(function(physical_device, surface, &count, null));
            const formats = try allocator.alloc(api.SurfaceFormatKHR, count);
            if (count == 0) return formats;
            const result = function(physical_device, surface, &count, formats.ptr);
            if (result == .incomplete) {
                allocator.free(formats);
                continue;
            }
            if (result != .success) {
                allocator.free(formats);
                try check(result);
                return error.VulkanError;
            }
            return formats[0..count];
        }
    }

    pub fn createWin32SurfaceKHR(self: *const Self, info: *const api.Win32SurfaceCreateInfoKHR) !api.SurfaceKHR {
        const function = self.dispatch.create_win32_surface_khr orelse return error.VulkanFunctionUnavailable;
        var surface: api.SurfaceKHR = 0;
        try check(function(self.handle, info, null, &surface));
        return surface;
    }

    pub fn createWaylandSurfaceKHR(self: *const Self, info: *const api.WaylandSurfaceCreateInfoKHR) !api.SurfaceKHR {
        const function = self.dispatch.create_wayland_surface_khr orelse return error.VulkanFunctionUnavailable;
        var surface: api.SurfaceKHR = 0;
        try check(function(self.handle, info, null, &surface));
        return surface;
    }

    pub fn createXlibSurfaceKHR(self: *const Self, info: *const api.XlibSurfaceCreateInfoKHR) !api.SurfaceKHR {
        const function = self.dispatch.create_xlib_surface_khr orelse return error.VulkanFunctionUnavailable;
        var surface: api.SurfaceKHR = 0;
        try check(function(self.handle, info, null, &surface));
        return surface;
    }

    pub fn destroySurfaceKHR(self: *const Self, surface: api.SurfaceKHR) void {
        const function = self.dispatch.destroy_surface_khr orelse return;
        function(self.handle, surface, null);
    }
};

pub const Device = struct {
    const Self = @This();

    pub const Dispatch = struct {
        device_wait_idle: api.PfnDeviceWaitIdle,
        wait_for_fences: api.PfnWaitForFences,
        acquire_next_image_khr: ?api.PfnAcquireNextImageKHR,
        reset_command_buffer: api.PfnResetCommandBuffer,
        begin_command_buffer: api.PfnBeginCommandBuffer,
        end_command_buffer: api.PfnEndCommandBuffer,
        queue_submit: api.PfnQueueSubmit,
        queue_present_khr: ?api.PfnQueuePresentKHR,
        create_swapchain_khr: ?api.PfnCreateSwapchainKHR,
        destroy_swapchain_khr: ?api.PfnDestroySwapchainKHR,
        get_swapchain_images_khr: ?api.PfnGetSwapchainImagesKHR,
        create_image_view: api.PfnCreateImageView,
        destroy_image_view: api.PfnDestroyImageView,
        allocate_command_buffers: api.PfnAllocateCommandBuffers,
        free_command_buffers: api.PfnFreeCommandBuffers,
        create_semaphore: api.PfnCreateSemaphore,
        destroy_semaphore: api.PfnDestroySemaphore,
        create_fence: api.PfnCreateFence,
        destroy_fence: api.PfnDestroyFence,
        create_image: api.PfnCreateImage,
        destroy_image: api.PfnDestroyImage,
        get_image_memory_requirements: api.PfnGetImageMemoryRequirements,
        bind_image_memory: api.PfnBindImageMemory,
        cmd_pipeline_barrier: api.PfnCmdPipelineBarrier,
    };

    handle: api.DeviceHandle,
    dispatch: Dispatch,

    pub fn init(instance: *const Instance, handle: api.DeviceHandle) Loader.Error!Self {
        const gpa = instance.dispatch.get_device_proc_addr;
        return .{
            .handle = handle,
            .dispatch = .{
                .device_wait_idle = try loadDevice(gpa, handle, api.PfnDeviceWaitIdle, "vkDeviceWaitIdle"),
                .wait_for_fences = try loadDevice(gpa, handle, api.PfnWaitForFences, "vkWaitForFences"),
                .acquire_next_image_khr = loadOptionalDevice(gpa, handle, api.PfnAcquireNextImageKHR, "vkAcquireNextImageKHR"),
                .reset_command_buffer = try loadDevice(gpa, handle, api.PfnResetCommandBuffer, "vkResetCommandBuffer"),
                .begin_command_buffer = try loadDevice(gpa, handle, api.PfnBeginCommandBuffer, "vkBeginCommandBuffer"),
                .end_command_buffer = try loadDevice(gpa, handle, api.PfnEndCommandBuffer, "vkEndCommandBuffer"),
                .queue_submit = try loadDevice(gpa, handle, api.PfnQueueSubmit, "vkQueueSubmit"),
                .queue_present_khr = loadOptionalDevice(gpa, handle, api.PfnQueuePresentKHR, "vkQueuePresentKHR"),
                .create_swapchain_khr = loadOptionalDevice(gpa, handle, api.PfnCreateSwapchainKHR, "vkCreateSwapchainKHR"),
                .destroy_swapchain_khr = loadOptionalDevice(gpa, handle, api.PfnDestroySwapchainKHR, "vkDestroySwapchainKHR"),
                .get_swapchain_images_khr = loadOptionalDevice(gpa, handle, api.PfnGetSwapchainImagesKHR, "vkGetSwapchainImagesKHR"),
                .create_image_view = try loadDevice(gpa, handle, api.PfnCreateImageView, "vkCreateImageView"),
                .destroy_image_view = try loadDevice(gpa, handle, api.PfnDestroyImageView, "vkDestroyImageView"),
                .allocate_command_buffers = try loadDevice(gpa, handle, api.PfnAllocateCommandBuffers, "vkAllocateCommandBuffers"),
                .free_command_buffers = try loadDevice(gpa, handle, api.PfnFreeCommandBuffers, "vkFreeCommandBuffers"),
                .create_semaphore = try loadDevice(gpa, handle, api.PfnCreateSemaphore, "vkCreateSemaphore"),
                .destroy_semaphore = try loadDevice(gpa, handle, api.PfnDestroySemaphore, "vkDestroySemaphore"),
                .create_fence = try loadDevice(gpa, handle, api.PfnCreateFence, "vkCreateFence"),
                .destroy_fence = try loadDevice(gpa, handle, api.PfnDestroyFence, "vkDestroyFence"),
                .create_image = try loadDevice(gpa, handle, api.PfnCreateImage, "vkCreateImage"),
                .destroy_image = try loadDevice(gpa, handle, api.PfnDestroyImage, "vkDestroyImage"),
                .get_image_memory_requirements = try loadDevice(gpa, handle, api.PfnGetImageMemoryRequirements, "vkGetImageMemoryRequirements"),
                .bind_image_memory = try loadDevice(gpa, handle, api.PfnBindImageMemory, "vkBindImageMemory"),
                .cmd_pipeline_barrier = try loadDevice(gpa, handle, api.PfnCmdPipelineBarrier, "vkCmdPipelineBarrier"),
            },
        };
    }

    pub fn deviceWaitIdle(self: *const Self) !void {
        try check(self.dispatch.device_wait_idle(self.handle));
    }

    pub fn waitForFences(self: *const Self, fences: []const api.Fence, wait_all: bool, timeout: u64) !api.Result {
        return try allowStatus(self.dispatch.wait_for_fences(self.handle, @intCast(fences.len), fences.ptr, if (wait_all) api.TRUE else api.FALSE, timeout));
    }

    pub const AcquireResult = struct {
        result: api.Result,
        image_index: u32,
    };

    pub fn acquireNextImageKHR(self: *const Self, swapchain: api.SwapchainKHR, timeout: u64, semaphore: api.Semaphore, fence: api.Fence) !AcquireResult {
        var image_index: u32 = 0;
        const function = self.dispatch.acquire_next_image_khr orelse return error.VulkanFunctionUnavailable;
        const result = try allowStatus(function(self.handle, swapchain, timeout, semaphore, fence, &image_index));
        return .{ .result = result, .image_index = image_index };
    }

    pub fn resetCommandBuffer(self: *const Self, command_buffer: api.CommandBuffer) !void {
        try check(self.dispatch.reset_command_buffer(command_buffer, 0));
    }

    pub fn beginCommandBuffer(self: *const Self, command_buffer: api.CommandBuffer) !void {
        const info = api.CommandBufferBeginInfo{
            .s_type = .command_buffer_begin_info,
            .p_next = null,
            .flags = api.command_buffer_usage.one_time_submit_bit,
            .p_inheritance_info = null,
        };
        try check(self.dispatch.begin_command_buffer(command_buffer, &info));
    }

    pub fn endCommandBuffer(self: *const Self, command_buffer: api.CommandBuffer) !void {
        try check(self.dispatch.end_command_buffer(command_buffer));
    }

    pub fn queueSubmit(self: *const Self, queue: api.Queue, submit_info: *const api.SubmitInfo, fence: api.Fence) !void {
        try check(self.dispatch.queue_submit(queue, 1, @ptrCast(submit_info), fence));
    }

    pub fn queuePresentKHR(self: *const Self, queue: api.Queue, present_info: *const api.PresentInfoKHR) !api.Result {
        const function = self.dispatch.queue_present_khr orelse return error.VulkanFunctionUnavailable;
        return try allowStatus(function(queue, present_info));
    }

    pub fn createSwapchainKHR(self: *const Self, info: *const api.SwapchainCreateInfoKHR) !api.SwapchainKHR {
        var swapchain: api.SwapchainKHR = 0;
        const function = self.dispatch.create_swapchain_khr orelse return error.VulkanFunctionUnavailable;
        try check(function(self.handle, info, null, &swapchain));
        return swapchain;
    }

    pub fn getSwapchainImagesAllocKHR(self: *const Self, swapchain: api.SwapchainKHR, allocator: std.mem.Allocator) ![]api.Image {
        const function = self.dispatch.get_swapchain_images_khr orelse return error.VulkanFunctionUnavailable;
        while (true) {
            var count: u32 = 0;
            try check(function(self.handle, swapchain, &count, null));
            const images = try allocator.alloc(api.Image, count);
            if (count == 0) return images;
            const result = function(self.handle, swapchain, &count, images.ptr);
            if (result == .incomplete) {
                allocator.free(images);
                continue;
            }
            if (result != .success) {
                allocator.free(images);
                try check(result);
                return error.VulkanError;
            }
            return images[0..count];
        }
    }

    pub fn destroySwapchainKHR(self: *const Self, swapchain: api.SwapchainKHR) void {
        const function = self.dispatch.destroy_swapchain_khr orelse return;
        function(self.handle, swapchain, null);
    }

    pub fn createImageView(self: *const Self, info: *const api.ImageViewCreateInfo) !api.ImageView {
        var view: api.ImageView = 0;
        try check(self.dispatch.create_image_view(self.handle, info, null, &view));
        return view;
    }

    pub fn destroyImageView(self: *const Self, view: api.ImageView) void {
        self.dispatch.destroy_image_view(self.handle, view, null);
    }

    pub fn allocateCommandBuffers(self: *const Self, info: *const api.CommandBufferAllocateInfo, buffers: []api.CommandBuffer) !void {
        try check(self.dispatch.allocate_command_buffers(self.handle, info, buffers.ptr));
    }

    pub fn freeCommandBuffers(self: *const Self, pool: api.CommandPool, buffers: []const api.CommandBuffer) void {
        self.dispatch.free_command_buffers(self.handle, pool, @intCast(buffers.len), buffers.ptr);
    }

    pub fn createSemaphore(self: *const Self) !api.Semaphore {
        var semaphore: api.Semaphore = 0;
        const info = api.SemaphoreCreateInfo{ .s_type = .semaphore_create_info, .p_next = null, .flags = 0 };
        try check(self.dispatch.create_semaphore(self.handle, &info, null, &semaphore));
        return semaphore;
    }

    pub fn destroySemaphore(self: *const Self, semaphore: api.Semaphore) void {
        self.dispatch.destroy_semaphore(self.handle, semaphore, null);
    }

    pub fn createFence(self: *const Self, signaled: bool) !api.Fence {
        var fence: api.Fence = 0;
        const info = api.FenceCreateInfo{
            .s_type = .fence_create_info,
            .p_next = null,
            .flags = if (signaled) api.fence_create.signaled_bit else 0,
        };
        try check(self.dispatch.create_fence(self.handle, &info, null, &fence));
        return fence;
    }

    pub fn destroyFence(self: *const Self, fence: api.Fence) void {
        self.dispatch.destroy_fence(self.handle, fence, null);
    }

    pub fn createImage(self: *const Self, info: *const api.ImageCreateInfo) !api.Image {
        var image: api.Image = 0;
        try check(self.dispatch.create_image(self.handle, info, null, &image));
        return image;
    }

    pub fn destroyImage(self: *const Self, image: api.Image) void {
        self.dispatch.destroy_image(self.handle, image, null);
    }

    pub fn getImageMemoryRequirements(self: *const Self, image: api.Image) api.MemoryRequirements {
        var requirements: api.MemoryRequirements = undefined;
        self.dispatch.get_image_memory_requirements(self.handle, image, &requirements);
        return requirements;
    }

    pub fn bindImageMemory(self: *const Self, image: api.Image, memory: api.DeviceMemory, offset: u64) !void {
        try check(self.dispatch.bind_image_memory(self.handle, image, memory, offset));
    }

    pub fn cmdPipelineBarrier(
        self: *const Self,
        command_buffer: api.CommandBuffer,
        src_stage: api.PipelineStageFlags,
        dst_stage: api.PipelineStageFlags,
        barrier: *const api.ImageMemoryBarrier,
    ) void {
        self.dispatch.cmd_pipeline_barrier(command_buffer, src_stage, dst_stage, 0, 0, null, 0, null, 1, @ptrCast(barrier));
    }
};

pub fn targets() type {
    if (!build_options.vk_extras) @compileError("enable -Dvk_extras=true");
    return @import("vulkan/targets.zig");
}

pub fn requiredInstanceExtensions(context: anytype) []const [*:0]const u8 {
    return context.requiredVulkanInstanceExtensions();
}

pub fn createSurface(instance: *const Instance, context: anytype, window: anytype) !api.SurfaceKHR {
    if (builtin.target.os.tag == .windows) {
        const info = api.Win32SurfaceCreateInfoKHR{
            .s_type = .win32_surface_create_info_khr,
            .p_next = null,
            .flags = 0,
            .hinstance = @ptrCast(window.nativeDisplay()),
            .hwnd = @ptrFromInt(window.nativeSurface()),
        };
        return instance.createWin32SurfaceKHR(&info);
    }

    if (builtin.target.os.tag == .linux) {
        return switch (context.backendKind()) {
            .wayland => instance.createWaylandSurfaceKHR(&.{
                .s_type = .wayland_surface_create_info_khr,
                .p_next = null,
                .flags = 0,
                .display = @ptrCast(@alignCast(window.nativeDisplay())),
                .surface = @ptrFromInt(window.nativeSurface()),
            }),
            .x11 => instance.createXlibSurfaceKHR(&.{
                .s_type = .xlib_surface_create_info_khr,
                .p_next = null,
                .flags = 0,
                .dpy = @ptrCast(@alignCast(window.nativeDisplay())),
                .window = @intCast(window.nativeSurface()),
            }),
            .offscreen => error.OffscreenSurfaceUnavailable,
            .windows => error.UnsupportedPlatform,
        };
    }

    @compileError("low.vulkan.createSurface is only implemented for Linux and Windows");
}

fn loadProc(comptime T: type, raw: api.PfnVoidFunction) Loader.Error!T {
    const value = raw orelse return error.VulkanFunctionUnavailable;
    return @ptrCast(@alignCast(value));
}

fn loadOptionalInstance(loader: *const Loader, instance: api.InstanceHandle, comptime T: type, name: [:0]const u8) ?T {
    return loader.loadInstance(instance, T, name) catch null;
}

fn loadDevice(get_device_proc_addr: api.PfnGetDeviceProcAddr, device: api.DeviceHandle, comptime T: type, name: [:0]const u8) Loader.Error!T {
    return loadProc(T, get_device_proc_addr(device, name));
}

fn loadOptionalDevice(get_device_proc_addr: api.PfnGetDeviceProcAddr, device: api.DeviceHandle, comptime T: type, name: [:0]const u8) ?T {
    return loadDevice(get_device_proc_addr, device, T, name) catch null;
}

fn allowStatus(result: api.Result) !api.Result {
    try check(result);
    return result;
}

fn check(result: api.Result) !void {
    return switch (result) {
        .success, .not_ready, .timeout, .event_set, .event_reset, .incomplete, .suboptimal_khr => {},
        .error_out_of_host_memory => error.OutOfHostMemory,
        .error_out_of_device_memory => error.OutOfDeviceMemory,
        .error_initialization_failed => error.InitializationFailed,
        .error_device_lost => error.DeviceLost,
        .error_memory_map_failed => error.MemoryMapFailed,
        .error_layer_not_present => error.LayerNotPresent,
        .error_extension_not_present => error.ExtensionNotPresent,
        .error_feature_not_present => error.FeatureNotPresent,
        .error_incompatible_driver => error.IncompatibleDriver,
        .error_too_many_objects => error.TooManyObjects,
        .error_format_not_supported => error.FormatNotSupported,
        .error_fragmented_pool => error.FragmentedPool,
        .error_surface_lost_khr => error.SurfaceLostKHR,
        .error_native_window_in_use_khr => error.NativeWindowInUseKHR,
        .error_out_of_date_khr => error.OutOfDateKHR,
        .error_unknown => error.VulkanError,
        else => error.VulkanError,
    };
}
