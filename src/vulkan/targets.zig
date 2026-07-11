//! Optional Vulkan render-target helpers.
//!
//! This module uses low's small runtime Vulkan ABI directly. Applications can
//! keep using any Vulkan binding for their own rendering commands.
const std = @import("std");
const vk = @import("api.zig");
const Vulkan = @import("../vulkan.zig");

pub const MemoryAllocator = struct {
    context: ?*anyopaque = null,
    allocate_and_bind: *const fn (?*anyopaque, vk.Image, vk.MemoryRequirements) anyerror!vk.DeviceMemory,
    free: *const fn (?*anyopaque, vk.DeviceMemory) void,
};

/// A Vulkan render target associated with one low window.
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
        ReadbackUnavailable,
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
        submit_fn: *const fn (?*anyopaque) anyerror!void,
        readback_fn: *const fn (?*anyopaque, std.mem.Allocator) anyerror!Readback,
        abort_fn: *const fn (?*anyopaque) void,
        state: ?*anyopaque,

        pub fn submitAndPresent(self: *Frame) !void {
            const state = self.state orelse return error.FrameAlreadyFinished;
            try self.submit_fn(state);
            self.state = null;
        }

        /// Submits the frame and waits until its tightly packed pixels have
        /// been copied into allocator-owned CPU memory. Onscreen frames are
        /// presented after the copy.
        pub fn submitAndReadback(self: *Frame, allocator: std.mem.Allocator) !Readback {
            const state = self.state orelse return error.FrameAlreadyFinished;
            const result = try self.readback_fn(state, allocator);
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

    pub fn init(allocator: std.mem.Allocator, options: anytype) !Self {
        const OptionsType = @TypeOf(options);
        if (!@hasField(OptionsType, "context") or !@hasField(OptionsType, "window")) {
            @compileError("RenderTarget.init requires context and window");
        }
        if (options.frames_in_flight == 0) return error.InvalidFramesInFlight;

        const Window = @TypeOf(options.window);
        const State = struct {
            const StateSelf = @This();
            const Slot = struct {
                command_buffer: vk.CommandBuffer = null,
                image_available: vk.Semaphore = 0,
                render_finished: vk.Semaphore = 0,
                fence: vk.Fence = 0,
                readback_buffer: vk.Buffer = 0,
                readback_memory: vk.DeviceMemory = 0,
                readback_capacity: u64 = 0,
            };

            allocator: std.mem.Allocator,
            window: Window,
            instance: *const Vulkan.Instance,
            physical_device: vk.PhysicalDevice,
            device: *const Vulkan.Device,
            graphics_queue: vk.Queue,
            graphics_queue_family: u32,
            command_pool: vk.CommandPool,
            color_format: vk.Format,
            memory_allocator: ?MemoryAllocator,
            memory_properties: vk.PhysicalDeviceMemoryProperties = undefined,
            frames_in_flight: u32,
            slots: []Slot = &.{},
            surface: vk.SurfaceKHR = 0,
            swapchain: vk.SwapchainKHR = 0,
            swapchain_images: []vk.Image = &.{},
            swapchain_views: []vk.ImageView = &.{},
            swapchain_layouts: []vk.ImageLayout = &.{},
            extent: vk.Extent2D = .{ .width = 0, .height = 0 },
            recreate_pending: bool = false,
            ring: ?OffscreenImageRing = null,
            next_slot: u32 = 0,
            active_slot: ?u32 = null,
            active_image: ?u32 = null,
            submitted: bool = false,

            fn deinitOpaque(ptr: *anyopaque) void {
                const self: *StateSelf = @ptrCast(@alignCast(ptr));
                self.device.deviceWaitIdle() catch {};
                self.destroyTarget();
                self.destroySync();
                if (self.surface != 0) {
                    self.instance.destroySurfaceKHR(self.surface);
                    self.surface = 0;
                }
                self.allocator.destroy(self);
            }

            fn acquireOpaque(ptr: *anyopaque) anyerror!Frame {
                const self: *StateSelf = @ptrCast(@alignCast(ptr));
                return self.acquireFrame(ptr);
            }

            fn submitOpaque(ptr: ?*anyopaque) anyerror!void {
                const self: *StateSelf = @ptrCast(@alignCast(ptr.?));
                _ = try self.submitFrame(null);
            }

            fn readbackOpaque(ptr: ?*anyopaque, output_allocator: std.mem.Allocator) anyerror!Readback {
                const self: *StateSelf = @ptrCast(@alignCast(ptr.?));
                return (try self.submitFrame(output_allocator)).?;
            }

            fn abortOpaque(ptr: ?*anyopaque) void {
                const self: *StateSelf = @ptrCast(@alignCast(ptr.?));
                self.abortFrame();
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
                    const acquired = self.device.acquireNextImageKHR(
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
                    };
                    if (acquired.result == .timeout or acquired.result == .not_ready) return error.FrameSkipped;
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

            fn submitFrame(self: *StateSelf, readback_allocator: ?std.mem.Allocator) anyerror!?Readback {
                const slot_index = self.active_slot orelse return error.FrameAlreadyFinished;
                const image_index = self.active_image orelse return error.FrameAlreadyFinished;
                const slot = &self.slots[slot_index];
                const image_handle = self.image(image_index);
                if (readback_allocator != null) {
                    if (self.color_format != vk.format.b8g8r8a8_unorm) return error.ReadbackUnavailable;
                    try self.ensureReadbackBuffer(slot, @as(u64, self.extent.width) * self.extent.height * 4);
                }
                const copy_image = readback_allocator != null;
                const post_render_layout: vk.ImageLayout = if (copy_image or self.surface == 0) .transfer_src_optimal else .present_src_khr;
                transitionImage(self.device, slot.command_buffer, image_handle, .color_attachment_optimal, post_render_layout, vk.pipeline_stage.color_attachment_output_bit, vk.access.color_attachment_write_bit, if (post_render_layout == .transfer_src_optimal) vk.pipeline_stage.transfer_bit else vk.pipeline_stage.bottom_of_pipe_bit, if (post_render_layout == .transfer_src_optimal) vk.access.transfer_read_bit else 0);
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
                    if (self.surface != 0) transitionImage(self.device, slot.command_buffer, image_handle, .transfer_src_optimal, .present_src_khr, vk.pipeline_stage.transfer_bit, vk.access.transfer_read_bit, vk.pipeline_stage.bottom_of_pipe_bit, 0);
                }
                try self.device.endCommandBuffer(slot.command_buffer);

                const command_buffers = [_]vk.CommandBuffer{slot.command_buffer};
                var wait_semaphores: [1]vk.Semaphore = undefined;
                var wait_stages: [1]vk.PipelineStageFlags = undefined;
                var signal_semaphores: [1]vk.Semaphore = undefined;
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
                    signal_semaphores[0] = slot.render_finished;
                    submit_info.wait_semaphore_count = 1;
                    submit_info.p_wait_semaphores = wait_semaphores[0..].ptr;
                    submit_info.p_wait_dst_stage_mask = wait_stages[0..].ptr;
                    submit_info.signal_semaphore_count = 1;
                    submit_info.p_signal_semaphores = signal_semaphores[0..].ptr;
                }
                try self.device.resetFences(&.{slot.fence});
                try self.device.queueSubmit(self.graphics_queue, &submit_info, slot.fence);
                self.submitted = true;
                self.setImageLayout(image_index, if (self.surface != 0) .present_src_khr else .transfer_src_optimal);
                self.active_slot = null;

                if (self.surface != 0) {
                    const swapchains = [_]vk.SwapchainKHR{self.swapchain};
                    const indices = [_]u32{image_index};
                    const present = self.device.queuePresentKHR(self.graphics_queue, &.{
                        .s_type = .present_info_khr,
                        .p_next = null,
                        .wait_semaphore_count = 1,
                        .p_wait_semaphores = signal_semaphores[0..].ptr,
                        .swapchain_count = 1,
                        .p_swapchains = swapchains[0..].ptr,
                        .p_image_indices = indices[0..].ptr,
                        .p_results = null,
                    }) catch |err| switch (err) {
                        error.OutOfDateKHR => {
                            self.recreate_pending = true;
                            return error.FrameOutOfDate;
                        },
                        else => return err,
                    };
                    if (present == .suboptimal_khr) self.recreate_pending = true;
                }
                if (readback_allocator) |output_allocator| {
                    _ = try self.device.waitForFences(&.{slot.fence}, true, std.math.maxInt(u64));
                    const len: usize = @intCast(@as(u64, self.extent.width) * self.extent.height * 4);
                    const pixels = try output_allocator.alloc(u8, len);
                    errdefer output_allocator.free(pixels);
                    const mapped = try self.device.mapMemory(slot.readback_memory, 0, len);
                    defer self.device.unmapMemory(slot.readback_memory);
                    @memcpy(pixels, @as([*]const u8, @ptrCast(mapped))[0..len]);
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
                const wanted_extent = chooseExtent(capabilities, wanted);
                if (wanted_extent.width == 0 or wanted_extent.height == 0) return error.FrameSkipped;
                if (self.swapchain == 0 or self.recreate_pending or self.extent.width != wanted_extent.width or self.extent.height != wanted_extent.height) {
                    if (self.swapchain != 0) try self.device.deviceWaitIdle();
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
                    .s_type = .swapchain_create_info_khr,
                    .p_next = null,
                    .flags = 0,
                    .surface = self.surface,
                    .min_image_count = image_count,
                    .image_format = selected_format.format,
                    .image_color_space = selected_format.color_space,
                    .image_extent = wanted_extent,
                    .image_array_layers = 1,
                    .image_usage = vk.image_usage.color_attachment_bit | vk.image_usage.transfer_src_bit,
                    .image_sharing_mode = .exclusive,
                    .queue_family_index_count = 0,
                    .p_queue_family_indices = null,
                    .pre_transform = capabilities.current_transform,
                    .composite_alpha = chooseCompositeAlpha(capabilities.supported_composite_alpha),
                    .present_mode = vk.present_mode.fifo_khr,
                    .clipped = vk.TRUE,
                    .old_swapchain = 0,
                });
                errdefer self.destroySwapchain();
                self.swapchain_images = try self.device.getSwapchainImagesAllocKHR(self.swapchain, self.allocator);
                self.swapchain_views = try self.allocator.alloc(vk.ImageView, self.swapchain_images.len);
                self.swapchain_layouts = try self.allocator.alloc(vk.ImageLayout, self.swapchain_images.len);
                @memset(self.swapchain_views, 0);
                @memset(self.swapchain_layouts, .undefined);
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

            fn destroyTarget(self: *StateSelf) void {
                if (self.ring) |*ring| ring.deinit();
                self.ring = null;
                self.destroySwapchain();
            }

            fn destroySwapchain(self: *StateSelf) void {
                for (self.swapchain_views) |view| if (view != 0) self.device.destroyImageView(view);
                if (self.swapchain_views.len != 0) self.allocator.free(self.swapchain_views);
                if (self.swapchain_images.len != 0) self.allocator.free(self.swapchain_images);
                if (self.swapchain_layouts.len != 0) self.allocator.free(self.swapchain_layouts);
                if (self.swapchain != 0) self.device.destroySwapchainKHR(self.swapchain);
                self.swapchain_views = &.{};
                self.swapchain_images = &.{};
                self.swapchain_layouts = &.{};
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
                    slot.render_finished = try self.device.createSemaphore();
                    slot.fence = try self.device.createFence(true);
                }
            }

            fn destroySync(self: *StateSelf) void {
                for (self.slots) |slot| {
                    if (slot.readback_buffer != 0) self.device.destroyBuffer(slot.readback_buffer);
                    if (slot.readback_memory != 0) self.device.freeMemory(slot.readback_memory);
                    if (slot.fence != 0) self.device.destroyFence(slot.fence);
                    if (slot.render_finished != 0) self.device.destroySemaphore(slot.render_finished);
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

        state.memory_properties = state.instance.getPhysicalDeviceMemoryProperties(state.physical_device);
        if (options.context.backendKind() != .offscreen) {
            state.surface = try Vulkan.createSurface(
                state.instance,
                options.context.backendKind(),
                options.window.nativeDisplay(),
                options.window.nativeSurface(),
            );
            if (try state.instance.getPhysicalDeviceSurfaceSupportKHR(state.physical_device, options.graphics_queue_family, state.surface) != vk.TRUE) return error.QueueFamilyCannotPresent;
        } else {
            if (state.memory_allocator == null) state.memory_allocator = .{
                .context = state,
                .allocate_and_bind = State.allocateDefaultMemory,
                .free = State.freeDefaultMemory,
            };
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

pub const VulkanWindow = RenderTarget;
pub const Target = RenderTarget;

pub const OffscreenImageRing = struct {
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
