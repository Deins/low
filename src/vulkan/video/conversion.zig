const std = @import("std");
const vk = @import("_vk_video");

// Every render-target format is normalized into the RGBA8 `source` image by
// recordCopy before this shader reads it. In particular, packed 10-bit UNORM
// targets are down-converted there, keeping the existing 8-bit NV12 encoder
// profiles and storage-image views valid.
const shader_spv align(@alignOf(u32)) = @embedFile("shaders/bgra_to_nv12.spv").*;

pub const ImageSet = struct {
    source: vk.Image,
    source_view: vk.ImageView,
    encode_input: vk.Image,
    luma_view: vk.ImageView,
    chroma_view: vk.ImageView,
};

pub const Pipeline = struct {
    allocator: std.mem.Allocator,
    descriptor_set_layout: vk.DescriptorSetLayout = .null_handle,
    pipeline_layout: vk.PipelineLayout = .null_handle,
    pipeline: vk.Pipeline = .null_handle,
    descriptor_pool: vk.DescriptorPool = .null_handle,
    descriptor_sets: []vk.DescriptorSet = &.{},

    pub fn init(allocator: std.mem.Allocator, device: vk.DeviceProxy, images: []const ImageSet) !Pipeline {
        var self: Pipeline = .{ .allocator = allocator };
        errdefer self.deinit(device);

        const bindings = [_]vk.DescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptor_type = .storage_image, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true } },
            .{ .binding = 1, .descriptor_type = .storage_image, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true } },
            .{ .binding = 2, .descriptor_type = .storage_image, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true } },
        };
        self.descriptor_set_layout = try device.createDescriptorSetLayout(&.{
            .binding_count = bindings.len,
            .p_bindings = &bindings,
        }, null);
        self.pipeline_layout = try device.createPipelineLayout(&.{
            .set_layout_count = 1,
            .p_set_layouts = @ptrCast(&self.descriptor_set_layout),
        }, null);

        const shader = try device.createShaderModule(&.{
            .code_size = shader_spv.len,
            .p_code = @ptrCast(&shader_spv),
        }, null);
        defer device.destroyShaderModule(shader, null);
        var pipelines: [1]vk.Pipeline = undefined;
        _ = try device.createComputePipelines(.null_handle, &.{.{
            .stage = .{
                .stage = .{ .compute_bit = true },
                .module = shader,
                .p_name = "main",
            },
            .layout = self.pipeline_layout,
            .base_pipeline_index = -1,
        }}, null, &pipelines);
        self.pipeline = pipelines[0];

        const pool_size = vk.DescriptorPoolSize{ .type = .storage_image, .descriptor_count = @intCast(images.len * 3) };
        self.descriptor_pool = try device.createDescriptorPool(&.{
            .max_sets = @intCast(images.len),
            .pool_size_count = 1,
            .p_pool_sizes = @ptrCast(&pool_size),
        }, null);
        self.descriptor_sets = try allocator.alloc(vk.DescriptorSet, images.len);
        const layouts = try allocator.alloc(vk.DescriptorSetLayout, images.len);
        defer allocator.free(layouts);
        @memset(layouts, self.descriptor_set_layout);
        try device.allocateDescriptorSets(&.{
            .descriptor_pool = self.descriptor_pool,
            .descriptor_set_count = @intCast(images.len),
            .p_set_layouts = layouts.ptr,
        }, self.descriptor_sets.ptr);

        for (images, self.descriptor_sets) |image_set, descriptor_set| {
            const infos = [_]vk.DescriptorImageInfo{
                .{ .sampler = .null_handle, .image_view = image_set.source_view, .image_layout = .general },
                .{ .sampler = .null_handle, .image_view = image_set.luma_view, .image_layout = .general },
                .{ .sampler = .null_handle, .image_view = image_set.chroma_view, .image_layout = .general },
            };
            var writes: [3]vk.WriteDescriptorSet = undefined;
            for (&writes, 0..) |*write, binding| {
                write.* = std.mem.zeroes(vk.WriteDescriptorSet);
                write.s_type = .write_descriptor_set;
                write.dst_set = descriptor_set;
                write.dst_binding = @intCast(binding);
                write.descriptor_count = 1;
                write.descriptor_type = .storage_image;
                write.p_image_info = @ptrCast(&infos[binding]);
            }
            device.updateDescriptorSets(&writes, null);
        }
        return self;
    }

    pub fn deinit(self: *Pipeline, device: vk.DeviceProxy) void {
        if (self.descriptor_pool != .null_handle) device.destroyDescriptorPool(self.descriptor_pool, null);
        if (self.pipeline != .null_handle) device.destroyPipeline(self.pipeline, null);
        if (self.pipeline_layout != .null_handle) device.destroyPipelineLayout(self.pipeline_layout, null);
        if (self.descriptor_set_layout != .null_handle) device.destroyDescriptorSetLayout(self.descriptor_set_layout, null);
        if (self.descriptor_sets.len != 0) self.allocator.free(self.descriptor_sets);
        self.* = .{ .allocator = self.allocator };
    }

    pub fn recordCopy(
        _: *const Pipeline,
        device: vk.DeviceProxy,
        command_buffer: vk.CommandBuffer,
        target_image: vk.Image,
        target_extent: vk.Extent2D,
        coded_extent: vk.Extent2D,
        images: ImageSet,
        initialized: bool,
    ) void {
        const color_range = colorSubresourceRange();
        const prepare = vk.ImageMemoryBarrier2{
            // Slot reuse waits for the preceding encode fence on the CPU.
            .src_stage_mask = .{},
            .src_access_mask = .{},
            .dst_stage_mask = .{ .all_transfer_bit = true },
            .dst_access_mask = .{ .transfer_write_bit = true },
            .old_layout = if (initialized) .general else .undefined,
            .new_layout = .transfer_dst_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = images.source,
            .subresource_range = color_range,
        };
        device.cmdPipelineBarrier2(command_buffer, &.{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = @ptrCast(&prepare),
        });

        const black = vk.ClearColorValue{ .float_32 = .{ 0.0, 0.0, 0.0, 1.0 } };
        device.cmdClearColorImage(command_buffer, images.source, .transfer_dst_optimal, &black, &.{color_range});
        const fit = letterboxRect(target_extent, coded_extent);
        device.cmdBlitImage(command_buffer, target_image, .transfer_src_optimal, images.source, .transfer_dst_optimal, &.{.{
            .src_subresource = colorLayers(),
            .src_offsets = .{
                .{ .x = 0, .y = 0, .z = 0 },
                .{ .x = @intCast(target_extent.width), .y = @intCast(target_extent.height), .z = 1 },
            },
            .dst_subresource = colorLayers(),
            .dst_offsets = .{
                .{ .x = fit.x, .y = fit.y, .z = 0 },
                .{ .x = fit.x + @as(i32, @intCast(fit.width)), .y = fit.y + @as(i32, @intCast(fit.height)), .z = 1 },
            },
        }}, .linear);

        const source_ready = vk.ImageMemoryBarrier2{
            .src_stage_mask = .{ .all_transfer_bit = true },
            .src_access_mask = .{ .transfer_write_bit = true },
            .dst_stage_mask = .{},
            .dst_access_mask = .{},
            .old_layout = .transfer_dst_optimal,
            .new_layout = .general,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = images.source,
            .subresource_range = color_range,
        };
        device.cmdPipelineBarrier2(command_buffer, &.{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = @ptrCast(&source_ready),
        });
    }

    pub fn recordConversion(
        self: *const Pipeline,
        device: vk.DeviceProxy,
        command_buffer: vk.CommandBuffer,
        slot_index: usize,
        coded_extent: vk.Extent2D,
        images: ImageSet,
        initialized: bool,
    ) void {
        const plane_range = vk.ImageSubresourceRange{
            .aspect_mask = .{ .plane_0_bit = true, .plane_1_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        };
        const prepare = [_]vk.ImageMemoryBarrier2{
            .{
                .src_stage_mask = .{},
                .src_access_mask = .{},
                .dst_stage_mask = .{ .compute_shader_bit = true },
                .dst_access_mask = .{ .shader_storage_read_bit = true },
                .old_layout = .general,
                .new_layout = .general,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .image = images.source,
                .subresource_range = colorSubresourceRange(),
            },
            .{
                .src_stage_mask = .{},
                .src_access_mask = .{},
                .dst_stage_mask = .{ .compute_shader_bit = true },
                .dst_access_mask = .{ .shader_storage_write_bit = true },
                .old_layout = if (initialized) .video_encode_src_khr else .undefined,
                .new_layout = .general,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .image = images.encode_input,
                .subresource_range = plane_range,
            },
        };
        device.cmdPipelineBarrier2(command_buffer, &.{
            .image_memory_barrier_count = prepare.len,
            .p_image_memory_barriers = &prepare,
        });

        device.cmdBindPipeline(command_buffer, .compute, self.pipeline);
        device.cmdBindDescriptorSets(command_buffer, .compute, self.pipeline_layout, 0, &.{self.descriptor_sets[slot_index]}, null);
        device.cmdDispatch(command_buffer, (coded_extent.width + 15) / 16, (coded_extent.height + 15) / 16, 1);

        const conversion_done = vk.ImageMemoryBarrier2{
            .src_stage_mask = .{ .compute_shader_bit = true },
            .src_access_mask = .{ .shader_storage_write_bit = true },
            .dst_stage_mask = .{},
            .dst_access_mask = .{},
            .old_layout = .general,
            .new_layout = .video_encode_src_khr,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = images.encode_input,
            .subresource_range = plane_range,
        };
        device.cmdPipelineBarrier2(command_buffer, &.{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = @ptrCast(&conversion_done),
        });
    }
};

pub const FitRect = struct { x: i32, y: i32, width: u32, height: u32 };

pub fn letterboxRect(source: vk.Extent2D, destination: vk.Extent2D) FitRect {
    if (source.width == 0 or source.height == 0 or destination.width == 0 or destination.height == 0) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    var width = destination.width;
    var height = destination.height;
    if (@as(u64, source.width) * destination.height > @as(u64, source.height) * destination.width) {
        height = @intCast(@max(@as(u64, 1), @as(u64, destination.width) * source.height / source.width));
    } else {
        width = @intCast(@max(@as(u64, 1), @as(u64, destination.height) * source.width / source.height));
    }
    return .{
        .x = @intCast((destination.width - width) / 2),
        .y = @intCast((destination.height - height) / 2),
        .width = width,
        .height = height,
    };
}

fn colorSubresourceRange() vk.ImageSubresourceRange {
    return .{
        .aspect_mask = .{ .color_bit = true },
        .base_mip_level = 0,
        .level_count = 1,
        .base_array_layer = 0,
        .layer_count = 1,
    };
}

fn colorLayers() vk.ImageSubresourceLayers {
    return .{ .aspect_mask = .{ .color_bit = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 };
}

test "letterbox transform preserves aspect and centers content" {
    try std.testing.expectEqual(FitRect{ .x = 0, .y = 120, .width = 1920, .height = 1080 }, letterboxRect(
        .{ .width = 1280, .height = 720 },
        .{ .width = 1920, .height = 1320 },
    ));
    try std.testing.expectEqual(FitRect{ .x = 320, .y = 0, .width = 1280, .height = 1080 }, letterboxRect(
        .{ .width = 4, .height = 3 },
        .{ .width = 1920, .height = 1080 },
    ));
}
