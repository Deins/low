const std = @import("std");
const low = @import("low");
const vk = @import("vulkan");

const VulkanLoader = low.vulkan.Loader(vk);
const vertex_spv align(@alignOf(u32)) = @embedFile("triangle_vert").*;
const fragment_spv align(@alignOf(u32)) = @embedFile("triangle_frag").*;

const PushConstants = extern struct {
    offset: [2]f32,
    // A vec3 has 16-byte alignment in the GLSL push-constant block.
    _padding: [2]f32 = .{ 0, 0 },
    color: [3]f32,
};

const DeviceSelection = struct {
    physical_device: vk.PhysicalDevice,
    graphics_queue_family: u32,
};

const Renderer = struct {
    gpa: std.mem.Allocator,
    instance: vk.InstanceProxy,
    physical_device: vk.PhysicalDevice,
    device_wrapper: *vk.DeviceWrapper,
    device: vk.DeviceProxy,
    graphics_queue: vk.Queue,
    graphics_queue_family: u32,
    command_pool: vk.CommandPool,
    pipeline_layout: vk.PipelineLayout,
    pipeline: vk.Pipeline,
    color_format: vk.Format,

    fn init(
        gpa: std.mem.Allocator,
        instance: vk.InstanceProxy,
        surfaces: []const vk.SurfaceKHR,
    ) !Renderer {
        const selection = try findDevice(gpa, instance, surfaces);

        var features_13 = vk.PhysicalDeviceVulkan13Features{
            .synchronization_2 = .true,
            .dynamic_rendering = .true,
        };
        const queue_priority = [_]f32{1.0};
        const queue_info = vk.DeviceQueueCreateInfo{
            .queue_family_index = selection.graphics_queue_family,
            .queue_count = 1,
            .p_queue_priorities = &queue_priority,
        };
        const device_extensions = [_][*:0]const u8{"VK_KHR_swapchain"};
        const device_info = vk.DeviceCreateInfo{
            .p_next = @ptrCast(&features_13),
            .queue_create_info_count = 1,
            .p_queue_create_infos = @ptrCast(&queue_info),
            .enabled_extension_count = device_extensions.len,
            .pp_enabled_extension_names = &device_extensions,
        };
        const device_handle = try instance.createDevice(selection.physical_device, &device_info, null);
        const device_wrapper = try gpa.create(vk.DeviceWrapper);
        errdefer gpa.destroy(device_wrapper);
        device_wrapper.* = vk.DeviceWrapper.load(
            device_handle,
            instance.wrapper.dispatch.vkGetDeviceProcAddr.?,
        );
        if (device_wrapper.dispatch.vkCreateSwapchainKHR == null) return error.SwapchainCommandsUnavailable;
        const device = vk.DeviceProxy.init(device_handle, device_wrapper);
        errdefer device.destroyDevice(null);

        const command_pool = try device.createCommandPool(&.{
            .flags = .{ .reset_command_buffer_bit = true },
            .queue_family_index = selection.graphics_queue_family,
        }, null);
        errdefer device.destroyCommandPool(command_pool, null);

        const formats = try instance.getPhysicalDeviceSurfaceFormatsAllocKHR(
            selection.physical_device,
            surfaces[0],
            gpa,
        );
        defer gpa.free(formats);
        const color_format = chooseSurfaceFormat(formats).format;

        const pipeline_layout = try createPipelineLayout(device);
        errdefer device.destroyPipelineLayout(pipeline_layout, null);
        const pipeline = try createPipeline(device, pipeline_layout, color_format);
        errdefer device.destroyPipeline(pipeline, null);

        return .{
            .gpa = gpa,
            .instance = instance,
            .physical_device = selection.physical_device,
            .device_wrapper = device_wrapper,
            .device = device,
            .graphics_queue = device.getDeviceQueue(selection.graphics_queue_family, 0),
            .graphics_queue_family = selection.graphics_queue_family,
            .command_pool = command_pool,
            .pipeline_layout = pipeline_layout,
            .pipeline = pipeline,
            .color_format = color_format,
        };
    }

    fn deinit(self: *Renderer) void {
        self.device.destroyPipeline(self.pipeline, null);
        self.device.destroyPipelineLayout(self.pipeline_layout, null);
        self.device.destroyCommandPool(self.command_pool, null);
        self.device.destroyDevice(null);
        self.gpa.destroy(self.device_wrapper);
        self.* = undefined;
    }
};

const AppWindow = struct {
    window: *low.Window,
    surface: vk.SurfaceKHR,
    swapchain: vk.SwapchainKHR = .null_handle,
    images: []vk.Image = &.{},
    image_views: []vk.ImageView = &.{},
    extent: vk.Extent2D = .{ .width = 0, .height = 0 },
    command_buffer: vk.CommandBuffer = .null_handle,
    image_available: vk.Semaphore = .null_handle,
    render_finished: vk.Semaphore = .null_handle,
    in_flight: vk.Fence = .null_handle,
    needs_recreate: bool = false,
    position: [2]f32,
    velocity: [2]f32,
    color: [3]f32,

    fn init(
        gpa: std.mem.Allocator,
        renderer: *const Renderer,
        window: *low.Window,
        surface: vk.SurfaceKHR,
        position: [2]f32,
        velocity: [2]f32,
        color: [3]f32,
    ) !AppWindow {
        var result: AppWindow = .{
            .window = window,
            .surface = surface,
            .position = position,
            .velocity = velocity,
            .color = color,
        };
        errdefer result.deinit(gpa, renderer);

        try result.createSwapchain(gpa, renderer);
        var command_buffers: [1]vk.CommandBuffer = undefined;
        try renderer.device.allocateCommandBuffers(&.{
            .command_pool = renderer.command_pool,
            .level = .primary,
            .command_buffer_count = command_buffers.len,
        }, &command_buffers);
        result.command_buffer = command_buffers[0];
        result.image_available = try renderer.device.createSemaphore(&.{}, null);
        result.render_finished = try renderer.device.createSemaphore(&.{}, null);
        result.in_flight = try renderer.device.createFence(&.{
            .flags = .{ .signaled_bit = true },
        }, null);

        return result;
    }

    fn installCallbacks(self: *AppWindow) void {
        self.window.setUserData(self);
        self.window.setCallbacks(.{
            .framebuffer_resize = onFramebufferResize,
            .mouse_button = onMouseButton,
        });
    }

    fn deinit(self: *AppWindow, gpa: std.mem.Allocator, renderer: *const Renderer) void {
        if (self.in_flight != .null_handle) renderer.device.destroyFence(self.in_flight, null);
        if (self.render_finished != .null_handle) renderer.device.destroySemaphore(self.render_finished, null);
        if (self.image_available != .null_handle) renderer.device.destroySemaphore(self.image_available, null);
        self.destroySwapchain(gpa, renderer);
        if (self.surface != .null_handle) renderer.instance.destroySurfaceKHR(self.surface, null);
        self.window.deinit();
        self.* = undefined;
    }

    fn update(self: *AppWindow, dt: f32) void {
        for (0..2) |axis| {
            self.position[axis] += self.velocity[axis] * dt;
            if (self.position[axis] > 0.74) {
                self.position[axis] = 0.74;
                self.velocity[axis] = -@abs(self.velocity[axis]);
            } else if (self.position[axis] < -0.74) {
                self.position[axis] = -0.74;
                self.velocity[axis] = @abs(self.velocity[axis]);
            }
        }
    }

    fn draw(self: *AppWindow, gpa: std.mem.Allocator, renderer: *const Renderer) !void {
        if (self.needs_recreate) {
            try self.recreateSwapchain(gpa, renderer);
            return;
        }
        if (self.extent.width == 0 or self.extent.height == 0) return;

        _ = try renderer.device.waitForFences(&.{self.in_flight}, .true, std.math.maxInt(u64));
        const acquired = renderer.device.acquireNextImageKHR(
            self.swapchain,
            std.math.maxInt(u64),
            self.image_available,
            .null_handle,
        ) catch |err| switch (err) {
            error.OutOfDateKHR => {
                self.needs_recreate = true;
                return;
            },
            else => return err,
        };
        const recreate_after_present = acquired.result == .suboptimal_khr;

        try renderer.device.resetFences(&.{self.in_flight});
        try renderer.device.resetCommandBuffer(self.command_buffer, .{});
        try renderer.device.beginCommandBuffer(self.command_buffer, &.{
            .flags = .{ .one_time_submit_bit = true },
        });

        const image = self.image_views[acquired.image_index];
        transitionImage(
            renderer.device,
            self.command_buffer,
            self.swapchainImage(acquired.image_index),
            .undefined,
            .color_attachment_optimal,
            .{},
            .{},
            .{ .color_attachment_output_bit = true },
            .{ .color_attachment_write_bit = true },
        );

        const color_attachment = vk.RenderingAttachmentInfo{
            .image_view = image,
            .image_layout = .color_attachment_optimal,
            .resolve_mode = .{},
            .resolve_image_layout = .undefined,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .color = .{ .float_32 = .{ 0.018, 0.025, 0.06, 1.0 } } },
        };
        renderer.device.cmdBeginRendering(self.command_buffer, &.{
            .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = self.extent },
            .layer_count = 1,
            .view_mask = 0,
            .color_attachment_count = 1,
            .p_color_attachments = @ptrCast(&color_attachment),
        });
        const viewport = vk.Viewport{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(self.extent.width),
            .height = @floatFromInt(self.extent.height),
            .min_depth = 0,
            .max_depth = 1,
        };
        const scissor = vk.Rect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = self.extent };
        renderer.device.cmdSetViewport(self.command_buffer, 0, &.{viewport});
        renderer.device.cmdSetScissor(self.command_buffer, 0, &.{scissor});
        renderer.device.cmdBindPipeline(self.command_buffer, .graphics, renderer.pipeline);
        const push = PushConstants{ .offset = self.position, .color = self.color };
        renderer.device.cmdPushConstants(
            self.command_buffer,
            renderer.pipeline_layout,
            .{ .vertex_bit = true },
            0,
            @sizeOf(PushConstants),
            @ptrCast(&push),
        );
        renderer.device.cmdDraw(self.command_buffer, 3, 1, 0, 0);
        renderer.device.cmdEndRendering(self.command_buffer);

        transitionImage(
            renderer.device,
            self.command_buffer,
            self.swapchainImage(acquired.image_index),
            .color_attachment_optimal,
            .present_src_khr,
            .{ .color_attachment_output_bit = true },
            .{ .color_attachment_write_bit = true },
            .{},
            .{},
        );
        try renderer.device.endCommandBuffer(self.command_buffer);

        const wait_info = [_]vk.SemaphoreSubmitInfo{.{
            .semaphore = self.image_available,
            .value = 0,
            .stage_mask = .{ .color_attachment_output_bit = true },
            .device_index = 0,
        }};
        const command_info = [_]vk.CommandBufferSubmitInfo{.{
            .command_buffer = self.command_buffer,
            .device_mask = 0,
        }};
        const signal_info = [_]vk.SemaphoreSubmitInfo{.{
            .semaphore = self.render_finished,
            .value = 0,
            .stage_mask = .{ .all_graphics_bit = true },
            .device_index = 0,
        }};
        try renderer.device.queueSubmit2(renderer.graphics_queue, &.{.{
            .wait_semaphore_info_count = wait_info.len,
            .p_wait_semaphore_infos = &wait_info,
            .command_buffer_info_count = command_info.len,
            .p_command_buffer_infos = &command_info,
            .signal_semaphore_info_count = signal_info.len,
            .p_signal_semaphore_infos = &signal_info,
        }}, self.in_flight);

        const swapchains = [_]vk.SwapchainKHR{self.swapchain};
        const indices = [_]u32{acquired.image_index};
        const present = renderer.device.queuePresentKHR(renderer.graphics_queue, &.{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = &.{self.render_finished},
            .swapchain_count = 1,
            .p_swapchains = &swapchains,
            .p_image_indices = &indices,
        }) catch |err| switch (err) {
            error.OutOfDateKHR => {
                self.needs_recreate = true;
                return;
            },
            else => return err,
        };
        self.needs_recreate = recreate_after_present or present == .suboptimal_khr;
    }

    fn swapchainImage(self: *const AppWindow, index: u32) vk.Image {
        return self.images[index];
    }

    fn createSwapchain(self: *AppWindow, gpa: std.mem.Allocator, renderer: *const Renderer) !void {
        const capabilities = try renderer.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(
            renderer.physical_device,
            self.surface,
        );
        const formats = try renderer.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(
            renderer.physical_device,
            self.surface,
            gpa,
        );
        defer gpa.free(formats);
        const format = findFormat(formats, renderer.color_format) orelse return error.IncompatibleSurfaceFormats;

        self.extent = chooseExtent(capabilities, self.window.getFramebufferSize());
        if (self.extent.width == 0 or self.extent.height == 0) {
            self.needs_recreate = true;
            return;
        }
        var image_count = capabilities.min_image_count + 1;
        if (capabilities.max_image_count != 0) image_count = @min(image_count, capabilities.max_image_count);

        self.swapchain = try renderer.device.createSwapchainKHR(&.{
            .surface = self.surface,
            .min_image_count = image_count,
            .image_format = format.format,
            .image_color_space = format.color_space,
            .image_extent = self.extent,
            .image_array_layers = 1,
            .image_usage = .{ .color_attachment_bit = true },
            .image_sharing_mode = .exclusive,
            .pre_transform = capabilities.current_transform,
            .composite_alpha = chooseCompositeAlpha(capabilities.supported_composite_alpha),
            .present_mode = .fifo_khr,
            .clipped = .true,
        }, null);
        errdefer self.destroySwapchain(gpa, renderer);

        self.images = try renderer.device.getSwapchainImagesAllocKHR(self.swapchain, gpa);
        self.image_views = try gpa.alloc(vk.ImageView, self.images.len);
        @memset(self.image_views, .null_handle);
        for (self.images, self.image_views) |image, *view| {
            view.* = try renderer.device.createImageView(&.{
                .image = image,
                .view_type = .@"2d",
                .format = renderer.color_format,
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
    }

    fn destroySwapchain(self: *AppWindow, gpa: std.mem.Allocator, renderer: *const Renderer) void {
        for (self.image_views) |view| {
            if (view != .null_handle) renderer.device.destroyImageView(view, null);
        }
        if (self.image_views.len != 0) gpa.free(self.image_views);
        if (self.images.len != 0) gpa.free(self.images);
        if (self.swapchain != .null_handle) renderer.device.destroySwapchainKHR(self.swapchain, null);
        self.swapchain = .null_handle;
        self.image_views = &.{};
        self.images = &.{};
    }

    fn recreateSwapchain(self: *AppWindow, gpa: std.mem.Allocator, renderer: *const Renderer) !void {
        const size = self.window.getFramebufferSize();
        if (size.width <= 0 or size.height <= 0) return;
        try renderer.device.deviceWaitIdle();
        self.destroySwapchain(gpa, renderer);
        try self.createSwapchain(gpa, renderer);
        self.needs_recreate = false;
    }
};

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa_state.deinit() == .ok);
    const gpa = gpa_state.allocator();

    try VulkanLoader.init();
    defer VulkanLoader.deinit();
    const get_instance_proc_addr = try VulkanLoader.getInstanceProcAddr();
    const base = vk.BaseWrapper.load(get_instance_proc_addr);

    const backend = try requestedBackend(try init.minimal.args.toSlice(init.arena.allocator()));
    var context = try low.Context.init(gpa, .{
        .app_name = "low.multiwindow_triangles",
        .backend = backend,
    });
    defer context.deinit();
    std.log.info("using {s} backend", .{@tagName(context.backendKind())});
    const extensions = low.vulkan.requiredInstanceExtensions(&context);

    const app_info = vk.ApplicationInfo{
        .p_application_name = "low multiwindow triangles",
        .application_version = 1,
        .p_engine_name = "low",
        .engine_version = 1,
        .api_version = @bitCast(vk.API_VERSION_1_3),
    };
    const instance_info = vk.InstanceCreateInfo{
        .p_application_info = &app_info,
        .enabled_extension_count = @intCast(extensions.len),
        .pp_enabled_extension_names = extensions.ptr,
    };
    const instance_handle = try base.createInstance(&instance_info, null);
    const instance_wrapper = vk.InstanceWrapper.load(instance_handle, get_instance_proc_addr);
    const instance = vk.InstanceProxy.init(instance_handle, &instance_wrapper);
    defer instance.destroyInstance(null);

    const first_window = try context.createWindow(.{
        .title = "low Vulkan — coral triangle",
        .size = .{ .width = 640, .height = 480 },
    });
    const first_surface = try low.vulkan.createSurface(vk, &context, first_window, instance);
    const second_window = try context.createWindow(.{
        .title = "low Vulkan — cyan triangle",
        .size = .{ .width = 520, .height = 400 },
    });
    const second_surface = try low.vulkan.createSurface(vk, &context, second_window, instance);

    var renderer = try Renderer.init(gpa, instance, &.{ first_surface, second_surface });
    defer renderer.deinit();
    var first: ?AppWindow = try AppWindow.init(
        gpa,
        &renderer,
        first_window,
        first_surface,
        .{ -0.3, 0.1 },
        .{ 0.73, 0.52 },
        .{ 1.0, 0.30, 0.20 },
    );
    defer if (first) |*app_window| app_window.deinit(gpa, &renderer);
    var second: ?AppWindow = try AppWindow.init(
        gpa,
        &renderer,
        second_window,
        second_surface,
        .{ 0.25, -0.2 },
        .{ -0.61, 0.67 },
        .{ 0.18, 0.90, 0.95 },
    );
    defer if (second) |*app_window| app_window.deinit(gpa, &renderer);
    first.?.installCallbacks();
    second.?.installCallbacks();

    var previous = std.Io.Timestamp.now(std.Options.debug_io, .awake);
    while (first != null or second != null) {
        context.pollEvents();

        const close_first = if (first) |app_window| app_window.window.shouldClose() else false;
        const close_second = if (second) |app_window| app_window.window.shouldClose() else false;
        if (close_first or close_second) {
            // A close event is delivered while polling. Destroy the matching
            // native window only after that dispatch has completed, and wait
            // until its in-flight Vulkan work can no longer reference it.
            try renderer.device.deviceWaitIdle();
            if (close_first) {
                if (first) |*app_window| app_window.deinit(gpa, &renderer);
                first = null;
            }
            if (close_second) {
                if (second) |*app_window| app_window.deinit(gpa, &renderer);
                second = null;
            }
            if (first == null and second == null) break;
        }

        const now = std.Io.Timestamp.now(std.Options.debug_io, .awake);
        const dt: f32 = @min(0.05, @as(f32, @floatFromInt(now.nanoseconds - previous.nanoseconds)) / 1_000_000_000);
        previous = now;
        if (first) |*app_window| {
            app_window.update(dt);
            try app_window.draw(gpa, &renderer);
        }
        if (second) |*app_window| {
            app_window.update(dt);
            try app_window.draw(gpa, &renderer);
        }
    }
    try renderer.device.deviceWaitIdle();
}

fn findDevice(gpa: std.mem.Allocator, instance: vk.InstanceProxy, surfaces: []const vk.SurfaceKHR) !DeviceSelection {
    const physical_devices = try instance.enumeratePhysicalDevicesAlloc(gpa);
    defer gpa.free(physical_devices);
    for (physical_devices) |physical_device| {
        const version: vk.Version = @bitCast(instance.getPhysicalDeviceProperties(physical_device).api_version);
        if (version.major < 1 or (version.major == 1 and version.minor < 3)) continue;

        const families = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(physical_device, gpa);
        defer gpa.free(families);
        for (families, 0..) |family, index| {
            if (!family.queue_flags.graphics_bit) continue;
            var can_present_everywhere = true;
            for (surfaces) |surface| {
                if (try instance.getPhysicalDeviceSurfaceSupportKHR(physical_device, @intCast(index), surface) != .true) {
                    can_present_everywhere = false;
                    break;
                }
            }
            if (can_present_everywhere) return .{
                .physical_device = physical_device,
                .graphics_queue_family = @intCast(index),
            };
        }
    }
    return error.NoVulkan13PresentDevice;
}

fn createPipelineLayout(device: vk.DeviceProxy) !vk.PipelineLayout {
    const range = vk.PushConstantRange{
        .stage_flags = .{ .vertex_bit = true },
        .offset = 0,
        .size = @sizeOf(PushConstants),
    };
    return device.createPipelineLayout(&.{
        .push_constant_range_count = 1,
        .p_push_constant_ranges = @ptrCast(&range),
    }, null);
}

fn createPipeline(device: vk.DeviceProxy, layout: vk.PipelineLayout, color_format: vk.Format) !vk.Pipeline {
    const vertex_module = try device.createShaderModule(&.{
        .code_size = vertex_spv.len,
        .p_code = @ptrCast(&vertex_spv),
    }, null);
    defer device.destroyShaderModule(vertex_module, null);
    const fragment_module = try device.createShaderModule(&.{
        .code_size = fragment_spv.len,
        .p_code = @ptrCast(&fragment_spv),
    }, null);
    defer device.destroyShaderModule(fragment_module, null);

    const stages = [_]vk.PipelineShaderStageCreateInfo{
        .{ .stage = .{ .vertex_bit = true }, .module = vertex_module, .p_name = "main" },
        .{ .stage = .{ .fragment_bit = true }, .module = fragment_module, .p_name = "main" },
    };
    const vertex_input = vk.PipelineVertexInputStateCreateInfo{};
    const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{
        .topology = .triangle_list,
        .primitive_restart_enable = .false,
    };
    const viewport = vk.PipelineViewportStateCreateInfo{
        .viewport_count = 1,
        .scissor_count = 1,
    };
    const rasterizer = vk.PipelineRasterizationStateCreateInfo{
        .depth_clamp_enable = .false,
        .rasterizer_discard_enable = .false,
        .polygon_mode = .fill,
        .cull_mode = .{},
        .front_face = .counter_clockwise,
        .depth_bias_enable = .false,
        .depth_bias_constant_factor = 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
        .line_width = 1,
    };
    const multisampling = vk.PipelineMultisampleStateCreateInfo{
        .rasterization_samples = .{ .@"1_bit" = true },
        .sample_shading_enable = .false,
        .min_sample_shading = 1,
        .alpha_to_coverage_enable = .false,
        .alpha_to_one_enable = .false,
    };
    const blend_attachment = vk.PipelineColorBlendAttachmentState{
        .blend_enable = .false,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
    };
    const blend = vk.PipelineColorBlendStateCreateInfo{
        .logic_op_enable = .false,
        .logic_op = .copy,
        .attachment_count = 1,
        .p_attachments = @ptrCast(&blend_attachment),
        .blend_constants = .{ 0, 0, 0, 0 },
    };
    const dynamic_states = [_]vk.DynamicState{ .viewport, .scissor };
    const dynamic = vk.PipelineDynamicStateCreateInfo{
        .dynamic_state_count = dynamic_states.len,
        .p_dynamic_states = &dynamic_states,
    };
    const rendering = vk.PipelineRenderingCreateInfo{
        .view_mask = 0,
        .color_attachment_count = 1,
        .p_color_attachment_formats = @ptrCast(&color_format),
        .depth_attachment_format = .undefined,
        .stencil_attachment_format = .undefined,
    };
    var pipelines: [1]vk.Pipeline = undefined;
    _ = try device.createGraphicsPipelines(.null_handle, &.{.{
        .p_next = @ptrCast(&rendering),
        .stage_count = stages.len,
        .p_stages = &stages,
        .p_vertex_input_state = &vertex_input,
        .p_input_assembly_state = &input_assembly,
        .p_viewport_state = &viewport,
        .p_rasterization_state = &rasterizer,
        .p_multisample_state = &multisampling,
        .p_color_blend_state = &blend,
        .p_dynamic_state = &dynamic,
        .layout = layout,
        .render_pass = .null_handle,
        .subpass = 0,
        .base_pipeline_index = -1,
    }}, null, &pipelines);
    return pipelines[0];
}

fn transitionImage(
    device: vk.DeviceProxy,
    command_buffer: vk.CommandBuffer,
    image: vk.Image,
    old_layout: vk.ImageLayout,
    new_layout: vk.ImageLayout,
    src_stage: vk.PipelineStageFlags2,
    src_access: vk.AccessFlags2,
    dst_stage: vk.PipelineStageFlags2,
    dst_access: vk.AccessFlags2,
) void {
    const barrier = vk.ImageMemoryBarrier2{
        .src_stage_mask = src_stage,
        .src_access_mask = src_access,
        .dst_stage_mask = dst_stage,
        .dst_access_mask = dst_access,
        .old_layout = old_layout,
        .new_layout = new_layout,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };
    device.cmdPipelineBarrier2(command_buffer, &.{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = @ptrCast(&barrier),
    });
}

fn chooseSurfaceFormat(formats: []const vk.SurfaceFormatKHR) vk.SurfaceFormatKHR {
    for (formats) |format| {
        if (format.format == .b8g8r8a8_unorm and format.color_space == .srgb_nonlinear_khr) return format;
    }
    return formats[0];
}

fn findFormat(formats: []const vk.SurfaceFormatKHR, desired: vk.Format) ?vk.SurfaceFormatKHR {
    for (formats) |format| if (format.format == desired) return format;
    return null;
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

fn requestedBackend(args: []const [:0]const u8) !low.BackendRequest {
    var selected: ?low.BackendRequest = null;
    for (args[1..]) |arg| {
        const backend: low.BackendRequest = if (std.mem.eql(u8, arg, "--x11"))
            .x11
        else if (std.mem.eql(u8, arg, "--wayland"))
            .wayland
        else
            return error.UnknownArgument;
        if (selected != null) return error.ConflictingBackendArguments;
        selected = backend;
    }
    return selected orelse .auto;
}

fn onFramebufferResize(window: *low.Window, _: low.Size) void {
    const self: *AppWindow = @ptrCast(@alignCast(window.getUserData() orelse return));
    self.needs_recreate = true;
}

fn onMouseButton(window: *low.Window, button: low.MouseButton, action: low.Action, _: low.Modifiers) void {
    if (button != .left or action != .press) return;
    const self: *AppWindow = @ptrCast(@alignCast(window.getUserData() orelse return));
    self.velocity = .{ -self.velocity[0], -self.velocity[1] };
    self.color = .{ self.color[1], self.color[2], self.color[0] };
}
