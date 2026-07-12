const std = @import("std");
const vk = @import("_vk_video");
const capabilities = @import("capabilities.zig");

/// Minimal Main-profile HEVC parameter set for a progressive 8-bit 4:2:0
/// stream. The encoder uses a flat IP GOP and one short-term reference.
pub const ParameterSets = struct {
    profile_tier_level: vk.StdVideoH265ProfileTierLevel,
    dpb: vk.StdVideoH265DecPicBufMgr,
    short_term: vk.StdVideoH265ShortTermRefPicSet,
    vui: vk.StdVideoH265SequenceParameterSetVui,
    vps: vk.StdVideoH265VideoParameterSet,
    sps: vk.StdVideoH265SequenceParameterSet,
    pps: vk.StdVideoH265PictureParameterSet,

    pub fn init(self: *ParameterSets, extent: vk.Extent2D, rate: capabilities.Rational, profile: vk.StdVideoH265ProfileIdc, level: vk.StdVideoH265LevelIdc) !void {
        const timing = try rate.reduced();
        const width = try alignForward(extent.width, 8);
        const height = try alignForward(extent.height, 8);
        self.* = std.mem.zeroes(ParameterSets);
        self.profile_tier_level.general_profile_idc = profile;
        self.profile_tier_level.general_level_idc = level;
        self.profile_tier_level.flags.general_progressive_source_flag = true;
        self.profile_tier_level.flags.general_frame_only_constraint_flag = true;
        self.dpb.max_dec_pic_buffering_minus_1[0] = 1;
        self.short_term.num_negative_pics = 1;
        self.short_term.used_by_curr_pic_s_0_flag = 1;
        self.vui.flags.vui_timing_info_present_flag = true;
        self.vui.flags.vui_poc_proportional_to_timing_flag = true;
        self.vui.vui_num_units_in_tick = timing.denominator;
        self.vui.vui_time_scale = timing.numerator;
        self.vui.vui_num_ticks_poc_diff_one_minus_1 = 0;

        self.vps.flags = .{ .vps_temporal_id_nesting_flag = true, .vps_sub_layer_ordering_info_present_flag = true };
        self.vps.p_profile_tier_level = &self.profile_tier_level;
        self.vps.p_dec_pic_buf_mgr = &self.dpb;

        self.sps.flags = .{
            .sps_temporal_id_nesting_flag = true,
            .conformance_window_flag = width != extent.width or height != extent.height,
            .sps_sub_layer_ordering_info_present_flag = true,
            .amp_enabled_flag = true,
            .strong_intra_smoothing_enabled_flag = true,
            .vui_parameters_present_flag = true,
        };
        self.sps.chroma_format_idc = .@"420";
        self.sps.pic_width_in_luma_samples = width;
        self.sps.pic_height_in_luma_samples = height;
        self.sps.log_2_max_pic_order_cnt_lsb_minus_4 = 4;
        self.sps.log_2_min_luma_coding_block_size_minus_3 = 0;
        self.sps.log_2_diff_max_min_luma_coding_block_size = 3;
        self.sps.log_2_min_luma_transform_block_size_minus_2 = 0;
        self.sps.log_2_diff_max_min_luma_transform_block_size = 3;
        self.sps.max_transform_hierarchy_depth_inter = 3;
        self.sps.max_transform_hierarchy_depth_intra = 3;
        self.sps.num_short_term_ref_pic_sets = 1;
        self.sps.conf_win_right_offset = (width - extent.width) / 2;
        self.sps.conf_win_bottom_offset = (height - extent.height) / 2;
        self.sps.p_profile_tier_level = &self.profile_tier_level;
        self.sps.p_dec_pic_buf_mgr = &self.dpb;
        self.sps.p_short_term_ref_pic_set = @ptrCast(&self.short_term);
        self.sps.p_sequence_parameter_set_vui = &self.vui;

        self.pps.flags = .{ .cabac_init_present_flag = true, .deblocking_filter_control_present_flag = true };
    }
};

pub const FrameInfo = struct {
    lists: vk.StdVideoEncodeH265ReferenceListsInfo,
    slice_header: vk.StdVideoEncodeH265SliceSegmentHeader,
    slice: vk.VideoEncodeH265NaluSliceSegmentInfoKHR,
    picture: vk.StdVideoEncodeH265PictureInfo,
    picture_info: vk.VideoEncodeH265PictureInfoKHR,

    pub fn init(self: *FrameInfo, frame_index: u64, gop_size: u32, constant_qp: bool, qp: i32) void {
        self.* = std.mem.zeroes(FrameInfo);
        const gop_index: u32 = @intCast(frame_index % gop_size);
        const idr = gop_index == 0;
        self.lists.ref_pic_list_0 = @splat(vk.STD_VIDEO_H265_NO_REFERENCE_PICTURE);
        self.lists.ref_pic_list_1 = @splat(vk.STD_VIDEO_H265_NO_REFERENCE_PICTURE);
        if (!idr) self.lists.ref_pic_list_0[0] = @intCast((gop_index - 1) & 1);
        self.slice_header.flags.first_slice_segment_in_pic_flag = true;
        self.slice_header.slice_type = if (idr) .i else .p;
        self.slice_header.max_num_merge_cand = 5;
        self.slice = .{ .constant_qp = if (constant_qp) qp else 0, .p_std_slice_segment_header = &self.slice_header };
        self.picture.flags = std.mem.zeroes(vk.StdVideoEncodeH265PictureInfoFlags);
        self.picture.flags.is_reference = true;
        self.picture.flags.irap_pic_flag = idr;
        self.picture.flags.no_output_of_prior_pics_flag = idr;
        self.picture.flags.pic_output_flag = true;
        self.picture.flags.short_term_ref_pic_set_sps_flag = true;
        self.picture.pic_type = if (idr) .idr else .p;
        self.picture.pic_order_cnt_val = @intCast(gop_index);
        self.picture.p_ref_lists = &self.lists;
        self.picture_info = .{
            .nalu_slice_segment_entry_count = 1,
            .p_nalu_slice_segment_entries = @ptrCast(&self.slice),
            .p_std_picture_info = &self.picture,
        };
    }
};

fn alignForward(value: u32, alignment: u32) !u32 {
    const remainder = value % alignment;
    return if (remainder == 0) value else std.math.add(u32, value, alignment - remainder) catch error.UnsupportedVideoExtent;
}

test "HEVC parameter and frame metadata initialize" {
    var sets: ParameterSets = undefined;
    try sets.init(.{ .width = 1920, .height = 1080 }, .fps(60), .main, .@"5_1");
    try std.testing.expectEqual(@as(u32, 1080), sets.sps.pic_height_in_luma_samples);
    var frame: FrameInfo = undefined;
    frame.init(1, 60, false, 26);
    try std.testing.expectEqual(vk.StdVideoH265PictureType.p, frame.picture.pic_type);
}
