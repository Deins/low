const std = @import("std");
const vk = @import("_vk_video");
const capabilities = @import("capabilities.zig");

pub const ParameterSets = struct {
    vui: vk.StdVideoH264SequenceParameterSetVui,
    sps: vk.StdVideoH264SequenceParameterSet,
    pps: vk.StdVideoH264PictureParameterSet,

    pub fn init(
        self: *ParameterSets,
        extent: vk.Extent2D,
        frame_rate: capabilities.Rational,
        gop_size: u32,
        profile: vk.StdVideoH264ProfileIdc,
        maximum_level: vk.StdVideoH264LevelIdc,
        bitrate: u64,
    ) !void {
        const timing = try frame_rate.reduced();
        if (gop_size == 0 or gop_size > 32_768) return error.InvalidGopSize;
        const time_scale = std.math.mul(u32, timing.numerator, 2) catch return error.FrameRateTooLarge;
        const level = chooseLevel(extent, timing, bitrate) orelse return error.UnsupportedVideoExtent;
        if (@intFromEnum(level) > @intFromEnum(maximum_level)) return error.UnsupportedVideoExtent;

        self.* = std.mem.zeroes(ParameterSets);
        self.vui.flags = .{
            .aspect_ratio_info_present_flag = true,
            .video_signal_type_present_flag = true,
            .color_description_present_flag = true,
            .chroma_loc_info_present_flag = true,
            .timing_info_present_flag = true,
            .fixed_frame_rate_flag = true,
            .bitstream_restriction_flag = true,
        };
        self.vui.aspect_ratio_idc = .square;
        self.vui.video_format = 5; // unspecified source, progressive component video
        self.vui.colour_primaries = 1; // BT.709
        self.vui.transfer_characteristics = 1; // BT.709
        self.vui.matrix_coefficients = 1; // BT.709
        self.vui.num_units_in_tick = timing.denominator;
        self.vui.time_scale = time_scale;
        self.vui.max_num_reorder_frames = 0;
        self.vui.max_dec_frame_buffering = 1;
        // The compute shader averages a 2x2 luma footprint, placing chroma at
        // the horizontal and vertical center of that footprint.
        self.vui.chroma_sample_loc_type_top_field = 1;
        self.vui.chroma_sample_loc_type_bottom_field = 1;

        const macroblock_width = try alignForward(extent.width, 16);
        const macroblock_height = try alignForward(extent.height, 16);
        self.sps.flags = .{
            .constraint_set_0_flag = profile == .baseline,
            .constraint_set_1_flag = profile == .baseline,
            .direct_8x_8_inference_flag = true,
            .frame_mbs_only_flag = true,
            .frame_cropping_flag = macroblock_width != extent.width or macroblock_height != extent.height,
            .vui_parameters_present_flag = true,
        };
        self.sps.profile_idc = profile;
        self.sps.level_idc = level;
        self.sps.chroma_format_idc = .@"420";
        self.sps.seq_parameter_set_id = 0;
        self.sps.bit_depth_luma_minus_8 = 0;
        self.sps.bit_depth_chroma_minus_8 = 0;
        const frame_num_bits: u8 = @intCast(@max(@as(u32, 4), std.math.log2_int_ceil(u32, @max(gop_size, 2))));
        const poc_bits: u8 = @intCast(@max(@as(u32, 4), std.math.log2_int_ceil(u32, gop_size * 2)));
        self.sps.log_2_max_frame_num_minus_4 = frame_num_bits - 4;
        self.sps.pic_order_cnt_type = .@"0";
        self.sps.log_2_max_pic_order_cnt_lsb_minus_4 = poc_bits - 4;
        self.sps.max_num_ref_frames = 1;
        self.sps.pic_width_in_mbs_minus_1 = macroblock_width / 16 - 1;
        self.sps.pic_height_in_map_units_minus_1 = macroblock_height / 16 - 1;
        // Progressive 4:2:0 crop units are two luma samples in each axis.
        self.sps.frame_crop_right_offset = (macroblock_width - extent.width) / 2;
        self.sps.frame_crop_bottom_offset = (macroblock_height - extent.height) / 2;
        self.sps.p_sequence_parameter_set_vui = &self.vui;

        self.pps.flags = .{
            // Keep the first encoder path within the syntax flags universally
            // exposed for High/Main/Baseline profiles. Drivers may omit the
            // transform-8x8 set capability even when High profile is present.
            .transform_8x_8_mode_flag = false,
            .deblocking_filter_control_present_flag = true,
            .entropy_coding_mode_flag = profile != .baseline,
        };
        self.pps.seq_parameter_set_id = 0;
        self.pps.pic_parameter_set_id = 0;
        self.pps.num_ref_idx_l_0_default_active_minus_1 = 0;
        self.pps.num_ref_idx_l_1_default_active_minus_1 = 0;
        self.pps.weighted_bipred_idc = .default;
    }
};

pub const FrameInfo = struct {
    reference_lists: vk.StdVideoEncodeH264ReferenceListsInfo,
    slice_header: vk.StdVideoEncodeH264SliceHeader,
    slice: vk.VideoEncodeH264NaluSliceInfoKHR,
    picture: vk.StdVideoEncodeH264PictureInfo,
    picture_info: vk.VideoEncodeH264PictureInfoKHR,

    pub fn init(self: *FrameInfo, frame_index: u64, gop_size: u32, log_2_max_pic_order_cnt_lsb_minus_4: u8, constant_qp: bool, qp: i32) void {
        self.* = std.mem.zeroes(FrameInfo);
        const gop_index: u32 = @intCast(frame_index % @max(gop_size, 1));
        const idr = gop_index == 0;

        self.reference_lists.ref_pic_list_0 = @splat(vk.STD_VIDEO_H264_NO_REFERENCE_PICTURE);
        self.reference_lists.ref_pic_list_1 = @splat(vk.STD_VIDEO_H264_NO_REFERENCE_PICTURE);
        if (!idr) self.reference_lists.ref_pic_list_0[0] = @intCast((gop_index - 1) & 1);

        self.slice_header.flags = .{
            .direct_spatial_mv_pred_flag = true,
            .num_ref_idx_active_override_flag = false,
        };
        self.slice_header.first_mb_in_slice = 0;
        self.slice_header.slice_type = if (idr) .i else .p;
        self.slice_header.cabac_init_idc = .@"0";
        self.slice_header.disable_deblocking_filter_idc = .disabled;
        self.slice_header.slice_qp_delta = 0;

        self.slice = .{
            .constant_qp = if (constant_qp) qp else 0,
            .p_std_slice_header = &self.slice_header,
        };
        self.picture.flags = .{
            .idr_pic_flag = idr,
            .is_reference = true,
            .no_output_of_prior_pics_flag = idr,
            .long_term_reference_flag = false,
            .adaptive_ref_pic_marking_mode_flag = false,
        };
        self.picture.seq_parameter_set_id = 0;
        self.picture.pic_parameter_set_id = 0;
        self.picture.idr_pic_id = @intCast((frame_index / @max(gop_size, 1)) & 0xffff);
        self.picture.primary_pic_type = if (idr) .idr else .p;
        self.picture.frame_num = gop_index;
        const poc_mask: u32 = (@as(u32, 1) << @intCast(log_2_max_pic_order_cnt_lsb_minus_4 + 4)) - 1;
        self.picture.pic_order_cnt = @intCast((gop_index * 2) & poc_mask);
        self.picture.p_ref_lists = &self.reference_lists;
        self.picture_info = .{
            .nalu_slice_entry_count = 1,
            .p_nalu_slice_entries = @ptrCast(&self.slice),
            .p_std_picture_info = &self.picture,
            .generate_prefix_nalu = .false,
        };
    }

    pub fn isIdr(self: *const FrameInfo) bool {
        return self.picture.flags.idr_pic_flag;
    }
};

pub fn chooseLevel(extent: vk.Extent2D, frame_rate: capabilities.Rational, bitrate: u64) ?vk.StdVideoH264LevelIdc {
    if (frame_rate.numerator == 0 or frame_rate.denominator == 0) return null;
    const width_mbs = (@as(u64, extent.width) + 15) / 16;
    const height_mbs = (@as(u64, extent.height) + 15) / 16;
    const frame_mbs = width_mbs * height_mbs;
    const mbps = std.math.divCeil(u64, frame_mbs * frame_rate.numerator, frame_rate.denominator) catch return null;
    const limits = [_]struct { level: vk.StdVideoH264LevelIdc, fs: u64, mbps: u64, high_bitrate: u64 }{
        .{ .level = .@"1_0", .fs = 99, .mbps = 1485, .high_bitrate = 80_000 },
        .{ .level = .@"1_1", .fs = 396, .mbps = 3000, .high_bitrate = 240_000 },
        .{ .level = .@"1_2", .fs = 396, .mbps = 6000, .high_bitrate = 480_000 },
        .{ .level = .@"1_3", .fs = 396, .mbps = 11880, .high_bitrate = 960_000 },
        .{ .level = .@"2_0", .fs = 396, .mbps = 11880, .high_bitrate = 2_500_000 },
        .{ .level = .@"2_1", .fs = 792, .mbps = 19800, .high_bitrate = 5_000_000 },
        .{ .level = .@"2_2", .fs = 1620, .mbps = 20250, .high_bitrate = 5_000_000 },
        .{ .level = .@"3_0", .fs = 1620, .mbps = 40500, .high_bitrate = 12_500_000 },
        .{ .level = .@"3_1", .fs = 3600, .mbps = 108000, .high_bitrate = 17_500_000 },
        .{ .level = .@"3_2", .fs = 5120, .mbps = 216000, .high_bitrate = 25_000_000 },
        .{ .level = .@"4_0", .fs = 8192, .mbps = 245760, .high_bitrate = 25_000_000 },
        .{ .level = .@"4_1", .fs = 8192, .mbps = 245760, .high_bitrate = 62_500_000 },
        .{ .level = .@"4_2", .fs = 8704, .mbps = 522240, .high_bitrate = 62_500_000 },
        .{ .level = .@"5_0", .fs = 22080, .mbps = 589824, .high_bitrate = 168_750_000 },
        .{ .level = .@"5_1", .fs = 36864, .mbps = 983040, .high_bitrate = 300_000_000 },
        .{ .level = .@"5_2", .fs = 36864, .mbps = 2073600, .high_bitrate = 300_000_000 },
        .{ .level = .@"6_0", .fs = 139264, .mbps = 4177920, .high_bitrate = 750_000_000 },
        .{ .level = .@"6_1", .fs = 139264, .mbps = 8355840, .high_bitrate = 1_500_000_000 },
        .{ .level = .@"6_2", .fs = 139264, .mbps = 16711680, .high_bitrate = 1_500_000_000 },
    };
    for (limits) |limit| if (frame_mbs <= limit.fs and mbps <= limit.mbps and bitrate <= limit.high_bitrate) return limit.level;
    return null;
}

fn alignForward(value: u32, alignment: u32) !u32 {
    const remainder = value % alignment;
    if (remainder == 0) return value;
    return std.math.add(u32, value, alignment - remainder) catch error.UnsupportedVideoExtent;
}

test "H.264 timing and crop metadata describe the coded image" {
    var sets: ParameterSets = undefined;
    try sets.init(.{ .width = 1920, .height = 1080 }, .{ .numerator = 60, .denominator = 1 }, 60, .high, .@"5_2", 12_000_000);
    try std.testing.expectEqual(vk.StdVideoH264LevelIdc.@"4_2", sets.sps.level_idc);
    try std.testing.expectEqual(@as(u32, 1), sets.vui.num_units_in_tick);
    try std.testing.expectEqual(@as(u32, 120), sets.vui.time_scale);
    try std.testing.expectEqual(@as(u32, 4), sets.sps.frame_crop_bottom_offset);
    try std.testing.expectEqual(@as(u8, 2), sets.sps.log_2_max_frame_num_minus_4);
    try std.testing.expectEqual(@as(u8, 3), sets.sps.log_2_max_pic_order_cnt_lsb_minus_4);
    try std.testing.expect(sets.sps.flags.frame_cropping_flag);
}

test "GOP state starts with IDR then references the preceding slot" {
    var frame: FrameInfo = undefined;
    frame.init(0, 60, 3, false, 26);
    try std.testing.expect(frame.isIdr());
    frame.init(1, 60, 3, false, 26);
    try std.testing.expect(!frame.isIdr());
    try std.testing.expectEqual(@as(u8, 0), frame.reference_lists.ref_pic_list_0[0]);
    frame.init(60, 60, 3, false, 26);
    try std.testing.expect(frame.isIdr());
}
