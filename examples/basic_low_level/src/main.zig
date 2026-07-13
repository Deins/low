const std = @import("std");
const low = @import("low");
const vk = @import("vulkan");

const DeviceSelection = struct {
    physical_device: vk.PhysicalDevice,
    queue_family: u32,
};

const RawTarget = struct {
    allocator: std.mem.Allocator,
    device: vk.DeviceProxy,
    graphics_queue: vk.Queue,
    swapchain: vk.SwapchainKHR,
    extent: vk.Extent2D,
    images: []vk.Image,
    views: []vk.ImageView,
    command_pool: vk.CommandPool = .null_handle,
    command_buffer: vk.CommandBuffer = .null_handle,
    image_available: vk.Semaphore = .null_handle,
    /// Presentation may continue after the graphics submission's fence signals.
    /// Keep a semaphore per swapchain image and only reuse it after that image
    /// has been acquired again.
    render_finished: []vk.Semaphore,
    in_flight: vk.Fence = .null_handle,

    fn init(
        allocator: std.mem.Allocator,
        instance: vk.InstanceProxy,
        physical_device: vk.PhysicalDevice,
        device: vk.DeviceProxy,
        graphics_queue: vk.Queue,
        queue_family: u32,
        surface: vk.SurfaceKHR,
        window: *low.Window,
    ) !RawTarget {
        var result: RawTarget = .{
            .allocator = allocator,
            .device = device,
            .graphics_queue = graphics_queue,
            .swapchain = .null_handle,
            .extent = .{ .width = 0, .height = 0 },
            .images = &.{},
            .views = &.{},
            .render_finished = &.{},
        };
        errdefer result.deinit();

        const capabilities = try instance.getPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface);
        const formats = try instance.getPhysicalDeviceSurfaceFormatsAllocKHR(physical_device, surface, allocator);
        defer allocator.free(formats);
        const format = chooseFormat(formats);
        const extent = chooseExtent(capabilities, window.getFramebufferSize());
        if (extent.width == 0 or extent.height == 0) return error.ZeroFramebuffer;
        if (!capabilities.supported_usage_flags.transfer_dst_bit) return error.TransferDestinationUnsupported;

        var image_count = capabilities.min_image_count + 1;
        if (capabilities.max_image_count != 0) image_count = @min(image_count, capabilities.max_image_count);
        result.swapchain = try device.createSwapchainKHR(&.{
            .surface = surface,
            .min_image_count = image_count,
            .image_format = format.format,
            .image_color_space = format.color_space,
            .image_extent = extent,
            .image_array_layers = 1,
            .image_usage = .{ .color_attachment_bit = true, .transfer_dst_bit = true },
            .image_sharing_mode = .exclusive,
            .pre_transform = capabilities.current_transform,
            .composite_alpha = chooseCompositeAlpha(capabilities.supported_composite_alpha),
            .present_mode = .fifo_khr,
            .clipped = .true,
        }, null);
        result.extent = extent;
        result.images = try device.getSwapchainImagesAllocKHR(result.swapchain, allocator);
        result.views = try allocator.alloc(vk.ImageView, result.images.len);
        result.render_finished = try allocator.alloc(vk.Semaphore, result.images.len);
        @memset(result.views, .null_handle);
        @memset(result.render_finished, .null_handle);
        for (result.images, result.views) |image, *view| {
            view.* = try device.createImageView(&.{
                .image = image,
                .view_type = .@"2d",
                .format = format.format,
                .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
            }, null);
        }
        result.command_pool = try device.createCommandPool(&.{
            .flags = .{ .reset_command_buffer_bit = true },
            .queue_family_index = queue_family,
        }, null);
        var command_buffers: [1]vk.CommandBuffer = undefined;
        try device.allocateCommandBuffers(&.{
            .command_pool = result.command_pool,
            .level = .primary,
            .command_buffer_count = command_buffers.len,
        }, &command_buffers);
        result.command_buffer = command_buffers[0];
        result.image_available = try device.createSemaphore(&.{}, null);
        for (result.render_finished) |*semaphore| semaphore.* = try device.createSemaphore(&.{}, null);
        result.in_flight = try device.createFence(&.{ .flags = .{ .signaled_bit = true } }, null);
        return result;
    }

    fn deinit(self: *RawTarget) void {
        self.device.deviceWaitIdle() catch {};
        if (self.in_flight != .null_handle) self.device.destroyFence(self.in_flight, null);
        for (self.render_finished) |semaphore| if (semaphore != .null_handle) self.device.destroySemaphore(semaphore, null);
        if (self.image_available != .null_handle) self.device.destroySemaphore(self.image_available, null);
        if (self.command_buffer != .null_handle) self.device.freeCommandBuffers(self.command_pool, &.{self.command_buffer});
        if (self.command_pool != .null_handle) self.device.destroyCommandPool(self.command_pool, null);
        for (self.views) |view| if (view != .null_handle) self.device.destroyImageView(view, null);
        if (self.views.len != 0) self.allocator.free(self.views);
        if (self.render_finished.len != 0) self.allocator.free(self.render_finished);
        if (self.images.len != 0) self.allocator.free(self.images);
        if (self.swapchain != .null_handle) self.device.destroySwapchainKHR(self.swapchain, null);
        self.* = undefined;
    }

    fn recreate(
        self: *RawTarget,
        instance: vk.InstanceProxy,
        physical_device: vk.PhysicalDevice,
        queue_family: u32,
        surface: vk.SurfaceKHR,
        window: *low.Window,
    ) !void {
        // Some surface implementations require the old swapchain to be
        // destroyed before another one can be created for the same window.
        // Leave an empty, safely deinitializable target in place if creation
        // of the replacement fails.
        const allocator = self.allocator;
        const device = self.device;
        const graphics_queue = self.graphics_queue;
        self.deinit();
        self.* = .{
            .allocator = allocator,
            .device = device,
            .graphics_queue = graphics_queue,
            .swapchain = .null_handle,
            .extent = .{ .width = 0, .height = 0 },
            .images = &.{},
            .views = &.{},
            .render_finished = &.{},
        };
        self.* = try RawTarget.init(
            allocator,
            instance,
            physical_device,
            device,
            graphics_queue,
            queue_family,
            surface,
            window,
        );
    }

    fn draw(self: *RawTarget, window: *low.Window) !void {
        _ = try self.device.waitForFences(&.{self.in_flight}, .true, std.math.maxInt(u64));
        const acquired = try self.device.acquireNextImageKHR(
            self.swapchain,
            std.math.maxInt(u64),
            self.image_available,
            .null_handle,
        );
        // Neither status acquires an image, so image_index is invalid here.
        if (acquired.result == .timeout or acquired.result == .not_ready) return;

        try self.device.resetCommandBuffer(self.command_buffer, .{});
        try self.device.beginCommandBuffer(self.command_buffer, &.{ .flags = .{ .one_time_submit_bit = true } });
        const image = self.images[acquired.image_index];
        const range = vk.ImageSubresourceRange{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        };
        const to_transfer = vk.ImageMemoryBarrier{
            .src_access_mask = .{},
            .dst_access_mask = .{ .transfer_write_bit = true },
            .old_layout = .undefined,
            .new_layout = .transfer_dst_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresource_range = range,
        };
        self.device.cmdPipelineBarrier(self.command_buffer, .{ .top_of_pipe_bit = true }, .{ .transfer_bit = true }, .{}, null, null, &.{to_transfer});
        const clear = vk.ClearColorValue{ .float_32 = .{ 0.08, 0.12, 0.28, 1.0 } };
        self.device.cmdClearColorImage(self.command_buffer, image, .transfer_dst_optimal, &clear, &.{range});
        const to_present = vk.ImageMemoryBarrier{
            .src_access_mask = .{ .transfer_write_bit = true },
            .dst_access_mask = .{},
            .old_layout = .transfer_dst_optimal,
            .new_layout = .present_src_khr,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresource_range = range,
        };
        self.device.cmdPipelineBarrier(self.command_buffer, .{ .transfer_bit = true }, .{ .bottom_of_pipe_bit = true }, .{}, null, null, &.{to_present});
        try self.device.endCommandBuffer(self.command_buffer);

        const wait_semaphores = [_]vk.Semaphore{self.image_available};
        const wait_stages = [_]vk.PipelineStageFlags{.{ .transfer_bit = true }};
        const command_buffers = [_]vk.CommandBuffer{self.command_buffer};
        const signal_semaphores = [_]vk.Semaphore{self.render_finished[acquired.image_index]};
        // A waited fence remains signaled. Reset it immediately before giving
        // it to the next submission.
        try self.device.resetFences(&.{self.in_flight});
        try self.device.queueSubmit(self.graphics_queue, &.{.{
            .wait_semaphore_count = wait_semaphores.len,
            .p_wait_semaphores = &wait_semaphores,
            .p_wait_dst_stage_mask = &wait_stages,
            .command_buffer_count = command_buffers.len,
            .p_command_buffers = &command_buffers,
            .signal_semaphore_count = signal_semaphores.len,
            .p_signal_semaphores = &signal_semaphores,
        }}, self.in_flight);
        const swapchains = [_]vk.SwapchainKHR{self.swapchain};
        const indices = [_]u32{acquired.image_index};
        // This must precede the Wayland surface commit performed by WSI
        // presentation, otherwise the callback applies to a later frame.
        window.requestFrame();
        const present = self.device.queuePresentKHR(self.graphics_queue, &.{
            .wait_semaphore_count = signal_semaphores.len,
            .p_wait_semaphores = &signal_semaphores,
            .swapchain_count = swapchains.len,
            .p_swapchains = &swapchains,
            .p_image_indices = &indices,
        }) catch |err| {
            window.cancelFrameRequest();
            return err;
        };
        if (acquired.result == .suboptimal_khr or present == .suboptimal_khr) return error.SwapchainSuboptimal;
    }
};

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa_state.deinit() == .ok);
    const allocator = gpa_state.allocator();

    var loader = try low.vulkan.Loader.init();
    defer loader.deinit();
    const get_instance_proc_addr: vk.PfnGetInstanceProcAddr = @ptrCast(loader.get_instance_proc_addr);
    const base = vk.BaseWrapper.load(get_instance_proc_addr);
    var context = try low.Context.init(allocator, .{ .app_name = "low.basic_low_level" });
    defer context.deinit();
    const extensions = context.requiredVulkanInstanceExtensions();
    const app_info = vk.ApplicationInfo{
        .p_application_name = "basic low level",
        .application_version = 1,
        .p_engine_name = "low",
        .engine_version = 1,
        .api_version = @bitCast(vk.API_VERSION_1_0),
    };
    const instance_handle = try base.createInstance(&.{
        .p_application_info = &app_info,
        .enabled_extension_count = @intCast(extensions.len),
        .pp_enabled_extension_names = extensions.ptr,
    }, null);
    var instance_wrapper = vk.InstanceWrapper.load(instance_handle, get_instance_proc_addr);
    const instance = vk.InstanceProxy.init(instance_handle, &instance_wrapper);
    defer instance.destroyInstance(null);
    const low_instance = try loader.loadInstanceApi(low.vulkan.toInstance(instance_handle));

    const window = try context.createWindow(.{ .title = "low raw Vulkan setup", .size = .{ .width = 800, .height = 600 } });
    window.setCallbacks(.{
        .mouse_button = onMouseButton,
        .scroll = onScroll,
        .key = onKey,
        .text = onText,
    });
    const low_surface = try context.createVulkanSurface(&low_instance, window);
    const surface: vk.SurfaceKHR = @enumFromInt(low_surface);
    defer instance.destroySurfaceKHR(surface, null);
    const selection = try selectDevice(allocator, instance, surface);
    const priority = [_]f32{1.0};
    const device_extensions = [_][*:0]const u8{"VK_KHR_swapchain"};
    const device_handle = try instance.createDevice(selection.physical_device, &.{
        .queue_create_info_count = 1,
        .p_queue_create_infos = @ptrCast(&vk.DeviceQueueCreateInfo{
            .queue_family_index = selection.queue_family,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        }),
        .enabled_extension_count = device_extensions.len,
        .pp_enabled_extension_names = &device_extensions,
    }, null);
    var device_wrapper = vk.DeviceWrapper.load(device_handle, instance.wrapper.dispatch.vkGetDeviceProcAddr.?);
    const device = vk.DeviceProxy.init(device_handle, &device_wrapper);
    defer device.destroyDevice(null);
    if (device_wrapper.dispatch.vkCreateSwapchainKHR == null) return error.SwapchainCommandsUnavailable;

    const graphics_queue = device.getDeviceQueue(selection.queue_family, 0);
    var target = try RawTarget.init(allocator, instance, selection.physical_device, device, graphics_queue, selection.queue_family, surface, window);
    defer target.deinit();
    std.log.info("created raw Vulkan surface, swapchain, {d} image views", .{target.views.len});

    while (!window.shouldClose()) {
        context.pollEvents();
        if (!window.shouldRender()) { // checks if window is minimized etc. optional
            const wait_started = std.Io.Timestamp.now(init.io, .awake);
            try context.waitForRender(window);
            { // for debug
                const elapsed_ns = std.Io.Timestamp.now(init.io, .awake).nanoseconds - wait_started.nanoseconds;
                if (elapsed_ns > std.time.ns_per_s / 10) {
                    std.log.debug("waited {d} ms for render permit", .{@divTrunc(elapsed_ns, std.time.ns_per_ms)});
                }
            }
            continue;
        }
        const framebuffer_size = window.getFramebufferSize();
        if (framebuffer_size.width == 0 or framebuffer_size.height == 0) continue;
        if (target.extent.width != framebuffer_size.width or target.extent.height != framebuffer_size.height) {
            try target.recreate(instance, selection.physical_device, selection.queue_family, surface, window);
            continue;
        }
        target.draw(window) catch |err| switch (err) {
            error.OutOfDateKHR, error.SwapchainSuboptimal => try target.recreate(instance, selection.physical_device, selection.queue_family, surface, window),
            error.SurfaceLostKHR => break,
            else => return err,
        };
    }
}

fn onMouseButton(_: *low.Window, button: low.MouseButton, action: low.Action, _: low.Modifiers) void {
    std.log.info("mouse {s}: {s}", .{ @tagName(button), @tagName(action) });
}

fn onScroll(_: *low.Window, x: f64, y: f64) void {
    std.log.info("scroll: x={d:.2}, y={d:.2}", .{ x, y });
}

fn onKey(_: *low.Window, key: low.Key, raw_keycode: u32, action: low.Action, _: low.Modifiers) void {
    std.log.info("key {s} (code {d}): {s}", .{ @tagName(key), raw_keycode, @tagName(action) });
}

fn onText(_: *low.Window, text: []const u8) void {
    std.log.info("text input: {s}", .{text});
}

fn selectDevice(allocator: std.mem.Allocator, instance: vk.InstanceProxy, surface: vk.SurfaceKHR) !DeviceSelection {
    const physical_devices = try instance.enumeratePhysicalDevicesAlloc(allocator);
    defer allocator.free(physical_devices);
    for (physical_devices) |physical_device| {
        const families = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(physical_device, allocator);
        defer allocator.free(families);
        for (families, 0..) |family, index| {
            if (!family.queue_flags.graphics_bit) continue;
            if (try instance.getPhysicalDeviceSurfaceSupportKHR(physical_device, @intCast(index), surface) != .true) continue;
            return .{ .physical_device = physical_device, .queue_family = @intCast(index) };
        }
    }
    return error.NoPresentDevice;
}

fn chooseFormat(formats: []const vk.SurfaceFormatKHR) vk.SurfaceFormatKHR {
    for (formats) |format| if (format.format == .b8g8r8a8_unorm and format.color_space == .srgb_nonlinear_khr) return format;
    return formats[0];
}

fn chooseExtent(capabilities: vk.SurfaceCapabilitiesKHR, size: low.Size) vk.Extent2D {
    if (capabilities.current_extent.width != std.math.maxInt(u32)) return capabilities.current_extent;
    return .{
        .width = std.math.clamp(@as(u32, @intCast(@max(size.width, 1))), capabilities.min_image_extent.width, capabilities.max_image_extent.width),
        .height = std.math.clamp(@as(u32, @intCast(@max(size.height, 1))), capabilities.min_image_extent.height, capabilities.max_image_extent.height),
    };
}

fn chooseCompositeAlpha(supported: vk.CompositeAlphaFlagsKHR) vk.CompositeAlphaFlagsKHR {
    if (supported.opaque_bit_khr) return .{ .opaque_bit_khr = true };
    if (supported.pre_multiplied_bit_khr) return .{ .pre_multiplied_bit_khr = true };
    if (supported.post_multiplied_bit_khr) return .{ .post_multiplied_bit_khr = true };
    return .{ .inherit_bit_khr = true };
}
