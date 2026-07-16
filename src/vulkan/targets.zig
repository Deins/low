//! Optional Vulkan render-target helpers.
//!
//! This module uses low's small runtime Vulkan ABI directly. Applications can
//! keep using any Vulkan binding for their own rendering commands.
const std = @import("std");
const vk = @import("api.zig");
const Vulkan = @import("../vulkan.zig");
const runtime = @import("../internal/runtime.zig");
const recording_submit = @import("recording_submit.zig");
const build_options = @import("build_options");
const log = std.log.scoped(.low);
const Video = if (build_options.vk_video) @import("video.zig") else struct {
    pub const SelectedVideoFormat = opaque {};
    pub const VideoDevice = opaque {};
    pub const VideoRecorder = struct {};
    pub const RecordingOptions = void;
    pub const RecordingStatus = void;
};
const Window = runtime.Window;

pub const RecordingRateLimit = recording_submit.RateLimit;
pub const RecordingFrameOptions = recording_submit.RecordingOptions;
pub const SubmitOptions = recording_submit.SubmitOptions;

/// Preferred render-target formats, ordered from highest precision to widest
/// presentation support.
pub const default_color_formats: []const vk.Format = &.{
    vk.format.a2b10g10r10_unorm_pack32,
    vk.format.a2r10g10b10_unorm_pack32,
    vk.format.b8g8r8a8_unorm,
};

/// The result of selecting a physical device with the caller's Vulkan binding.
///
/// `Vk` is intentionally supplied by the caller: low does not impose a
/// particular generated Vulkan binding on applications.
pub fn DeviceSelection(comptime Vk: type) type {
    return struct {
        physical_device: Vk.PhysicalDevice,
        graphics_queue_family: u32,
        encode_queue_family: ?u32 = null,
        selected_video_format: ?Video.SelectedVideoFormat = null,
    };
}

/// Owns an instance and the generated binding's dispatch wrapper.
pub fn InstanceResources(comptime Vk: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        handle: Vk.Instance,
        wrapper: *Vk.InstanceWrapper,
        instance: Vk.InstanceProxy,

        pub fn deinit(self: *Self) void {
            self.instance.destroyInstance(null);
            self.allocator.destroy(self.wrapper);
            self.* = undefined;
        }
    };
}

/// Creates an instance and loads the caller's generated dispatch wrapper.
/// The loader remains owned by the caller and must outlive the returned
/// resources.
pub fn createInstance(
    comptime Vk: type,
    allocator: std.mem.Allocator,
    base: anytype,
    get_instance_proc_addr: anytype,
    application_info: anytype,
    extensions: []const [*:0]const u8,
) !InstanceResources(Vk) {
    const instance_info = Vk.InstanceCreateInfo{
        .p_application_info = &application_info,
        .enabled_extension_count = @intCast(extensions.len),
        .pp_enabled_extension_names = extensions.ptr,
    };
    const handle = try base.createInstance(&instance_info, null);
    const wrapper = try allocator.create(Vk.InstanceWrapper);
    errdefer allocator.destroy(wrapper);
    wrapper.* = Vk.InstanceWrapper.load(handle, get_instance_proc_addr);
    return .{
        .allocator = allocator,
        .handle = handle,
        .wrapper = wrapper,
        .instance = Vk.InstanceProxy.init(handle, wrapper),
    };
}

/// Owns a logical device, its generated dispatch wrapper, and low's ABI
/// device view. Queue requirements from Vulkan Video are translated into the
/// caller's generated binding so bindings remain interchangeable.
pub fn DeviceResources(comptime Vk: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        wrapper: *Vk.DeviceWrapper,
        device: Vk.DeviceProxy,
        low_device: Vulkan.Device,
        graphics_queue: Vk.Queue,
        encode_queue: Vk.Queue,

        pub fn deinit(self: *Self) void {
            self.device.destroyDevice(null);
            self.allocator.destroy(self.wrapper);
            self.* = undefined;
        }
    };
}

/// Creates a logical device for a previous `findDevice` result.
pub fn createDevice(
    comptime Vk: type,
    allocator: std.mem.Allocator,
    instance: anytype,
    low_instance: *const Vulkan.Instance,
    selection: DeviceSelection(Vk),
    features: anytype,
    extensions: []const [*:0]const u8,
) !DeviceResources(Vk) {
    const queue_priority = [_]f32{1.0};
    var queue_infos: [2]Vk.DeviceQueueCreateInfo = undefined;
    queue_infos[0] = .{
        .queue_family_index = selection.graphics_queue_family,
        .queue_count = 1,
        .p_queue_priorities = &queue_priority,
    };
    var queue_info_count: u32 = 1;
    if (build_options.vk_video) {
        if (selection.selected_video_format) |selected| {
            var requirements = try selected.deviceRequirements(.{
                .allocator = allocator,
                .graphics_queue_family = selection.graphics_queue_family,
                .queue_priority = 1.0,
            });
            defer requirements.deinit();
            queue_info_count = @intCast(requirements.queue_create_infos.len);
            for (requirements.queue_create_infos, 0..) |requirement, index| {
                queue_infos[index] = .{
                    .queue_family_index = requirement.queue_family_index,
                    .queue_count = 1,
                    .p_queue_priorities = &queue_priority,
                };
            }
        }
    }

    const device_info = Vk.DeviceCreateInfo{
        .p_next = @ptrCast(features),
        .queue_create_info_count = queue_info_count,
        .p_queue_create_infos = &queue_infos,
        .enabled_extension_count = @intCast(extensions.len),
        .pp_enabled_extension_names = extensions.ptr,
    };
    const handle = try instance.createDevice(selection.physical_device, &device_info, null);
    const wrapper = try allocator.create(Vk.DeviceWrapper);
    errdefer allocator.destroy(wrapper);
    wrapper.* = Vk.DeviceWrapper.load(handle, instance.wrapper.dispatch.vkGetDeviceProcAddr.?);
    const device = Vk.DeviceProxy.init(handle, wrapper);
    errdefer device.destroyDevice(null);
    const low_device = try Vulkan.Device.init(low_instance, Vulkan.toDevice(handle));
    return .{
        .allocator = allocator,
        .wrapper = wrapper,
        .device = device,
        .low_device = low_device,
        .graphics_queue = device.getDeviceQueue(selection.graphics_queue_family, 0),
        .encode_queue = device.getDeviceQueue(selection.encode_queue_family orelse selection.graphics_queue_family, 0),
    };
}

/// Selects a Vulkan 1.3 physical device with a graphics queue and, when a
/// surface is supplied, presentation support. If video recording is enabled,
/// the first device supporting the requested codec policy is selected too.
///
/// The generated Vulkan binding is passed as `Vk` so the returned handles and
/// structures remain native to the application's binding.
pub fn findDevice(
    comptime Vk: type,
    allocator: std.mem.Allocator,
    instance: anytype,
    low_instance: *const Vulkan.Instance,
    presentation_surface: ?vk.SurfaceKHR,
    recording: anytype,
) !DeviceSelection(Vk) {
    const physical_devices = try instance.enumeratePhysicalDevicesAlloc(allocator);
    defer allocator.free(physical_devices);

    for (physical_devices) |physical_device| {
        const version: Vk.Version = @bitCast(instance.getPhysicalDeviceProperties(physical_device).api_version);
        if (version.major < 1 or (version.major == 1 and version.minor < 3)) continue;

        var features_13 = Vk.PhysicalDeviceVulkan13Features{};
        var features_2 = Vk.PhysicalDeviceFeatures2{ .p_next = @ptrCast(&features_13), .features = .{} };
        instance.getPhysicalDeviceFeatures2(physical_device, &features_2);
        if (features_13.synchronization_2 != .true or features_13.dynamic_rendering != .true) continue;

        const families = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(physical_device, allocator);
        defer allocator.free(families);

        var graphics_queue_family: ?u32 = null;
        for (families, 0..) |family, index| {
            if (!family.queue_flags.graphics_bit) continue;
            if (presentation_surface) |surface| {
                if (try low_instance.getPhysicalDeviceSurfaceSupportKHR(
                    Vulkan.toPhysicalDevice(physical_device),
                    @intCast(index),
                    surface,
                ) != vk.TRUE) continue;
            }
            graphics_queue_family = @intCast(index);
            break;
        }
        const graphics_family = graphics_queue_family orelse continue;

        var selection = DeviceSelection(Vk){
            .physical_device = physical_device,
            .graphics_queue_family = graphics_family,
        };
        if (build_options.vk_video) {
            if (recording.enabled()) {
                const selected = try Video.selectVideoFormat(.{
                    .instance = low_instance,
                    .physical_device = Vulkan.toPhysicalDevice(physical_device),
                    .extent = .{ .width = 640, .height = 480 },
                    .allocator = allocator,
                }, recording) orelse continue;
                selection.encode_queue_family = selected.encodeQueueFamily();
                selection.selected_video_format = selected;
            }
        }
        return selection;
    }
    return error.NoVulkan13PresentDevice;
}

/// Presentation preferences used by the three standard vsync policies.
const vsync_on_present_modes: []const vk.PresentModeKHR = &[_]vk.PresentModeKHR{
    vk.present_mode.fifo_khr,
};
const vsync_off_present_modes: []const vk.PresentModeKHR = &[_]vk.PresentModeKHR{
    vk.present_mode.immediate_khr,
    vk.present_mode.mailbox_khr,
    vk.present_mode.fifo_relaxed_khr,
    vk.present_mode.fifo_khr,
};
const relaxed_vsync_present_modes: []const vk.PresentModeKHR = &[_]vk.PresentModeKHR{
    vk.present_mode.fifo_relaxed_khr,
    vk.present_mode.fifo_khr,
};

pub const VSync = enum {
    on,
    off,
    relaxed,
};

fn formatName(format: vk.Format) []const u8 {
    return switch (format) {
        vk.format.a2b10g10r10_unorm_pack32 => "a2b10g10r10_unorm_pack32",
        vk.format.a2r10g10b10_unorm_pack32 => "a2r10g10b10_unorm_pack32",
        vk.format.b8g8r8a8_unorm => "b8g8r8a8_unorm",
        else => "unknown",
    };
}

/// Selects the first requested format advertised by a presentation surface.
/// A surface advertising VK_FORMAT_UNDEFINED accepts the first requested
/// format, using the color space supplied by that surface entry.
pub fn chooseSurfaceFormat(available: []const vk.SurfaceFormatKHR, desired: []const vk.Format) ?vk.SurfaceFormatKHR {
    for (desired) |wanted| {
        for (available) |candidate| {
            if (candidate.format == wanted) return candidate;
        }
    }
    for (available) |candidate| {
        if (candidate.format == vk.format.undefined and desired.len != 0) {
            return .{ .format = desired[0], .color_space = candidate.color_space };
        }
    }
    return null;
}

/// Queries and selects a surface format in one step.
fn chooseSurfaceFormatAlloc(
    instance: *const Vulkan.Instance,
    physical_device: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
    allocator: std.mem.Allocator,
    desired: []const vk.Format,
) !vk.SurfaceFormatKHR {
    const available = try instance.getPhysicalDeviceSurfaceFormatsAllocKHR(physical_device, surface, allocator);
    defer allocator.free(available);
    return chooseSurfaceFormat(available, desired) orelse error.UnsupportedSurfaceFormat;
}

/// Selects a render format for a presentation or offscreen target before the
/// target is created, which is useful when creating a format-specialized
/// graphics pipeline.
pub fn chooseColorFormat(
    instance: *const Vulkan.Instance,
    physical_device: vk.PhysicalDevice,
    surface: ?vk.SurfaceKHR,
    allocator: std.mem.Allocator,
    desired: []const vk.Format,
) !vk.Format {
    if (surface) |handle| return (try chooseSurfaceFormatAlloc(instance, physical_device, handle, allocator, desired)).format;
    return chooseOffscreenFormat(instance, physical_device, desired) orelse error.UnsupportedSurfaceFormat;
}

/// Selects the first requested format that supports this target's offscreen
/// image usage.
pub fn chooseOffscreenFormat(instance: *const Vulkan.Instance, physical_device: vk.PhysicalDevice, desired: []const vk.Format) ?vk.Format {
    return chooseOffscreenFormatForUsage(instance, physical_device, desired, true);
}

fn chooseOffscreenFormatForUsage(instance: *const Vulkan.Instance, physical_device: vk.PhysicalDevice, desired: []const vk.Format, transfer_source: bool) ?vk.Format {
    const required = vk.format_feature.color_attachment_bit | if (transfer_source) vk.format_feature.transfer_src_bit else 0;
    for (desired) |wanted| {
        const properties = instance.getPhysicalDeviceFormatProperties(physical_device, wanted);
        if (properties.optimal_tiling_features & required == required) return wanted;
    }
    return null;
}

pub const MemoryAllocator = struct {
    context: ?*anyopaque = null,
    allocate_and_bind: *const fn (?*anyopaque, vk.Image, vk.MemoryRequirements) anyerror!vk.DeviceMemory,
    free: *const fn (?*anyopaque, vk.DeviceMemory) void,
};

/// Optional queue used when presentation is not supported by the graphics
/// queue family.
pub const PresentQueue = struct {
    queue: vk.Queue,
    family: u32,
};

/// Vulkan resources shared by one or more render targets.
///
/// The context must remain at a stable address, and all of its fields must
/// remain valid, for as long as any `RenderTarget` created from it exists.
pub const RenderContext = struct {
    instance: Vulkan.Instance,
    physical_device: vk.PhysicalDevice,
    device: Vulkan.Device,
    graphics_queue: vk.Queue,
    graphics_queue_family: u32,
    present_queue: ?PresentQueue = null,
    command_pool: vk.CommandPool,
    video_device: ?*Video.VideoDevice = null,

    pub fn init(
        instance: Vulkan.Instance,
        physical_device: vk.PhysicalDevice,
        device: Vulkan.Device,
        graphics_queue: vk.Queue,
        graphics_queue_family: u32,
        command_pool: vk.CommandPool,
    ) @This() {
        return .{
            .instance = instance,
            .physical_device = physical_device,
            .device = device,
            .graphics_queue = graphics_queue,
            .graphics_queue_family = graphics_queue_family,
            .command_pool = command_pool,
        };
    }
};

/// A Vulkan render target associated with one low window.
pub const RenderTarget = struct {
    const Self = @This();

    pub const Options = struct {
        window: *Window,
        context: *const RenderContext,
        /// An existing surface owned by the caller. When omitted, the target
        /// creates and owns a surface from the low window handles.
        surface: ?vk.SurfaceKHR = null,
        /// An already-created low surface whose ownership moves to this
        /// target. This supports device selection before target creation
        /// without leaving surface lifetime management to the application.
        presentation_surface: ?Vulkan.PresentationSurface = null,
        /// Render-target formats in preference order. The first format
        /// supported by the surface or offscreen device is selected.
        color_formats: []const vk.Format = default_color_formats,
        /// Use `.off` for unsynchronized presentation or `.relaxed` to allow
        /// tearing only when late. FIFO is the final fallback. Vsync defaults
        /// to on.
        vsync: VSync = .on,
        /// Advanced override for the presentation-mode preference order.
        present_modes: ?[]const vk.PresentModeKHR = null,
        /// Enable transfer-source usage for screenshot readback. Recording
        /// enables the required usage independently when Vulkan Video is built.
        readback: bool = false,
        frames_in_flight: u32 = 2,
        memory_allocator: ?MemoryAllocator = null,
    };

    pub const Error = error{
        InvalidFramesInFlight,
        InvalidImageCount,
        UnsupportedSurfaceFormat,
        UnsupportedSurfaceUsage,
        UnsupportedPresentMode,
        QueueFamilyCannotPresent,
        FrameAlreadyAcquired,
        FrameAlreadyFinished,
        FrameSkipped,
        FrameOutOfDate,
        ConflictingSurfaceOwnership,
        PresentationSurfaceUnsupported,
        ReadbackUnavailable,
        VideoDeviceUnavailable,
    };

    pub const Readback = struct {
        allocator: std.mem.Allocator,
        pixels: []u8,
        extent: vk.Extent2D,
        /// Pixels are tightly packed BGRA8, from the top-left row downward.
        format: enum { bgra8_unorm } = .bgra8_unorm,

        pub fn deinit(self: *Readback) void {
            self.allocator.free(self.pixels);
            self.* = undefined;
        }

        /// Writes the readback as an uncompressed 32-bit BMP. The BGRA8 pixel
        /// data can be written directly; a negative height preserves its
        /// top-to-bottom row order.
        pub fn writeBmp(self: *const Readback, io: std.Io, path: []const u8) !void {
            var header: [54]u8 = @splat(0);
            header[0] = 'B';
            header[1] = 'M';
            std.mem.writeInt(u32, header[2..6], @intCast(header.len + self.pixels.len), .little);
            std.mem.writeInt(u32, header[10..14], header.len, .little);
            std.mem.writeInt(u32, header[14..18], 40, .little);
            std.mem.writeInt(i32, header[18..22], @intCast(self.extent.width), .little);
            std.mem.writeInt(i32, header[22..26], -@as(i32, @intCast(self.extent.height)), .little);
            std.mem.writeInt(u16, header[26..28], 1, .little);
            std.mem.writeInt(u16, header[28..30], 32, .little);
            std.mem.writeInt(u32, header[34..38], @intCast(self.pixels.len), .little);

            var file = try std.Io.Dir.cwd().createFile(io, path, .{});
            defer file.close(io);
            try file.writeStreamingAll(io, &header);
            try file.writeStreamingAll(io, self.pixels);
        }
    };

    pub const Frame = struct {
        index: u32,
        image: vk.Image,
        view: vk.ImageView,
        extent: vk.Extent2D,
        command_buffer: vk.CommandBuffer,
        submit_fn: *const fn (?*anyopaque, SubmitOptions) anyerror!void,
        readback_fn: *const fn (?*anyopaque, std.mem.Allocator, SubmitOptions) anyerror!Readback,
        abort_fn: *const fn (?*anyopaque) void,
        state: ?*anyopaque,

        /// Converts this frame's low ABI command-buffer handle to the
        /// application's generated Vulkan binding type.
        pub inline fn commandBuffer(self: *const Frame, comptime CommandBuffer: type) CommandBuffer {
            return Vulkan.fromCommandBuffer(CommandBuffer, self.command_buffer);
        }

        /// Converts this frame's low ABI image-view handle to the
        /// application's generated Vulkan binding type.
        pub inline fn imageView(self: *const Frame, comptime ImageView: type) ImageView {
            return Vulkan.fromImageView(ImageView, self.view);
        }

        /// Submits and presents this frame. Recording options are ignored when
        /// no recording is active.
        pub fn submitAndPresent(self: *Frame, options: SubmitOptions) !void {
            const state = self.state orelse return error.FrameAlreadyFinished;
            try self.submit_fn(state, options);
            self.state = null;
        }

        /// Submits the frame and waits until its tightly packed pixels have
        /// been copied into allocator-owned CPU memory. Onscreen frames are
        /// presented after the copy.
        pub fn submitAndReadback(self: *Frame, allocator: std.mem.Allocator, options: SubmitOptions) !Readback {
            const state = self.state orelse return error.FrameAlreadyFinished;
            const result = try self.readback_fn(state, allocator, options);
            self.state = null;
            return result;
        }

        pub fn abort(self: *Frame) void {
            if (self.state) |state| self.abort_fn(state);
            self.state = null;
        }
    };

    allocator: std.mem.Allocator,
    state: *anyopaque,
    deinit_fn: *const fn (*anyopaque) void,
    acquire_fn: *const fn (*anyopaque) anyerror!Frame,
    frame_command_buffer_fn: *const fn (*anyopaque) vk.CommandBuffer,
    color_format_fn: *const fn (*anyopaque) vk.Format,
    set_present_modes_fn: *const fn (*anyopaque, []const vk.PresentModeKHR) anyerror!void,
    begin_recording_fn: *const fn (*anyopaque, *const anyopaque) anyerror!void,
    end_recording_fn: *const fn (*anyopaque) anyerror!void,
    recording_status_fn: *const fn (*anyopaque, *anyopaque) void,
    is_recording_fn: *const fn (*anyopaque) bool,
    release_recording_fn: *const fn (*anyopaque) void,
    recording_extent_fn: *const fn (*anyopaque, *anyopaque) void,

    pub fn init(allocator: std.mem.Allocator, options: Options) !Self {
        if (options.frames_in_flight == 0) return error.InvalidFramesInFlight;

        const State = struct {
            const StateSelf = @This();
            const Slot = struct {
                command_buffer: vk.CommandBuffer = null,
                image_available: vk.Semaphore = 0,
                fence: vk.Fence = 0,
                readback_buffer: vk.Buffer = 0,
                readback_memory: vk.DeviceMemory = 0,
                readback_capacity: u64 = 0,
            };

            allocator: std.mem.Allocator,
            window: *Window,
            instance: *const Vulkan.Instance,
            physical_device: vk.PhysicalDevice,
            device: *const Vulkan.Device,
            graphics_queue: vk.Queue,
            graphics_queue_family: u32,
            present_queue: vk.Queue,
            present_queue_family: u32,
            command_pool: vk.CommandPool,
            color_format: vk.Format,
            color_formats: []vk.Format,
            present_modes: []vk.PresentModeKHR,
            readback_enabled: bool,
            memory_allocator: ?MemoryAllocator,
            memory_properties: vk.PhysicalDeviceMemoryProperties = undefined,
            frames_in_flight: u32,
            slots: []Slot = &.{},
            surface: vk.SurfaceKHR = 0,
            owned_surface: ?Vulkan.PresentationSurface = null,
            swapchain: vk.SwapchainKHR = 0,
            swapchain_images: []vk.Image = &.{},
            swapchain_views: []vk.ImageView = &.{},
            swapchain_layouts: []vk.ImageLayout = &.{},
            swapchain_render_finished: []vk.Semaphore = &.{},
            extent: vk.Extent2D = .{ .width = 0, .height = 0 },
            recreate_pending: bool = false,
            ring: ?OffscreenImageRing = null,
            next_slot: u32 = 0,
            active_slot: ?u32 = null,
            active_image: ?u32 = null,
            has_acquired: bool = false,
            submitted: bool = false,
            video_device: ?*Video.VideoDevice = null,
            video_device_attached: bool = false,
            recorder: ?Video.VideoRecorder = null,

            fn deinitOpaque(ptr: *anyopaque) void {
                const self: *StateSelf = @ptrCast(@alignCast(ptr));
                self.device.deviceWaitIdle() catch {};
                if (comptime build_options.vk_video) {
                    if (self.recorder) |*recorder| recorder.deinit();
                    if (self.video_device_attached) self.video_device.?.detachTarget();
                }
                self.destroyTarget();
                self.destroySync();
                if (self.owned_surface) |*surface| surface.deinit();
                if (self.color_formats.len != 0) self.allocator.free(self.color_formats);
                if (self.present_modes.len != 0) self.allocator.free(self.present_modes);
                self.allocator.destroy(self);
            }

            fn acquireOpaque(ptr: *anyopaque) anyerror!Frame {
                const self: *StateSelf = @ptrCast(@alignCast(ptr));
                return self.acquireFrame(ptr);
            }

            fn frameCommandBufferOpaque(ptr: *anyopaque) vk.CommandBuffer {
                const self: *StateSelf = @ptrCast(@alignCast(ptr));
                std.debug.assert(!self.has_acquired);
                return self.slots[0].command_buffer;
            }

            fn colorFormatOpaque(ptr: *anyopaque) vk.Format {
                const self: *StateSelf = @ptrCast(@alignCast(ptr));
                return self.color_format;
            }

            fn setPresentModesOpaque(ptr: *anyopaque, modes: []const vk.PresentModeKHR) anyerror!void {
                const self: *StateSelf = @ptrCast(@alignCast(ptr));
                if (self.surface == 0) return;
                if (self.active_slot != null) return error.FrameAlreadyAcquired;
                const replacement = try self.allocator.dupe(vk.PresentModeKHR, modes);
                self.allocator.free(self.present_modes);
                self.present_modes = replacement;
                self.recreate_pending = true;
            }

            fn submitOpaque(ptr: ?*anyopaque, submit_options: SubmitOptions) anyerror!void {
                const self: *StateSelf = @ptrCast(@alignCast(ptr.?));
                _ = try self.submitFrame(null, submit_options);
            }

            fn readbackOpaque(ptr: ?*anyopaque, output_allocator: std.mem.Allocator, submit_options: SubmitOptions) anyerror!Readback {
                const self: *StateSelf = @ptrCast(@alignCast(ptr.?));
                return (try self.submitFrame(output_allocator, submit_options)).?;
            }

            fn abortOpaque(ptr: ?*anyopaque) void {
                const self: *StateSelf = @ptrCast(@alignCast(ptr.?));
                self.abortFrame();
            }

            fn beginRecordingOpaque(ptr: *anyopaque, options_ptr: *const anyopaque) anyerror!void {
                if (comptime !build_options.vk_video) return error.VideoDeviceUnavailable;
                const self: *StateSelf = @ptrCast(@alignCast(ptr));
                if (self.active_slot != null) return error.FrameAlreadyAcquired;
                const video_device = self.video_device orelse return error.VideoDeviceUnavailable;
                try self.ensureTarget();
                if (self.recorder == null) self.recorder = Video.VideoRecorder.init(
                    self.allocator,
                    video_device,
                    self.graphics_queue_family,
                    self.frames_in_flight,
                    self.color_format,
                );
                const recording_options: *const Video.RecordingOptions = @ptrCast(@alignCast(options_ptr));
                try self.recorder.?.begin(self.extent, recording_options.*);
            }

            fn endRecordingOpaque(ptr: *anyopaque) anyerror!void {
                if (comptime !build_options.vk_video) return error.VideoDeviceUnavailable;
                const self: *StateSelf = @ptrCast(@alignCast(ptr));
                if (self.active_slot != null) return error.FrameAlreadyAcquired;
                if (self.recorder) |*recorder| try recorder.end();
            }

            fn recordingStatusOpaque(ptr: *anyopaque, output: *anyopaque) void {
                if (comptime build_options.vk_video) {
                    const self: *StateSelf = @ptrCast(@alignCast(ptr));
                    const result: *?Video.RecordingStatus = @ptrCast(@alignCast(output));
                    result.* = if (self.recorder) |*recorder| recorder.status() else null;
                }
            }

            fn isRecordingOpaque(ptr: *anyopaque) bool {
                if (comptime !build_options.vk_video) return false;
                const self: *StateSelf = @ptrCast(@alignCast(ptr));
                return if (self.recorder) |*recorder| recorder.isRecording() else false;
            }

            fn releaseRecordingOpaque(ptr: *anyopaque) void {
                if (comptime build_options.vk_video) {
                    const self: *StateSelf = @ptrCast(@alignCast(ptr));
                    if (self.recorder) |*recorder| recorder.releaseResources();
                }
            }

            fn recordingExtentOpaque(ptr: *anyopaque, output: *anyopaque) void {
                if (comptime build_options.vk_video) {
                    const self: *StateSelf = @ptrCast(@alignCast(ptr));
                    const result: *?vk.Extent2D = @ptrCast(@alignCast(output));
                    result.* = if (self.recorder) |*recorder| if (recorder.codedExtent()) |extent|
                        .{ .width = extent.width, .height = extent.height }
                    else
                        null else null;
                }
            }

            fn allocateDefaultMemory(context: ?*anyopaque, _: vk.Image, requirements: vk.MemoryRequirements) anyerror!vk.DeviceMemory {
                const self: *StateSelf = @ptrCast(@alignCast(context orelse return error.MissingMemoryAllocator));
                var fallback: ?u32 = null;
                for (0..self.memory_properties.memory_type_count) |index| {
                    const memory_type: u32 = @intCast(index);
                    if (requirements.memory_type_bits & (@as(u32, 1) << @intCast(index)) == 0) continue;
                    fallback = memory_type;
                    if (self.memory_properties.memory_types[index].property_flags & vk.memory_property.device_local_bit != 0) {
                        return self.device.allocateMemory(&.{
                            .s_type = .memory_allocate_info,
                            .p_next = null,
                            .allocation_size = requirements.size,
                            .memory_type_index = memory_type,
                        });
                    }
                }
                const memory_type = fallback orelse return error.NoCompatibleMemoryType;
                return self.device.allocateMemory(&.{
                    .s_type = .memory_allocate_info,
                    .p_next = null,
                    .allocation_size = requirements.size,
                    .memory_type_index = memory_type,
                });
            }

            fn freeDefaultMemory(context: ?*anyopaque, memory: vk.DeviceMemory) void {
                const self: *StateSelf = @ptrCast(@alignCast(context orelse return));
                self.device.freeMemory(memory);
            }

            fn acquireFrame(self: *StateSelf, ptr: *anyopaque) anyerror!Frame {
                if (self.active_slot != null) return error.FrameAlreadyAcquired;
                try self.ensureTarget();

                const slot_index = self.next_slot;
                self.next_slot = (self.next_slot + 1) % self.frames_in_flight;
                const slot = &self.slots[slot_index];
                _ = try self.device.waitForFences(&.{slot.fence}, true, std.math.maxInt(u64));

                var image_index: u32 = slot_index;
                if (self.surface != 0) {
                    const acquired = (self.device.acquireNextImageKHR(
                        self.swapchain,
                        std.math.maxInt(u64),
                        slot.image_available,
                        0,
                    ) catch |err| switch (err) {
                        error.OutOfDateKHR => {
                            self.recreate_pending = true;
                            return error.FrameOutOfDate;
                        },
                        else => return err,
                    }) orelse return error.FrameSkipped;
                    image_index = acquired.image_index;
                    if (acquired.result == .suboptimal_khr) self.recreate_pending = true;
                }

                try self.device.resetCommandBuffer(slot.command_buffer);
                try self.device.beginCommandBuffer(slot.command_buffer);

                const image_handle = self.image(image_index);
                const old_layout = self.imageLayout(image_index);
                const source_stage: vk.PipelineStageFlags = switch (old_layout) {
                    .undefined => vk.pipeline_stage.top_of_pipe_bit,
                    .transfer_src_optimal => vk.pipeline_stage.transfer_bit,
                    .present_src_khr => vk.pipeline_stage.bottom_of_pipe_bit,
                    else => vk.pipeline_stage.color_attachment_output_bit,
                };
                const source_access: vk.AccessFlags = switch (old_layout) {
                    .undefined, .present_src_khr => 0,
                    .transfer_src_optimal => vk.access.transfer_read_bit,
                    else => vk.access.color_attachment_write_bit,
                };
                transitionImage(self.device, slot.command_buffer, image_handle, old_layout, .color_attachment_optimal, source_stage, source_access, vk.pipeline_stage.color_attachment_output_bit, vk.access.color_attachment_write_bit);

                self.active_slot = slot_index;
                self.active_image = image_index;
                self.has_acquired = true;
                self.submitted = false;
                return .{
                    .index = image_index,
                    .image = image_handle,
                    .view = self.imageView(image_index),
                    .extent = self.extent,
                    .command_buffer = slot.command_buffer,
                    .submit_fn = submitOpaque,
                    .readback_fn = readbackOpaque,
                    .abort_fn = abortOpaque,
                    .state = ptr,
                };
            }

            fn submitFrame(self: *StateSelf, readback_allocator: ?std.mem.Allocator, submit_options: SubmitOptions) anyerror!?Readback {
                const slot_index = self.active_slot orelse return error.FrameAlreadyFinished;
                const image_index = self.active_image orelse return error.FrameAlreadyFinished;
                const slot = &self.slots[slot_index];
                const image_handle = self.image(image_index);
                if (readback_allocator != null) {
                    if (!self.readback_enabled) return error.ReadbackUnavailable;
                    if (!readbackFormatSupported(self.color_format)) return error.ReadbackUnavailable;
                    try self.ensureReadbackBuffer(slot, @as(u64, self.extent.width) * self.extent.height * 4);
                }
                const wants_recording = if (comptime build_options.vk_video)
                    if (self.recorder) |*recorder| recorder.isRecording() else false
                else
                    false;
                const recording_frame = if (comptime build_options.vk_video)
                    if (wants_recording) try self.recorder.?.selectFrame(submit_options.recording) else null
                else
                    null;
                const copy_image = readback_allocator != null or recording_frame != null;
                const post_render_layout: vk.ImageLayout = if (copy_image) .transfer_src_optimal else if (self.surface == 0) .color_attachment_optimal else .present_src_khr;
                transitionImage(self.device, slot.command_buffer, image_handle, .color_attachment_optimal, post_render_layout, vk.pipeline_stage.color_attachment_output_bit, vk.access.color_attachment_write_bit, if (post_render_layout == .transfer_src_optimal) vk.pipeline_stage.transfer_bit else vk.pipeline_stage.bottom_of_pipe_bit, if (post_render_layout == .transfer_src_optimal) vk.access.transfer_read_bit else 0);
                var recorder_prepared = false;
                var recorder_signal: vk.Semaphore = 0;
                if (comptime build_options.vk_video) {
                    if (recording_frame) |selected| {
                        if (try self.recorder.?.prepareFrame(slot.command_buffer, image_handle, self.extent, selected)) |prepared| {
                            recorder_prepared = true;
                            recorder_signal = prepared.signal_semaphore;
                        }
                    }
                }
                if (readback_allocator != null) {
                    self.device.cmdCopyImageToBuffer(slot.command_buffer, image_handle, .transfer_src_optimal, slot.readback_buffer, &.{
                        .buffer_offset = 0,
                        .buffer_row_length = 0,
                        .buffer_image_height = 0,
                        .image_subresource = .{ .aspect_mask = vk.image_aspect.color_bit, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
                        .image_offset = .{ .x = 0, .y = 0, .z = 0 },
                        .image_extent = .{ .width = self.extent.width, .height = self.extent.height, .depth = 1 },
                    });
                    self.device.cmdBufferPipelineBarrier(slot.command_buffer, vk.pipeline_stage.transfer_bit, vk.pipeline_stage.host_bit, &.{
                        .s_type = .buffer_memory_barrier,
                        .p_next = null,
                        .src_access_mask = vk.access.transfer_write_bit,
                        .dst_access_mask = vk.access.host_read_bit,
                        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                        .buffer = slot.readback_buffer,
                        .offset = 0,
                        .size = @as(u64, self.extent.width) * self.extent.height * 4,
                    });
                }
                if (self.surface != 0 and post_render_layout == .transfer_src_optimal) transitionImage(self.device, slot.command_buffer, image_handle, .transfer_src_optimal, .present_src_khr, vk.pipeline_stage.transfer_bit, vk.access.transfer_read_bit, vk.pipeline_stage.bottom_of_pipe_bit, 0);
                self.device.endCommandBuffer(slot.command_buffer) catch |err| {
                    if (comptime build_options.vk_video) if (recorder_prepared) self.recorder.?.abortPrepared(err);
                    return err;
                };

                const command_buffers = [_]vk.CommandBuffer{slot.command_buffer};
                var wait_semaphores: [1]vk.Semaphore = undefined;
                var wait_stages: [1]vk.PipelineStageFlags = undefined;
                var signal_semaphores: [2]vk.Semaphore = undefined;
                var submit_info = vk.SubmitInfo{
                    .s_type = .submit_info,
                    .p_next = null,
                    .wait_semaphore_count = 0,
                    .p_wait_semaphores = null,
                    .p_wait_dst_stage_mask = null,
                    .command_buffer_count = 1,
                    .p_command_buffers = command_buffers[0..].ptr,
                    .signal_semaphore_count = 0,
                    .p_signal_semaphores = null,
                };
                if (self.surface != 0) {
                    wait_semaphores[0] = slot.image_available;
                    wait_stages[0] = vk.pipeline_stage.color_attachment_output_bit;
                    // Presentation waits can outlive the graphics frame slot.
                    // Index this semaphore by acquired swapchain image so it
                    // is only reused after that image has been acquired again.
                    signal_semaphores[0] = self.swapchain_render_finished[image_index];
                    submit_info.wait_semaphore_count = 1;
                    submit_info.p_wait_semaphores = wait_semaphores[0..].ptr;
                    submit_info.p_wait_dst_stage_mask = wait_stages[0..].ptr;
                    submit_info.signal_semaphore_count = 1;
                    submit_info.p_signal_semaphores = signal_semaphores[0..].ptr;
                }
                if (recorder_prepared) {
                    const index: usize = submit_info.signal_semaphore_count;
                    signal_semaphores[index] = recorder_signal;
                    submit_info.signal_semaphore_count += 1;
                    submit_info.p_signal_semaphores = signal_semaphores[0..].ptr;
                }
                self.device.resetFences(&.{slot.fence}) catch |err| {
                    if (comptime build_options.vk_video) if (recorder_prepared) self.recorder.?.abortPrepared(err);
                    return err;
                };
                self.device.queueSubmit(self.graphics_queue, &submit_info, slot.fence) catch |err| {
                    if (comptime build_options.vk_video) if (recorder_prepared) self.recorder.?.abortPrepared(err);
                    return err;
                };
                self.submitted = true;
                self.setImageLayout(image_index, if (self.surface != 0) .present_src_khr else post_render_layout);
                self.active_slot = null;

                var present_error: ?anyerror = null;
                if (self.surface != 0) {
                    self.window.requestFrame();
                    const swapchains = [_]vk.SwapchainKHR{self.swapchain};
                    const indices = [_]u32{image_index};
                    const present = self.device.queuePresentKHR(self.present_queue, &.{
                        .s_type = .present_info_khr,
                        .p_next = null,
                        .wait_semaphore_count = 1,
                        .p_wait_semaphores = signal_semaphores[0..].ptr,
                        .swapchain_count = 1,
                        .p_swapchains = swapchains[0..].ptr,
                        .p_image_indices = indices[0..].ptr,
                        .p_results = null,
                    }) catch |err| switch (err) {
                        error.OutOfDateKHR => blk: {
                            self.window.cancelFrameRequest();
                            self.recreate_pending = true;
                            present_error = error.FrameOutOfDate;
                            break :blk .success;
                        },
                        else => blk: {
                            self.window.cancelFrameRequest();
                            present_error = err;
                            break :blk .success;
                        },
                    };
                    if (present == .suboptimal_khr) self.recreate_pending = true;
                }
                if (comptime build_options.vk_video) if (recorder_prepared) try self.recorder.?.submitPrepared();
                if (present_error) |err| return err;
                if (readback_allocator) |output_allocator| {
                    _ = try self.device.waitForFences(&.{slot.fence}, true, std.math.maxInt(u64));
                    const len: usize = @intCast(@as(u64, self.extent.width) * self.extent.height * 4);
                    const pixels = try output_allocator.alloc(u8, len);
                    errdefer output_allocator.free(pixels);
                    const mapped = try self.device.mapMemory(slot.readback_memory, 0, len);
                    defer self.device.unmapMemory(slot.readback_memory);
                    const source = @as([*]const u8, @ptrCast(mapped))[0..len];
                    convertReadback(self.color_format, source, pixels);
                    return .{ .allocator = output_allocator, .pixels = pixels, .extent = self.extent };
                }
                return null;
            }

            fn ensureReadbackBuffer(self: *StateSelf, slot: *Slot, size: u64) !void {
                if (slot.readback_capacity >= size) return;
                if (slot.readback_buffer != 0) self.device.destroyBuffer(slot.readback_buffer);
                if (slot.readback_memory != 0) self.device.freeMemory(slot.readback_memory);
                slot.readback_buffer = 0;
                slot.readback_memory = 0;
                slot.readback_capacity = 0;
                slot.readback_buffer = try self.device.createBuffer(&.{ .s_type = .buffer_create_info, .p_next = null, .flags = 0, .size = size, .usage = vk.buffer_usage.transfer_dst_bit, .sharing_mode = .exclusive, .queue_family_index_count = 0, .p_queue_family_indices = null });
                errdefer {
                    self.device.destroyBuffer(slot.readback_buffer);
                    slot.readback_buffer = 0;
                }
                const requirements = self.device.getBufferMemoryRequirements(slot.readback_buffer);
                var memory_type: ?u32 = null;
                for (0..self.memory_properties.memory_type_count) |index| {
                    if (requirements.memory_type_bits & (@as(u32, 1) << @intCast(index)) == 0) continue;
                    const wanted = vk.memory_property.host_visible_bit | vk.memory_property.host_coherent_bit;
                    if (self.memory_properties.memory_types[index].property_flags & wanted == wanted) {
                        memory_type = @intCast(index);
                        break;
                    }
                }
                slot.readback_memory = try self.device.allocateMemory(&.{ .s_type = .memory_allocate_info, .p_next = null, .allocation_size = requirements.size, .memory_type_index = memory_type orelse return error.NoCompatibleMemoryType });
                errdefer {
                    self.device.freeMemory(slot.readback_memory);
                    slot.readback_memory = 0;
                }
                try self.device.bindBufferMemory(slot.readback_buffer, slot.readback_memory, 0);
                slot.readback_capacity = size;
            }

            fn abortFrame(self: *StateSelf) void {
                const slot_index = self.active_slot orelse return;
                if (!self.submitted) self.device.resetCommandBuffer(self.slots[slot_index].command_buffer) catch {};
                self.active_slot = null;
                self.active_image = null;
                self.submitted = false;
            }

            fn ensureTarget(self: *StateSelf) anyerror!void {
                const size = self.window.getFramebufferSize();
                if (size.width <= 0 or size.height <= 0) return error.FrameSkipped;
                const wanted = vk.Extent2D{
                    .width = @intCast(size.width),
                    .height = @intCast(size.height),
                };
                if (self.surface == 0) {
                    if (self.ring == null) {
                        const memory = self.memory_allocator.?;
                        self.ring = try OffscreenImageRing.init(.{
                            .allocator = self.allocator,
                            .device = self.device,
                            .memory = memory,
                            .extent = wanted,
                            .format = self.color_format,
                            .image_count = self.frames_in_flight,
                            .usage = vk.image_usage.color_attachment_bit | if (self.transferSourceRequired()) vk.image_usage.transfer_src_bit else 0,
                        });
                        self.extent = wanted;
                    } else if (self.extent.width != wanted.width or self.extent.height != wanted.height) {
                        try self.device.deviceWaitIdle();
                        if (comptime build_options.vk_video) if (self.recorder) |*recorder| try recorder.noticeResize(wanted);
                        try self.ring.?.resize(wanted);
                        self.extent = wanted;
                    }
                    return;
                }

                const capabilities = try self.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(self.physical_device, self.surface);
                const wanted_extent = chooseExtent(capabilities, wanted);
                if (wanted_extent.width == 0 or wanted_extent.height == 0) return error.FrameSkipped;
                if (self.swapchain == 0 or self.recreate_pending or self.extent.width != wanted_extent.width or self.extent.height != wanted_extent.height) {
                    if (self.swapchain != 0) try self.device.deviceWaitIdle();
                    if (comptime build_options.vk_video) if (self.recorder) |*recorder| try recorder.noticeResize(wanted_extent);
                    self.destroySwapchain();
                    try self.createSwapchain(capabilities, wanted_extent);
                }
            }

            fn createSwapchain(self: *StateSelf, capabilities: vk.SurfaceCapabilitiesKHR, wanted_extent: vk.Extent2D) anyerror!void {
                const formats = try self.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(self.physical_device, self.surface, self.allocator);
                defer self.allocator.free(formats);
                const selected_format = chooseSurfaceFormat(formats, self.color_formats) orelse return error.UnsupportedSurfaceFormat;
                self.color_format = selected_format.format;
                const transfer_src_required = self.transferSourceRequired();
                if (transfer_src_required and capabilities.supported_usage_flags & vk.image_usage.transfer_src_bit == 0) {
                    return error.UnsupportedSurfaceUsage;
                }
                const present_modes = try self.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(self.physical_device, self.surface, self.allocator);
                defer self.allocator.free(present_modes);
                const present_mode = choosePresentMode(present_modes, self.present_modes) orelse return error.UnsupportedPresentMode;
                var image_count = capabilities.min_image_count + 1;
                if (capabilities.max_image_count != 0) image_count = @min(image_count, capabilities.max_image_count);
                const concurrent = self.present_queue_family != self.graphics_queue_family;
                const queue_family_indices = [_]u32{ self.graphics_queue_family, self.present_queue_family };
                self.swapchain = try self.device.createSwapchainKHR(&.{
                    .s_type = .swapchain_create_info_khr,
                    .p_next = null,
                    .flags = 0,
                    .surface = self.surface,
                    .min_image_count = image_count,
                    .image_format = selected_format.format,
                    .image_color_space = selected_format.color_space,
                    .image_extent = wanted_extent,
                    .image_array_layers = 1,
                    .image_usage = vk.image_usage.color_attachment_bit | if (transfer_src_required) vk.image_usage.transfer_src_bit else 0,
                    .image_sharing_mode = if (concurrent) .concurrent else .exclusive,
                    .queue_family_index_count = if (concurrent) 2 else 0,
                    .p_queue_family_indices = if (concurrent) queue_family_indices[0..].ptr else null,
                    .pre_transform = capabilities.current_transform,
                    .composite_alpha = chooseCompositeAlpha(capabilities.supported_composite_alpha),
                    .present_mode = present_mode,
                    .clipped = vk.TRUE,
                    .old_swapchain = 0,
                });
                errdefer self.destroySwapchain();
                self.swapchain_images = try self.device.getSwapchainImagesAllocKHR(self.swapchain, self.allocator);
                self.swapchain_views = try self.allocator.alloc(vk.ImageView, self.swapchain_images.len);
                self.swapchain_layouts = try self.allocator.alloc(vk.ImageLayout, self.swapchain_images.len);
                self.swapchain_render_finished = try self.allocator.alloc(vk.Semaphore, self.swapchain_images.len);
                @memset(self.swapchain_views, 0);
                @memset(self.swapchain_layouts, .undefined);
                @memset(self.swapchain_render_finished, 0);
                for (self.swapchain_render_finished) |*semaphore| semaphore.* = try self.device.createSemaphore();
                for (self.swapchain_images, self.swapchain_views) |swap_image, *view| {
                    view.* = try self.device.createImageView(&.{
                        .s_type = .image_view_create_info,
                        .p_next = null,
                        .flags = 0,
                        .image = swap_image,
                        .view_type = .@"2d",
                        .format = selected_format.format,
                        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
                        .subresource_range = .{
                            .aspect_mask = vk.image_aspect.color_bit,
                            .base_mip_level = 0,
                            .level_count = 1,
                            .base_array_layer = 0,
                            .layer_count = 1,
                        },
                    });
                }
                self.extent = wanted_extent;
                self.recreate_pending = false;
            }

            fn transferSourceRequired(self: *const StateSelf) bool {
                return self.readback_enabled or self.video_device != null;
            }

            fn destroyTarget(self: *StateSelf) void {
                if (self.ring) |*ring| ring.deinit();
                self.ring = null;
                self.destroySwapchain();
            }

            fn destroySwapchain(self: *StateSelf) void {
                for (self.swapchain_views) |view| if (view != 0) self.device.destroyImageView(view);
                for (self.swapchain_render_finished) |semaphore| if (semaphore != 0) self.device.destroySemaphore(semaphore);
                if (self.swapchain_views.len != 0) self.allocator.free(self.swapchain_views);
                if (self.swapchain_images.len != 0) self.allocator.free(self.swapchain_images);
                if (self.swapchain_layouts.len != 0) self.allocator.free(self.swapchain_layouts);
                if (self.swapchain_render_finished.len != 0) self.allocator.free(self.swapchain_render_finished);
                if (self.swapchain != 0) self.device.destroySwapchainKHR(self.swapchain);
                self.swapchain_views = &.{};
                self.swapchain_images = &.{};
                self.swapchain_layouts = &.{};
                self.swapchain_render_finished = &.{};
                self.swapchain = 0;
                self.extent = .{ .width = 0, .height = 0 };
            }

            fn createSync(self: *StateSelf) anyerror!void {
                self.slots = try self.allocator.alloc(Slot, self.frames_in_flight);
                @memset(self.slots, .{});
                errdefer self.destroySync();
                const command_buffers = try self.allocator.alloc(vk.CommandBuffer, self.frames_in_flight);
                defer self.allocator.free(command_buffers);
                try self.device.allocateCommandBuffers(&.{
                    .s_type = .command_buffer_allocate_info,
                    .p_next = null,
                    .command_pool = self.command_pool,
                    .level = .primary,
                    .command_buffer_count = self.frames_in_flight,
                }, command_buffers);
                for (self.slots, command_buffers) |*slot, command_buffer| {
                    slot.command_buffer = command_buffer;
                    slot.image_available = try self.device.createSemaphore();
                    slot.fence = try self.device.createFence(true);
                }
            }

            fn destroySync(self: *StateSelf) void {
                for (self.slots) |slot| {
                    if (slot.readback_buffer != 0) self.device.destroyBuffer(slot.readback_buffer);
                    if (slot.readback_memory != 0) self.device.freeMemory(slot.readback_memory);
                    if (slot.fence != 0) self.device.destroyFence(slot.fence);
                    if (slot.image_available != 0) self.device.destroySemaphore(slot.image_available);
                }
                for (self.slots) |slot| if (slot.command_buffer != null) {
                    self.device.freeCommandBuffers(self.command_pool, &.{slot.command_buffer});
                };
                if (self.slots.len != 0) self.allocator.free(self.slots);
                self.slots = &.{};
            }

            fn image(self: *const StateSelf, index: u32) vk.Image {
                if (self.surface != 0) return self.swapchain_images[index];
                return self.ring.?.images[index];
            }

            fn imageView(self: *const StateSelf, index: u32) vk.ImageView {
                if (self.surface != 0) return self.swapchain_views[index];
                return self.ring.?.views[index];
            }

            fn imageLayout(self: *const StateSelf, index: u32) vk.ImageLayout {
                if (self.surface != 0) return self.swapchain_layouts[index];
                return self.ring.?.layouts[index];
            }

            fn setImageLayout(self: *StateSelf, index: u32, layout: vk.ImageLayout) void {
                if (self.surface != 0) self.swapchain_layouts[index] = layout else self.ring.?.layouts[index] = layout;
            }
        };

        const backend_kind = options.window.ctx.backendKind();
        if (options.surface != null and options.presentation_surface != null) unreachable;
        if (backend_kind == .offscreen and options.presentation_surface != null) unreachable;

        const state = try allocator.create(State);
        const present_queue = options.context.present_queue orelse PresentQueue{
            .queue = options.context.graphics_queue,
            .family = options.context.graphics_queue_family,
        };
        state.* = .{
            .allocator = allocator,
            .window = options.window,
            .instance = &options.context.instance,
            .physical_device = options.context.physical_device,
            .device = &options.context.device,
            .graphics_queue = options.context.graphics_queue,
            .graphics_queue_family = options.context.graphics_queue_family,
            .present_queue = present_queue.queue,
            .present_queue_family = present_queue.family,
            .command_pool = options.context.command_pool,
            .color_format = 0,
            .color_formats = &.{},
            .present_modes = &.{},
            .readback_enabled = options.readback,
            .memory_allocator = options.memory_allocator,
            .frames_in_flight = options.frames_in_flight,
            .video_device = if (comptime build_options.vk_video) options.context.video_device else null,
        };
        errdefer State.deinitOpaque(@ptrCast(state));
        state.color_formats = try allocator.dupe(vk.Format, options.color_formats);
        if (backend_kind != .offscreen) {
            const present_modes = options.present_modes orelse switch (options.vsync) {
                .on => vsync_on_present_modes,
                .off => vsync_off_present_modes,
                .relaxed => relaxed_vsync_present_modes,
            };
            state.present_modes = try allocator.dupe(vk.PresentModeKHR, present_modes);
        }

        if (comptime build_options.vk_video) if (state.video_device) |video_device| {
            video_device.attachTarget();
            state.video_device_attached = true;
        };

        state.memory_properties = state.instance.getPhysicalDeviceMemoryProperties(state.physical_device);
        if (backend_kind != .offscreen) {
            if (options.presentation_surface) |surface| {
                state.owned_surface = surface;
                state.surface = surface.handle;
            } else if (options.surface) |surface| {
                state.surface = surface;
            } else {
                state.owned_surface = try Vulkan.PresentationSurface.init(
                    state.instance,
                    options.window.ctx.backendKind(),
                    options.window.nativeDisplay(),
                    options.window.nativeSurface(),
                );
                state.surface = state.owned_surface.?.handle;
            }
            if (try state.instance.getPhysicalDeviceSurfaceSupportKHR(state.physical_device, state.present_queue_family, state.surface) != vk.TRUE) return error.QueueFamilyCannotPresent;
            const formats = try state.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(state.physical_device, state.surface, allocator);
            defer allocator.free(formats);
            state.color_format = (chooseSurfaceFormat(formats, state.color_formats) orelse return error.UnsupportedSurfaceFormat).format;
        } else {
            state.color_format = chooseOffscreenFormatForUsage(state.instance, state.physical_device, state.color_formats, state.transferSourceRequired()) orelse return error.UnsupportedSurfaceFormat;
            if (state.memory_allocator == null) state.memory_allocator = .{
                .context = state,
                .allocate_and_bind = State.allocateDefaultMemory,
                .free = State.freeDefaultMemory,
            };
        }
        const physical_device_id: usize = if (state.physical_device) |physical_device| @intFromPtr(physical_device) else 0;
        log.debug("selected Vulkan target: device=0x{x}, backend={s}, queue_family={d}, format={s}", .{
            physical_device_id,
            @tagName(backend_kind),
            options.context.graphics_queue_family,
            formatName(state.color_format),
        });
        try state.createSync();
        if (backend_kind == .offscreen) try state.ensureTarget();
        return .{
            .allocator = allocator,
            .state = state,
            .deinit_fn = State.deinitOpaque,
            .acquire_fn = State.acquireOpaque,
            .frame_command_buffer_fn = State.frameCommandBufferOpaque,
            .color_format_fn = State.colorFormatOpaque,
            .set_present_modes_fn = State.setPresentModesOpaque,
            .begin_recording_fn = State.beginRecordingOpaque,
            .end_recording_fn = State.endRecordingOpaque,
            .recording_status_fn = State.recordingStatusOpaque,
            .is_recording_fn = State.isRecordingOpaque,
            .release_recording_fn = State.releaseRecordingOpaque,
            .recording_extent_fn = State.recordingExtentOpaque,
        };
    }

    pub fn deinit(self: *Self) void {
        self.deinit_fn(self.state);
        self.* = undefined;
    }

    pub fn acquire(self: *Self) !Frame {
        return self.acquire_fn(self.state);
    }

    /// Returns a reusable frame command buffer before the first acquisition.
    /// This is useful for setup APIs such as GPU profilers that need a command
    /// buffer at initialization.
    pub fn frameCommandBuffer(self: *const Self) vk.CommandBuffer {
        return self.frame_command_buffer_fn(self.state);
    }

    /// Converts the setup command buffer to the application's generated
    /// Vulkan binding type.
    pub inline fn frameCommandBufferAs(self: *const Self, comptime CommandBuffer: type) CommandBuffer {
        return Vulkan.fromCommandBuffer(CommandBuffer, self.frameCommandBuffer());
    }

    pub fn colorFormat(self: *const Self) vk.Format {
        return self.color_format_fn(self.state);
    }

    /// Selects one of low's standard presentation policies. This is a no-op
    /// for offscreen targets.
    pub fn setVSync(self: *Self, vsync: VSync) !void {
        return self.setPresentModes(switch (vsync) {
            .on => vsync_on_present_modes,
            .off => vsync_off_present_modes,
            .relaxed => relaxed_vsync_present_modes,
        });
    }

    /// Updates preferred presentation modes. This is a no-op for offscreen targets.
    pub fn setPresentModes(self: *Self, modes: []const vk.PresentModeKHR) !void {
        return self.set_present_modes_fn(self.state, modes);
    }

    /// Starts encoding subsequent submitted frames.
    ///
    /// The simplest form is `try target.beginRecording(.{ .io = io,
    /// .writer = writer });`. Use `.format = .mkv` for variable-rate
    /// timing or resize handling. Finish with `endRecording` before closing
    /// the writer; use `recordingStatus` to observe asynchronous failures.
    pub fn beginRecording(self: *Self, options: Video.RecordingOptions) !void {
        if (comptime !build_options.vk_video) @compileError("enable -Dvk_video=true");
        return self.begin_recording_fn(self.state, @ptrCast(&options));
    }

    /// Stops recording, waits for submitted frames to be encoded, and writes
    /// the remaining Matroska data. The writer remains owned by the caller.
    pub fn endRecording(self: *Self) !void {
        if (comptime !build_options.vk_video) @compileError("enable -Dvk_video=true");
        return self.end_recording_fn(self.state);
    }

    /// Returns null when inactive, otherwise the current recorder state.
    pub fn recordingStatus(self: *Self) ?Video.RecordingStatus {
        if (comptime !build_options.vk_video) @compileError("enable -Dvk_video=true");
        var result: ?Video.RecordingStatus = null;
        self.recording_status_fn(self.state, @ptrCast(&result));
        return result;
    }

    pub fn isRecording(self: *Self) bool {
        if (comptime !build_options.vk_video) @compileError("enable -Dvk_video=true");
        return self.is_recording_fn(self.state);
    }

    /// Releases cached encoder resources after recording has stopped. This is
    /// optional; resources are also released when the target is deinitialized.
    pub fn releaseRecordingResources(self: *Self) void {
        if (comptime !build_options.vk_video) @compileError("enable -Dvk_video=true");
        self.release_recording_fn(self.state);
    }

    pub fn recordingExtent(self: *Self) ?vk.Extent2D {
        if (comptime !build_options.vk_video) @compileError("enable -Dvk_video=true");
        var result: ?vk.Extent2D = null;
        self.recording_extent_fn(self.state, @ptrCast(&result));
        return result;
    }
};

const OffscreenImageRing = struct {
    const Self = @This();
    pub const Options = struct {
        allocator: std.mem.Allocator,
        device: *const Vulkan.Device,
        memory: MemoryAllocator,
        extent: vk.Extent2D,
        format: vk.Format,
        image_count: u32 = 3,
        usage: vk.ImageUsageFlags = vk.image_usage.color_attachment_bit | vk.image_usage.transfer_src_bit,
    };

    pub const Frame = struct {
        index: u32,
        image: vk.Image,
        view: vk.ImageView,
        extent: vk.Extent2D,
    };

    allocator: std.mem.Allocator,
    device: *const Vulkan.Device,
    memory: MemoryAllocator,
    format: vk.Format,
    extent: vk.Extent2D,
    usage: vk.ImageUsageFlags,
    images: []vk.Image = &.{},
    views: []vk.ImageView = &.{},
    allocations: []vk.DeviceMemory = &.{},
    layouts: []vk.ImageLayout = &.{},
    next_index: u32 = 0,

    pub fn init(options: Options) !Self {
        var self: Self = .{
            .allocator = options.allocator,
            .device = options.device,
            .memory = options.memory,
            .format = options.format,
            .extent = options.extent,
            .usage = options.usage,
        };
        errdefer self.deinit();
        try self.create(options.image_count);
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.destroyResources();
        self.* = undefined;
    }

    pub fn resize(self: *Self, extent: vk.Extent2D) !void {
        const replacement = try Self.init(.{
            .allocator = self.allocator,
            .device = self.device,
            .memory = self.memory,
            .extent = extent,
            .format = self.format,
            .image_count = @intCast(self.images.len),
            .usage = self.usage,
        });
        self.destroyResources();
        self.* = replacement;
    }

    pub fn acquire(self: *Self) Frame {
        const index = self.next_index % @as(u32, @intCast(self.images.len));
        self.next_index +%= 1;
        return .{ .index = index, .image = self.images[index], .view = self.views[index], .extent = self.extent };
    }

    fn create(self: *Self, count: u32) !void {
        if (count == 0) return error.InvalidImageCount;
        errdefer self.destroyResources();
        self.images = try self.allocator.alloc(vk.Image, count);
        self.views = try self.allocator.alloc(vk.ImageView, count);
        self.allocations = try self.allocator.alloc(vk.DeviceMemory, count);
        self.layouts = try self.allocator.alloc(vk.ImageLayout, count);
        @memset(self.images, 0);
        @memset(self.views, 0);
        @memset(self.allocations, 0);
        @memset(self.layouts, .undefined);
        for (self.images, self.views, self.allocations) |*image, *view, *allocation| {
            image.* = try self.device.createImage(&.{
                .s_type = .image_create_info,
                .p_next = null,
                .flags = 0,
                .image_type = .@"2d",
                .format = self.format,
                .extent = .{ .width = self.extent.width, .height = self.extent.height, .depth = 1 },
                .mip_levels = 1,
                .array_layers = 1,
                .samples = vk.sample_count.@"1_bit",
                .tiling = .optimal,
                .usage = self.usage,
                .sharing_mode = .exclusive,
                .queue_family_index_count = 0,
                .p_queue_family_indices = null,
                .initial_layout = .undefined,
            });
            allocation.* = try self.memory.allocate_and_bind(self.memory.context, image.*, self.device.getImageMemoryRequirements(image.*));
            try self.device.bindImageMemory(image.*, allocation.*, 0);
            view.* = try self.device.createImageView(&.{
                .s_type = .image_view_create_info,
                .p_next = null,
                .flags = 0,
                .image = image.*,
                .view_type = .@"2d",
                .format = self.format,
                .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
                .subresource_range = .{
                    .aspect_mask = vk.image_aspect.color_bit,
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
            });
        }
    }

    fn destroyResources(self: *Self) void {
        for (self.views) |view| if (view != 0) self.device.destroyImageView(view);
        for (self.images, self.allocations) |image, allocation| {
            if (image != 0) self.device.destroyImage(image);
            if (allocation != 0) self.memory.free(self.memory.context, allocation);
        }
        if (self.views.len != 0) self.allocator.free(self.views);
        if (self.images.len != 0) self.allocator.free(self.images);
        if (self.allocations.len != 0) self.allocator.free(self.allocations);
        if (self.layouts.len != 0) self.allocator.free(self.layouts);
        self.views = &.{};
        self.images = &.{};
        self.allocations = &.{};
        self.layouts = &.{};
    }
};

fn readbackFormatSupported(format: vk.Format) bool {
    return format == vk.format.b8g8r8a8_unorm or
        format == vk.format.a2b10g10r10_unorm_pack32 or
        format == vk.format.a2r10g10b10_unorm_pack32;
}

fn convertReadback(format: vk.Format, source: []const u8, destination: []u8) void {
    if (format == vk.format.b8g8r8a8_unorm) {
        @memcpy(destination, source);
        return;
    }

    std.debug.assert(source.len == destination.len);
    for (0..source.len / 4) |index| {
        const packed_value = std.mem.readInt(u32, source[index * 4 ..][0..4], .little);
        const r: u32 = if (format == vk.format.a2b10g10r10_unorm_pack32) packed_value & 0x3ff else (packed_value >> 20) & 0x3ff;
        const g: u32 = (packed_value >> 10) & 0x3ff;
        const b: u32 = if (format == vk.format.a2b10g10r10_unorm_pack32) (packed_value >> 20) & 0x3ff else packed_value & 0x3ff;
        const a: u32 = (packed_value >> 30) & 0x3;
        destination[index * 4 + 0] = @intCast((b * 255 + 511) / 1023);
        destination[index * 4 + 1] = @intCast((g * 255 + 511) / 1023);
        destination[index * 4 + 2] = @intCast((r * 255 + 511) / 1023);
        destination[index * 4 + 3] = @intCast((a * 255 + 1) / 3);
    }
}

test "packed 10-bit readback conversion" {
    const packed_value: u32 = 1023 | (512 << 10) | (3 << 30);
    var source: [4]u8 = undefined;
    std.mem.writeInt(u32, &source, packed_value, .little);
    var destination: [4]u8 = undefined;
    convertReadback(vk.format.a2b10g10r10_unorm_pack32, &source, &destination);
    try std.testing.expectEqualSlices(u8, &.{ 0, 128, 255, 255 }, &destination);
}

fn chooseExtent(capabilities: vk.SurfaceCapabilitiesKHR, requested: vk.Extent2D) vk.Extent2D {
    if (capabilities.current_extent.width != std.math.maxInt(u32)) return capabilities.current_extent;
    return .{
        .width = std.math.clamp(requested.width, capabilities.min_image_extent.width, capabilities.max_image_extent.width),
        .height = std.math.clamp(requested.height, capabilities.min_image_extent.height, capabilities.max_image_extent.height),
    };
}

fn chooseCompositeAlpha(supported: vk.CompositeAlphaFlagsKHR) vk.CompositeAlphaFlagsKHR {
    if (supported & vk.composite_alpha.opaque_bit_khr != 0) return vk.composite_alpha.opaque_bit_khr;
    if (supported & vk.composite_alpha.pre_multiplied_bit_khr != 0) return vk.composite_alpha.pre_multiplied_bit_khr;
    if (supported & vk.composite_alpha.post_multiplied_bit_khr != 0) return vk.composite_alpha.post_multiplied_bit_khr;
    return vk.composite_alpha.inherit_bit_khr;
}

fn choosePresentMode(available: []const vk.PresentModeKHR, desired: []const vk.PresentModeKHR) ?vk.PresentModeKHR {
    for (desired) |wanted| {
        for (available) |candidate| {
            if (candidate == wanted) return candidate;
        }
    }
    for (available) |candidate| {
        if (candidate == vk.present_mode.fifo_khr) return candidate;
    }
    return if (available.len != 0) available[0] else null;
}

test "present mode selection honors preference and fifo fallback" {
    const available = [_]vk.PresentModeKHR{
        vk.present_mode.fifo_khr,
        vk.present_mode.mailbox_khr,
    };
    try std.testing.expectEqual(
        vk.present_mode.mailbox_khr,
        choosePresentMode(&available, &.{ vk.present_mode.immediate_khr, vk.present_mode.mailbox_khr }),
    );
    try std.testing.expectEqual(
        vk.present_mode.fifo_khr,
        choosePresentMode(&available, &.{vk.present_mode.immediate_khr}),
    );
    try std.testing.expectEqual(@as(?vk.PresentModeKHR, null), choosePresentMode(&.{}, &.{vk.present_mode.fifo_khr}));
}

test "standard vsync policies preserve their intent" {
    const available = [_]vk.PresentModeKHR{
        vk.present_mode.fifo_khr,
        vk.present_mode.fifo_relaxed_khr,
        vk.present_mode.mailbox_khr,
        vk.present_mode.immediate_khr,
    };
    try std.testing.expectEqual(vk.present_mode.fifo_khr, choosePresentMode(&available, vsync_on_present_modes));
    try std.testing.expectEqual(vk.present_mode.fifo_relaxed_khr, choosePresentMode(&available, relaxed_vsync_present_modes));
    try std.testing.expectEqual(vk.present_mode.immediate_khr, choosePresentMode(&available, vsync_off_present_modes));
}

fn transitionImage(
    device: *const Vulkan.Device,
    command_buffer: vk.CommandBuffer,
    image: vk.Image,
    old_layout: vk.ImageLayout,
    new_layout: vk.ImageLayout,
    src_stage: vk.PipelineStageFlags,
    src_access: vk.AccessFlags,
    dst_stage: vk.PipelineStageFlags,
    dst_access: vk.AccessFlags,
) void {
    const barrier = vk.ImageMemoryBarrier{
        .s_type = .image_memory_barrier,
        .p_next = null,
        .src_access_mask = src_access,
        .dst_access_mask = dst_access,
        .old_layout = old_layout,
        .new_layout = new_layout,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresource_range = .{
            .aspect_mask = vk.image_aspect.color_bit,
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };
    device.cmdPipelineBarrier(command_buffer, src_stage, dst_stage, &barrier);
}
