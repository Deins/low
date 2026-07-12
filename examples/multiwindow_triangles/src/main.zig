const std = @import("std");
const low = @import("low");
const vk = @import("vulkan");
const example_options = @import("example_options");
const video = if (example_options.vk_video) low.vulkan.video() else struct {};

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
    encode_queue_family: ?u32 = null,
};

const RecordingFileFormat = if (example_options.vk_video) video.RecordingFormat else enum { h264, mkv };

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
    encode_queue: vk.Queue,
    encode_queue_family: ?u32,
    video_device: if (example_options.vk_video) ?video.VideoDevice else void,

    fn init(
        gpa: std.mem.Allocator,
        instance: vk.InstanceProxy,
        low_instance_input: low.vulkan.Instance,
        presentation: bool,
        recording: bool,
    ) !Renderer {
        const selection = try findDevice(gpa, instance, &low_instance_input, recording);

        var features_13 = vk.PhysicalDeviceVulkan13Features{
            .synchronization_2 = .true,
            .dynamic_rendering = .true,
        };
        // Surface extensions come from Context.requiredVulkanInstanceExtensions
        // when creating the instance. VK_KHR_swapchain is separately a device
        // extension, and is unnecessary for RenderTarget's offscreen images.
        var extension_storage: [4][*:0]const u8 = undefined;
        var extension_count: usize = 0;
        if (presentation) {
            extension_storage[extension_count] = "VK_KHR_swapchain";
            extension_count += 1;
        }
        if (recording) {
            if (comptime !example_options.vk_video) return error.VideoRecordingNotCompiled;
            for (video.required_device_extensions) |extension| {
                extension_storage[extension_count] = extension;
                extension_count += 1;
            }
        }
        const device_extensions = extension_storage[0..extension_count];
        const queue_priority = [_]f32{1.0};
        var queue_infos: [2]vk.DeviceQueueCreateInfo = undefined;
        queue_infos[0] = .{
            .queue_family_index = selection.graphics_queue_family,
            .queue_count = 1,
            .p_queue_priorities = &queue_priority,
        };
        var queue_info_count: u32 = 1;
        if (recording) {
            if (comptime !example_options.vk_video) return error.VideoRecordingNotCompiled;
            const support = try video.queryH264Support(.{
                .instance = &low_instance_input,
                .physical_device = lowPhysicalDevice(selection.physical_device),
                .extent = .{ .width = 640, .height = 480 },
                .allocator = gpa,
            });
            var requirements = try support.deviceRequirements(.{
                .allocator = gpa,
                .graphics_queue_family = selection.graphics_queue_family,
                .queue_priority = 1.0,
            });
            defer requirements.deinit(gpa);
            queue_info_count = @intCast(requirements.queue_create_infos.len);
            for (requirements.queue_create_infos, 0..) |requirement, index| queue_infos[index] = .{
                .queue_family_index = requirement.queue_family_index,
                .queue_count = 1,
                .p_queue_priorities = &queue_priority,
            };
        }
        const device_info = vk.DeviceCreateInfo{
            .p_next = @ptrCast(&features_13),
            .queue_create_info_count = queue_info_count,
            .p_queue_create_infos = &queue_infos,
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
        const low_instance = low_instance_input;
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

        const graphics_queue = device.getDeviceQueue(selection.graphics_queue_family, 0);
        const encode_queue = device.getDeviceQueue(selection.encode_queue_family orelse selection.graphics_queue_family, 0);
        return .{
            .gpa = gpa,
            .instance = instance,
            .low_instance = low_instance,
            .physical_device = selection.physical_device,
            .device_wrapper = device_wrapper,
            .device = device,
            .low_device = low_device,
            .graphics_queue = graphics_queue,
            .graphics_queue_family = selection.graphics_queue_family,
            .command_pool = command_pool,
            .pipeline_layout = pipeline_layout,
            .pipeline = pipeline,
            .color_format = color_format,
            .encode_queue = encode_queue,
            .encode_queue_family = selection.encode_queue_family,
            .video_device = if (comptime example_options.vk_video) null else {},
        };
    }

    fn initVideo(self: *Renderer) !void {
        if (comptime !example_options.vk_video) return error.VideoRecordingNotCompiled;
        const encode_family = self.encode_queue_family orelse return error.NoH264Device;
        self.video_device = try video.VideoDevice.init(.{
            .allocator = self.gpa,
            .instance = &self.low_instance,
            .physical_device = lowPhysicalDevice(self.physical_device),
            .device = &self.low_device,
            .encode_queue = lowQueue(self.encode_queue),
            .encode_queue_family = encode_family,
            .compute_queue = lowQueue(self.graphics_queue),
            .compute_queue_family = self.graphics_queue_family,
        });
    }

    fn deinit(self: *Renderer) void {
        if (comptime example_options.vk_video) if (self.video_device) |*video_device| video_device.deinit();
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
        renderer: *Renderer,
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
                .video_device = if (comptime example_options.vk_video) if (renderer.video_device) |*video_device| video_device else null else null,
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
        if (comptime example_options.vk_video) self.target.endRecording() catch |err| std.log.err("failed to finalize recording: {s}", .{@errorName(err)});
        self.target.deinit();
        self.window.deinit();
        self.* = undefined;
    }

    fn startRecording(self: *AppWindow, io: std.Io, writer: *std.Io.Writer, format: RecordingFileFormat, fps: u32, bitrate: u32, gop_size: u32) !void {
        if (comptime !example_options.vk_video) return error.VideoRecordingNotCompiled;
        try self.target.beginRecording(.{
            .allocator = self.target.allocator,
            .io = io,
            .writer = writer,
            .frame_rate = .{ .numerator = fps, .denominator = 1 },
            .bitrate = bitrate,
            .gop_size = gop_size,
            .format = format,
        });
    }

    fn stopRecording(self: *AppWindow) !void {
        if (comptime !example_options.vk_video) return;
        try self.target.endRecording();
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
            var readback = try frame.submitAndReadback(renderer.gpa);
            defer readback.deinit();
            try readback.writeBmp(io, path);
        } else {
            try frame.submitAndPresent();
        }
    }
};

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa_state.deinit() == .ok);
    const gpa = gpa_state.allocator();
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const app_options = try parseOptions(args);
    const backend = app_options.backend;
    const recording_requested = app_options.first_record_path != null or app_options.second_record_path != null;
    if (app_options.restart_recording_at != null and
        ((app_options.first_record_path != null and recordingFileFormat(app_options.first_record_path.?) == .mkv) or
            (app_options.second_record_path != null and recordingFileFormat(app_options.second_record_path.?) == .mkv)))
    {
        std.log.err("--restart-recording-at cannot append a second Matroska timeline to the same file; use a fresh writer for each MKV recording", .{});
        return;
    }
    if (recording_requested and !example_options.vk_video) {
        std.log.err("recording support is not compiled; rebuild with -Dvk_video=true", .{});
        return;
    }

    var first_record_file: ?std.Io.File = null;
    var second_record_file: ?std.Io.File = null;
    var first_record_buffer: [64 * 1024]u8 = undefined;
    var second_record_buffer: [64 * 1024]u8 = undefined;
    var first_record_writer: ?std.Io.File.Writer = null;
    var second_record_writer: ?std.Io.File.Writer = null;
    if (app_options.first_record_path) |path| {
        first_record_file = try std.Io.Dir.cwd().createFile(init.io, path, .{});
        first_record_writer = first_record_file.?.writer(init.io, &first_record_buffer);
    }
    defer if (first_record_file) |*file| file.close(init.io);
    if (app_options.second_record_path) |path| {
        second_record_file = try std.Io.Dir.cwd().createFile(init.io, path, .{});
        second_record_writer = second_record_file.?.writer(init.io, &second_record_buffer);
    }
    defer if (second_record_file) |*file| file.close(init.io);
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

    const low_instance = try loader.loadInstanceApi(@ptrFromInt(@intFromEnum(instance.handle)));
    var renderer = Renderer.init(gpa, instance, low_instance, context.backendKind() != .offscreen, recording_requested) catch |err| {
        if (recording_requested) {
            std.log.err("no device can render and encode H.264: {s}", .{@errorName(err)});
            return;
        }
        return err;
    };
    if (recording_requested) try renderer.initVideo();
    defer renderer.deinit();
    const first_window = try context.createWindow(.{
        .title = "low Vulkan — coral triangle",
        .size = .{ .width = 640, .height = 480 },
    });
    const second_window = try context.createWindow(.{
        .title = "low Vulkan — cyan triangle",
        .size = .{ .width = 520, .height = 400 },
    });
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
    if (first_record_writer) |*writer| first.?.startRecording(init.io, &writer.interface, recordingFileFormat(app_options.first_record_path.?), app_options.record_fps, app_options.record_bitrate, app_options.record_gop) catch |err| {
        std.log.err("first stream could not start: {s}", .{@errorName(err)});
    };
    if (second_record_writer) |*writer| second.?.startRecording(init.io, &writer.interface, recordingFileFormat(app_options.second_record_path.?), app_options.record_fps, app_options.record_bitrate, app_options.record_gop) catch |err| {
        std.log.err("second stream could not start: {s}", .{@errorName(err)});
    };

    var previous = std.Io.Timestamp.now(std.Options.debug_io, .awake);
    var rendered_frames: u32 = 0;
    const offscreen = context.backendKind() == .offscreen;
    const frame_limit: ?u32 = app_options.frames orelse if (offscreen) @as(u32, 10) else null;
    if (offscreen) try std.Io.Dir.cwd().createDirPath(init.io, "tmp");
    while (first != null or second != null) {
        if (offscreen) try context.nextFrame();
        context.pollEvents();

        const close_first = if (first) |app_window| app_window.window.shouldClose() else false;
        const close_second = if (second) |app_window| app_window.window.shouldClose() else false;
        if (close_first or close_second) {
            // A close event is delivered while polling. Destroy the matching
            // native window only after that dispatch has completed, and wait
            // until its in-flight Vulkan work can no longer reference it.
            try renderer.device.deviceWaitIdle();
            if (close_first) {
                if (first) |*app_window| {
                    try app_window.stopRecording();
                    app_window.deinit();
                }
                first = null;
            }
            if (close_second) {
                if (second) |*app_window| {
                    try app_window.stopRecording();
                    app_window.deinit();
                }
                second = null;
            }
            if (first == null and second == null) break;
        }

        const now = std.Io.Timestamp.now(std.Options.debug_io, .awake);
        const dt: f32 = @min(0.05, @as(f32, @floatFromInt(now.nanoseconds - previous.nanoseconds)) / 1_000_000_000);
        previous = now;
        if (first) |*app_window| {
            app_window.update(dt);
            var path_buffer: [64]u8 = undefined;
            const path = if (offscreen) try std.fmt.bufPrint(&path_buffer, "tmp/first-{d:0>4}.bmp", .{rendered_frames + 1}) else null;
            try app_window.draw(&renderer, init.io, path);
        }
        if (second) |*app_window| {
            app_window.update(dt);
            var path_buffer: [64]u8 = undefined;
            const path = if (offscreen) try std.fmt.bufPrint(&path_buffer, "tmp/second-{d:0>4}.bmp", .{rendered_frames + 1}) else null;
            try app_window.draw(&renderer, init.io, path);
        }
        rendered_frames += 1;
        if (app_options.restart_recording_at) |restart_frame| {
            if (rendered_frames == restart_frame) {
                if (first_record_writer) |*writer| if (first) |*app_window| {
                    try app_window.stopRecording();
                    try app_window.startRecording(init.io, &writer.interface, recordingFileFormat(app_options.first_record_path.?), app_options.record_fps, app_options.record_bitrate, app_options.record_gop);
                };
                if (second_record_writer) |*writer| if (second) |*app_window| {
                    try app_window.stopRecording();
                    try app_window.startRecording(init.io, &writer.interface, recordingFileFormat(app_options.second_record_path.?), app_options.record_fps, app_options.record_bitrate, app_options.record_gop);
                };
            }
        }
        if (frame_limit) |limit| {
            if (rendered_frames == limit) {
                if (first) |app_window| app_window.window.setShouldClose(true);
                if (second) |app_window| app_window.window.setShouldClose(true);
            }
        }
    }
    try renderer.device.deviceWaitIdle();
}

fn findDevice(gpa: std.mem.Allocator, instance: vk.InstanceProxy, low_instance: *const low.vulkan.Instance, recording: bool) !DeviceSelection {
    const physical_devices = try instance.enumeratePhysicalDevicesAlloc(gpa);
    defer gpa.free(physical_devices);
    for (physical_devices) |physical_device| {
        const version: vk.Version = @bitCast(instance.getPhysicalDeviceProperties(physical_device).api_version);
        if (version.major < 1 or (version.major == 1 and version.minor < 3)) continue;

        const families = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(physical_device, gpa);
        defer gpa.free(families);
        for (families, 0..) |family, index| {
            if (!family.queue_flags.graphics_bit) continue;
            if (recording) {
                if (comptime !example_options.vk_video) return error.VideoRecordingNotCompiled;
                const support = try video.queryH264Support(.{
                    .instance = low_instance,
                    .physical_device = lowPhysicalDevice(physical_device),
                    .extent = .{ .width = 640, .height = 480 },
                    .allocator = gpa,
                });
                if (!support.available) continue;
                std.log.info("H.264 encode: profile {s}, level {s}, coded extent {d}x{d}, queue family {d}", .{
                    @tagName(support.profile),
                    @tagName(support.max_level),
                    support.coded_extent.width,
                    support.coded_extent.height,
                    support.encode_queue_family.?,
                });
                return .{
                    .physical_device = physical_device,
                    .graphics_queue_family = @intCast(index),
                    .encode_queue_family = support.encode_queue_family,
                };
            }
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

const AppOptions = struct {
    backend: low.BackendRequest = .auto,
    first_record_path: ?[]const u8 = null,
    second_record_path: ?[]const u8 = null,
    record_fps: u32 = 60,
    record_bitrate: u32 = 12_000_000,
    record_gop: u32 = 60,
    frames: ?u32 = null,
    restart_recording_at: ?u32 = null,
};

fn parseOptions(args: []const [:0]const u8) !AppOptions {
    var result: AppOptions = .{};
    var backend_selected = false;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--x11") or std.mem.eql(u8, arg, "--wayland") or std.mem.eql(u8, arg, "--offscreen")) {
            if (backend_selected) return error.ConflictingBackendArguments;
            result.backend = if (std.mem.eql(u8, arg, "--x11")) .x11 else if (std.mem.eql(u8, arg, "--wayland")) .wayland else .offscreen;
            backend_selected = true;
        } else if (std.mem.eql(u8, arg, "--record")) {
            index += 1;
            if (index == args.len) return error.MissingArgumentValue;
            result.first_record_path = args[index];
        } else if (std.mem.eql(u8, arg, "--record-second")) {
            index += 1;
            if (index == args.len) return error.MissingArgumentValue;
            result.second_record_path = args[index];
        } else if (std.mem.eql(u8, arg, "--record-fps")) {
            index += 1;
            if (index == args.len) return error.MissingArgumentValue;
            result.record_fps = try std.fmt.parseInt(u32, args[index], 10);
            if (result.record_fps == 0) return error.InvalidFrameRate;
        } else if (std.mem.eql(u8, arg, "--record-bitrate")) {
            index += 1;
            if (index == args.len) return error.MissingArgumentValue;
            result.record_bitrate = try std.fmt.parseInt(u32, args[index], 10);
            if (result.record_bitrate == 0) return error.InvalidBitrate;
        } else if (std.mem.eql(u8, arg, "--record-gop")) {
            index += 1;
            if (index == args.len) return error.MissingArgumentValue;
            result.record_gop = try std.fmt.parseInt(u32, args[index], 10);
            if (result.record_gop == 0 or result.record_gop > 32_768) return error.InvalidGopSize;
        } else if (std.mem.eql(u8, arg, "--frames")) {
            index += 1;
            if (index == args.len) return error.MissingArgumentValue;
            result.frames = try std.fmt.parseInt(u32, args[index], 10);
            if (result.frames.? == 0) return error.InvalidFrameCount;
        } else if (std.mem.eql(u8, arg, "--restart-recording-at")) {
            index += 1;
            if (index == args.len) return error.MissingArgumentValue;
            result.restart_recording_at = try std.fmt.parseInt(u32, args[index], 10);
            if (result.restart_recording_at.? == 0) return error.InvalidFrameCount;
        } else {
            return error.UnknownArgument;
        }
    }
    return result;
}

fn recordingFileFormat(path: []const u8) RecordingFileFormat {
    return if (std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".mkv")) .mkv else .h264;
}

fn onMouseButton(window: *low.Window, button: low.MouseButton, action: low.Action, _: low.Modifiers) void {
    if (button != .left or action != .press) return;
    const self: *AppWindow = @ptrCast(@alignCast(window.getUserData() orelse return));
    self.velocity = .{ -self.velocity[0], -self.velocity[1] };
    self.color = .{ self.color[1], self.color[2], self.color[0] };
}
