const std = @import("std");
const vk = @import("_vk_video");

pub const Sequence = struct {
    color: vk.StdVideoAV1ColorConfig,
    header: vk.StdVideoAV1SequenceHeader,

    pub fn init(self: *Sequence, extent: vk.Extent2D, profile: vk.StdVideoAV1Profile) !void {
        if (extent.width == 0 or extent.height == 0 or extent.width > 65536 or extent.height > 65536) return error.UnsupportedVideoExtent;
        self.* = std.mem.zeroes(Sequence);
        self.color.flags = std.mem.zeroes(vk.StdVideoAV1ColorConfigFlags);
        self.color.flags.color_description_present_flag = true;
        self.color.bit_depth = 8;
        self.color.subsampling_x = 1;
        self.color.subsampling_y = 1;
        self.color.color_primaries = .bt_709;
        self.color.transfer_characteristics = .bt_709;
        self.color.matrix_coefficients = .bt_709;
        self.color.chroma_sample_position = .colocated;
        self.header.flags = std.mem.zeroes(vk.StdVideoAV1SequenceHeaderFlags);
        self.header.flags.enable_order_hint = true;
        self.header.seq_profile = profile;
        self.header.frame_width_bits_minus_1 = @intCast(std.math.log2_int_ceil(u32, extent.width) -| 1);
        self.header.frame_height_bits_minus_1 = @intCast(std.math.log2_int_ceil(u32, extent.height) -| 1);
        self.header.max_frame_width_minus_1 = @intCast(extent.width - 1);
        self.header.max_frame_height_minus_1 = @intCast(extent.height - 1);
        self.header.order_hint_bits_minus_1 = 7;
        self.header.seq_force_integer_mv = 2;
        self.header.seq_force_screen_content_tools = 2;
        self.header.p_color_config = &self.color;
    }
};

/// Serializes the subset of AV1 sequence-header syntax represented by
/// `Sequence.init` as a size-delimited OBU. Vulkan's AV1 encode operation emits
/// frame OBUs, while applications remain responsible for sequence headers.
pub fn writeSequenceHeader(allocator: std.mem.Allocator, sequence: *const Sequence, level: vk.StdVideoAV1Level) ![]u8 {
    var payload: [64]u8 = @splat(0);
    var bits = BitWriter{ .bytes = &payload };
    try bits.put(@intFromEnum(sequence.header.seq_profile), 3);
    try bits.put(0, 1); // still_picture
    try bits.put(0, 1); // reduced_still_picture_header
    try bits.put(0, 1); // timing_info_present_flag
    try bits.put(0, 1); // initial_display_delay_present_flag
    try bits.put(0, 5); // operating_points_cnt_minus_1
    try bits.put(0, 12); // operating_point_idc
    const level_value: u8 = @intCast(@intFromEnum(level));
    try bits.put(level_value, 5);
    if (level_value > 7) try bits.put(0, 1); // seq_tier
    try bits.put(sequence.header.frame_width_bits_minus_1, 4);
    try bits.put(sequence.header.frame_height_bits_minus_1, 4);
    try bits.put(sequence.header.max_frame_width_minus_1, sequence.header.frame_width_bits_minus_1 + 1);
    try bits.put(sequence.header.max_frame_height_minus_1, sequence.header.frame_height_bits_minus_1 + 1);
    try bits.put(0, 1); // frame_id_numbers_present_flag
    try bits.put(0, 1); // use_128x128_superblock
    try bits.put(0, 1); // enable_filter_intra
    try bits.put(0, 1); // enable_intra_edge_filter
    try bits.put(0, 1); // enable_interintra_compound
    try bits.put(0, 1); // enable_masked_compound
    try bits.put(0, 1); // enable_warped_motion
    try bits.put(0, 1); // enable_dual_filter
    try bits.put(1, 1); // enable_order_hint
    try bits.put(0, 1); // enable_jnt_comp
    try bits.put(0, 1); // enable_ref_frame_mvs
    try bits.put(1, 1); // seq_choose_screen_content_tools
    try bits.put(1, 1); // seq_choose_integer_mv
    try bits.put(sequence.header.order_hint_bits_minus_1, 3);
    try bits.put(0, 1); // enable_superres
    try bits.put(0, 1); // enable_cdef
    try bits.put(0, 1); // enable_restoration
    try bits.put(0, 1); // high_bitdepth
    try bits.put(0, 1); // mono_chrome
    try bits.put(1, 1); // color_description_present_flag
    try bits.put(@intFromEnum(sequence.color.color_primaries), 8);
    try bits.put(@intFromEnum(sequence.color.transfer_characteristics), 8);
    try bits.put(@intFromEnum(sequence.color.matrix_coefficients), 8);
    try bits.put(0, 1); // color_range (studio swing)
    try bits.put(@intFromEnum(sequence.color.chroma_sample_position), 2);
    try bits.put(0, 1); // separate_uv_delta_q
    try bits.put(0, 1); // film_grain_params_present
    try bits.put(1, 1); // trailing_one_bit
    bits.byteAlign();
    const payload_size = bits.byteLength();
    if (payload_size >= 128) return error.Av1SequenceHeaderTooLarge;
    const result = try allocator.alloc(u8, payload_size + 2);
    result[0] = 0x0a; // OBU_SEQUENCE_HEADER with obu_has_size_field = 1
    result[1] = @intCast(payload_size); // one-byte LEB128
    @memcpy(result[2..], payload[0..payload_size]);
    return result;
}

const BitWriter = struct {
    bytes: *[64]u8,
    bit_position: usize = 0,

    fn put(self: *BitWriter, value: anytype, count: u8) !void {
        if (self.bit_position + count > self.bytes.len * 8) return error.Av1SequenceHeaderTooLarge;
        var remaining = count;
        while (remaining != 0) {
            remaining -= 1;
            const bit: u8 = @intCast((@as(u64, @intCast(value)) >> @intCast(remaining)) & 1);
            self.bytes[self.bit_position / 8] |= bit << @intCast(7 - self.bit_position % 8);
            self.bit_position += 1;
        }
    }

    fn byteAlign(self: *BitWriter) void {
        self.bit_position = std.mem.alignForward(usize, self.bit_position, 8);
    }

    fn byteLength(self: *const BitWriter) usize {
        return self.bit_position / 8;
    }
};

pub const FrameInfo = struct {
    quantization: vk.StdVideoAV1Quantization,
    loop_filter: vk.StdVideoAV1LoopFilter,
    global_motion: vk.StdVideoAV1GlobalMotion,
    picture: vk.StdVideoEncodeAV1PictureInfo,
    picture_info: vk.VideoEncodeAV1PictureInfoKHR,

    pub fn init(self: *FrameInfo, frame_index: u64, gop_size: u32, constant_q: bool, q: u32) void {
        self.* = std.mem.zeroes(FrameInfo);
        const gop_index: u32 = @intCast(frame_index % gop_size);
        const key = gop_index == 0;
        const current_slot: u3 = @intCast(gop_index & 1);
        const previous_slot: i8 = @intCast(if (key) 0 else (gop_index - 1) & 1);
        self.quantization.base_q_idx = @intCast(@min(q, 255));
        self.picture.flags = std.mem.zeroes(vk.StdVideoEncodeAV1PictureInfoFlags);
        self.picture.flags.error_resilient_mode = key;
        self.picture.flags.show_frame = true;
        self.picture.frame_type = if (key) .key else .inter;
        self.picture.order_hint = @truncate(gop_index);
        self.picture.primary_ref_frame = if (key) vk.STD_VIDEO_AV1_PRIMARY_REF_NONE else 0;
        self.picture.refresh_frame_flags = if (key) 0xff else @as(u8, 1) << current_slot;
        self.picture.ref_frame_idx = @splat(previous_slot);
        self.picture.interpolation_filter = .eighttap;
        self.picture.tx_mode = .select;
        self.picture.p_quantization = &self.quantization;
        self.picture.p_loop_filter = &self.loop_filter;
        self.picture.p_global_motion = &self.global_motion;
        self.picture_info = .{
            .prediction_mode = if (key) .intra_only_khr else .single_reference_khr,
            .rate_control_group = if (key) .intra_khr else .predictive_khr,
            .constant_q_index = if (constant_q) q else 0,
            .p_std_picture_info = &self.picture,
            .reference_name_slot_indices = @splat(-1),
            .primary_reference_cdf_only = .false,
            .generate_obu_extension_header = .false,
        };
        if (!key) self.picture_info.reference_name_slot_indices[0] = previous_slot;
    }
};

test "AV1 sequence and intra picture metadata initialize" {
    var sequence: Sequence = undefined;
    try sequence.init(.{ .width = 1920, .height = 1080 }, .main);
    try std.testing.expectEqual(@as(u16, 1919), sequence.header.max_frame_width_minus_1);
    var frame: FrameInfo = undefined;
    frame.init(0, 60, true, 100);
    try std.testing.expectEqual(vk.StdVideoAV1FrameType.key, frame.picture.frame_type);
    const header = try writeSequenceHeader(std.testing.allocator, &sequence, .@"5_1");
    defer std.testing.allocator.free(header);
    try std.testing.expectEqual(@as(u8, 0x0a), header[0]);
}
