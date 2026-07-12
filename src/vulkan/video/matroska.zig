const std = @import("std");

pub const FrameRate = struct {
    numerator: u32,
    denominator: u32,
};

pub const Extent = struct {
    width: u32,
    height: u32,
};

pub const CodecState = struct {
    parameter_sets: []const u8,
    extent: Extent,
};

pub const Codec = enum { h264, h265, av1 };

/// Codec-dispatching facade used by the Vulkan recorder. AVC keeps its codec
/// private data path below; HEVC and AV1 are written as streaming tracks with
/// in-band sequence headers.
pub const RecordingMuxer = union(Codec) {
    h264: Muxer,
    h265: ElementaryMuxer,
    av1: ElementaryMuxer,

    pub fn init(writer: *std.Io.Writer, frame_rate: FrameRate, extent: Extent, parameter_sets: []const u8, variable: bool, codec: Codec) !RecordingMuxer {
        return switch (codec) {
            .h264 => .{ .h264 = try Muxer.init(writer, frame_rate, extent, parameter_sets, variable) },
            .h265 => .{ .h265 = try ElementaryMuxer.init(writer, frame_rate, extent, variable, .h265) },
            .av1 => .{ .av1 = try ElementaryMuxer.init(writer, frame_rate, extent, variable, .av1) },
        };
    }

    pub fn writeFrame(self: *RecordingMuxer, prefix: ?[]const u8, state: ?CodecState, packet: []const u8, keyframe: bool, timestamp_ns: u64) !void {
        return switch (self.*) {
            .h264 => |*muxer| muxer.writeFrame(prefix, state, packet, keyframe, timestamp_ns),
            inline .h265, .av1 => |*muxer| muxer.writeFrame(prefix, state, packet, keyframe, timestamp_ns),
        };
    }
};

const ElementaryMuxer = struct {
    writer: *std.Io.Writer,
    codec: Codec,
    extent: Extent,
    default_duration: ?u64,
    last_timestamp_ns: ?u64 = null,

    fn init(writer: *std.Io.Writer, rate: FrameRate, extent: Extent, variable: bool, codec: Codec) !ElementaryMuxer {
        if (rate.numerator == 0 or rate.denominator == 0) return error.InvalidFrameRate;
        if (extent.width == 0 or extent.height == 0) return error.UnsupportedVideoExtent;
        const duration = if (variable) null else try defaultDuration(rate);
        try writeEbmlHeader(writer);
        try writeId(writer, ids.segment);
        try writer.writeAll(&.{ 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff });
        try writeInfo(writer);
        try writeElementaryTracks(writer, extent, duration, codec);
        return .{ .writer = writer, .codec = codec, .extent = extent, .default_duration = duration };
    }

    fn writeFrame(self: *ElementaryMuxer, prefix: ?[]const u8, state: ?CodecState, packet: []const u8, keyframe: bool, timestamp_ns: u64) !void {
        if (self.last_timestamp_ns) |previous| if (timestamp_ns <= previous) return error.NonMonotonicFrameTimestamp;
        const prefix_size: u64 = if (prefix) |bytes| try elementarySampleSize(self.codec, bytes) else 0;
        const packet_size = try elementarySampleSize(self.codec, packet);
        const sample_size = try checkedAdd(prefix_size, packet_size);
        const block_payload = try checkedAdd(4, sample_size);
        const timestamp = timestampTicks(timestamp_ns, Muxer.timestamp_scale_ns);
        const timestamp_size = try uintElementLength(ids.timestamp, timestamp);
        const block_size = try elementLength(ids.simple_block, block_payload);
        if (state) |new_state| try writeElementaryTracks(self.writer, new_state.extent, self.default_duration, self.codec);
        try writeElementHeader(self.writer, ids.cluster, try checkedAdd(timestamp_size, block_size));
        try writeUIntElement(self.writer, ids.timestamp, timestamp);
        try writeElementHeader(self.writer, ids.simple_block, block_payload);
        try self.writer.writeAll(&.{ 0x81, 0x00, 0x00, if (keyframe) 0x80 else 0x00 });
        if (prefix) |bytes| try writeElementarySample(self.writer, self.codec, bytes);
        try writeElementarySample(self.writer, self.codec, packet);
        if (state) |new_state| self.extent = new_state.extent;
        self.last_timestamp_ns = timestamp_ns;
    }
};

/// A forward-only Matroska muxer for the recorder's H.264 stream.
///
/// The Segment has an unknown size, as permitted for live Matroska streams,
/// so the caller's writer does not need to seek. Each frame gets a known-size
/// Cluster and block. H.264 NAL units are converted from Annex B to the
/// four-byte length-prefixed AVC representation required by Matroska. A
/// resolution change uses a new Track description and BlockGroup CodecState.
pub const Muxer = struct {
    writer: *std.Io.Writer,
    frame_rate: FrameRate,
    variable_timestamps: bool,
    extent: Extent,
    default_duration: ?u64,
    last_timestamp_ns: ?u64 = null,

    const timestamp_scale_ns: u64 = 1;

    pub fn init(
        writer: *std.Io.Writer,
        frame_rate: FrameRate,
        extent: Extent,
        parameter_sets: []const u8,
        variable_timestamps: bool,
    ) !Muxer {
        if (frame_rate.numerator == 0 or frame_rate.denominator == 0) return error.InvalidFrameRate;
        if (extent.width == 0 or extent.height == 0) return error.UnsupportedVideoExtent;
        const sets = try findParameterSets(parameter_sets);
        const default_duration = if (variable_timestamps) null else try defaultDuration(frame_rate);

        // Finish all validation and size calculations before the first write,
        // so malformed parameter sets cannot leave a partial container header.
        _ = try ebmlPayloadLength();
        _ = try infoPayloadLength();
        _ = try tracksPayloadLength(extent, default_duration, sets);

        try writeEbmlHeader(writer);
        try writeId(writer, ids.segment);
        try writer.writeAll(&.{ 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff });
        try writeInfo(writer);
        try writeTracks(writer, extent, default_duration, sets);
        return .{
            .writer = writer,
            .frame_rate = frame_rate,
            .variable_timestamps = variable_timestamps,
            .extent = extent,
            .default_duration = default_duration,
        };
    }

    pub fn writeFrame(
        self: *Muxer,
        repeated_parameter_sets: ?[]const u8,
        codec_state: ?CodecState,
        packet: []const u8,
        keyframe: bool,
        timestamp_ns: u64,
    ) !void {
        if (self.last_timestamp_ns) |previous| if (timestamp_ns <= previous) return error.NonMonotonicFrameTimestamp;
        const prefix_size = if (repeated_parameter_sets) |prefix| try avcSampleSize(prefix) else 0;
        const packet_size = try avcSampleSize(packet);
        const sample_size = try checkedAdd(prefix_size, packet_size);
        const block_payload_size = try checkedAdd(4, sample_size);
        const timestamp = timestampTicks(timestamp_ns, timestamp_scale_ns);
        const timestamp_element_size = try uintElementLength(ids.timestamp, timestamp);
        const state_sets = if (codec_state) |state| try findParameterSets(state.parameter_sets) else null;
        const frame_element_size = if (state_sets) |sets| blk: {
            const block_size = try elementLength(ids.block, block_payload_size);
            const state_size = try elementLength(ids.codec_state, try avcConfigurationLength(sets));
            break :blk try elementLength(ids.block_group, try checkedAdd(block_size, state_size));
        } else try elementLength(ids.simple_block, block_payload_size);
        const cluster_payload_size = try checkedAdd(timestamp_element_size, frame_element_size);

        if (codec_state) |state| try writeTracks(self.writer, state.extent, self.default_duration, state_sets.?);
        try writeElementHeader(self.writer, ids.cluster, cluster_payload_size);
        try writeUIntElement(self.writer, ids.timestamp, timestamp);
        if (state_sets) |sets| {
            const block_size = try elementLength(ids.block, block_payload_size);
            const state_size = try elementLength(ids.codec_state, try avcConfigurationLength(sets));
            try writeElementHeader(self.writer, ids.block_group, try checkedAdd(block_size, state_size));
            try writeElementHeader(self.writer, ids.block, block_payload_size);
            try self.writer.writeAll(&.{ 0x81, 0x00, 0x00, 0x00 });
            if (repeated_parameter_sets) |prefix| try writeAvcSample(self.writer, prefix);
            try writeAvcSample(self.writer, packet);
            try writeElementHeader(self.writer, ids.codec_state, try avcConfigurationLength(sets));
            try writeAvcConfiguration(self.writer, sets);
        } else {
            try writeElementHeader(self.writer, ids.simple_block, block_payload_size);
            try self.writer.writeAll(&.{ 0x81, 0x00, 0x00, if (keyframe) 0x80 else 0x00 });
            if (repeated_parameter_sets) |prefix| try writeAvcSample(self.writer, prefix);
            try writeAvcSample(self.writer, packet);
        }
        if (codec_state) |state| self.extent = state.extent;
        self.last_timestamp_ns = timestamp_ns;
    }
};

const ids = struct {
    const ebml: u32 = 0x1a45dfa3;
    const ebml_version: u32 = 0x4286;
    const ebml_read_version: u32 = 0x42f7;
    const ebml_max_id_length: u32 = 0x42f2;
    const ebml_max_size_length: u32 = 0x42f3;
    const doc_type: u32 = 0x4282;
    const doc_type_version: u32 = 0x4287;
    const doc_type_read_version: u32 = 0x4285;

    const segment: u32 = 0x18538067;
    const info: u32 = 0x1549a966;
    const timestamp_scale: u32 = 0x2ad7b1;
    const muxing_app: u32 = 0x4d80;
    const writing_app: u32 = 0x5741;

    const tracks: u32 = 0x1654ae6b;
    const track_entry: u32 = 0xae;
    const track_number: u32 = 0xd7;
    const track_uid: u32 = 0x73c5;
    const track_type: u32 = 0x83;
    const flag_enabled: u32 = 0xb9;
    const flag_default: u32 = 0x88;
    const flag_forced: u32 = 0x55aa;
    const flag_lacing: u32 = 0x9c;
    const default_duration: u32 = 0x23e383;
    const codec_id: u32 = 0x86;
    const codec_private: u32 = 0x63a2;
    const codec_delay: u32 = 0x56aa;
    const seek_pre_roll: u32 = 0x56bb;

    const video: u32 = 0xe0;
    const flag_interlaced: u32 = 0x9a;
    const pixel_width: u32 = 0xb0;
    const pixel_height: u32 = 0xba;
    const colour: u32 = 0x55b0;
    const matrix_coefficients: u32 = 0x55b1;
    const bits_per_channel: u32 = 0x55b2;
    const chroma_subsampling_horz: u32 = 0x55b3;
    const chroma_subsampling_vert: u32 = 0x55b4;
    const chroma_siting_horz: u32 = 0x55b7;
    const chroma_siting_vert: u32 = 0x55b8;
    const color_range: u32 = 0x55b9;
    const transfer_characteristics: u32 = 0x55ba;
    const primaries: u32 = 0x55bb;

    const cluster: u32 = 0x1f43b675;
    const timestamp: u32 = 0xe7;
    const simple_block: u32 = 0xa3;
    const block_group: u32 = 0xa0;
    const block: u32 = 0xa1;
    const codec_state: u32 = 0xa4;
};

const application_name = "low 0.0.0";
const codec_name = "V_MPEG4/ISO/AVC";
const hevc_codec_name = "V_MPEGH/ISO/HEVC";
const av1_codec_name = "V_AV1";

const ParameterSets = struct {
    sps: []const u8,
    pps: []const u8,
};

const StartCode = struct {
    offset: usize,
    length: usize,
};

const AnnexBIterator = struct {
    bytes: []const u8,
    cursor: usize = 0,

    fn next(self: *AnnexBIterator) !?[]const u8 {
        while (self.cursor < self.bytes.len) {
            const start = findStartCode(self.bytes, self.cursor) orelse return error.MalformedAnnexB;
            for (self.bytes[self.cursor..start.offset]) |byte| if (byte != 0) return error.MalformedAnnexB;
            const payload_start = start.offset + start.length;
            const following = findStartCode(self.bytes, payload_start);
            const payload_end = if (following) |next_start| next_start.offset else self.bytes.len;
            self.cursor = if (following) |next_start| next_start.offset else self.bytes.len;
            if (payload_start == payload_end) continue;
            return self.bytes[payload_start..payload_end];
        }
        return null;
    }
};

fn findStartCode(bytes: []const u8, start: usize) ?StartCode {
    var index = start;
    while (index + 3 <= bytes.len) : (index += 1) {
        if (index + 4 <= bytes.len and
            bytes[index] == 0 and bytes[index + 1] == 0 and
            bytes[index + 2] == 0 and bytes[index + 3] == 1)
        {
            return .{ .offset = index, .length = 4 };
        }
        if (bytes[index] == 0 and bytes[index + 1] == 0 and bytes[index + 2] == 1) {
            return .{ .offset = index, .length = 3 };
        }
    }
    return null;
}

fn findParameterSets(bytes: []const u8) !ParameterSets {
    var sps: ?[]const u8 = null;
    var pps: ?[]const u8 = null;
    var iterator = AnnexBIterator{ .bytes = bytes };
    while (try iterator.next()) |nal| {
        switch (nal[0] & 0x1f) {
            7 => {
                if (sps == null) sps = nal;
            },
            8 => {
                if (pps == null) pps = nal;
            },
            else => {},
        }
    }
    const result = ParameterSets{ .sps = sps orelse return error.MissingParameterSets, .pps = pps orelse return error.MissingParameterSets };
    if (result.sps.len < 4 or result.sps.len > std.math.maxInt(u16) or result.pps.len > std.math.maxInt(u16)) {
        return error.MalformedParameterSets;
    }
    return result;
}

fn avcSampleSize(bytes: []const u8) !u64 {
    var iterator = AnnexBIterator{ .bytes = bytes };
    var result: u64 = 0;
    var count: usize = 0;
    while (try iterator.next()) |nal| {
        if (nal.len > std.math.maxInt(u32)) return error.EncodedPacketOutOfBounds;
        result = try checkedAdd(result, try checkedAdd(4, nal.len));
        count += 1;
    }
    if (count == 0) return error.MalformedAnnexB;
    return result;
}

fn writeAvcSample(writer: *std.Io.Writer, bytes: []const u8) !void {
    var iterator = AnnexBIterator{ .bytes = bytes };
    while (try iterator.next()) |nal| {
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(nal.len), .big);
        try writer.writeAll(&length);
        try writer.writeAll(nal);
    }
}

fn avcConfigurationLength(sets: ParameterSets) !u64 {
    var result = try checkedAdd(11, try checkedAdd(sets.sps.len, sets.pps.len));
    if (usesExtendedAvcConfiguration(sets.sps[1])) result = try checkedAdd(result, 4);
    return result;
}

fn usesExtendedAvcConfiguration(profile: u8) bool {
    // The recorder currently negotiates Baseline, Main, or High. High's
    // AVCDecoderConfigurationRecord carries the 4:2:0 and 8-bit extension.
    return profile == 100;
}

fn writeAvcConfiguration(writer: *std.Io.Writer, sets: ParameterSets) !void {
    try writer.writeAll(&.{ 1, sets.sps[1], sets.sps[2], sets.sps[3], 0xff, 0xe1 });
    var length: [2]u8 = undefined;
    std.mem.writeInt(u16, &length, @intCast(sets.sps.len), .big);
    try writer.writeAll(&length);
    try writer.writeAll(sets.sps);
    try writer.writeByte(1);
    std.mem.writeInt(u16, &length, @intCast(sets.pps.len), .big);
    try writer.writeAll(&length);
    try writer.writeAll(sets.pps);
    if (usesExtendedAvcConfiguration(sets.sps[1])) try writer.writeAll(&.{ 0xfd, 0xf8, 0xf8, 0x00 });
}

fn ebmlPayloadLength() !u64 {
    var result: u64 = 0;
    result = try checkedAdd(result, try uintElementLength(ids.ebml_version, 1));
    result = try checkedAdd(result, try uintElementLength(ids.ebml_read_version, 1));
    result = try checkedAdd(result, try uintElementLength(ids.ebml_max_id_length, 4));
    result = try checkedAdd(result, try uintElementLength(ids.ebml_max_size_length, 8));
    result = try checkedAdd(result, try binaryElementLength(ids.doc_type, "matroska".len));
    result = try checkedAdd(result, try uintElementLength(ids.doc_type_version, 4));
    result = try checkedAdd(result, try uintElementLength(ids.doc_type_read_version, 2));
    return result;
}

fn writeEbmlHeader(writer: *std.Io.Writer) !void {
    try writeElementHeader(writer, ids.ebml, try ebmlPayloadLength());
    try writeUIntElement(writer, ids.ebml_version, 1);
    try writeUIntElement(writer, ids.ebml_read_version, 1);
    try writeUIntElement(writer, ids.ebml_max_id_length, 4);
    try writeUIntElement(writer, ids.ebml_max_size_length, 8);
    try writeBinaryElement(writer, ids.doc_type, "matroska");
    try writeUIntElement(writer, ids.doc_type_version, 4);
    try writeUIntElement(writer, ids.doc_type_read_version, 2);
}

fn infoPayloadLength() !u64 {
    var result: u64 = 0;
    result = try checkedAdd(result, try uintElementLength(ids.timestamp_scale, Muxer.timestamp_scale_ns));
    result = try checkedAdd(result, try binaryElementLength(ids.muxing_app, application_name.len));
    result = try checkedAdd(result, try binaryElementLength(ids.writing_app, application_name.len));
    return result;
}

fn writeInfo(writer: *std.Io.Writer) !void {
    try writeElementHeader(writer, ids.info, try infoPayloadLength());
    try writeUIntElement(writer, ids.timestamp_scale, Muxer.timestamp_scale_ns);
    try writeBinaryElement(writer, ids.muxing_app, application_name);
    try writeBinaryElement(writer, ids.writing_app, application_name);
}

fn colourPayloadLength() !u64 {
    var result: u64 = 0;
    result = try checkedAdd(result, try uintElementLength(ids.matrix_coefficients, 1));
    result = try checkedAdd(result, try uintElementLength(ids.bits_per_channel, 8));
    result = try checkedAdd(result, try uintElementLength(ids.chroma_subsampling_horz, 1));
    result = try checkedAdd(result, try uintElementLength(ids.chroma_subsampling_vert, 1));
    result = try checkedAdd(result, try uintElementLength(ids.chroma_siting_horz, 2));
    result = try checkedAdd(result, try uintElementLength(ids.chroma_siting_vert, 2));
    result = try checkedAdd(result, try uintElementLength(ids.color_range, 1));
    result = try checkedAdd(result, try uintElementLength(ids.transfer_characteristics, 1));
    result = try checkedAdd(result, try uintElementLength(ids.primaries, 1));
    return result;
}

fn videoPayloadLength(extent: Extent) !u64 {
    var result: u64 = 0;
    result = try checkedAdd(result, try uintElementLength(ids.flag_interlaced, 2));
    result = try checkedAdd(result, try uintElementLength(ids.pixel_width, extent.width));
    result = try checkedAdd(result, try uintElementLength(ids.pixel_height, extent.height));
    result = try checkedAdd(result, try elementLength(ids.colour, try colourPayloadLength()));
    return result;
}

fn trackEntryPayloadLength(extent: Extent, duration: ?u64, sets: ParameterSets) !u64 {
    var result: u64 = 0;
    result = try checkedAdd(result, try uintElementLength(ids.track_number, 1));
    result = try checkedAdd(result, try uintElementLength(ids.track_uid, 1));
    result = try checkedAdd(result, try uintElementLength(ids.track_type, 1));
    result = try checkedAdd(result, try uintElementLength(ids.flag_enabled, 1));
    result = try checkedAdd(result, try uintElementLength(ids.flag_default, 1));
    result = try checkedAdd(result, try uintElementLength(ids.flag_forced, 0));
    result = try checkedAdd(result, try uintElementLength(ids.flag_lacing, 0));
    if (duration) |value| result = try checkedAdd(result, try uintElementLength(ids.default_duration, value));
    result = try checkedAdd(result, try binaryElementLength(ids.codec_id, codec_name.len));
    result = try checkedAdd(result, try elementLength(ids.codec_private, try avcConfigurationLength(sets)));
    result = try checkedAdd(result, try uintElementLength(ids.codec_delay, 0));
    result = try checkedAdd(result, try uintElementLength(ids.seek_pre_roll, 0));
    result = try checkedAdd(result, try elementLength(ids.video, try videoPayloadLength(extent)));
    return result;
}

fn tracksPayloadLength(extent: Extent, duration: ?u64, sets: ParameterSets) !u64 {
    return elementLength(ids.track_entry, try trackEntryPayloadLength(extent, duration, sets));
}

fn writeTracks(writer: *std.Io.Writer, extent: Extent, duration: ?u64, sets: ParameterSets) !void {
    try writeElementHeader(writer, ids.tracks, try tracksPayloadLength(extent, duration, sets));
    try writeElementHeader(writer, ids.track_entry, try trackEntryPayloadLength(extent, duration, sets));
    try writeUIntElement(writer, ids.track_number, 1);
    try writeUIntElement(writer, ids.track_uid, 1);
    try writeUIntElement(writer, ids.track_type, 1);
    try writeUIntElement(writer, ids.flag_enabled, 1);
    try writeUIntElement(writer, ids.flag_default, 1);
    try writeUIntElement(writer, ids.flag_forced, 0);
    try writeUIntElement(writer, ids.flag_lacing, 0);
    if (duration) |value| try writeUIntElement(writer, ids.default_duration, value);
    try writeBinaryElement(writer, ids.codec_id, codec_name);
    try writeElementHeader(writer, ids.codec_private, try avcConfigurationLength(sets));
    try writeAvcConfiguration(writer, sets);
    try writeUIntElement(writer, ids.codec_delay, 0);
    try writeUIntElement(writer, ids.seek_pre_roll, 0);

    try writeElementHeader(writer, ids.video, try videoPayloadLength(extent));
    try writeUIntElement(writer, ids.flag_interlaced, 2);
    try writeUIntElement(writer, ids.pixel_width, extent.width);
    try writeUIntElement(writer, ids.pixel_height, extent.height);
    try writeElementHeader(writer, ids.colour, try colourPayloadLength());
    try writeUIntElement(writer, ids.matrix_coefficients, 1);
    try writeUIntElement(writer, ids.bits_per_channel, 8);
    try writeUIntElement(writer, ids.chroma_subsampling_horz, 1);
    try writeUIntElement(writer, ids.chroma_subsampling_vert, 1);
    try writeUIntElement(writer, ids.chroma_siting_horz, 2);
    try writeUIntElement(writer, ids.chroma_siting_vert, 2);
    try writeUIntElement(writer, ids.color_range, 1);
    try writeUIntElement(writer, ids.transfer_characteristics, 1);
    try writeUIntElement(writer, ids.primaries, 1);
}

fn elementaryCodecName(codec: Codec) []const u8 {
    return switch (codec) {
        .h264 => codec_name,
        .h265 => hevc_codec_name,
        .av1 => av1_codec_name,
    };
}

fn elementaryTrackEntryLength(extent: Extent, duration: ?u64, codec: Codec) !u64 {
    var result: u64 = 0;
    inline for (.{ ids.track_number, ids.track_uid, ids.track_type, ids.flag_enabled, ids.flag_default }) |id| result = try checkedAdd(result, try uintElementLength(id, 1));
    result = try checkedAdd(result, try uintElementLength(ids.flag_forced, 0));
    result = try checkedAdd(result, try uintElementLength(ids.flag_lacing, 0));
    if (duration) |value| result = try checkedAdd(result, try uintElementLength(ids.default_duration, value));
    result = try checkedAdd(result, try binaryElementLength(ids.codec_id, elementaryCodecName(codec).len));
    result = try checkedAdd(result, try uintElementLength(ids.codec_delay, 0));
    result = try checkedAdd(result, try uintElementLength(ids.seek_pre_roll, 0));
    return checkedAdd(result, try elementLength(ids.video, try videoPayloadLength(extent)));
}

fn writeElementaryTracks(writer: *std.Io.Writer, extent: Extent, duration: ?u64, codec: Codec) !void {
    const entry_length = try elementaryTrackEntryLength(extent, duration, codec);
    try writeElementHeader(writer, ids.tracks, try elementLength(ids.track_entry, entry_length));
    try writeElementHeader(writer, ids.track_entry, entry_length);
    try writeUIntElement(writer, ids.track_number, 1);
    try writeUIntElement(writer, ids.track_uid, 1);
    try writeUIntElement(writer, ids.track_type, 1);
    try writeUIntElement(writer, ids.flag_enabled, 1);
    try writeUIntElement(writer, ids.flag_default, 1);
    try writeUIntElement(writer, ids.flag_forced, 0);
    try writeUIntElement(writer, ids.flag_lacing, 0);
    if (duration) |value| try writeUIntElement(writer, ids.default_duration, value);
    try writeBinaryElement(writer, ids.codec_id, elementaryCodecName(codec));
    try writeUIntElement(writer, ids.codec_delay, 0);
    try writeUIntElement(writer, ids.seek_pre_roll, 0);
    try writeElementHeader(writer, ids.video, try videoPayloadLength(extent));
    try writeUIntElement(writer, ids.flag_interlaced, 2);
    try writeUIntElement(writer, ids.pixel_width, extent.width);
    try writeUIntElement(writer, ids.pixel_height, extent.height);
    try writeElementHeader(writer, ids.colour, try colourPayloadLength());
    try writeUIntElement(writer, ids.matrix_coefficients, 1);
    try writeUIntElement(writer, ids.bits_per_channel, 8);
    try writeUIntElement(writer, ids.chroma_subsampling_horz, 1);
    try writeUIntElement(writer, ids.chroma_subsampling_vert, 1);
    try writeUIntElement(writer, ids.chroma_siting_horz, 2);
    try writeUIntElement(writer, ids.chroma_siting_vert, 2);
    try writeUIntElement(writer, ids.color_range, 1);
    try writeUIntElement(writer, ids.transfer_characteristics, 1);
    try writeUIntElement(writer, ids.primaries, 1);
}

fn elementarySampleSize(codec: Codec, bytes: []const u8) !u64 {
    if (bytes.len == 0) return error.EncodedPacketOutOfBounds;
    return switch (codec) {
        .h265, .av1 => bytes.len,
        .h264 => unreachable,
    };
}

fn writeElementarySample(writer: *std.Io.Writer, codec: Codec, bytes: []const u8) !void {
    switch (codec) {
        .h265, .av1 => try writer.writeAll(bytes),
        .h264 => unreachable,
    }
}

fn defaultDuration(frame_rate: FrameRate) !u64 {
    const numerator = @as(u128, frame_rate.denominator) * std.time.ns_per_s;
    const rounded = (numerator + frame_rate.numerator / 2) / frame_rate.numerator;
    if (rounded == 0 or rounded > std.math.maxInt(u64)) return error.InvalidFrameRate;
    return @intCast(rounded);
}

fn timestampTicks(timestamp_ns: u64, scale_ns: u64) u64 {
    const quotient = timestamp_ns / scale_ns;
    return quotient + @intFromBool(timestamp_ns % scale_ns >= (scale_ns + 1) / 2);
}

fn checkedAdd(a: u64, b: u64) !u64 {
    return std.math.add(u64, a, b) catch error.MatroskaElementTooLarge;
}

fn idLength(id: u32) usize {
    if (id > 0x00ff_ffff) return 4;
    if (id > 0x0000_ffff) return 3;
    if (id > 0x0000_00ff) return 2;
    return 1;
}

fn uintLength(value: u64) usize {
    if (value == 0) return 1;
    return (@as(usize, std.math.log2_int(u64, value)) / 8) + 1;
}

fn sizeVintLength(value: u64) !usize {
    for (1..9) |length| {
        const value_bits: u6 = @intCast(length * 7);
        const reserved = (@as(u64, 1) << value_bits) - 1;
        if (value < reserved) return length;
    }
    return error.MatroskaElementTooLarge;
}

fn elementLength(id: u32, payload_length: u64) !u64 {
    return checkedAdd(idLength(id) + try sizeVintLength(payload_length), payload_length);
}

fn uintElementLength(id: u32, value: u64) !u64 {
    return elementLength(id, uintLength(value));
}

fn binaryElementLength(id: u32, length: u64) !u64 {
    return elementLength(id, length);
}

fn writeId(writer: *std.Io.Writer, id: u32) !void {
    var encoded: [4]u8 = undefined;
    std.mem.writeInt(u32, &encoded, id, .big);
    try writer.writeAll(encoded[4 - idLength(id) ..]);
}

fn writeSizeVint(writer: *std.Io.Writer, value: u64) !void {
    const length = try sizeVintLength(value);
    var encoded: [8]u8 = @splat(0);
    var remaining = value;
    var index: usize = encoded.len;
    for (0..length) |_| {
        index -= 1;
        encoded[index] = @truncate(remaining);
        remaining >>= 8;
    }
    encoded[index] |= @as(u8, 1) << @intCast(8 - length);
    try writer.writeAll(encoded[index..]);
}

fn writeElementHeader(writer: *std.Io.Writer, id: u32, payload_length: u64) !void {
    try writeId(writer, id);
    try writeSizeVint(writer, payload_length);
}

fn writeUIntElement(writer: *std.Io.Writer, id: u32, value: u64) !void {
    const length = uintLength(value);
    try writeElementHeader(writer, id, length);
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, value, .big);
    try writer.writeAll(encoded[encoded.len - length ..]);
}

fn writeBinaryElement(writer: *std.Io.Writer, id: u32, bytes: []const u8) !void {
    try writeElementHeader(writer, id, bytes.len);
    try writer.writeAll(bytes);
}

test "streaming Matroska header carries AVC configuration and length-prefixed frames" {
    const parameter_sets = &.{
        0x00, 0x00, 0x00, 0x01, 0x67, 0x64, 0x00, 0x1f, 0xaa,
        0x00, 0x00, 0x01, 0x68, 0xee, 0x3c,
    };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var muxer = try Muxer.init(&output.writer, .{ .numerator = 60, .denominator = 1 }, .{ .width = 640, .height = 480 }, parameter_sets, false);
    try muxer.writeFrame(null, null, &.{ 0x00, 0x00, 0x01, 0x65, 0xaa, 0xbb }, true, 0);

    const bytes = output.written();
    try std.testing.expect(std.mem.startsWith(u8, bytes, &.{ 0x1a, 0x45, 0xdf, 0xa3 }));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "matroska") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, codec_name) != null);
    const expected_avcc = &.{
        0x01, 0x64, 0x00, 0x1f, 0xff, 0xe1,
        0x00, 0x05, 0x67, 0x64, 0x00, 0x1f,
        0xaa, 0x01, 0x00, 0x03, 0x68, 0xee,
        0x3c, 0xfd, 0xf8, 0xf8, 0x00,
    };
    try std.testing.expect(std.mem.indexOf(u8, bytes, expected_avcc) != null);
    try std.testing.expect(std.mem.endsWith(u8, bytes, &.{
        0x81, 0x00, 0x00, 0x80,
        0x00, 0x00, 0x00, 0x03,
        0x65, 0xaa, 0xbb,
    }));
}

test "Matroska timestamps preserve fractional fixed frame rates" {
    const rate = FrameRate{ .numerator = 30_000, .denominator = 1001 };
    try std.testing.expectEqual(@as(u64, 33_366_667), try defaultDuration(rate));
    try std.testing.expectEqual(@as(u64, 0), timestampTicks(0, Muxer.timestamp_scale_ns));
    try std.testing.expectEqual(@as(u64, 33_366_667), timestampTicks(33_366_667, Muxer.timestamp_scale_ns));
}

test "Matroska writes codec state for a resolution change" {
    const parameter_sets = &.{
        0x00, 0x00, 0x00, 0x01, 0x67, 0x64, 0x00, 0x1f, 0xaa,
        0x00, 0x00, 0x01, 0x68, 0xee, 0x3c,
    };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var muxer = try Muxer.init(&output.writer, .{ .numerator = 60, .denominator = 1 }, .{ .width = 640, .height = 480 }, parameter_sets, true);
    try muxer.writeFrame(null, null, &.{ 0x00, 0x00, 0x01, 0x65, 0xaa }, true, 0);
    const before_change = output.written().len;
    try muxer.writeFrame(parameter_sets, .{
        .parameter_sets = parameter_sets,
        .extent = .{ .width = 800, .height = 464 },
    }, &.{ 0x00, 0x00, 0x01, 0x65, 0xbb }, true, 1_000_000_000);

    const changed = output.written()[before_change..];
    try std.testing.expect(std.mem.indexOf(u8, changed, &.{ 0x16, 0x54, 0xae, 0x6b }) != null);
    try std.testing.expect(std.mem.indexOf(u8, changed, &.{0xa0}) != null);
    try std.testing.expect(std.mem.indexOf(u8, changed, &.{0xa4}) != null);
    try std.testing.expectEqual(Extent{ .width = 800, .height = 464 }, muxer.extent);
}

test "Matroska validates packets before writing and converts repeated parameter sets" {
    const parameter_sets = &.{
        0x00, 0x00, 0x00, 0x01, 0x67, 0x4d, 0x00, 0x1f,
        0x00, 0x00, 0x01, 0x68, 0xee,
    };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var muxer = try Muxer.init(&output.writer, .{ .numerator = 24, .denominator = 1 }, .{ .width = 64, .height = 64 }, parameter_sets, true);
    const header_length = output.written().len;
    try std.testing.expectError(error.MalformedAnnexB, muxer.writeFrame(null, null, &.{ 0x65, 0xaa }, true, 1_000_000));
    try std.testing.expectEqual(header_length, output.written().len);

    try muxer.writeFrame(parameter_sets, null, &.{ 0x00, 0x00, 0x01, 0x65, 0xaa }, true, 1_000_000);
    try std.testing.expect(std.mem.endsWith(u8, output.written(), &.{
        0x81, 0x00, 0x00, 0x80,
        0x00, 0x00, 0x00, 0x04,
        0x67, 0x4d, 0x00, 0x1f,
        0x00, 0x00, 0x00, 0x02,
        0x68, 0xee, 0x00, 0x00,
        0x00, 0x02, 0x65, 0xaa,
    }));
}

test "Matroska rejects incomplete parameter sets before writing" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectError(error.MissingParameterSets, Muxer.init(
        &output.writer,
        .{ .numerator = 60, .denominator = 1 },
        .{ .width = 64, .height = 64 },
        &.{ 0x00, 0x00, 0x01, 0x67, 0x64, 0x00, 0x1f },
        false,
    ));
    try std.testing.expectEqual(@as(usize, 0), output.written().len);
}

test "recording muxer labels and packages HEVC and AV1" {
    var hevc_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer hevc_output.deinit();
    var hevc = try RecordingMuxer.init(&hevc_output.writer, .{ .numerator = 60, .denominator = 1 }, .{ .width = 64, .height = 64 }, &.{}, false, .h265);
    try hevc.writeFrame(null, null, &.{ 0, 0, 0, 1, 0x26, 0x01, 0xaa }, true, 0);
    try std.testing.expect(std.mem.indexOf(u8, hevc_output.written(), hevc_codec_name) != null);
    try std.testing.expect(std.mem.endsWith(u8, hevc_output.written(), &.{ 0, 0, 0, 1, 0x26, 0x01, 0xaa }));

    var av1_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer av1_output.deinit();
    var av1_muxer = try RecordingMuxer.init(&av1_output.writer, .{ .numerator = 60, .denominator = 1 }, .{ .width = 64, .height = 64 }, &.{}, false, .av1);
    try av1_muxer.writeFrame(null, null, &.{ 0x12, 0x00, 0x32, 0x01, 0xaa }, true, 0);
    try std.testing.expect(std.mem.indexOf(u8, av1_output.written(), av1_codec_name) != null);
    try std.testing.expect(std.mem.endsWith(u8, av1_output.written(), &.{ 0x12, 0x00, 0x32, 0x01, 0xaa }));
}
