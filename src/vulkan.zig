//! Small Vulkan glue shared by low applications.
//!
//! The library owns only the ABI and dispatch needed by its render-target
//! helpers. Applications may use any Vulkan binding for the rest of their
//! renderer.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const types = @import("internal/types.zig");
pub const api = @import("vulkan/api.zig");

pub const Loader = struct {
    const Self = @This();
    pub const Error = error{ VulkanLoaderUnavailable, VulkanFunctionUnavailable };

    const Library = if (builtin.target.os.tag == .windows) *anyopaque else std.DynLib;

    library: ?Library,
    get_instance_proc_addr: api.PfnGetInstanceProcAddr,

    /// Opens the system Vulkan loader and resolves vkGetInstanceProcAddr.
    pub fn init() Error!Self {
        var self: Self = undefined;
        if (builtin.target.os.tag == .linux) {
            self.library = std.DynLib.open("libvulkan.so.1") catch return error.VulkanLoaderUnavailable;
            self.get_instance_proc_addr = self.library.?.lookup(api.PfnGetInstanceProcAddr, "vkGetInstanceProcAddr") orelse {
                self.deinit();
                return error.VulkanLoaderUnavailable;
            };
        } else if (builtin.target.os.tag == .windows) {
            self.library = LoadLibraryExW(
                std.unicode.utf8ToUtf16LeStringLiteral("vulkan-1.dll"),
                null,
                0,
            ) orelse return error.VulkanLoaderUnavailable;
            self.get_instance_proc_addr = rawLookup(api.PfnGetInstanceProcAddr, self.library.?, "vkGetInstanceProcAddr") orelse {
                self.deinit();
                return error.VulkanLoaderUnavailable;
            };
        } else return error.VulkanLoaderUnavailable;
        return self;
    }

    /// Releases the loader. All Vulkan objects created from it must already
    /// have been destroyed.
    pub fn deinit(self: *Self) void {
        if (builtin.target.os.tag == .windows) {
            _ = FreeLibrary(self.library orelse return);
        } else {
            var library = self.library orelse return;
            library.close();
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
        const raw = GetProcAddress(@ptrCast(library), name.ptr) orelse return null;
        return @ptrCast(@alignCast(raw));
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
        get_physical_device_format_properties: api.PfnGetPhysicalDeviceFormatProperties,
        get_physical_device_memory_properties: api.PfnGetPhysicalDeviceMemoryProperties,
        destroy_surface_khr: ?api.PfnDestroySurfaceKHR,
        get_physical_device_surface_support_khr: ?api.PfnGetPhysicalDeviceSurfaceSupportKHR,
        get_physical_device_surface_capabilities_khr: ?api.PfnGetPhysicalDeviceSurfaceCapabilitiesKHR,
        get_physical_device_surface_formats_khr: ?api.PfnGetPhysicalDeviceSurfaceFormatsKHR,
        get_physical_device_surface_present_modes_khr: ?api.PfnGetPhysicalDeviceSurfacePresentModesKHR,
        get_physical_device_wayland_presentation_support_khr: ?api.PfnGetPhysicalDeviceWaylandPresentationSupportKHR = null,
        get_physical_device_win32_presentation_support_khr: ?api.PfnGetPhysicalDeviceWin32PresentationSupportKHR = null,
        get_physical_device_xlib_presentation_support_khr: ?api.PfnGetPhysicalDeviceXlibPresentationSupportKHR = null,
        create_win32_surface_khr: ?api.PfnCreateWin32SurfaceKHR = null,
        create_wayland_surface_khr: ?api.PfnCreateWaylandSurfaceKHR = null,
        create_xlib_surface_khr: ?api.PfnCreateXlibSurfaceKHR = null,
    };

    handle: api.InstanceHandle,
    get_instance_proc_addr: api.PfnGetInstanceProcAddr,
    dispatch: Dispatch,

    fn init(loader: *const Loader, handle: api.InstanceHandle) Loader.Error!Self {
        return .{
            .handle = handle,
            .get_instance_proc_addr = loader.get_instance_proc_addr,
            .dispatch = .{
                .get_device_proc_addr = try loader.loadInstance(handle, api.PfnGetDeviceProcAddr, "vkGetDeviceProcAddr"),
                .destroy_instance = try loader.loadInstance(handle, api.PfnDestroyInstance, "vkDestroyInstance"),
                .get_physical_device_format_properties = try loader.loadInstance(handle, api.PfnGetPhysicalDeviceFormatProperties, "vkGetPhysicalDeviceFormatProperties"),
                .get_physical_device_memory_properties = try loader.loadInstance(handle, api.PfnGetPhysicalDeviceMemoryProperties, "vkGetPhysicalDeviceMemoryProperties"),
                .destroy_surface_khr = loadOptionalInstance(loader, handle, api.PfnDestroySurfaceKHR, "vkDestroySurfaceKHR"),
                .get_physical_device_surface_support_khr = loadOptionalInstance(loader, handle, api.PfnGetPhysicalDeviceSurfaceSupportKHR, "vkGetPhysicalDeviceSurfaceSupportKHR"),
                .get_physical_device_surface_capabilities_khr = loadOptionalInstance(loader, handle, api.PfnGetPhysicalDeviceSurfaceCapabilitiesKHR, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR"),
                .get_physical_device_surface_formats_khr = loadOptionalInstance(loader, handle, api.PfnGetPhysicalDeviceSurfaceFormatsKHR, "vkGetPhysicalDeviceSurfaceFormatsKHR"),
                .get_physical_device_surface_present_modes_khr = loadOptionalInstance(loader, handle, api.PfnGetPhysicalDeviceSurfacePresentModesKHR, "vkGetPhysicalDeviceSurfacePresentModesKHR"),
                .get_physical_device_wayland_presentation_support_khr = loadOptionalInstance(loader, handle, api.PfnGetPhysicalDeviceWaylandPresentationSupportKHR, "vkGetPhysicalDeviceWaylandPresentationSupportKHR"),
                .get_physical_device_win32_presentation_support_khr = loadOptionalInstance(loader, handle, api.PfnGetPhysicalDeviceWin32PresentationSupportKHR, "vkGetPhysicalDeviceWin32PresentationSupportKHR"),
                .get_physical_device_xlib_presentation_support_khr = loadOptionalInstance(loader, handle, api.PfnGetPhysicalDeviceXlibPresentationSupportKHR, "vkGetPhysicalDeviceXlibPresentationSupportKHR"),
                .create_win32_surface_khr = loadOptionalInstance(loader, handle, api.PfnCreateWin32SurfaceKHR, "vkCreateWin32SurfaceKHR"),
                .create_wayland_surface_khr = loadOptionalInstance(loader, handle, api.PfnCreateWaylandSurfaceKHR, "vkCreateWaylandSurfaceKHR"),
                .create_xlib_surface_khr = loadOptionalInstance(loader, handle, api.PfnCreateXlibSurfaceKHR, "vkCreateXlibSurfaceKHR"),
            },
        };
    }

    pub fn getPhysicalDeviceMemoryProperties(self: *const Self, physical_device: api.PhysicalDevice) api.PhysicalDeviceMemoryProperties {
        var properties: api.PhysicalDeviceMemoryProperties = undefined;
        self.dispatch.get_physical_device_memory_properties(physical_device, &properties);
        return properties;
    }

    pub fn getPhysicalDeviceFormatProperties(self: *const Self, physical_device: api.PhysicalDevice, format: api.Format) api.FormatProperties {
        var properties: api.FormatProperties = undefined;
        self.dispatch.get_physical_device_format_properties(physical_device, format, &properties);
        return properties;
    }

    pub fn getPhysicalDeviceSurfaceSupportKHR(self: *const Self, physical_device: api.PhysicalDevice, queue_family: u32, surface: api.SurfaceKHR) !api.Bool32 {
        var supported: api.Bool32 = api.FALSE;
        const function = self.dispatch.get_physical_device_surface_support_khr orelse return error.VulkanFunctionUnavailable;
        try check(function(physical_device, queue_family, surface, &supported));
        return supported;
    }

    /// Returns the first queue family that can present to `surface`.
    ///
    /// The queue-family properties themselves are binding-specific, so the
    /// caller supplies the number of families obtained from its Vulkan
    /// binding. A null result means no family in that range supports the
    /// surface.
    pub fn findSurfacePresentQueueFamilyKHR(self: *const Self, physical_device: api.PhysicalDevice, surface: api.SurfaceKHR, queue_family_count: u32) !?u32 {
        for (0..queue_family_count) |index| {
            if (try self.getPhysicalDeviceSurfaceSupportKHR(physical_device, @intCast(index), surface) == api.TRUE) {
                return @intCast(index);
            }
        }
        return null;
    }

    /// Tests presentation support without creating a native window or Vulkan
    /// surface. Xlib uses the context's default visual.
    pub fn getPhysicalDevicePresentationSupportKHR(
        self: *const Self,
        physical_device: api.PhysicalDevice,
        queue_family: u32,
        presentation: PresentationSupport,
    ) !api.Bool32 {
        return switch (presentation) {
            .wayland => |display| (self.dispatch.get_physical_device_wayland_presentation_support_khr orelse return error.VulkanFunctionUnavailable)(
                physical_device,
                queue_family,
                display,
            ),
            .xlib => |xlib| (self.dispatch.get_physical_device_xlib_presentation_support_khr orelse return error.VulkanFunctionUnavailable)(
                physical_device,
                queue_family,
                xlib.display,
                xlib.visual_id,
            ),
            .win32 => (self.dispatch.get_physical_device_win32_presentation_support_khr orelse return error.VulkanFunctionUnavailable)(
                physical_device,
                queue_family,
            ),
        };
    }

    /// Returns the first queue family with platform presentation support,
    /// without requiring a window or surface.
    pub fn findPresentQueueFamilyKHR(
        self: *const Self,
        physical_device: api.PhysicalDevice,
        presentation: PresentationSupport,
        queue_family_count: u32,
    ) !?u32 {
        for (0..queue_family_count) |index| {
            if (try self.getPhysicalDevicePresentationSupportKHR(physical_device, @intCast(index), presentation) == api.TRUE) {
                return @intCast(index);
            }
        }
        return null;
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

    pub fn getPhysicalDeviceSurfacePresentModesAllocKHR(self: *const Self, physical_device: api.PhysicalDevice, surface: api.SurfaceKHR, allocator: std.mem.Allocator) ![]api.PresentModeKHR {
        const function = self.dispatch.get_physical_device_surface_present_modes_khr orelse return error.VulkanFunctionUnavailable;
        while (true) {
            var count: u32 = 0;
            try check(function(physical_device, surface, &count, null));
            const modes = try allocator.alloc(api.PresentModeKHR, count);
            if (count == 0) return modes;
            const result = function(physical_device, surface, &count, modes.ptr);
            if (result == .incomplete) {
                allocator.free(modes);
                continue;
            }
            if (result != .success) {
                allocator.free(modes);
                try check(result);
                return error.VulkanError;
            }
            return modes[0..count];
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

/// Native context state needed by Vulkan's platform presentation-support
/// queries. Obtain this from `Context.vulkanPresentationSupport()`.
pub const PresentationSupport = union(enum) {
    wayland: *anyopaque,
    win32: void,
    xlib: struct {
        display: *anyopaque,
        visual_id: c_ulong,
    },
};

/// An owned Vulkan presentation surface created for a low window.
///
/// The Vulkan instance must outlive this value. A `RenderTarget` can borrow
/// the `handle` through `Options.surface`, or take ownership of this value
/// through `Options.presentation_surface`.
pub const PresentationSurface = struct {
    instance: Instance,
    handle: api.SurfaceKHR,

    pub fn init(instance: *const Instance, backend_kind: types.BackendKind, native_display: *anyopaque, native_surface: usize) !@This() {
        return .{
            .instance = instance.*,
            .handle = try createSurface(instance, backend_kind, native_display, native_surface),
        };
    }

    pub fn deinit(self: *@This()) void {
        if (self.handle != 0) self.instance.destroySurfaceKHR(self.handle);
        self.* = undefined;
    }
};

pub const Device = struct {
    const Self = @This();

    pub const Dispatch = struct {
        device_wait_idle: api.PfnDeviceWaitIdle,
        wait_for_fences: api.PfnWaitForFences,
        reset_fences: api.PfnResetFences,
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
        create_buffer: api.PfnCreateBuffer,
        destroy_buffer: api.PfnDestroyBuffer,
        get_buffer_memory_requirements: api.PfnGetBufferMemoryRequirements,
        bind_buffer_memory: api.PfnBindBufferMemory,
        map_memory: api.PfnMapMemory,
        unmap_memory: api.PfnUnmapMemory,
        allocate_memory: api.PfnAllocateMemory,
        free_memory: api.PfnFreeMemory,
        cmd_pipeline_barrier: api.PfnCmdPipelineBarrier,
        cmd_copy_image_to_buffer: api.PfnCmdCopyImageToBuffer,
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
                .reset_fences = try loadDevice(gpa, handle, api.PfnResetFences, "vkResetFences"),
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
                .create_buffer = try loadDevice(gpa, handle, api.PfnCreateBuffer, "vkCreateBuffer"),
                .destroy_buffer = try loadDevice(gpa, handle, api.PfnDestroyBuffer, "vkDestroyBuffer"),
                .get_buffer_memory_requirements = try loadDevice(gpa, handle, api.PfnGetBufferMemoryRequirements, "vkGetBufferMemoryRequirements"),
                .bind_buffer_memory = try loadDevice(gpa, handle, api.PfnBindBufferMemory, "vkBindBufferMemory"),
                .map_memory = try loadDevice(gpa, handle, api.PfnMapMemory, "vkMapMemory"),
                .unmap_memory = try loadDevice(gpa, handle, api.PfnUnmapMemory, "vkUnmapMemory"),
                .allocate_memory = try loadDevice(gpa, handle, api.PfnAllocateMemory, "vkAllocateMemory"),
                .free_memory = try loadDevice(gpa, handle, api.PfnFreeMemory, "vkFreeMemory"),
                .cmd_pipeline_barrier = try loadDevice(gpa, handle, api.PfnCmdPipelineBarrier, "vkCmdPipelineBarrier"),
                .cmd_copy_image_to_buffer = try loadDevice(gpa, handle, api.PfnCmdCopyImageToBuffer, "vkCmdCopyImageToBuffer"),
            },
        };
    }

    pub fn deviceWaitIdle(self: *const Self) !void {
        try check(self.dispatch.device_wait_idle(self.handle));
    }

    pub fn waitForFences(self: *const Self, fences: []const api.Fence, wait_all: bool, timeout: u64) !api.Result {
        return try allowStatus(self.dispatch.wait_for_fences(self.handle, @intCast(fences.len), fences.ptr, if (wait_all) api.TRUE else api.FALSE, timeout));
    }

    pub fn resetFences(self: *const Self, fences: []const api.Fence) !void {
        try check(self.dispatch.reset_fences(self.handle, @intCast(fences.len), fences.ptr));
    }

    /// An acquired image. `result` is either `VK_SUCCESS` or
    /// `VK_SUBOPTIMAL_KHR`.
    pub const AcquireResult = struct {
        result: api.Result,
        image_index: u32,
    };

    /// Acquires the next presentable image. Returns `null` for `VK_NOT_READY`
    /// and `VK_TIMEOUT`, when no image index is available.
    pub fn acquireNextImageKHR(self: *const Self, swapchain: api.SwapchainKHR, timeout: u64, semaphore: api.Semaphore, fence: api.Fence) !?AcquireResult {
        var image_index: u32 = undefined;
        const function = self.dispatch.acquire_next_image_khr orelse return error.VulkanFunctionUnavailable;
        const result = function(self.handle, swapchain, timeout, semaphore, fence, &image_index);
        return switch (result) {
            .success, .suboptimal_khr => .{ .result = result, .image_index = image_index },
            .not_ready, .timeout => null,
            else => {
                try check(result);
                return error.VulkanError;
            },
        };
    }

    pub fn resetCommandBuffer(self: *const Self, command_buffer: api.CommandBuffer) !void {
        try check(self.dispatch.reset_command_buffer(command_buffer, 0));
    }

    /// Begins recording using caller-provided Vulkan begin information.
    /// Secondary command buffers require a valid `p_inheritance_info`.
    pub fn beginCommandBufferWithInfo(self: *const Self, command_buffer: api.CommandBuffer, info: *const api.CommandBufferBeginInfo) !void {
        try check(self.dispatch.begin_command_buffer(command_buffer, info));
    }

    /// Begins a primary command buffer for one-time submission.
    pub fn beginCommandBuffer(self: *const Self, command_buffer: api.CommandBuffer) !void {
        const info = api.CommandBufferBeginInfo{
            .s_type = .command_buffer_begin_info,
            .p_next = null,
            .flags = api.command_buffer_usage.one_time_submit_bit,
            .p_inheritance_info = null,
        };
        try self.beginCommandBufferWithInfo(command_buffer, &info);
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
        if (builtin.mode == .Debug) std.debug.assert(buffers.len == @as(usize, info.command_buffer_count));
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

    pub fn createBuffer(self: *const Self, info: *const api.BufferCreateInfo) !api.Buffer {
        var buffer: api.Buffer = 0;
        try check(self.dispatch.create_buffer(self.handle, info, null, &buffer));
        return buffer;
    }

    pub fn destroyBuffer(self: *const Self, buffer: api.Buffer) void {
        self.dispatch.destroy_buffer(self.handle, buffer, null);
    }
    pub fn getBufferMemoryRequirements(self: *const Self, buffer: api.Buffer) api.MemoryRequirements {
        var requirements: api.MemoryRequirements = undefined;
        self.dispatch.get_buffer_memory_requirements(self.handle, buffer, &requirements);
        return requirements;
    }
    pub fn bindBufferMemory(self: *const Self, buffer: api.Buffer, memory: api.DeviceMemory, offset: u64) !void {
        try check(self.dispatch.bind_buffer_memory(self.handle, buffer, memory, offset));
    }
    pub fn mapMemory(self: *const Self, memory: api.DeviceMemory, offset: u64, size: u64) !*anyopaque {
        var ptr: ?*anyopaque = null;
        try check(self.dispatch.map_memory(self.handle, memory, offset, size, 0, &ptr));
        return ptr.?;
    }
    pub fn unmapMemory(self: *const Self, memory: api.DeviceMemory) void {
        self.dispatch.unmap_memory(self.handle, memory);
    }

    pub fn allocateMemory(self: *const Self, info: *const api.MemoryAllocateInfo) !api.DeviceMemory {
        var memory: api.DeviceMemory = 0;
        try check(self.dispatch.allocate_memory(self.handle, info, null, &memory));
        return memory;
    }

    pub fn freeMemory(self: *const Self, memory: api.DeviceMemory) void {
        self.dispatch.free_memory(self.handle, memory, null);
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

    pub fn cmdBufferPipelineBarrier(
        self: *const Self,
        command_buffer: api.CommandBuffer,
        src_stage: api.PipelineStageFlags,
        dst_stage: api.PipelineStageFlags,
        barrier: *const api.BufferMemoryBarrier,
    ) void {
        self.dispatch.cmd_pipeline_barrier(command_buffer, src_stage, dst_stage, 0, 0, null, 1, @ptrCast(barrier), 0, null);
    }

    pub fn cmdCopyImageToBuffer(self: *const Self, command_buffer: api.CommandBuffer, image: api.Image, layout: api.ImageLayout, buffer: api.Buffer, region: *const api.BufferImageCopy) void {
        self.dispatch.cmd_copy_image_to_buffer(command_buffer, image, layout, buffer, 1, @ptrCast(region));
    }
};

/// Converts a dispatchable handle from a generated Vulkan binding to low's
/// ABI handle representation.
pub inline fn toInstance(value: anytype) api.InstanceHandle {
    return @ptrFromInt(@intFromEnum(value));
}

/// Converts a dispatchable physical-device handle from a generated Vulkan
/// binding to low's ABI handle representation.
pub inline fn toPhysicalDevice(value: anytype) api.PhysicalDevice {
    return @ptrFromInt(@intFromEnum(value));
}

/// Converts a dispatchable device handle from a generated Vulkan binding to
/// low's ABI handle representation.
pub inline fn toDevice(value: anytype) api.DeviceHandle {
    return @ptrFromInt(@intFromEnum(value));
}

/// Converts a dispatchable queue handle from a generated Vulkan binding to
/// low's ABI handle representation.
pub inline fn toQueue(value: anytype) api.Queue {
    return @ptrFromInt(@intFromEnum(value));
}

/// Converts a dispatchable command-buffer handle from a generated Vulkan
/// binding to low's ABI handle representation.
pub inline fn toCommandBuffer(value: anytype) api.CommandBuffer {
    return @ptrFromInt(@intFromEnum(value));
}

/// Converts a low ABI command-buffer handle to a generated Vulkan binding
/// handle. `CommandBuffer` is normally `vk.CommandBuffer`.
pub inline fn fromCommandBuffer(comptime CommandBuffer: type, value: api.CommandBuffer) CommandBuffer {
    return @enumFromInt(@intFromPtr(value));
}

/// Converts a generated Vulkan format enum to low's numeric format ABI.
pub inline fn toFormat(value: anytype) api.Format {
    return @intCast(@intFromEnum(value));
}

/// Converts a generated Vulkan non-dispatchable image-view handle to low's
/// numeric handle ABI.
pub inline fn toImageView(value: anytype) api.ImageView {
    return @intCast(@intFromEnum(value));
}

/// Converts a low ABI image-view handle to a generated Vulkan binding handle.
/// `ImageView` is normally `vk.ImageView`.
pub inline fn fromImageView(comptime ImageView: type, value: api.ImageView) ImageView {
    return @enumFromInt(value);
}

/// Converts a generated Vulkan non-dispatchable surface handle to low's
/// numeric handle ABI.
pub inline fn toSurface(value: anytype) api.SurfaceKHR {
    return @intCast(@intFromEnum(value));
}

pub fn targets() type {
    if (!build_options.vk_extras) @compileError("enable -Dvk_extras=true");
    return @import("vulkan/targets.zig");
}

/// Returns the optional Vulkan Video H.264 recording API.
pub fn video() type {
    if (!build_options.vk_video) @compileError("enable -Dvk_video=true");
    return @import("vulkan/video.zig");
}

/// Creates a presentation surface for an explicit native backend handle.
/// Prefer `Context.requiredVulkanInstanceExtensions` when creating the Vulkan
/// instance; this helper only creates the surface itself.
pub fn createSurface(instance: *const Instance, backend_kind: types.BackendKind, native_display: *anyopaque, native_surface: usize) !api.SurfaceKHR {
    if (builtin.target.os.tag == .windows) {
        switch (backend_kind) {
            .windows => {},
            .offscreen => return error.OffscreenSurfaceUnavailable,
            .wayland, .x11 => return error.UnsupportedPlatform,
        }
        const info = api.Win32SurfaceCreateInfoKHR{
            .s_type = .win32_surface_create_info_khr,
            .p_next = null,
            .flags = 0,
            .hinstance = @ptrCast(native_display),
            .hwnd = @ptrFromInt(native_surface),
        };
        return instance.createWin32SurfaceKHR(&info);
    }

    if (builtin.target.os.tag == .linux) {
        return switch (backend_kind) {
            .wayland => instance.createWaylandSurfaceKHR(&.{
                .s_type = .wayland_surface_create_info_khr,
                .p_next = null,
                .flags = 0,
                .display = @ptrCast(@alignCast(native_display)),
                .surface = @ptrFromInt(native_surface),
            }),
            .x11 => instance.createXlibSurfaceKHR(&.{
                .s_type = .xlib_surface_create_info_khr,
                .p_next = null,
                .flags = 0,
                .dpy = @ptrCast(@alignCast(native_display)),
                .window = @intCast(native_surface),
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

const VulkanTestStubs = struct {
    fn noImage(_: api.DeviceHandle, _: api.SwapchainKHR, _: u64, _: api.Semaphore, _: api.Fence, image_index: *u32) callconv(api.call_conv) api.Result {
        image_index.* = 99;
        return .timeout;
    }

    fn notReady(_: api.DeviceHandle, _: api.SwapchainKHR, _: u64, _: api.Semaphore, _: api.Fence, image_index: *u32) callconv(api.call_conv) api.Result {
        image_index.* = 99;
        return .not_ready;
    }

    fn acquired(_: api.DeviceHandle, _: api.SwapchainKHR, _: u64, _: api.Semaphore, _: api.Fence, image_index: *u32) callconv(api.call_conv) api.Result {
        image_index.* = 7;
        return .suboptimal_khr;
    }

    fn presentSupport(_: api.PhysicalDevice, queue_family: u32, _: api.SurfaceKHR, supported: *api.Bool32) callconv(api.call_conv) api.Result {
        supported.* = if (queue_family == 2) api.TRUE else api.FALSE;
        return .success;
    }

    fn waylandPresentationSupport(_: api.PhysicalDevice, queue_family: u32, display: *anyopaque) callconv(api.call_conv) api.Bool32 {
        std.debug.assert(@intFromPtr(display) == 0x1234);
        return if (queue_family == 2) api.TRUE else api.FALSE;
    }

    fn win32PresentationSupport(_: api.PhysicalDevice, queue_family: u32) callconv(api.call_conv) api.Bool32 {
        return if (queue_family == 2) api.TRUE else api.FALSE;
    }

    fn xlibPresentationSupport(_: api.PhysicalDevice, queue_family: u32, display: *anyopaque, visual_id: c_ulong) callconv(api.call_conv) api.Bool32 {
        std.debug.assert(@intFromPtr(display) == 0x5678);
        std.debug.assert(visual_id == 42);
        return if (queue_family == 2) api.TRUE else api.FALSE;
    }

    fn beginWithInheritance(_: api.CommandBuffer, info: *const api.CommandBufferBeginInfo) callconv(api.call_conv) api.Result {
        std.debug.assert(info.p_inheritance_info != null);
        std.debug.assert(info.p_inheritance_info.?.s_type == .command_buffer_inheritance_info);
        return .success;
    }

    fn createWin32Surface(_: api.InstanceHandle, _: *const api.Win32SurfaceCreateInfoKHR, _: ?*const anyopaque, surface: *api.SurfaceKHR) callconv(api.call_conv) api.Result {
        surface.* = 1;
        return .success;
    }
};

fn testDevice(acquire: api.PfnAcquireNextImageKHR) Device {
    var dispatch: Device.Dispatch = undefined;
    dispatch.acquire_next_image_khr = acquire;
    return .{ .handle = null, .dispatch = dispatch };
}

test "acquireNextImageKHR omits the index when no image is acquired" {
    const device = testDevice(VulkanTestStubs.noImage);
    const acquired = try device.acquireNextImageKHR(0, 0, 0, 0);
    try std.testing.expect(acquired == null);

    const not_ready_device = testDevice(VulkanTestStubs.notReady);
    const not_ready = try not_ready_device.acquireNextImageKHR(0, 0, 0, 0);
    try std.testing.expect(not_ready == null);
}

test "acquireNextImageKHR returns an index only after acquisition" {
    const device = testDevice(VulkanTestStubs.acquired);
    const acquired = (try device.acquireNextImageKHR(0, 0, 0, 0)).?;
    try std.testing.expectEqual(api.Result.suboptimal_khr, acquired.result);
    try std.testing.expectEqual(@as(u32, 7), acquired.image_index);
}

test "findSurfacePresentQueueFamilyKHR returns the first supported family" {
    var dispatch: Instance.Dispatch = undefined;
    dispatch.get_physical_device_surface_support_khr = VulkanTestStubs.presentSupport;
    const instance = Instance{
        .handle = null,
        .get_instance_proc_addr = undefined,
        .dispatch = dispatch,
    };
    try std.testing.expectEqual(@as(?u32, 2), try instance.findSurfacePresentQueueFamilyKHR(null, 1, 4));
    try std.testing.expectEqual(@as(?u32, null), try instance.findSurfacePresentQueueFamilyKHR(null, 1, 2));
}

test "findPresentQueueFamilyKHR uses native platform queries" {
    var wayland_dispatch: Instance.Dispatch = undefined;
    wayland_dispatch.get_physical_device_wayland_presentation_support_khr = VulkanTestStubs.waylandPresentationSupport;
    const wayland_instance = Instance{
        .handle = null,
        .get_instance_proc_addr = undefined,
        .dispatch = wayland_dispatch,
    };
    try std.testing.expectEqual(@as(?u32, 2), try wayland_instance.findPresentQueueFamilyKHR(
        null,
        .{ .wayland = @ptrFromInt(0x1234) },
        4,
    ));

    var win32_dispatch: Instance.Dispatch = undefined;
    win32_dispatch.get_physical_device_win32_presentation_support_khr = VulkanTestStubs.win32PresentationSupport;
    const win32_instance = Instance{
        .handle = null,
        .get_instance_proc_addr = undefined,
        .dispatch = win32_dispatch,
    };
    try std.testing.expectEqual(@as(?u32, 2), try win32_instance.findPresentQueueFamilyKHR(
        null,
        .{ .win32 = {} },
        4,
    ));

    var xlib_dispatch: Instance.Dispatch = undefined;
    xlib_dispatch.get_physical_device_xlib_presentation_support_khr = VulkanTestStubs.xlibPresentationSupport;
    const xlib_instance = Instance{
        .handle = null,
        .get_instance_proc_addr = undefined,
        .dispatch = xlib_dispatch,
    };
    try std.testing.expectEqual(@as(?u32, 2), try xlib_instance.findPresentQueueFamilyKHR(
        null,
        .{ .xlib = .{ .display = @ptrFromInt(0x5678), .visual_id = 42 } },
        4,
    ));
}

test "beginCommandBufferWithInfo accepts secondary inheritance" {
    var dispatch: Device.Dispatch = undefined;
    dispatch.begin_command_buffer = VulkanTestStubs.beginWithInheritance;
    const device = Device{ .handle = null, .dispatch = dispatch };
    const inheritance = api.CommandBufferInheritanceInfo{
        .s_type = .command_buffer_inheritance_info,
        .p_next = null,
        .render_pass = 0,
        .subpass = 0,
        .framebuffer = 0,
        .occlusion_query_enable = api.FALSE,
        .query_flags = 0,
        .pipeline_statistics = 0,
    };
    try device.beginCommandBufferWithInfo(null, &.{
        .s_type = .command_buffer_begin_info,
        .p_next = null,
        .flags = api.command_buffer_usage.render_pass_continue_bit,
        .p_inheritance_info = &inheritance,
    });
}

test "createSurface rejects an offscreen backend" {
    if (builtin.target.os.tag != .linux and builtin.target.os.tag != .windows) return;

    var dispatch: Instance.Dispatch = undefined;
    dispatch.create_win32_surface_khr = VulkanTestStubs.createWin32Surface;
    const instance = Instance{
        .handle = null,
        .get_instance_proc_addr = undefined,
        .dispatch = dispatch,
    };
    try std.testing.expectError(
        error.OffscreenSurfaceUnavailable,
        createSurface(&instance, .offscreen, @ptrFromInt(1), 0),
    );
}
