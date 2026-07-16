const std = @import("std");
const low = @import("low");
const vk = @import("vulkan");
const video = low.vulkan.video();
const log = std.log.scoped(.low);

const Targets = low.vulkan.targets();
const RenderTarget = Targets.RenderTarget;
const RenderContext = Targets.RenderContext;
const vertex_spv align(@alignOf(u32)) = @embedFile("triangle_vert").*;
const fragment_spv align(@alignOf(u32)) = @embedFile("triangle_frag").*;
const triangle_half_size_px: f32 = 70.0;

const PushConstants = extern struct {
    offset: [2]f32,
    screen_size: [2]f32,
    color: [3]f32,
};

const Renderer = struct {
    gpa: std.mem.Allocator,
    instance: vk.InstanceProxy,
    render_context: RenderContext,
    physical_device: vk.PhysicalDevice,
    device_resources: Targets.DeviceResources(vk),
    device: vk.DeviceProxy,
    graphics_queue: vk.Queue,
    graphics_queue_family: u32,
    command_pool: vk.CommandPool,
    pipeline_layout: vk.PipelineLayout,
    pipeline: vk.Pipeline,
    color_format: vk.Format,
    encode_queue: vk.Queue,
    encode_queue_family: ?u32,
    video_device: ?video.VideoDevice,
    video_codec: ?video.Codec,

    fn init(
        gpa: std.mem.Allocator,
        instance: vk.InstanceProxy,
        low_instance_input: low.vulkan.Instance,
        presentation_surface: ?low.vulkan.api.SurfaceKHR,
        recording: video.RecordingRequest,
    ) !Renderer {
        const selection = try Targets.findDevice(
            vk,
            gpa,
            instance,
            &low_instance_input,
            presentation_surface,
            recording,
        );
        if (selection.selected_video_format) |selected| {
            const coded_extent = selected.codedExtent();
            log.debug("{s} encode: coded extent {d}x{d}, queue family {d}", .{
                @tagName(selected.codec()),
                coded_extent.width,
                coded_extent.height,
                selected.encodeQueueFamily().?,
            });
        }
        const color_format: vk.Format = @enumFromInt(try Targets.chooseColorFormat(
            &low_instance_input,
            low.vulkan.toPhysicalDevice(selection.physical_device),
            presentation_surface,
            gpa,
            Targets.default_color_formats,
        ));
        const properties = instance.getPhysicalDeviceProperties(selection.physical_device);
        const version: vk.Version = @bitCast(properties.api_version);
        log.debug("selected Vulkan device: {s}, API {d}.{d}.{d}, graphics queue family {d}", .{
            std.mem.sliceTo(&properties.device_name, 0),
            version.major,
            version.minor,
            version.patch,
            selection.graphics_queue_family,
        });

        var features_13 = vk.PhysicalDeviceVulkan13Features{
            .synchronization_2 = .true,
            .dynamic_rendering = .true,
        };
        var av1_features = vk.PhysicalDeviceVideoEncodeAV1FeaturesKHR{};
        if (selection.selected_video_format != null and selection.selected_video_format.?.codec() == .av1) {
            av1_features.video_encode_av1 = .true;
            features_13.p_next = @ptrCast(&av1_features);
        }
        // Surface extensions come from Context.requiredVulkanInstanceExtensions
        // when creating the instance. VK_KHR_swapchain is separately a device
        // extension, and is unnecessary for RenderTarget's offscreen images.
        var extension_storage: [4][*:0]const u8 = undefined;
        var extension_count: usize = 0;
        if (presentation_surface != null) {
            extension_storage[extension_count] = "VK_KHR_swapchain";
            extension_count += 1;
        }
        if (selection.selected_video_format) |selected| {
            for (selected.deviceExtensions()) |extension| {
                extension_storage[extension_count] = extension;
                extension_count += 1;
            }
        }
        const device_extensions = extension_storage[0..extension_count];
        var device_resources = try Targets.createDevice(
            vk,
            gpa,
            instance,
            &low_instance_input,
            selection,
            &features_13,
            device_extensions,
        );
        errdefer device_resources.deinit();
        if (presentation_surface != null and device_resources.wrapper.dispatch.vkCreateSwapchainKHR == null) return error.SwapchainCommandsUnavailable;
        const device = device_resources.device;
        const low_instance = low_instance_input;
        const low_device = device_resources.low_device;

        const command_pool = try device.createCommandPool(&.{
            .flags = .{ .reset_command_buffer_bit = true },
            .queue_family_index = selection.graphics_queue_family,
        }, null);
        errdefer device.destroyCommandPool(command_pool, null);

        const pipeline_layout = try createPipelineLayout(device);
        errdefer device.destroyPipelineLayout(pipeline_layout, null);
        const pipeline = try createPipeline(device, pipeline_layout, color_format);
        errdefer device.destroyPipeline(pipeline, null);

        const graphics_queue = device_resources.graphics_queue;
        const encode_queue = device_resources.encode_queue;
        return .{
            .gpa = gpa,
            .instance = instance,
            .render_context = RenderContext.init(
                low_instance,
                low.vulkan.toPhysicalDevice(selection.physical_device),
                low_device,
                low.vulkan.toQueue(graphics_queue),
                selection.graphics_queue_family,
                @intFromEnum(command_pool),
            ),
            .physical_device = selection.physical_device,
            .device_resources = device_resources,
            .device = device,
            .graphics_queue = graphics_queue,
            .graphics_queue_family = selection.graphics_queue_family,
            .command_pool = command_pool,
            .pipeline_layout = pipeline_layout,
            .pipeline = pipeline,
            .color_format = color_format,
            .encode_queue = encode_queue,
            .encode_queue_family = selection.encode_queue_family,
            .video_device = null,
            .video_codec = if (selection.selected_video_format) |selected| selected.codec() else null,
        };
    }

    fn initVideo(self: *Renderer) !void {
        const encode_family = self.encode_queue_family orelse return error.NoVideoEncodeDevice;
        self.video_device = try video.VideoDevice.init(.{
            .allocator = self.gpa,
            .instance = &self.render_context.instance,
            .physical_device = low.vulkan.toPhysicalDevice(self.physical_device),
            .device = &self.render_context.device,
            .encode_queue = low.vulkan.toQueue(self.encode_queue),
            .encode_queue_family = encode_family,
            .compute_queue = low.vulkan.toQueue(self.graphics_queue),
            .compute_queue_family = self.graphics_queue_family,
            .codec = self.video_codec orelse return error.NoVideoEncodeDevice,
        });
        self.render_context.video_device = &self.video_device.?;
    }

    fn deinit(self: *Renderer) void {
        if (self.video_device) |*video_device| video_device.deinit();
        self.device.destroyPipeline(self.pipeline, null);
        self.device.destroyPipelineLayout(self.pipeline_layout, null);
        self.device.destroyCommandPool(self.command_pool, null);
        self.device_resources.deinit();
        self.* = undefined;
    }
};

const AppWindow = struct {
    window: *low.Window,
    target: RenderTarget,
    position: [2]f32,
    velocity: [2]f32,
    color: [3]f32,
    dump_prefix: []const u8,
    recording_path: []const u8,
    record_file: ?std.Io.File = null,
    record_buffer: [64 * 1024]u8 = undefined,
    record_writer: ?std.Io.File.Writer = null,

    fn init(
        gpa: std.mem.Allocator,
        renderer: *Renderer,
        window: *low.Window,
        position: [2]f32,
        velocity: [2]f32,
        color: [3]f32,
        dump_prefix: []const u8,
        recording_path: []const u8,
        readback: bool,
    ) !AppWindow {
        var target = try RenderTarget.init(gpa, .{
            .window = window,
            .context = &renderer.render_context,
            .readback = readback,
        });
        errdefer target.deinit();
        if (target.colorFormat() != low.vulkan.toFormat(renderer.color_format)) return error.UnsupportedSurfaceFormat;
        return .{
            .window = window,
            .target = target,
            .position = position,
            .velocity = velocity,
            .color = color,
            .dump_prefix = dump_prefix,
            .recording_path = recording_path,
        };
    }

    fn installCallbacks(self: *AppWindow) void {
        self.window.setUserData(self);
        self.window.setCallbacks(.{
            .mouse_button = onMouseButton,
        });
    }

    fn deinit(self: *AppWindow, io: std.Io) void {
        self.target.endRecording() catch |err| std.log.err("failed to finalize recording: {s}", .{@errorName(err)});
        self.target.deinit();
        self.window.deinit();
        if (self.record_file) |*file| file.close(io);
        self.* = undefined;
    }

    fn startRecording(self: *AppWindow, io: std.Io) !void {
        self.record_file = try std.Io.Dir.cwd().createFile(io, self.recording_path, .{});
        errdefer {
            self.record_file.?.close(io);
            self.record_file = null;
        }
        self.record_writer = self.record_file.?.writer(io, &self.record_buffer);
        errdefer self.record_writer = null;
        if (self.record_writer) |*writer| try self.target.beginRecording(.{
            .io = io,
            .writer = &writer.interface,
            .resize = .change_resolution,
        });
    }

    fn dumpPath(self: *const AppWindow, buffer: []u8, frame: u32) ![]const u8 {
        return std.fmt.bufPrint(buffer, "tmp/{s}-{d:0>4}.bmp", .{ self.dump_prefix, frame });
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

    fn draw(self: *AppWindow, renderer: *const Renderer, io: std.Io, dump_path: ?[]const u8) !void {
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
        if (dump_path) |path| {
            var readback = try frame.submitAndReadback(renderer.gpa, .{});
            defer readback.deinit();
            try readback.writeBmp(io, path);
        } else {
            try frame.submitAndPresent(.{});
        }
    }
};

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa_state.deinit() == .ok);
    const gpa = gpa_state.allocator();
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const app_options = try parseOptions(args);
    const recording_requested = app_options.screencap or app_options.record_codec != null;

    var loader = try low.vulkan.Loader.init();
    defer loader.deinit();
    const get_instance_proc_addr: vk.PfnGetInstanceProcAddr = @ptrCast(loader.get_instance_proc_addr);
    const base = vk.BaseWrapper.load(get_instance_proc_addr);

    var context = try low.Context.init(gpa, .{
        .app_name = "low.multiwindow_triangles",
        .backend = app_options.backend,
        .offscreen = .{ .frame_mode = .{ .continuous = .{} } },
    });
    defer context.deinit();
    log.debug("using {s} backend", .{@tagName(context.backendKind())});
    const extensions = context.requiredVulkanInstanceExtensions();

    const app_info = vk.ApplicationInfo{
        .p_application_name = "low multiwindow triangles",
        .application_version = 1,
        .p_engine_name = "low",
        .engine_version = 1,
        .api_version = @bitCast(vk.API_VERSION_1_3),
    };
    var instance_resources = try Targets.createInstance(
        vk,
        gpa,
        base,
        get_instance_proc_addr,
        app_info,
        extensions,
    );
    defer instance_resources.deinit();
    const instance = instance_resources.instance;

    const low_instance = try loader.loadInstanceApi(low.vulkan.toInstance(instance.handle));
    const offscreen = context.backendKind() == .offscreen;
    const first_window = try context.createWindow(.{
        .title = "low Vulkan — first window",
        .size = .{ .width = 640, .height = 480 },
    });
    var selection_surface: ?low.vulkan.PresentationSurface = null;
    if (!offscreen) {
        selection_surface = try context.createVulkanPresentationSurface(&low_instance, first_window);
    }
    defer if (selection_surface) |*surface| surface.deinit();
    const recording_request: video.RecordingRequest = if (!recording_requested)
        .off
    else if (app_options.record_codec) |codec|
        .{ .codec = codec }
    else
        .on;
    var renderer = Renderer.init(
        gpa,
        instance,
        low_instance,
        if (selection_surface) |surface| surface.handle else null,
        recording_request,
    ) catch |err| {
        if (recording_requested) {
            std.log.err("no device can render and encode the requested video format: {s}", .{@errorName(err)});
        }
        return err;
    };
    defer renderer.deinit();
    if (recording_requested) try renderer.initVideo();
    const second_window = try context.createWindow(.{
        .title = "low Vulkan — second window",
        .size = .{ .width = 320, .height = 240 },
    });
    var first: ?AppWindow = try AppWindow.init(
        gpa,
        &renderer,
        first_window,
        .{ -0.3, 0.1 },
        .{ 0.73, 0.52 },
        .{ 1.0, 0.30, 0.20 },
        "first",
        "tmp/first.mkv",
        app_options.dump,
    );
    defer if (first) |*app_window| app_window.deinit(init.io);
    var second: ?AppWindow = try AppWindow.init(
        gpa,
        &renderer,
        second_window,
        .{ 0.25, -0.2 },
        .{ -0.61, 0.67 },
        .{ 0.18, 0.90, 0.95 },
        "second",
        "tmp/second.mkv",
        app_options.dump,
    );
    defer if (second) |*app_window| app_window.deinit(init.io);
    const windows = [_]*?AppWindow{ &first, &second };
    first.?.installCallbacks();
    second.?.installCallbacks();
    if (recording_requested) {
        try std.Io.Dir.cwd().createDirPath(init.io, "tmp");
        for (windows) |window_slot| {
            if (window_slot.*) |*app_window| app_window.startRecording(init.io) catch |err| {
                std.log.err("{s} stream could not start: {s}", .{ app_window.dump_prefix, @errorName(err) });
            };
        }
    }

    var previous = std.Io.Timestamp.now(std.Options.debug_io, .awake);
    var rendered_frames: u32 = 0;
    if (app_options.dump) try std.Io.Dir.cwd().createDirPath(init.io, "tmp");
    while (first != null or second != null) {
        if (offscreen) try context.nextFrame();
        context.pollEvents();

        for (windows) |window_slot| {
            if (window_slot.*) |*app_window| {
                if (app_window.window.shouldClose()) {
                    app_window.deinit(init.io);
                    window_slot.* = null;
                }
            }
        }
        if (first == null and second == null) break;

        const all_frames_blocked = !offscreen and
            (first == null or !first.?.window.shouldRender()) and
            (second == null or !second.?.window.shouldRender());
        if (all_frames_blocked) {
            var render_windows: [2]*low.Window = undefined;
            var render_window_count: usize = 0;
            for (windows) |window_slot| {
                if (window_slot.*) |app_window| {
                    render_windows[render_window_count] = app_window.window;
                    render_window_count += 1;
                }
            }
            try context.waitForAnyRender(render_windows[0..render_window_count]);
            continue;
        }

        const now = std.Io.Timestamp.now(std.Options.debug_io, .awake);
        const dt: f32 = @min(0.05, @as(f32, @floatFromInt(now.nanoseconds - previous.nanoseconds)) / 1_000_000_000);
        previous = now;
        var rendered = false;
        for (windows) |window_slot| {
            if (window_slot.*) |*app_window| {
                if (!app_window.window.shouldRender()) continue;
                app_window.update(dt);
                var path_buffer: [64]u8 = undefined;
                const path = if (app_options.dump) try app_window.dumpPath(&path_buffer, rendered_frames + 1) else null;
                try app_window.draw(&renderer, init.io, path);
                rendered = true;
            }
        }
        if (!rendered) continue;
        rendered_frames += 1;
        if (app_options.frames) |limit| {
            if (rendered_frames == limit) {
                for (windows) |window_slot| {
                    if (window_slot.*) |app_window| app_window.window.setShouldClose(true);
                }
            }
        }
    }
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

const AppOptions = struct {
    backend: low.BackendRequest = .auto,
    screencap: bool = false,
    dump: bool = false,
    record_codec: ?video.Codec = null,
    frames: ?u32 = null,
};

fn parseOptions(args: []const [:0]const u8) !AppOptions {
    var result: AppOptions = .{};
    var desktop_selected = false;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.startsWith(u8, arg, "--desktop=")) {
            if (desktop_selected) return error.ConflictingDesktopArguments;
            const name = arg["--desktop=".len..];
            result.backend = std.meta.stringToEnum(low.BackendRequest, name) orelse return error.InvalidDesktop;
            desktop_selected = true;
        } else if (std.mem.eql(u8, arg, "--screencap")) {
            result.screencap = true;
        } else if (std.mem.eql(u8, arg, "--dump")) {
            result.dump = true;
        } else if (std.mem.startsWith(u8, arg, "--record-codec=")) {
            const name = arg["--record-codec=".len..];
            result.record_codec = std.meta.stringToEnum(video.Codec, name) orelse return error.InvalidRecordingCodec;
        } else if (std.mem.startsWith(u8, arg, "--frames=")) {
            result.frames = try std.fmt.parseInt(u32, arg["--frames=".len..], 10);
            if (result.frames.? == 0) return error.InvalidFrameCount;
        } else {
            return error.UnknownArgument;
        }
    }
    return result;
}

fn onMouseButton(window: *low.Window, button: low.MouseButton, action: low.Action, _: low.Modifiers) void {
    if (button != .left or action != .press) return;
    const self: *AppWindow = @ptrCast(@alignCast(window.getUserData() orelse return));
    self.velocity = .{ -self.velocity[0], -self.velocity[1] };
    self.color = .{ self.color[1], self.color[2], self.color[0] };
}
