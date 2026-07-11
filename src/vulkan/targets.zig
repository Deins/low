//! Optional Vulkan render-target helpers.
//!
//! This is deliberately the only module in `low` which knows about Vulkan
//! object types and commands.  The binding is supplied by the caller as the
//! `vk` comptime parameter.
const std = @import("std");

pub fn Api(comptime vk: type) type {
    return struct {
        pub const MemoryAllocator = OffscreenMemoryAllocator(vk);

        /// A Vulkan render target associated with one low window.
        ///
        /// `acquire` begins the returned command buffer and transitions its
        /// image to `color_attachment_optimal`. `submitAndPresent` ends and
        /// submits that buffer, then presents on desktop or leaves the image
        /// in `transfer_src_optimal` for an offscreen consumer. Use
        /// `defer frame.abort()` immediately after acquiring a frame.
        pub const RenderTarget = struct {
            const Self = @This();
            pub const Error = error{
                InvalidFramesInFlight,
                InvalidImageCount,
                UnsupportedSurfaceFormat,
                QueueFamilyCannotPresent,
                FrameAlreadyAcquired,
                FrameAlreadyFinished,
                FrameSkipped,
                FrameOutOfDate,
                DesktopTargetNotImplemented,
                OffscreenAllocatorRequired,
            };

            pub const Frame = struct {
                /// The swapchain image or offscreen ring slot index.
                index: u32,
                image: vk.Image,
                view: vk.ImageView,
                extent: vk.Extent2D,
                command_buffer: vk.CommandBuffer,
                submit_fn: *const fn (?*anyopaque) anyerror!void,
                abort_fn: *const fn (?*anyopaque) void,
                state: ?*anyopaque,

                pub fn submitAndPresent(self: *Frame) !void {
                    const state = self.state orelse return error.FrameAlreadyFinished;
                    try self.submit_fn(state);
                    self.state = null;
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

            /// Creates a desktop swapchain target or an offscreen image ring.
            /// The backend is selected from `options.context.backendKind()`;
            /// offscreen never calls the surface or swapchain Vulkan APIs.
            pub fn init(allocator: std.mem.Allocator, options: anytype) !Self {
                const OptionsType = @TypeOf(options);
                if (!@hasField(OptionsType, "context") or !@hasField(OptionsType, "window")) {
                    @compileError("RenderTarget.init requires context and window");
                }
                if (options.frames_in_flight == 0) return error.InvalidFramesInFlight;

                const Device = @TypeOf(options.device);
                const Instance = @TypeOf(options.instance);
                const Window = @TypeOf(options.window);
                const Ring = OffscreenImageRing(vk, Device);
                const State = struct {
                    const StateSelf = @This();
                    const Slot = struct {
                        command_buffer: vk.CommandBuffer = .null_handle,
                        image_available: vk.Semaphore = .null_handle,
                        render_finished: vk.Semaphore = .null_handle,
                        fence: vk.Fence = .null_handle,
                    };

                    allocator: std.mem.Allocator,
                    window: Window,
                    instance: Instance,
                    physical_device: vk.PhysicalDevice,
                    device: Device,
                    graphics_queue: vk.Queue,
                    graphics_queue_family: u32,
                    command_pool: vk.CommandPool,
                    color_format: vk.Format,
                    memory_allocator: ?MemoryAllocator,
                    frames_in_flight: u32,
                    slots: []Slot = &.{},
                    surface: vk.SurfaceKHR = .null_handle,
                    swapchain: vk.SwapchainKHR = .null_handle,
                    swapchain_images: []vk.Image = &.{},
                    swapchain_views: []vk.ImageView = &.{},
                    swapchain_layouts: []vk.ImageLayout = &.{},
                    extent: vk.Extent2D = .{ .width = 0, .height = 0 },
                    recreate_pending: bool = false,
                    ring: ?Ring = null,
                    next_slot: u32 = 0,
                    active_slot: ?u32 = null,
                    active_image: ?u32 = null,
                    submitted: bool = false,

                    fn deinitOpaque(ptr: *anyopaque) void {
                        const self: *StateSelf = @ptrCast(@alignCast(ptr));
                        // The helper owns all objects created after the
                        // device was supplied. Waiting here makes `deinit`
                        // safe even when the last frame was just submitted.
                        self.device.deviceWaitIdle() catch {};
                        self.destroyTarget();
                        self.destroySync();
                        if (self.surface != .null_handle) {
                            self.instance.destroySurfaceKHR(self.surface, null);
                            self.surface = .null_handle;
                        }
                        self.allocator.destroy(self);
                    }

                    fn acquireOpaque(ptr: *anyopaque) anyerror!Frame {
                        const self: *StateSelf = @ptrCast(@alignCast(ptr));
                        return self.acquireFrame(ptr);
                    }

                    fn submitOpaque(ptr: ?*anyopaque) anyerror!void {
                        const self: *StateSelf = @ptrCast(@alignCast(ptr.?));
                        return self.submitFrame();
                    }

                    fn abortOpaque(ptr: ?*anyopaque) void {
                        const self: *StateSelf = @ptrCast(@alignCast(ptr.?));
                        self.abortFrame();
                    }

                    fn acquireFrame(self: *StateSelf, ptr: *anyopaque) anyerror!Frame {
                        if (self.active_slot != null) return error.FrameAlreadyAcquired;
                        try self.ensureTarget();

                        const slot_index = self.next_slot;
                        self.next_slot = (self.next_slot + 1) % self.frames_in_flight;
                        const slot = &self.slots[slot_index];
                        _ = try self.device.waitForFences(&.{slot.fence}, .true, std.math.maxInt(u64));

                        var image_index: u32 = slot_index;
                        var suboptimal = false;
                        if (self.surface != .null_handle) {
                            const acquired = self.device.acquireNextImageKHR(
                                self.swapchain,
                                std.math.maxInt(u64),
                                slot.image_available,
                                .null_handle,
                            ) catch |err| switch (err) {
                                error.OutOfDateKHR => {
                                    self.recreate_pending = true;
                                    return error.FrameOutOfDate;
                                },
                                else => return err,
                            };
                            if (acquired.result == .timeout or acquired.result == .not_ready) return error.FrameSkipped;
                            image_index = acquired.image_index;
                            suboptimal = acquired.result == .suboptimal_khr;
                            if (suboptimal) self.recreate_pending = true;
                        }

                        try self.device.resetCommandBuffer(slot.command_buffer, .{});
                        try self.device.beginCommandBuffer(slot.command_buffer, &.{
                            .flags = .{ .one_time_submit_bit = true },
                        });

                        const image_handle = self.image(image_index);
                        const old_layout = self.imageLayout(image_index);
                        const source_stage: vk.PipelineStageFlags2 = if (old_layout == .undefined)
                            .{ .top_of_pipe_bit = true }
                        else
                            .{ .color_attachment_output_bit = true };
                        const source_access: vk.AccessFlags2 = if (old_layout == .undefined)
                            .{}
                        else
                            .{ .color_attachment_write_bit = true };
                        transitionImage(vk, self.device, slot.command_buffer, image_handle, old_layout, .color_attachment_optimal, source_stage, source_access, .{ .color_attachment_output_bit = true }, .{ .color_attachment_write_bit = true });

                        self.active_slot = slot_index;
                        self.active_image = image_index;
                        self.submitted = false;
                        return .{
                            .index = image_index,
                            .image = image_handle,
                            .view = self.imageView(image_index),
                            .extent = self.extent,
                            .command_buffer = slot.command_buffer,
                            .submit_fn = submitOpaque,
                            .abort_fn = abortOpaque,
                            .state = ptr,
                        };
                    }

                    fn submitFrame(self: *StateSelf) anyerror!void {
                        const slot_index = self.active_slot orelse return error.FrameAlreadyFinished;
                        const image_index = self.active_image orelse return error.FrameAlreadyFinished;
                        const slot = &self.slots[slot_index];
                        const image_handle = self.image(image_index);
                        const final_layout: vk.ImageLayout = if (self.surface != .null_handle) .present_src_khr else .transfer_src_optimal;
                        transitionImage(vk, self.device, slot.command_buffer, image_handle, .color_attachment_optimal, final_layout, .{ .color_attachment_output_bit = true }, .{ .color_attachment_write_bit = true }, .{}, .{});
                        try self.device.endCommandBuffer(slot.command_buffer);

                        const command_info = [_]vk.CommandBufferSubmitInfo{.{
                            .command_buffer = slot.command_buffer,
                            .device_mask = 0,
                        }};
                        var wait_info: [1]vk.SemaphoreSubmitInfo = undefined;
                        var signal_info: [1]vk.SemaphoreSubmitInfo = undefined;
                        var submit_info = vk.SubmitInfo2{
                            .command_buffer_info_count = command_info.len,
                            .p_command_buffer_infos = &command_info,
                        };
                        if (self.surface != .null_handle) {
                            wait_info[0] = .{
                                .semaphore = slot.image_available,
                                .value = 0,
                                .stage_mask = .{ .color_attachment_output_bit = true },
                                .device_index = 0,
                            };
                            signal_info[0] = .{
                                .semaphore = slot.render_finished,
                                .value = 0,
                                .stage_mask = .{ .all_graphics_bit = true },
                                .device_index = 0,
                            };
                            submit_info.wait_semaphore_info_count = wait_info.len;
                            submit_info.p_wait_semaphore_infos = &wait_info;
                            submit_info.signal_semaphore_info_count = signal_info.len;
                            submit_info.p_signal_semaphore_infos = &signal_info;
                        }
                        try self.device.queueSubmit2(self.graphics_queue, &.{submit_info}, slot.fence);
                        self.submitted = true;
                        self.setImageLayout(image_index, final_layout);
                        self.active_slot = null;

                        if (self.surface != .null_handle) {
                            const swapchains = [_]vk.SwapchainKHR{self.swapchain};
                            const indices = [_]u32{image_index};
                            const present = self.device.queuePresentKHR(self.graphics_queue, &.{
                                .wait_semaphore_count = 1,
                                .p_wait_semaphores = &.{slot.render_finished},
                                .swapchain_count = 1,
                                .p_swapchains = &swapchains,
                                .p_image_indices = &indices,
                            }) catch |err| switch (err) {
                                error.OutOfDateKHR => {
                                    self.recreate_pending = true;
                                    return error.FrameOutOfDate;
                                },
                                else => return err,
                            };
                            if (present == .suboptimal_khr) self.recreate_pending = true;
                        }
                    }

                    fn abortFrame(self: *StateSelf) void {
                        const slot_index = self.active_slot orelse return;
                        if (!self.submitted) self.device.resetCommandBuffer(self.slots[slot_index].command_buffer, .{}) catch {};
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
                        if (self.surface == .null_handle) {
                            if (self.ring == null) {
                                const memory = self.memory_allocator orelse return error.OffscreenAllocatorRequired;
                                self.ring = try Ring.init(.{
                                    .allocator = self.allocator,
                                    .device = self.device,
                                    .memory = memory,
                                    .extent = wanted,
                                    .format = self.color_format,
                                    .image_count = self.frames_in_flight,
                                });
                                self.extent = wanted;
                            } else if (self.extent.width != wanted.width or self.extent.height != wanted.height) {
                                try self.device.deviceWaitIdle();
                                try self.ring.?.resize(wanted);
                                self.extent = wanted;
                            }
                            return;
                        }

                        const capabilities = try self.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(self.physical_device, self.surface);
                        const wanted_extent = chooseExtent(vk, capabilities, wanted);
                        if (wanted_extent.width == 0 or wanted_extent.height == 0) return error.FrameSkipped;
                        if (self.swapchain == .null_handle or self.recreate_pending or self.extent.width != wanted_extent.width or self.extent.height != wanted_extent.height) {
                            if (self.swapchain != .null_handle) try self.device.deviceWaitIdle();
                            self.destroySwapchain();
                            try self.createSwapchain(capabilities, wanted_extent);
                        }
                    }

                    fn createSwapchain(self: *StateSelf, capabilities: vk.SurfaceCapabilitiesKHR, wanted_extent: vk.Extent2D) anyerror!void {
                        const formats = try self.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(self.physical_device, self.surface, self.allocator);
                        defer self.allocator.free(formats);
                        var format: ?vk.SurfaceFormatKHR = null;
                        for (formats) |candidate| {
                            if (candidate.format == self.color_format) {
                                format = candidate;
                                break;
                            }
                        }
                        const selected_format = format orelse return error.UnsupportedSurfaceFormat;
                        var image_count = capabilities.min_image_count + 1;
                        if (capabilities.max_image_count != 0) image_count = @min(image_count, capabilities.max_image_count);
                        self.swapchain = try self.device.createSwapchainKHR(&.{
                            .surface = self.surface,
                            .min_image_count = image_count,
                            .image_format = selected_format.format,
                            .image_color_space = selected_format.color_space,
                            .image_extent = wanted_extent,
                            .image_array_layers = 1,
                            .image_usage = .{ .color_attachment_bit = true },
                            .image_sharing_mode = .exclusive,
                            .pre_transform = capabilities.current_transform,
                            .composite_alpha = chooseCompositeAlpha(vk, capabilities.supported_composite_alpha),
                            .present_mode = .fifo_khr,
                            .clipped = .true,
                        }, null);
                        errdefer self.destroySwapchain();
                        self.swapchain_images = try self.device.getSwapchainImagesAllocKHR(self.swapchain, self.allocator);
                        self.swapchain_views = try self.allocator.alloc(vk.ImageView, self.swapchain_images.len);
                        self.swapchain_layouts = try self.allocator.alloc(vk.ImageLayout, self.swapchain_images.len);
                        @memset(self.swapchain_views, .null_handle);
                        @memset(self.swapchain_layouts, .undefined);
                        for (self.swapchain_images, self.swapchain_views) |swap_image, *view| {
                            view.* = try self.device.createImageView(&.{
                                .image = swap_image,
                                .view_type = .@"2d",
                                .format = selected_format.format,
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
                        self.extent = wanted_extent;
                        self.recreate_pending = false;
                    }

                    fn destroyTarget(self: *StateSelf) void {
                        if (self.ring) |*ring| ring.deinit();
                        self.ring = null;
                        self.destroySwapchain();
                    }

                    fn destroySwapchain(self: *StateSelf) void {
                        for (self.swapchain_views) |view| if (view != .null_handle) self.device.destroyImageView(view, null);
                        if (self.swapchain_views.len != 0) self.allocator.free(self.swapchain_views);
                        if (self.swapchain_images.len != 0) self.allocator.free(self.swapchain_images);
                        if (self.swapchain_layouts.len != 0) self.allocator.free(self.swapchain_layouts);
                        if (self.swapchain != .null_handle) self.device.destroySwapchainKHR(self.swapchain, null);
                        self.swapchain_views = &.{};
                        self.swapchain_images = &.{};
                        self.swapchain_layouts = &.{};
                        self.swapchain = .null_handle;
                        self.extent = .{ .width = 0, .height = 0 };
                    }

                    fn createSync(self: *StateSelf) anyerror!void {
                        self.slots = try self.allocator.alloc(Slot, self.frames_in_flight);
                        @memset(self.slots, .{});
                        errdefer self.destroySync();
                        const command_buffers = try self.allocator.alloc(vk.CommandBuffer, self.frames_in_flight);
                        defer self.allocator.free(command_buffers);
                        try self.device.allocateCommandBuffers(&.{
                            .command_pool = self.command_pool,
                            .level = .primary,
                            .command_buffer_count = self.frames_in_flight,
                        }, command_buffers.ptr);
                        for (self.slots, command_buffers) |*slot, command_buffer| {
                            slot.command_buffer = command_buffer;
                            slot.image_available = try self.device.createSemaphore(&.{}, null);
                            slot.render_finished = try self.device.createSemaphore(&.{}, null);
                            slot.fence = try self.device.createFence(&.{ .flags = .{ .signaled_bit = true } }, null);
                        }
                    }

                    fn destroySync(self: *StateSelf) void {
                        for (self.slots) |slot| {
                            if (slot.fence != .null_handle) self.device.destroyFence(slot.fence, null);
                            if (slot.render_finished != .null_handle) self.device.destroySemaphore(slot.render_finished, null);
                            if (slot.image_available != .null_handle) self.device.destroySemaphore(slot.image_available, null);
                        }
                        for (self.slots) |slot| if (slot.command_buffer != .null_handle) {
                            self.device.freeCommandBuffers(self.command_pool, &.{slot.command_buffer});
                        };
                        if (self.slots.len != 0) self.allocator.free(self.slots);
                        self.slots = &.{};
                    }

                    fn image(self: *const StateSelf, index: u32) vk.Image {
                        if (self.surface != .null_handle) return self.swapchain_images[index];
                        return self.ring.?.images[index];
                    }

                    fn imageView(self: *const StateSelf, index: u32) vk.ImageView {
                        if (self.surface != .null_handle) return self.swapchain_views[index];
                        return self.ring.?.views[index];
                    }

                    fn imageLayout(self: *const StateSelf, index: u32) vk.ImageLayout {
                        if (self.surface != .null_handle) return self.swapchain_layouts[index];
                        return self.ring.?.layouts[index];
                    }

                    fn setImageLayout(self: *StateSelf, index: u32, layout: vk.ImageLayout) void {
                        if (self.surface != .null_handle) self.swapchain_layouts[index] = layout else self.ring.?.layouts[index] = layout;
                    }
                };

                const state = try allocator.create(State);
                state.* = .{
                    .allocator = allocator,
                    .window = options.window,
                    .instance = options.instance,
                    .physical_device = options.physical_device,
                    .device = options.device,
                    .graphics_queue = options.graphics_queue,
                    .graphics_queue_family = options.graphics_queue_family,
                    .command_pool = options.command_pool,
                    .color_format = options.color_format,
                    .memory_allocator = if (@hasField(OptionsType, "memory_allocator")) options.memory_allocator else null,
                    .frames_in_flight = options.frames_in_flight,
                };
                errdefer State.deinitOpaque(@ptrCast(state));

                if (options.context.backendKind() != .offscreen) {
                    state.surface = try @import("../vulkan.zig").createSurface(vk, options.context, options.window, options.instance);
                    if (try options.instance.getPhysicalDeviceSurfaceSupportKHR(options.physical_device, options.graphics_queue_family, state.surface) != .true) return error.QueueFamilyCannotPresent;
                }
                try state.createSync();
                if (options.context.backendKind() == .offscreen) try state.ensureTarget();
                return .{
                    .allocator = allocator,
                    .state = state,
                    .deinit_fn = State.deinitOpaque,
                    .acquire_fn = State.acquireOpaque,
                };
            }

            pub fn deinit(self: *Self) void {
                self.deinit_fn(self.state);
                self.* = undefined;
            }

            pub fn acquire(self: *Self) !Frame {
                return self.acquire_fn(self.state);
            }
        };

        /// Backwards-compatible names for the initial target API.
        pub const VulkanWindow = RenderTarget;
        pub const Target = RenderTarget;
    };
}

pub fn OffscreenMemoryAllocator(comptime vk: type) type {
    return struct {
        context: ?*anyopaque = null,
        allocate_and_bind: *const fn (?*anyopaque, vk.Image, vk.MemoryRequirements) anyerror!vk.DeviceMemory,
        free: *const fn (?*anyopaque, vk.DeviceMemory) void,
    };
}

/// A rotating collection of renderable offscreen Vulkan images.
///
/// Memory-type selection remains application-owned through the callback.
pub fn OffscreenImageRing(comptime vk: type, comptime Device: type) type {
    return struct {
        const Self = @This();
        pub const MemoryAllocator = OffscreenMemoryAllocator(vk);

        pub const Options = struct {
            allocator: std.mem.Allocator,
            device: Device,
            memory: MemoryAllocator,
            extent: vk.Extent2D,
            format: vk.Format,
            image_count: u32 = 3,
            usage: vk.ImageUsageFlags = .{ .color_attachment_bit = true, .transfer_src_bit = true },
        };

        pub const Frame = struct {
            index: u32,
            image: vk.Image,
            view: vk.ImageView,
            extent: vk.Extent2D,
        };

        allocator: std.mem.Allocator,
        device: Device,
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

        /// The helper waits for device idle before calling this method.
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

        /// The caller waits on its own per-image fence before reuse.
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
            @memset(self.images, .null_handle);
            @memset(self.views, .null_handle);
            @memset(self.allocations, .null_handle);
            @memset(self.layouts, .undefined);
            for (self.images, self.views, self.allocations) |*image, *view, *allocation| {
                image.* = try self.device.createImage(&.{
                    .image_type = .@"2d",
                    .format = self.format,
                    .extent = .{ .width = self.extent.width, .height = self.extent.height, .depth = 1 },
                    .mip_levels = 1,
                    .array_layers = 1,
                    .samples = .{ .@"1_bit" = true },
                    .tiling = .optimal,
                    .usage = self.usage,
                    .sharing_mode = .exclusive,
                    .initial_layout = .undefined,
                }, null);
                allocation.* = try self.memory.allocate_and_bind(self.memory.context, image.*, self.device.getImageMemoryRequirements(image.*));
                try self.device.bindImageMemory(image.*, allocation.*, 0);
                view.* = try self.device.createImageView(&.{
                    .image = image.*,
                    .view_type = .@"2d",
                    .format = self.format,
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

        fn destroyResources(self: *Self) void {
            for (self.views) |view| if (view != .null_handle) self.device.destroyImageView(view, null);
            for (self.images, self.allocations) |image, allocation| {
                if (image != .null_handle) self.device.destroyImage(image, null);
                if (allocation != .null_handle) self.memory.free(self.memory.context, allocation);
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
}

fn chooseExtent(comptime vk: type, capabilities: vk.SurfaceCapabilitiesKHR, requested: vk.Extent2D) vk.Extent2D {
    if (capabilities.current_extent.width != std.math.maxInt(u32)) return capabilities.current_extent;
    return .{
        .width = std.math.clamp(requested.width, capabilities.min_image_extent.width, capabilities.max_image_extent.width),
        .height = std.math.clamp(requested.height, capabilities.min_image_extent.height, capabilities.max_image_extent.height),
    };
}

fn chooseCompositeAlpha(comptime vk: type, supported: vk.CompositeAlphaFlagsKHR) vk.CompositeAlphaFlagsKHR {
    if (supported.opaque_bit_khr) return .{ .opaque_bit_khr = true };
    if (supported.pre_multiplied_bit_khr) return .{ .pre_multiplied_bit_khr = true };
    if (supported.post_multiplied_bit_khr) return .{ .post_multiplied_bit_khr = true };
    return .{ .inherit_bit_khr = true };
}

fn transitionImage(
    comptime vk: type,
    device: anytype,
    command_buffer: anytype,
    image: anytype,
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
