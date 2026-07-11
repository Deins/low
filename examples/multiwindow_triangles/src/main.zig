const std = @import("std");
const low = @import("low");
const vk = @import("vulkan");

const RenderTarget = low.vulkan.targets().RenderTarget;
const vertex_spv align(@alignOf(u32)) = @embedFile("triangle_vert").*;
const fragment_spv align(@alignOf(u32)) = @embedFile("triangle_frag").*;
const triangle_half_size_px: f32 = 70.0;

fn lowPhysicalDevice(value: vk.PhysicalDevice) low.vulkan.api.PhysicalDevice {
    return @ptrFromInt(@intFromEnum(value));
}

fn lowQueue(value: vk.Queue) low.vulkan.api.Queue {
    return @ptrFromInt(@intFromEnum(value));
}

fn lowFormat(value: vk.Format) low.vulkan.api.Format {
    return @intCast(@intFromEnum(value));
}

const PushConstants = extern struct {
    offset: [2]f32,
    screen_size: [2]f32,
    color: [3]f32,
};

const DeviceSelection = struct {
    physical_device: vk.PhysicalDevice,
    graphics_queue_family: u32,
};

const Renderer = struct {
    gpa: std.mem.Allocator,
    instance: vk.InstanceProxy,
    low_instance: low.vulkan.Instance,
    physical_device: vk.PhysicalDevice,
    device_wrapper: *vk.DeviceWrapper,
    device: vk.DeviceProxy,
    low_device: low.vulkan.Device,
    graphics_queue: vk.Queue,
    graphics_queue_family: u32,
    command_pool: vk.CommandPool,
    pipeline_layout: vk.PipelineLayout,
    pipeline: vk.Pipeline,
    color_format: vk.Format,

    fn init(
        gpa: std.mem.Allocator,
        loader: *const low.vulkan.Loader,
        instance: vk.InstanceProxy,
        presentation: bool,
    ) !Renderer {
        const selection = try findDevice(gpa, instance);

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
        // Surface extensions come from Context.requiredVulkanInstanceExtensions
        // when creating the instance. VK_KHR_swapchain is separately a device
        // extension, and is unnecessary for RenderTarget's offscreen images.
        const device_extensions: []const [*:0]const u8 = if (presentation) &.{"VK_KHR_swapchain"} else &.{};
        const device_info = vk.DeviceCreateInfo{
            .p_next = @ptrCast(&features_13),
            .queue_create_info_count = 1,
            .p_queue_create_infos = @ptrCast(&queue_info),
            .enabled_extension_count = @intCast(device_extensions.len),
            .pp_enabled_extension_names = device_extensions.ptr,
        };
        const device_handle = try instance.createDevice(selection.physical_device, &device_info, null);
        const device_wrapper = try gpa.create(vk.DeviceWrapper);
        errdefer gpa.destroy(device_wrapper);
        device_wrapper.* = vk.DeviceWrapper.load(
            device_handle,
            instance.wrapper.dispatch.vkGetDeviceProcAddr.?,
        );
        if (presentation and device_wrapper.dispatch.vkCreateSwapchainKHR == null) return error.SwapchainCommandsUnavailable;
        const device = vk.DeviceProxy.init(device_handle, device_wrapper);
        errdefer device.destroyDevice(null);
        const low_instance = try loader.loadInstanceApi(@ptrFromInt(@intFromEnum(instance.handle)));
        const low_device = try low.vulkan.Device.init(&low_instance, @ptrFromInt(@intFromEnum(device_handle)));

        const command_pool = try device.createCommandPool(&.{
            .flags = .{ .reset_command_buffer_bit = true },
            .queue_family_index = selection.graphics_queue_family,
        }, null);
        errdefer device.destroyCommandPool(command_pool, null);

        const color_format: vk.Format = .b8g8r8a8_unorm;

        const pipeline_layout = try createPipelineLayout(device);
        errdefer device.destroyPipelineLayout(pipeline_layout, null);
        const pipeline = try createPipeline(device, pipeline_layout, color_format);
        errdefer device.destroyPipeline(pipeline, null);

        return .{
            .gpa = gpa,
            .instance = instance,
            .low_instance = low_instance,
            .physical_device = selection.physical_device,
            .device_wrapper = device_wrapper,
            .device = device,
            .low_device = low_device,
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
    target: RenderTarget,
    position: [2]f32,
    velocity: [2]f32,
    color: [3]f32,

    fn init(
        gpa: std.mem.Allocator,
        renderer: *const Renderer,
        context: *low.Context,
        window: *low.Window,
        position: [2]f32,
        velocity: [2]f32,
        color: [3]f32,
    ) !AppWindow {
        return .{
            .window = window,
            .target = try RenderTarget.init(gpa, .{
                .context = context,
                .window = window,
                .instance = &renderer.low_instance,
                .physical_device = lowPhysicalDevice(renderer.physical_device),
                .device = &renderer.low_device,
                .graphics_queue = lowQueue(renderer.graphics_queue),
                .graphics_queue_family = renderer.graphics_queue_family,
                .command_pool = @intFromEnum(renderer.command_pool),
                .color_format = lowFormat(renderer.color_format),
                .frames_in_flight = 2,
            }),
            .position = position,
            .velocity = velocity,
            .color = color,
        };
    }

    fn installCallbacks(self: *AppWindow) void {
        self.window.setUserData(self);
        self.window.setCallbacks(.{ .mouse_button = onMouseButton });
    }

    fn deinit(self: *AppWindow) void {
        self.target.deinit();
        self.window.deinit();
        self.* = undefined;
    }

    fn update(self: *AppWindow, dt: f32) void {
        const framebuffer_size = self.window.getFramebufferSize();
        const width: f32 = @floatFromInt(@max(framebuffer_size.width, 1));
        const height: f32 = @floatFromInt(@max(framebuffer_size.height, 1));
        const bounds = [2]f32{
            @max(0.0, 1.0 - 2.0 * triangle_half_size_px / width),
            @max(0.0, 1.0 - 2.0 * triangle_half_size_px / height),
        };
        for (0..2) |axis| {
            self.position[axis] += self.velocity[axis] * dt;
            if (self.position[axis] > bounds[axis]) {
                self.position[axis] = bounds[axis];
                self.velocity[axis] = -@abs(self.velocity[axis]);
            } else if (self.position[axis] < -bounds[axis]) {
                self.position[axis] = -bounds[axis];
                self.velocity[axis] = @abs(self.velocity[axis]);
            }
        }
    }

    fn draw(self: *AppWindow, renderer: *const Renderer) !void {
        var frame = self.target.acquire() catch |err| switch (err) {
            error.FrameSkipped, error.FrameOutOfDate => return,
            else => return err,
        };
        defer frame.abort();
        const command_buffer: vk.CommandBuffer = @enumFromInt(@intFromPtr(frame.command_buffer.?));
        const image_view: vk.ImageView = @enumFromInt(frame.view);
        const extent = vk.Extent2D{ .width = frame.extent.width, .height = frame.extent.height };
        const color_attachment = vk.RenderingAttachmentInfo{
            .image_view = image_view,
            .image_layout = .color_attachment_optimal,
            .resolve_mode = .{},
            .resolve_image_layout = .undefined,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .color = .{ .float_32 = .{ 0.018, 0.025, 0.06, 1.0 } } },
        };
        renderer.device.cmdBeginRendering(command_buffer, &.{
            .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = extent },
            .layer_count = 1,
            .view_mask = 0,
            .color_attachment_count = 1,
            .p_color_attachments = @ptrCast(&color_attachment),
        });
        const viewport = vk.Viewport{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(extent.width),
            .height = @floatFromInt(extent.height),
            .min_depth = 0,
            .max_depth = 1,
        };
        const scissor = vk.Rect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = extent };
        renderer.device.cmdSetViewport(command_buffer, 0, &.{viewport});
        renderer.device.cmdSetScissor(command_buffer, 0, &.{scissor});
        renderer.device.cmdBindPipeline(command_buffer, .graphics, renderer.pipeline);
        const push = PushConstants{
            .offset = self.position,
            .screen_size = .{ @floatFromInt(extent.width), @floatFromInt(extent.height) },
            .color = self.color,
        };
        renderer.device.cmdPushConstants(command_buffer, renderer.pipeline_layout, .{ .vertex_bit = true }, 0, @sizeOf(PushConstants), @ptrCast(&push));
        renderer.device.cmdDraw(command_buffer, 3, 1, 0, 0);
        renderer.device.cmdEndRendering(command_buffer);
        try frame.submitAndPresent();
    }
};

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa_state.deinit() == .ok);
    const gpa = gpa_state.allocator();
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const backend = try requestedBackend(args);
    var loader = try low.vulkan.Loader.init();
    defer loader.deinit();
    const get_instance_proc_addr: vk.PfnGetInstanceProcAddr = @ptrCast(loader.get_instance_proc_addr);
    const base = vk.BaseWrapper.load(get_instance_proc_addr);

    var context = try low.Context.init(gpa, .{
        .app_name = "low.multiwindow_triangles",
        .backend = backend,
        .offscreen = .{ .frame_mode = .{ .continuous = .{} } },
    });
    defer context.deinit();
    std.log.info("using {s} backend", .{@tagName(context.backendKind())});
    const extensions = context.requiredVulkanInstanceExtensions();

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
    const second_window = try context.createWindow(.{
        .title = "low Vulkan — cyan triangle",
        .size = .{ .width = 520, .height = 400 },
    });

    var renderer = try Renderer.init(gpa, &loader, instance, context.backendKind() != .offscreen);
    defer renderer.deinit();
    var first: ?AppWindow = try AppWindow.init(
        gpa,
        &renderer,
        &context,
        first_window,
        .{ -0.3, 0.1 },
        .{ 0.73, 0.52 },
        .{ 1.0, 0.30, 0.20 },
    );
    defer if (first) |*app_window| app_window.deinit();
    var second: ?AppWindow = try AppWindow.init(
        gpa,
        &renderer,
        &context,
        second_window,
        .{ 0.25, -0.2 },
        .{ -0.61, 0.67 },
        .{ 0.18, 0.90, 0.95 },
    );
    defer if (second) |*app_window| app_window.deinit();
    first.?.installCallbacks();
    second.?.installCallbacks();

    var previous = std.Io.Timestamp.now(std.Options.debug_io, .awake);
    var offscreen_frames: u32 = 0;
    while (first != null or second != null) {
        if (context.backendKind() == .offscreen) try context.nextFrame();
        context.pollEvents();

        const close_first = if (first) |app_window| app_window.window.shouldClose() else false;
        const close_second = if (second) |app_window| app_window.window.shouldClose() else false;
        if (close_first or close_second) {
            // A close event is delivered while polling. Destroy the matching
            // native window only after that dispatch has completed, and wait
            // until its in-flight Vulkan work can no longer reference it.
            try renderer.device.deviceWaitIdle();
            if (close_first) {
                if (first) |*app_window| app_window.deinit();
                first = null;
            }
            if (close_second) {
                if (second) |*app_window| app_window.deinit();
                second = null;
            }
            if (first == null and second == null) break;
        }

        const now = std.Io.Timestamp.now(std.Options.debug_io, .awake);
        const dt: f32 = @min(0.05, @as(f32, @floatFromInt(now.nanoseconds - previous.nanoseconds)) / 1_000_000_000);
        previous = now;
        if (first) |*app_window| {
            app_window.update(dt);
            try app_window.draw(&renderer);
        }
        if (second) |*app_window| {
            app_window.update(dt);
            try app_window.draw(&renderer);
        }
        if (context.backendKind() == .offscreen) {
            offscreen_frames += 1;
            if (offscreen_frames == 10) {
                if (first) |app_window| try app_window.window.injectEvent(.close);
                if (second) |app_window| try app_window.window.injectEvent(.close);
            }
        }
    }
    try renderer.device.deviceWaitIdle();
}

fn findDevice(gpa: std.mem.Allocator, instance: vk.InstanceProxy) !DeviceSelection {
    const physical_devices = try instance.enumeratePhysicalDevicesAlloc(gpa);
    defer gpa.free(physical_devices);
    for (physical_devices) |physical_device| {
        const version: vk.Version = @bitCast(instance.getPhysicalDeviceProperties(physical_device).api_version);
        if (version.major < 1 or (version.major == 1 and version.minor < 3)) continue;

        const families = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(physical_device, gpa);
        defer gpa.free(families);
        for (families, 0..) |family, index| {
            if (!family.queue_flags.graphics_bit) continue;
            return .{
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

fn requestedBackend(args: []const [:0]const u8) !low.BackendRequest {
    var selected: ?low.BackendRequest = null;
    for (args[1..]) |arg| {
        const backend: low.BackendRequest = if (std.mem.eql(u8, arg, "--x11"))
            .x11
        else if (std.mem.eql(u8, arg, "--wayland"))
            .wayland
        else if (std.mem.eql(u8, arg, "--offscreen"))
            .offscreen
        else
            return error.UnknownArgument;
        if (selected != null) return error.ConflictingBackendArguments;
        selected = backend;
    }
    return selected orelse .auto;
}

fn onMouseButton(window: *low.Window, button: low.MouseButton, action: low.Action, _: low.Modifiers) void {
    if (button != .left or action != .press) return;
    const self: *AppWindow = @ptrCast(@alignCast(window.getUserData() orelse return));
    self.velocity = .{ -self.velocity[0], -self.velocity[1] };
    self.color = .{ self.color[1], self.color[2], self.color[0] };
}
