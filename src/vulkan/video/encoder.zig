const std = @import("std");
const vk = @import("_vk_video");
const low_vk = @import("../api.zig");
const recording_submit = @import("../recording_submit.zig");
const capabilities = @import("capabilities.zig");
const conversion = @import("conversion.zig");
const h264 = @import("h264.zig");
const h265 = @import("h265.zig");
const av1 = @import("av1.zig");
const matroska = @import("matroska.zig");
const VideoDevice = @import("device.zig").VideoDevice;

pub const RecordingFormat = enum {
    /// Elementary stream in the selected codec's native byte-stream format.
    /// It cannot carry timestamps; use `.mkv` for variable-rate output.
    raw,
    /// Streaming Matroska container. This is the recommended default: it
    /// supports variable timestamps and resizing.
    mkv,
};

/// Selects how recorded frames are timestamped and supplies the nominal rate
/// required to configure the selected encoder.
///
/// Variable-rate timing (`.monotonic`) requires `.mkv` output; raw elementary
/// streams have no container timestamps.
pub const RecordingTiming = union(enum) {
    /// Space accepted frames evenly at this rate. Automatic per-frame rate
    /// limiting uses the same rate so faster presentation does not slow down
    /// playback.
    fixed_rate: capabilities.FrameRate,
    /// Timestamp accepted frames from the monotonic clock or a per-frame
    /// caller timestamp. Frames can have variable spacing; the carried rate
    /// is also the automatic capture cap.
    monotonic: capabilities.FrameRate,

    pub fn frameRate(self: RecordingTiming) capabilities.FrameRate {
        return switch (self) {
            inline else => |frame_rate| frame_rate,
        };
    }

    pub fn isFixedRate(self: RecordingTiming) bool {
        return self == .fixed_rate;
    }
};

/// Configuration for `RenderTarget.beginRecording` or `Recorder.begin`.
///
/// Typical window recording needs only `io` and `writer`; the
/// defaults produce a 60 fps, 12 Mbps Matroska file. Call `endRecording` (or
/// `Recorder.end`) before closing the writer so pending GPU work is drained
/// and the container is finalized.
///
/// The recorder accepts BGRA8 and packed 10-bit UNORM render-target frames.
/// Packed 10-bit sources are converted to the recorder's 8-bit 4:2:0 encode
/// input; it does not capture audio.
pub const RecordingOptions = struct {
    /// Clock used by `.timing.monotonic`.
    io: std.Io,
    /// Destination for the encoded stream. The caller owns and closes it after
    /// `endRecording` completes.
    writer: *std.Io.Writer,
    /// Select timestamp behavior and the nominal encoder rate. Use `.fps(60)`
    /// for whole-number rates or `.init(30_000, 1001)` for exact fractions.
    timing: RecordingTiming = .{ .monotonic = .fps(60) },
    /// Target video bitrate in bits per second. Higher values preserve detail
    /// but increase file size; 12 Mbps is a reasonable 1080p starting point.
    bitrate: u32 = 12_000_000,
    /// Maximum frames between IDR keyframes. Smaller values improve seeking
    /// and recovery but increase bitrate; 60 is about one second at 60 fps.
    gop_size: u32 = 60,
    /// Encoder tuning preference. `.balanced` is the portable default;
    /// `.low_latency` and `.high_quality` need matching device support.
    quality: capabilities.Quality = .balanced,
    /// Behavior when the render target changes size. For window capture,
    /// `.change_resolution` preserves pixels; `.scale_and_letterbox` keeps one
    /// encoded size; `.stop_recording` gives the caller a clean boundary.
    resize: capabilities.ResizePolicy = .scale_and_letterbox,
    /// Whether to repeat H.264/H.265 parameter sets at keyframes. Keep the
    /// default for streaming or independently decodable segments.
    parameter_sets: capabilities.ParameterSetPolicy = .every_idr,
    /// `.mkv` is recommended. `.raw` only supports fixed-rate output.
    format: RecordingFormat = .mkv,
};

pub const RecordingStatus = union(enum) {
    /// Frames are being accepted and encoded.
    recording,
    /// A recording error occurred; the payload is the first error retained by
    /// the recorder. End the recording before reusing the target.
    failed: anyerror,
    /// The source resized while using `.resize = .stop_recording`.
    stopped_resize,
};

pub const PreparedFrame = struct {
    signal_semaphore: low_vk.Semaphore,
};

pub const Recorder = struct {
    allocator: std.mem.Allocator,
    video_device: *VideoDevice,
    graphics_queue_family: u32,
    frames_in_flight: u32,
    color_format: low_vk.Format,
    cache: ?*Cache = null,
    run: ?Run = null,
    prepared_slot: ?usize = null,
    last_error: ?anyerror = null,
    cache_poisoned: bool = false,

    const Run = struct {
        io: std.Io,
        writer: *std.Io.Writer,
        timing: RecordingTiming,
        bitrate: u32,
        gop_size: u32,
        quality: capabilities.Quality,
        resize: capabilities.ResizePolicy,
        parameter_sets: capabilities.ParameterSetPolicy,
        codec: capabilities.Codec,
        format: RecordingFormat,
        mkv: ?matroska.RecordingMuxer = null,
        start_time_ns: i128,
        output_frames: u64 = 0,
        last_timestamp_ns: ?u64 = null,
        rate_state: ?CaptureRateState = null,
        source_extent: low_vk.Extent2D,
        submitted: u64 = 0,
        consumed: u64 = 0,
        accepting: bool = true,
        stopped_resize: bool = false,
        sticky_error: ?anyerror = null,
        pending_sequence_header: bool = false,
    };

    const ResolvedRateLimit = struct {
        numerator: u64,
        denominator: u64,
    };

    const CaptureRateState = struct {
        limit: ResolvedRateLimit,
        origin_ns: u64,
        slot: u64,
    };

    pub const SelectedFrame = struct {
        timestamp_ns: u64,
        rate_state: ?CaptureRateState,
    };

    pub fn init(allocator: std.mem.Allocator, video_device: *VideoDevice, graphics_queue_family: u32, frames_in_flight: u32, color_format: low_vk.Format) Recorder {
        return .{
            .allocator = allocator,
            .video_device = video_device,
            .graphics_queue_family = graphics_queue_family,
            .frames_in_flight = frames_in_flight,
            .color_format = color_format,
        };
    }

    pub fn deinit(self: *Recorder) void {
        self.end() catch {};
        self.releaseResources();
        self.* = undefined;
    }

    pub fn begin(self: *Recorder, extent: low_vk.Extent2D, options: RecordingOptions) !void {
        if (self.run != null) return error.RecordingAlreadyActive;
        if (self.cache_poisoned) self.releaseResources();
        if (self.frames_in_flight == 0) return error.InvalidFramesInFlight;
        if (!sourceFormatSupported(self.color_format)) return error.UnsupportedSourceFormat;
        const codec = self.video_device.codec;
        try validateRecordingCodec(codec);
        try options.timing.frameRate().validate();
        if (options.bitrate == 0) return error.InvalidBitrate;
        if (options.gop_size == 0) return error.InvalidGopSize;
        if (options.format != .mkv and !options.timing.isFixedRate()) return error.TimestampedOutputRequiresMkv;

        _ = try self.configureCache(extent, options, codec, true);

        var run = Run{
            .io = options.io,
            .writer = options.writer,
            .timing = options.timing,
            .bitrate = options.bitrate,
            .gop_size = options.gop_size,
            .quality = options.quality,
            .resize = options.resize,
            .parameter_sets = options.parameter_sets,
            .codec = codec,
            .format = options.format,
            .start_time_ns = 0,
            .source_extent = extent,
        };
        // Container headers are written synchronously so a failed output is
        // reported by begin and cannot leave an apparently active recorder.
        switch (run.format) {
            .raw => {
                if (run.codec == .av1) try run.writer.writeAll(&av1_temporal_delimiter);
                try run.writer.writeAll(self.cache.?.header);
            },
            .mkv => run.mkv = try matroska.RecordingMuxer.init(
                run.writer,
                .{ .numerator = run.timing.frameRate().numerator, .denominator = run.timing.frameRate().denominator },
                .{ .width = self.cache.?.key.extent.width, .height = self.cache.?.key.extent.height },
                self.cache.?.header,
                !run.timing.isFixedRate(),
                switch (run.codec) {
                    .h264 => .h264,
                    .h265 => .h265,
                    .av1 => .av1,
                },
            ),
        }
        run.start_time_ns = std.Io.Timestamp.now(run.io, .awake).nanoseconds;
        self.run = run;
        self.last_error = null;
    }

    fn configureCache(self: *Recorder, extent: low_vk.Extent2D, options: RecordingOptions, codec: capabilities.Codec, reset_compatible: bool) !bool {
        const query_options = capabilities.QueryH264SupportOptions{
            .instance = self.video_device.low_instance,
            .physical_device = toLowPhysicalDevice(self.video_device.physical_device),
            .extent = extent,
            .allocator = self.allocator,
        };
        const support: AnySupport = switch (codec) {
            .h264 => AnySupport.fromH264(try capabilities.queryH264Support(query_options)),
            .h265 => AnySupport.fromCodec(try capabilities.queryH265Support(query_options)),
            .av1 => AnySupport.fromCodec(try capabilities.queryAV1Support(query_options)),
        };
        if (!support.available) return supportError(support.reason);
        if (support.encode_queue_family.? != self.video_device.encode_queue_family) return error.MissingVideoEncodeQueue;
        if (support.max_dpb_slots < 2 or support.max_active_reference_pictures < 1) return error.UnsupportedVideoProfile;
        if (!support.encode_feedback_flags.bitstream_buffer_offset_bit_khr or
            !support.encode_feedback_flags.bitstream_bytes_written_bit_khr)
        {
            return error.EncodeFeedbackUnavailable;
        }

        const policy = try selectPolicy(support, options.quality);
        if (!policy.rate_control.disabled_bit_khr and
            (support.max_bitrate == 0 or options.bitrate > support.max_bitrate))
        {
            return error.UnsupportedRateControl;
        }
        const key = CacheKey{
            .extent = support.coded_extent,
            .input_format = support.input_format.?,
            .dpb_format = support.dpb_format.?,
            .codec = codec,
            .profile = support.profile,
            .max_level = support.max_level,
            .frame_rate = try options.timing.frameRate().reduced(),
            .bitrate = options.bitrate,
            .gop_size = options.gop_size,
            .quality = options.quality,
            .frames_in_flight = self.frames_in_flight,
            .tuning = policy.tuning,
            .rate_control = policy.rate_control,
            .quality_level = policy.quality_level,
        };

        if (self.cache == null or !std.meta.eql(self.cache.?.key, key)) {
            const replacement = try self.allocator.create(Cache);
            replacement.* = Cache.empty(self.allocator, self.video_device, self.graphics_queue_family, key, support);
            errdefer {
                replacement.deinit();
                self.allocator.destroy(replacement);
            }
            try replacement.create();
            try replacement.initializeVideoSession();
            if (self.cache) |old| {
                old.deinit();
                old.allocator.destroy(old);
            }
            self.cache = replacement;
            return true;
        }

        if (reset_compatible) self.cache.?.initializeVideoSession() catch |err| {
            self.cache_poisoned = true;
            return err;
        };
        return false;
    }

    pub fn end(self: *Recorder) !void {
        if (self.run == null) {
            if (self.last_error) |err| return err;
            return;
        }
        if (self.prepared_slot != null) return error.FrameAlreadyAcquired;
        var run = &self.run.?;
        while (run.consumed < run.submitted) {
            const slot_index: usize = @intCast(run.consumed % self.cache.?.slots.len);
            self.consumeSlot(slot_index) catch |err| {
                if (run.sticky_error == null) run.sticky_error = err;
                if (isSharedError(err)) self.cache_poisoned = true;
                // Even after an output error, continue waiting and releasing
                // remaining GPU work without attempting more writes.
                self.discardSlot(slot_index) catch |discard_err| {
                    if (run.sticky_error == null) run.sticky_error = discard_err;
                    self.cache_poisoned = true;
                    // A fence that cannot be waited cannot be drained by
                    // retrying the same slot. Resource destruction will wait
                    // for the device once more and then discard the cache.
                    run.consumed = run.submitted;
                    break;
                };
            };
        }
        run.writer.flush() catch |err| if (run.sticky_error == null) {
            run.sticky_error = err;
        };
        const result = run.sticky_error;
        self.last_error = result;
        self.run = null;
        if (result) |err| return err;
    }

    pub fn status(self: *const Recorder) ?RecordingStatus {
        const run = self.run orelse return null;
        if (run.sticky_error) |err| return .{ .failed = err };
        if (run.stopped_resize) return .stopped_resize;
        return .recording;
    }

    pub fn isRecording(self: *const Recorder) bool {
        return self.run != null and self.run.?.accepting;
    }

    pub fn codedExtent(self: *const Recorder) ?vk.Extent2D {
        return if (self.cache) |cache| cache.key.extent else null;
    }

    pub fn noticeResize(self: *Recorder, extent: low_vk.Extent2D) !void {
        var run = &(self.run orelse return);
        if (run.source_extent.width == extent.width and run.source_extent.height == extent.height) return;
        switch (run.resize) {
            .scale_and_letterbox => {},
            .stop_recording => {
                run.accepting = false;
                run.stopped_resize = true;
            },
            .change_resolution => self.reconfigureForResize(extent) catch |err| {
                if (isSharedError(err)) {
                    self.failShared(err);
                    return err;
                }
                self.failLocal(err);
            },
        }
    }

    fn reconfigureForResize(self: *Recorder, extent: low_vk.Extent2D) !void {
        if (self.prepared_slot != null) return error.FrameAlreadyAcquired;
        while (self.run.?.consumed < self.run.?.submitted) {
            const slot_index: usize = @intCast(self.run.?.consumed % self.cache.?.slots.len);
            try self.consumeSlot(slot_index);
        }

        const run = &self.run.?;
        const options = RecordingOptions{
            .io = run.io,
            .writer = run.writer,
            .timing = run.timing,
            .bitrate = run.bitrate,
            .gop_size = run.gop_size,
            .quality = run.quality,
            .resize = run.resize,
            .parameter_sets = run.parameter_sets,
            .format = run.format,
        };
        const changed = try self.configureCache(extent, options, run.codec, false);
        self.run.?.source_extent = extent;
        if (!changed) return;
        self.run.?.submitted = 0;
        self.run.?.consumed = 0;
        self.run.?.pending_sequence_header = true;
    }

    /// Resolves this submission's timestamp and rate policy before the render
    /// target records any transfer work. A null result presents the frame but
    /// omits it from the recording.
    pub fn selectFrame(self: *Recorder, options: recording_submit.RecordingOptions) !?SelectedFrame {
        const run = &(self.run orelse return null);
        if (!run.accepting or run.sticky_error != null or options.skip_frame) return null;

        const capture_timestamp_ns = options.timestamp_ns orelse self.monotonicTimestamp();
        const limit = try resolveRateLimit(run.timing, options.rate_limit);
        const rate_state = if (limit) |resolved|
            (try selectRateSlot(run.rate_state, resolved, capture_timestamp_ns)) orelse return null
        else
            null;
        const output_timestamp_ns = switch (run.timing) {
            .fixed_rate => |frame_rate| try fixedFrameTimestamp(run.output_frames, frame_rate),
            .monotonic => capture_timestamp_ns,
        };
        if (run.last_timestamp_ns) |previous| if (output_timestamp_ns <= previous) return error.NonMonotonicFrameTimestamp;
        return .{ .timestamp_ns = output_timestamp_ns, .rate_state = rate_state };
    }

    pub fn prepareFrame(self: *Recorder, command_buffer: low_vk.CommandBuffer, image: low_vk.Image, extent: low_vk.Extent2D, selected: SelectedFrame) !?PreparedFrame {
        const run = &(self.run orelse return null);
        if (!run.accepting or run.sticky_error != null) return null;
        std.debug.assert(self.prepared_slot == null);
        const cache = self.cache.?;
        const slot_index: usize = @intCast(run.submitted % cache.slots.len);
        if (cache.slots[slot_index].pending) {
            self.consumeSlot(slot_index) catch |err| {
                if (isSharedError(err)) {
                    self.failShared(err);
                    return err;
                }
                self.failLocal(err);
                return null;
            };
        }

        const device = self.video_device.device();
        const slot = &cache.slots[slot_index];
        errdefer |err| self.failShared(err);
        try device.resetCommandBuffer(slot.encode_command_buffer, .{});
        try device.resetCommandBuffer(slot.compute_command_buffer, .{});
        cache.conversion_pipeline.?.recordCopy(
            device,
            toCommandBuffer(command_buffer),
            @enumFromInt(image),
            .{ .width = extent.width, .height = extent.height },
            cache.key.extent,
            slot.conversionImages(),
            slot.initialized,
        );
        try device.beginCommandBuffer(slot.compute_command_buffer, &.{ .flags = .{ .one_time_submit_bit = true } });
        cache.conversion_pipeline.?.recordConversion(
            device,
            slot.compute_command_buffer,
            slot_index,
            cache.key.extent,
            slot.conversionImages(),
            slot.initialized,
        );
        try device.endCommandBuffer(slot.compute_command_buffer);
        try cache.recordEncode(slot_index, run.submitted);
        slot.frame_index = run.submitted;
        slot.is_idr = run.submitted % run.gop_size == 0;
        slot.timestamp_ns = selected.timestamp_ns;
        slot.rate_state = selected.rate_state;
        self.prepared_slot = slot_index;
        return .{ .signal_semaphore = @intFromEnum(slot.copy_finished) };
    }

    pub fn submitPrepared(self: *Recorder) !void {
        const slot_index = self.prepared_slot orelse return;
        const cache = self.cache.?;
        const slot = &cache.slots[slot_index];
        const device = self.video_device.device();
        errdefer |err| {
            self.prepared_slot = null;
            self.failShared(err);
        }
        try device.resetFences(&.{slot.encode_finished});
        const wait_stage = [_]vk.PipelineStageFlags{.{ .all_commands_bit = true }};
        const compute_submit = vk.SubmitInfo{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&slot.copy_finished),
            .p_wait_dst_stage_mask = &wait_stage,
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&slot.compute_command_buffer),
            .signal_semaphore_count = 1,
            .p_signal_semaphores = @ptrCast(&slot.conversion_finished),
        };
        try device.queueSubmit(self.video_device.compute_queue, &.{compute_submit}, .null_handle);
        const encode_submit = vk.SubmitInfo{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&slot.conversion_finished),
            .p_wait_dst_stage_mask = &wait_stage,
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&slot.encode_command_buffer),
        };
        try device.queueSubmit(self.video_device.encode_queue, &.{encode_submit}, slot.encode_finished);
        slot.pending = true;
        slot.initialized = true;
        self.run.?.submitted += 1;
        self.run.?.output_frames += 1;
        self.run.?.last_timestamp_ns = slot.timestamp_ns;
        self.run.?.rate_state = slot.rate_state;
        self.prepared_slot = null;
    }

    pub fn abortPrepared(self: *Recorder, err: anyerror) void {
        if (self.prepared_slot) |slot_index| {
            self.video_device.device().resetCommandBuffer(self.cache.?.slots[slot_index].encode_command_buffer, .{}) catch {};
            self.video_device.device().resetCommandBuffer(self.cache.?.slots[slot_index].compute_command_buffer, .{}) catch {};
            self.prepared_slot = null;
        }
        self.failShared(err);
    }

    pub fn releaseResources(self: *Recorder) void {
        if (self.run != null) return;
        if (self.cache) |cache| {
            cache.deinit();
            cache.allocator.destroy(cache);
            self.cache = null;
        }
        self.cache_poisoned = false;
    }

    fn consumeSlot(self: *Recorder, slot_index: usize) !void {
        const cache = self.cache.?;
        const slot = &cache.slots[slot_index];
        if (!slot.pending) return error.EncodeFeedbackUnavailable;
        const device = self.video_device.device();
        const wait_result = try device.waitForFences(&.{slot.encode_finished}, .true, std.math.maxInt(u64));
        if (wait_result != .success) return error.EncodeFeedbackUnavailable;
        var feedback: Feedback = .{};
        const query_result = try device.getQueryPoolResults(
            slot.query_pool,
            0,
            1,
            @sizeOf(Feedback),
            &feedback,
            @sizeOf(Feedback),
            .{},
        );
        if (query_result != .success) return error.EncodeFeedbackUnavailable;
        const range = try checkedPacketRange(feedback.offset, feedback.size, slot.bitstream_size);
        if (!slot.host_coherent) try device.invalidateMappedMemoryRanges(&.{.{
            .memory = slot.bitstream_memory,
            .offset = 0,
            .size = vk.WHOLE_SIZE,
        }});
        const run = &self.run.?;
        if (run.sticky_error == null) {
            const bytes: [*]const u8 = @ptrCast(slot.mapped.?);
            const packet = bytes[range.offset..][0..range.size];
            const initial_in_band_header = cache.header.len != 0 and slot.frame_index == 0 and run.codec != .h264;
            const repeat_parameter_sets = cache.header.len != 0 and slot.is_idr and slot.frame_index != 0 and run.parameter_sets == .every_idr;
            const new_sequence = run.pending_sequence_header;
            switch (run.format) {
                .raw => {
                    if (run.codec == .av1 and (slot.frame_index != 0 or new_sequence)) try run.writer.writeAll(&av1_temporal_delimiter);
                    if (new_sequence or repeat_parameter_sets) try run.writer.writeAll(cache.header);
                    try run.writer.writeAll(packet);
                },
                .mkv => try run.mkv.?.writeFrame(
                    if (initial_in_band_header or new_sequence or repeat_parameter_sets) cache.header else null,
                    if (new_sequence) .{
                        .parameter_sets = cache.header,
                        .extent = .{ .width = cache.key.extent.width, .height = cache.key.extent.height },
                    } else null,
                    packet,
                    slot.is_idr,
                    slot.timestamp_ns,
                ),
            }
            run.pending_sequence_header = false;
        }
        slot.pending = false;
        run.consumed += 1;
    }

    fn discardSlot(self: *Recorder, slot_index: usize) !void {
        const slot = &self.cache.?.slots[slot_index];
        if (!slot.pending) return;
        const result = try self.video_device.device().waitForFences(&.{slot.encode_finished}, .true, std.math.maxInt(u64));
        if (result != .success) return error.EncodeFeedbackUnavailable;
        slot.pending = false;
        self.run.?.consumed += 1;
    }

    fn failLocal(self: *Recorder, err: anyerror) void {
        if (self.run) |*run| {
            if (run.sticky_error == null) run.sticky_error = err;
            run.accepting = false;
        }
    }

    fn failShared(self: *Recorder, err: anyerror) void {
        self.cache_poisoned = true;
        self.failLocal(err);
    }

    fn monotonicTimestamp(self: *const Recorder) u64 {
        const run = &self.run.?;
        const now = std.Io.Timestamp.now(run.io, .awake).nanoseconds;
        return @intCast(@max(now - run.start_time_ns, 0));
    }
};

const Feedback = extern struct { offset: u32 = 0, size: u32 = 0 };
const av1_temporal_delimiter = [_]u8{ 0x12, 0x00 };
pub const PacketRange = struct { offset: usize, size: usize };

pub fn checkedPacketRange(offset: u64, size: u64, capacity: u64) !PacketRange {
    if (size == 0 or offset > capacity or size > capacity - offset) return error.EncodedPacketOutOfBounds;
    return .{ .offset = @intCast(offset), .size = @intCast(size) };
}

pub fn annexBStartCodeLength(bytes: []const u8) ?usize {
    if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], &.{ 0, 0, 0, 1 })) return 4;
    if (bytes.len >= 3 and std.mem.eql(u8, bytes[0..3], &.{ 0, 0, 1 })) return 3;
    return null;
}

const AnySupport = struct {
    available: bool,
    reason: ?capabilities.UnsupportedReason,
    encode_queue_family: ?u32,
    input_format: ?vk.Format,
    dpb_format: ?vk.Format,
    coded_extent: vk.Extent2D,
    max_extent: vk.Extent2D,
    max_dpb_slots: u32,
    max_active_reference_pictures: u32,
    min_bitstream_buffer_size_alignment: u64,
    rate_control_modes: vk.VideoEncodeRateControlModeFlagsKHR,
    encode_feedback_flags: vk.VideoEncodeFeedbackFlagsKHR,
    tuning_modes: capabilities.TuningModeSupport,
    max_quality_levels: u32,
    max_bitrate: u64,
    profile: i32,
    max_level: i32,
    std_header_version: vk.ExtensionProperties,

    fn fromH264(value: capabilities.H264Support) AnySupport {
        return from(value, @intFromEnum(value.profile), @intFromEnum(value.max_level));
    }
    fn fromCodec(value: capabilities.CodecSupport) AnySupport {
        return from(value, value.profile, value.max_level);
    }
    fn from(value: anytype, profile: i32, max_level: i32) AnySupport {
        return .{
            .available = value.available,
            .reason = value.reason,
            .encode_queue_family = value.encode_queue_family,
            .input_format = value.input_format,
            .dpb_format = value.dpb_format,
            .coded_extent = value.coded_extent,
            .max_extent = value.max_extent,
            .max_dpb_slots = value.max_dpb_slots,
            .max_active_reference_pictures = value.max_active_reference_pictures,
            .min_bitstream_buffer_size_alignment = value.min_bitstream_buffer_size_alignment,
            .rate_control_modes = value.rate_control_modes,
            .encode_feedback_flags = value.encode_feedback_flags,
            .tuning_modes = value.tuning_modes,
            .max_quality_levels = value.max_quality_levels,
            .max_bitrate = value.max_bitrate,
            .profile = profile,
            .max_level = max_level,
            .std_header_version = value.std_header_version,
        };
    }
};

const Policy = struct {
    tuning: vk.VideoEncodeTuningModeKHR,
    rate_control: vk.VideoEncodeRateControlModeFlagsKHR,
    quality_level: u32,
};

fn selectPolicy(support: AnySupport, quality: capabilities.Quality) !Policy {
    return switch (quality) {
        .low_latency => .{
            .tuning = if (support.tuning_modes.low_latency) .low_latency_khr else return error.UnsupportedRateControl,
            .rate_control = if (support.rate_control_modes.cbr_bit_khr) .{ .cbr_bit_khr = true } else return error.UnsupportedRateControl,
            .quality_level = 0,
        },
        .balanced => .{
            .tuning = .default_khr,
            .rate_control = if (support.rate_control_modes.vbr_bit_khr)
                .{ .vbr_bit_khr = true }
            else if (support.rate_control_modes.cbr_bit_khr)
                .{ .cbr_bit_khr = true }
            else if (support.rate_control_modes.disabled_bit_khr)
                .{ .disabled_bit_khr = true }
            else
                return error.UnsupportedRateControl,
            .quality_level = if (support.max_quality_levels == 0) 0 else (support.max_quality_levels - 1) / 2,
        },
        .high_quality => .{
            .tuning = if (support.tuning_modes.high_quality) .high_quality_khr else return error.UnsupportedRateControl,
            .rate_control = if (support.rate_control_modes.vbr_bit_khr) .{ .vbr_bit_khr = true } else return error.UnsupportedRateControl,
            .quality_level = if (support.max_quality_levels == 0) 0 else support.max_quality_levels - 1,
        },
    };
}

const CacheKey = struct {
    codec: capabilities.Codec,
    extent: vk.Extent2D,
    input_format: vk.Format,
    dpb_format: vk.Format,
    profile: i32,
    max_level: i32,
    frame_rate: capabilities.Rational,
    bitrate: u32,
    gop_size: u32,
    quality: capabilities.Quality,
    frames_in_flight: u32,
    tuning: vk.VideoEncodeTuningModeKHR,
    rate_control: vk.VideoEncodeRateControlModeFlagsKHR,
    quality_level: u32,
};

const Cache = struct {
    allocator: std.mem.Allocator,
    video_device: *VideoDevice,
    graphics_queue_family: u32,
    key: CacheKey,
    support: AnySupport,
    usage_info: vk.VideoEncodeUsageInfoKHR = undefined,
    h264_profile: vk.VideoEncodeH264ProfileInfoKHR = undefined,
    h265_profile: vk.VideoEncodeH265ProfileInfoKHR = undefined,
    av1_profile: vk.VideoEncodeAV1ProfileInfoKHR = undefined,
    profile: vk.VideoProfileInfoKHR = undefined,
    profile_list: vk.VideoProfileListInfoKHR = undefined,
    quality_properties: vk.VideoEncodeQualityLevelPropertiesKHR = undefined,
    h264_quality_properties: vk.VideoEncodeH264QualityLevelPropertiesKHR = undefined,
    h265_quality_properties: vk.VideoEncodeH265QualityLevelPropertiesKHR = undefined,
    av1_quality_properties: vk.VideoEncodeAV1QualityLevelPropertiesKHR = undefined,
    session: vk.VideoSessionKHR = .null_handle,
    session_memory: []vk.DeviceMemory = &.{},
    parameter_sets: h264.ParameterSets = undefined,
    h265_parameter_sets: h265.ParameterSets = undefined,
    av1_sequence: av1.Sequence = undefined,
    session_parameters: vk.VideoSessionParametersKHR = .null_handle,
    header: []u8 = &.{},
    command_pool: vk.CommandPool = .null_handle,
    compute_command_pool: vk.CommandPool = .null_handle,
    dpb_image: vk.Image = .null_handle,
    dpb_memory: vk.DeviceMemory = .null_handle,
    dpb_views: [2]vk.ImageView = .{ .null_handle, .null_handle },
    slots: []Slot = &.{},
    conversion_pipeline: ?conversion.Pipeline = null,
    bitstream_size: u64 = 0,
    session_initialized: bool = false,

    fn empty(allocator: std.mem.Allocator, video_device: *VideoDevice, graphics_queue_family: u32, key: CacheKey, support: AnySupport) Cache {
        return .{ .allocator = allocator, .video_device = video_device, .graphics_queue_family = graphics_queue_family, .key = key, .support = support };
    }

    fn create(self: *Cache) !void {
        const device = self.video_device.device();
        self.initProfile();
        try self.queryQualityProperties();
        // RADV currently advertises large encode extents while leaving the
        // optional H.264 max-level field at its zero-initialized Level 1.0
        // value. In that internally inconsistent case, let the session derive
        // its limit and choose the SPS level from extent/rate/bitrate.
        const h264_max: vk.StdVideoH264LevelIdc = @enumFromInt(self.key.max_level);
        const effective_max_level: vk.StdVideoH264LevelIdc = if (h264_max == .@"1_0" and
            (self.support.max_extent.width > 176 or self.support.max_extent.height > 144))
            .@"6_2"
        else
            h264_max;
        var h264_session = vk.VideoEncodeH264SessionCreateInfoKHR{
            .use_max_level_idc = .false,
            .max_level_idc = h264_max,
        };
        var h265_session = vk.VideoEncodeH265SessionCreateInfoKHR{ .use_max_level_idc = .false, .max_level_idc = @enumFromInt(self.key.max_level) };
        var av1_session = vk.VideoEncodeAV1SessionCreateInfoKHR{ .use_max_level = .false, .max_level = @enumFromInt(self.key.max_level) };
        switch (self.key.codec) {
            .h264 => try self.parameter_sets.init(self.key.extent, self.key.frame_rate, self.key.gop_size, @enumFromInt(self.key.profile), effective_max_level, self.key.bitrate),
            .h265 => try self.h265_parameter_sets.init(self.key.extent, self.key.frame_rate, @enumFromInt(self.key.profile), @enumFromInt(self.key.max_level)),
            .av1 => {
                try self.av1_sequence.init(self.key.extent, @enumFromInt(self.key.profile));
                self.header = try av1.writeSequenceHeader(self.allocator, &self.av1_sequence, @enumFromInt(self.key.max_level));
            },
        }
        self.session = try device.createVideoSessionKHR(&.{
            .p_next = switch (self.key.codec) {
                .h264 => @ptrCast(&h264_session),
                .h265 => @ptrCast(&h265_session),
                .av1 => @ptrCast(&av1_session),
            },
            .queue_family_index = self.video_device.encode_queue_family,
            .p_video_profile = &self.profile,
            .picture_format = self.key.input_format,
            .max_coded_extent = self.key.extent,
            .reference_picture_format = self.key.dpb_format,
            .max_dpb_slots = 2,
            .max_active_reference_pictures = 1,
            .p_std_header_version = &self.support.std_header_version,
        }, null);
        try self.allocateSessionMemory();
        try self.createSessionParameters();
        if (self.key.codec != .av1) try self.readHeader();

        self.command_pool = try device.createCommandPool(&.{
            .flags = .{ .reset_command_buffer_bit = true },
            .queue_family_index = self.video_device.encode_queue_family,
        }, null);
        self.compute_command_pool = try device.createCommandPool(&.{
            .flags = .{ .reset_command_buffer_bit = true },
            .queue_family_index = self.video_device.compute_queue_family,
        }, null);
        try self.createDpb();
        try self.createSlots();

        const image_sets = try self.allocator.alloc(conversion.ImageSet, self.slots.len);
        defer self.allocator.free(image_sets);
        for (self.slots, image_sets) |slot, *images| images.* = slot.conversionImages();
        self.conversion_pipeline = try conversion.Pipeline.init(self.allocator, device, image_sets);
    }

    fn deinit(self: *Cache) void {
        const device = self.video_device.device();
        device.deviceWaitIdle() catch {};
        if (self.conversion_pipeline) |*pipeline| pipeline.deinit(device);
        self.conversion_pipeline = null;
        for (self.slots) |*slot| slot.deinit(self);
        if (self.slots.len != 0) self.allocator.free(self.slots);
        self.slots = &.{};
        for (self.dpb_views) |view| if (view != .null_handle) device.destroyImageView(view, null);
        if (self.dpb_image != .null_handle) device.destroyImage(self.dpb_image, null);
        if (self.dpb_memory != .null_handle) device.freeMemory(self.dpb_memory, null);
        if (self.command_pool != .null_handle) device.destroyCommandPool(self.command_pool, null);
        if (self.compute_command_pool != .null_handle) device.destroyCommandPool(self.compute_command_pool, null);
        if (self.header.len != 0) self.allocator.free(self.header);
        if (self.session_parameters != .null_handle) device.destroyVideoSessionParametersKHR(self.session_parameters, null);
        if (self.session != .null_handle) device.destroyVideoSessionKHR(self.session, null);
        for (self.session_memory) |memory| if (memory != .null_handle) device.freeMemory(memory, null);
        if (self.session_memory.len != 0) self.allocator.free(self.session_memory);
        self.* = empty(self.allocator, self.video_device, self.graphics_queue_family, self.key, self.support);
    }

    fn initProfile(self: *Cache) void {
        self.usage_info = .{
            .video_usage_hints = .{ .recording_bit_khr = true },
            .video_content_hints = .{ .rendered_bit_khr = true },
            .tuning_mode = self.key.tuning,
        };
        self.h264_profile = .{ .p_next = @ptrCast(&self.usage_info), .std_profile_idc = @enumFromInt(self.key.profile) };
        self.h265_profile = .{ .p_next = @ptrCast(&self.usage_info), .std_profile_idc = @enumFromInt(self.key.profile) };
        self.av1_profile = .{ .p_next = @ptrCast(&self.usage_info), .std_profile = @enumFromInt(self.key.profile) };
        self.profile = .{
            .p_next = switch (self.key.codec) {
                .h264 => @ptrCast(&self.h264_profile),
                .h265 => @ptrCast(&self.h265_profile),
                .av1 => @ptrCast(&self.av1_profile),
            },
            .video_codec_operation = switch (self.key.codec) {
                .h264 => .{ .encode_h264_bit_khr = true },
                .h265 => .{ .encode_h265_bit_khr = true },
                .av1 => .{ .encode_av1_bit_khr = true },
            },
            .chroma_subsampling = .{ .@"420_bit_khr" = true },
            .luma_bit_depth = .{ .@"8_bit_khr" = true },
            .chroma_bit_depth = .{ .@"8_bit_khr" = true },
        };
        self.profile_list = .{ .profile_count = 1, .p_profiles = @ptrCast(&self.profile) };
    }

    fn queryQualityProperties(self: *Cache) !void {
        if (self.video_device.instance_wrapper.dispatch.vkGetPhysicalDeviceVideoEncodeQualityLevelPropertiesKHR == null) {
            return error.VulkanVideoFunctionUnavailable;
        }
        self.h264_quality_properties = std.mem.zeroes(vk.VideoEncodeH264QualityLevelPropertiesKHR);
        self.h265_quality_properties = std.mem.zeroes(vk.VideoEncodeH265QualityLevelPropertiesKHR);
        self.av1_quality_properties = std.mem.zeroes(vk.VideoEncodeAV1QualityLevelPropertiesKHR);
        self.h264_quality_properties.s_type = .video_encode_h264_quality_level_properties_khr;
        self.h265_quality_properties.s_type = .video_encode_h265_quality_level_properties_khr;
        self.av1_quality_properties.s_type = .video_encode_av1_quality_level_properties_khr;
        self.quality_properties = undefined;
        self.quality_properties.s_type = .video_encode_quality_level_properties_khr;
        self.quality_properties.p_next = switch (self.key.codec) {
            .h264 => @ptrCast(&self.h264_quality_properties),
            .h265 => @ptrCast(&self.h265_quality_properties),
            .av1 => @ptrCast(&self.av1_quality_properties),
        };
        try self.video_device.instance_wrapper.getPhysicalDeviceVideoEncodeQualityLevelPropertiesKHR(
            self.video_device.physical_device,
            &.{ .p_video_profile = &self.profile, .quality_level = self.key.quality_level },
            &self.quality_properties,
        );
        self.quality_properties.p_next = null;
    }

    fn rateControlFlags(self: *const Cache) vk.VideoEncodeH264RateControlFlagsKHR {
        var flags = self.h264_quality_properties.preferred_rate_control_flags;
        flags.regular_gop_bit_khr = true;
        flags.reference_pattern_flat_bit_khr = true;
        flags.reference_pattern_dyadic_bit_khr = false;
        return flags;
    }

    fn h265RateControlFlags(self: *const Cache) vk.VideoEncodeH265RateControlFlagsKHR {
        var flags = self.h265_quality_properties.preferred_rate_control_flags;
        flags.regular_gop_bit_khr = true;
        flags.reference_pattern_flat_bit_khr = true;
        flags.reference_pattern_dyadic_bit_khr = false;
        return flags;
    }

    fn av1RateControlFlags(self: *const Cache) vk.VideoEncodeAV1RateControlFlagsKHR {
        var flags = self.av1_quality_properties.preferred_rate_control_flags;
        flags.regular_gop_bit_khr = true;
        flags.reference_pattern_flat_bit_khr = true;
        flags.reference_pattern_dyadic_bit_khr = false;
        return flags;
    }

    fn allocateSessionMemory(self: *Cache) !void {
        const device = self.video_device.device();
        var count: u32 = 0;
        _ = try device.getVideoSessionMemoryRequirementsKHR(self.session, &count, null);
        if (count == 0) return;
        const requirements = try self.allocator.alloc(vk.VideoSessionMemoryRequirementsKHR, count);
        defer self.allocator.free(requirements);
        for (requirements) |*requirement| {
            requirement.* = undefined;
            requirement.s_type = .video_session_memory_requirements_khr;
            requirement.p_next = null;
        }
        _ = try device.getVideoSessionMemoryRequirementsKHR(self.session, &count, requirements.ptr);
        self.session_memory = try self.allocator.alloc(vk.DeviceMemory, count);
        @memset(self.session_memory, .null_handle);
        const bindings = try self.allocator.alloc(vk.BindVideoSessionMemoryInfoKHR, count);
        defer self.allocator.free(bindings);
        for (requirements[0..count], self.session_memory[0..count], bindings[0..count]) |requirement, *memory, *binding| {
            const memory_type = try self.video_device.findMemoryType(requirement.memory_requirements.memory_type_bits, .{}, .{ .device_local_bit = true });
            memory.* = try device.allocateMemory(&.{
                .allocation_size = requirement.memory_requirements.size,
                .memory_type_index = memory_type,
            }, null);
            binding.* = .{
                .memory_bind_index = requirement.memory_bind_index,
                .memory = memory.*,
                .memory_offset = 0,
                .memory_size = requirement.memory_requirements.size,
            };
        }
        try device.bindVideoSessionMemoryKHR(self.session, bindings[0..count]);
    }

    fn createSessionParameters(self: *Cache) !void {
        const add = vk.VideoEncodeH264SessionParametersAddInfoKHR{
            .std_sps_count = 1,
            .p_std_sp_ss = @ptrCast(&self.parameter_sets.sps),
            .std_pps_count = 1,
            .p_std_pp_ss = @ptrCast(&self.parameter_sets.pps),
        };
        const quality = vk.VideoEncodeQualityLevelInfoKHR{ .quality_level = self.key.quality_level };
        const h264_create = vk.VideoEncodeH264SessionParametersCreateInfoKHR{
            .p_next = @ptrCast(&quality),
            .max_std_sps_count = 1,
            .max_std_pps_count = 1,
            .p_parameters_add_info = &add,
        };
        const h265_add = vk.VideoEncodeH265SessionParametersAddInfoKHR{
            .std_vps_count = 1,
            .p_std_vp_ss = @ptrCast(&self.h265_parameter_sets.vps),
            .std_sps_count = 1,
            .p_std_sp_ss = @ptrCast(&self.h265_parameter_sets.sps),
            .std_pps_count = 1,
            .p_std_pp_ss = @ptrCast(&self.h265_parameter_sets.pps),
        };
        const h265_create = vk.VideoEncodeH265SessionParametersCreateInfoKHR{
            .p_next = @ptrCast(&quality),
            .max_std_vps_count = 1,
            .max_std_sps_count = 1,
            .max_std_pps_count = 1,
            .p_parameters_add_info = &h265_add,
        };
        const av1_create = vk.VideoEncodeAV1SessionParametersCreateInfoKHR{
            .p_next = @ptrCast(&quality),
            .p_std_sequence_header = &self.av1_sequence.header,
        };
        self.session_parameters = try self.video_device.device().createVideoSessionParametersKHR(&.{
            .p_next = switch (self.key.codec) {
                .h264 => @ptrCast(&h264_create),
                .h265 => @ptrCast(&h265_create),
                .av1 => @ptrCast(&av1_create),
            },
            .video_session = self.session,
        }, null);
    }

    fn readHeader(self: *Cache) !void {
        const h264_get = vk.VideoEncodeH264SessionParametersGetInfoKHR{
            .write_std_sps = .true,
            .write_std_pps = .true,
            .std_sps_id = 0,
            .std_pps_id = 0,
        };
        const h265_get = vk.VideoEncodeH265SessionParametersGetInfoKHR{
            .write_std_vps = .true,
            .write_std_sps = .true,
            .write_std_pps = .true,
            .std_vps_id = 0,
            .std_sps_id = 0,
            .std_pps_id = 0,
        };
        const get = vk.VideoEncodeSessionParametersGetInfoKHR{
            .p_next = switch (self.key.codec) {
                .h264 => @ptrCast(&h264_get),
                .h265 => @ptrCast(&h265_get),
                .av1 => unreachable,
            },
            .video_session_parameters = self.session_parameters,
        };
        var size: usize = 0;
        _ = try self.video_device.device().getEncodedVideoSessionParametersKHR(&get, null, &size, null);
        if (size == 0) return error.EncodeFeedbackUnavailable;
        self.header = try self.allocator.alloc(u8, size);
        var h264_feedback: vk.VideoEncodeH264SessionParametersFeedbackInfoKHR = undefined;
        h264_feedback.s_type = .video_encode_h264_session_parameters_feedback_info_khr;
        h264_feedback.p_next = null;
        var feedback: vk.VideoEncodeSessionParametersFeedbackInfoKHR = undefined;
        feedback.s_type = .video_encode_session_parameters_feedback_info_khr;
        var h265_feedback: vk.VideoEncodeH265SessionParametersFeedbackInfoKHR = undefined;
        h265_feedback.s_type = .video_encode_h265_session_parameters_feedback_info_khr;
        h265_feedback.p_next = null;
        feedback.p_next = switch (self.key.codec) {
            .h264 => @ptrCast(&h264_feedback),
            .h265 => @ptrCast(&h265_feedback),
            .av1 => unreachable,
        };
        _ = try self.video_device.device().getEncodedVideoSessionParametersKHR(&get, &feedback, &size, self.header.ptr);
        self.header = try self.allocator.realloc(self.header, size);
        if (annexBStartCodeLength(self.header) == null) return error.MalformedParameterSets;
    }

    fn createDpb(self: *Cache) !void {
        const device = self.video_device.device();
        self.dpb_image = try device.createImage(&.{
            .p_next = @ptrCast(&self.profile_list),
            .image_type = .@"2d",
            .format = self.key.dpb_format,
            .extent = .{ .width = self.key.extent.width, .height = self.key.extent.height, .depth = 1 },
            .mip_levels = 1,
            .array_layers = 2,
            .samples = .{ .@"1_bit" = true },
            .tiling = .optimal,
            .usage = .{ .video_encode_dpb_bit_khr = true },
            .sharing_mode = .exclusive,
            .initial_layout = .undefined,
        }, null);
        const requirements = device.getImageMemoryRequirements(self.dpb_image);
        self.dpb_memory = try device.allocateMemory(&.{
            .allocation_size = requirements.size,
            .memory_type_index = try self.video_device.findMemoryType(requirements.memory_type_bits, .{}, .{ .device_local_bit = true }),
        }, null);
        try device.bindImageMemory(self.dpb_image, self.dpb_memory, 0);
        for (&self.dpb_views, 0..) |*view, layer| {
            var range = colorRange();
            range.base_array_layer = @intCast(layer);
            view.* = try device.createImageView(&.{
                .image = self.dpb_image,
                .view_type = .@"2d",
                .format = self.key.dpb_format,
                .components = identityComponents(),
                .subresource_range = range,
            }, null);
        }
    }

    fn createSlots(self: *Cache) !void {
        const device = self.video_device.device();
        self.bitstream_size = try alignedBitstreamSize(self.key.extent, self.support.min_bitstream_buffer_size_alignment);
        self.slots = try self.allocator.alloc(Slot, self.key.frames_in_flight);
        @memset(self.slots, .{});
        const command_buffers = try self.allocator.alloc(vk.CommandBuffer, self.slots.len);
        defer self.allocator.free(command_buffers);
        const compute_command_buffers = try self.allocator.alloc(vk.CommandBuffer, self.slots.len);
        defer self.allocator.free(compute_command_buffers);
        try device.allocateCommandBuffers(&.{
            .command_pool = self.command_pool,
            .level = .primary,
            .command_buffer_count = @intCast(command_buffers.len),
        }, command_buffers.ptr);
        try device.allocateCommandBuffers(&.{
            .command_pool = self.compute_command_pool,
            .level = .primary,
            .command_buffer_count = @intCast(compute_command_buffers.len),
        }, compute_command_buffers.ptr);
        for (self.slots, command_buffers, compute_command_buffers) |*slot, command_buffer, compute_command_buffer| {
            slot.encode_command_buffer = command_buffer;
            slot.compute_command_buffer = compute_command_buffer;
            try slot.create(self);
        }
    }

    fn initializeVideoSession(self: *Cache) !void {
        const device = self.video_device.device();
        var command_buffer: vk.CommandBuffer = undefined;
        try device.allocateCommandBuffers(&.{
            .command_pool = self.command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, @ptrCast(&command_buffer));
        defer device.freeCommandBuffers(self.command_pool, &.{command_buffer});
        try device.beginCommandBuffer(command_buffer, &.{ .flags = .{ .one_time_submit_bit = true } });
        if (!self.session_initialized) {
            const barriers = [_]vk.ImageMemoryBarrier2{dpbInitialBarrier(self.dpb_image)};
            device.cmdPipelineBarrier2(command_buffer, &.{
                .image_memory_barrier_count = barriers.len,
                .p_image_memory_barriers = &barriers,
            });
        }
        var quality = vk.VideoEncodeQualityLevelInfoKHR{ .quality_level = self.key.quality_level };
        var h264_rate = vk.VideoEncodeH264RateControlInfoKHR{
            .flags = self.rateControlFlags(),
            .gop_frame_count = self.key.gop_size,
            .idr_period = self.key.gop_size,
            .consecutive_b_frame_count = 0,
            .temporal_layer_count = if (self.key.rate_control.disabled_bit_khr) 0 else 1,
        };
        const h264_layer = vk.VideoEncodeH264RateControlLayerInfoKHR{
            .use_min_qp = .false,
            .min_qp = .{ .qp_i = 0, .qp_p = 0, .qp_b = 0 },
            .use_max_qp = .false,
            .max_qp = .{ .qp_i = 0, .qp_p = 0, .qp_b = 0 },
            .use_max_frame_size = .false,
            .max_frame_size = .{ .frame_i_size = 0, .frame_p_size = 0, .frame_b_size = 0 },
        };
        var h265_rate = vk.VideoEncodeH265RateControlInfoKHR{
            .flags = self.h265RateControlFlags(),
            .gop_frame_count = self.key.gop_size,
            .idr_period = self.key.gop_size,
            .consecutive_b_frame_count = 0,
            .sub_layer_count = if (self.key.rate_control.disabled_bit_khr) 0 else 1,
        };
        const h265_layer = vk.VideoEncodeH265RateControlLayerInfoKHR{
            .use_min_qp = .false,
            .min_qp = .{ .qp_i = 0, .qp_p = 0, .qp_b = 0 },
            .use_max_qp = .false,
            .max_qp = .{ .qp_i = 0, .qp_p = 0, .qp_b = 0 },
            .use_max_frame_size = .false,
            .max_frame_size = .{ .frame_i_size = 0, .frame_p_size = 0, .frame_b_size = 0 },
        };
        var av1_rate = vk.VideoEncodeAV1RateControlInfoKHR{
            .flags = self.av1RateControlFlags(),
            .gop_frame_count = self.key.gop_size,
            .key_frame_period = self.key.gop_size,
            .consecutive_bipredictive_frame_count = 0,
            .temporal_layer_count = if (self.key.rate_control.disabled_bit_khr) 0 else 1,
        };
        const av1_layer = vk.VideoEncodeAV1RateControlLayerInfoKHR{
            .use_min_q_index = .false,
            .min_q_index = .{ .intra_q_index = 0, .predictive_q_index = 0, .bipredictive_q_index = 0 },
            .use_max_q_index = .false,
            .max_q_index = .{ .intra_q_index = 0, .predictive_q_index = 0, .bipredictive_q_index = 0 },
            .use_max_frame_size = .false,
            .max_frame_size = .{ .intra_frame_size = 0, .predictive_frame_size = 0, .bipredictive_frame_size = 0 },
        };
        const max_bitrate = @min(self.support.max_bitrate, @as(u64, self.key.bitrate) * 3 / 2);
        const layer = vk.VideoEncodeRateControlLayerInfoKHR{
            .p_next = switch (self.key.codec) {
                .h264 => @ptrCast(&h264_layer),
                .h265 => @ptrCast(&h265_layer),
                .av1 => @ptrCast(&av1_layer),
            },
            .average_bitrate = self.key.bitrate,
            .max_bitrate = if (self.key.rate_control.cbr_bit_khr) self.key.bitrate else max_bitrate,
            .frame_rate_numerator = self.key.frame_rate.numerator,
            .frame_rate_denominator = self.key.frame_rate.denominator,
        };
        const rate = vk.VideoEncodeRateControlInfoKHR{
            .p_next = switch (self.key.codec) {
                .h264 => @ptrCast(&h264_rate),
                .h265 => @ptrCast(&h265_rate),
                .av1 => @ptrCast(&av1_rate),
            },
            .rate_control_mode = self.key.rate_control,
            .layer_count = if (self.key.rate_control.disabled_bit_khr) 0 else 1,
            .p_layers = if (self.key.rate_control.disabled_bit_khr) null else @ptrCast(&layer),
            .virtual_buffer_size_in_ms = 1000,
            .initial_virtual_buffer_size_in_ms = 500,
        };
        device.cmdBeginVideoCodingKHR(command_buffer, &.{
            .p_next = if (self.session_initialized) @ptrCast(&rate) else null,
            .video_session = self.session,
            .video_session_parameters = self.session_parameters,
        });
        switch (self.key.codec) {
            .h264 => h264_rate.p_next = @ptrCast(&quality),
            .h265 => h265_rate.p_next = @ptrCast(&quality),
            .av1 => av1_rate.p_next = @ptrCast(&quality),
        }
        const control = vk.VideoCodingControlInfoKHR{
            .p_next = @ptrCast(&rate),
            .flags = .{
                .reset_bit_khr = true,
                .encode_rate_control_bit_khr = true,
                .encode_quality_level_bit_khr = true,
            },
        };
        device.cmdControlVideoCodingKHR(command_buffer, &control);
        device.cmdEndVideoCodingKHR(command_buffer, &.{});
        try device.endCommandBuffer(command_buffer);
        const fence = try device.createFence(&.{}, null);
        defer device.destroyFence(fence, null);
        try device.queueSubmit(self.video_device.encode_queue, &.{.{
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&command_buffer),
        }}, fence);
        const result = try device.waitForFences(&.{fence}, .true, std.math.maxInt(u64));
        if (result != .success) return error.VideoSessionCreationFailed;
        self.session_initialized = true;
    }

    fn recordEncode(self: *Cache, slot_index: usize, frame_index: u64) !void {
        return switch (self.key.codec) {
            .h264 => self.recordEncodeH264(slot_index, frame_index),
            .h265 => self.recordEncodeH265(slot_index, frame_index),
            .av1 => self.recordEncodeAV1(slot_index, frame_index),
        };
    }

    fn recordEncodeH264(self: *Cache, slot_index: usize, frame_index: u64) !void {
        const device = self.video_device.device();
        const slot = &self.slots[slot_index];
        const gop_index: u32 = @intCast(frame_index % self.key.gop_size);
        const idr = gop_index == 0;
        const current_dpb: usize = gop_index & 1;
        const previous_gop_index = if (gop_index == 0) @as(u32, 0) else gop_index - 1;
        const previous_dpb: usize = previous_gop_index & 1;
        var frame: h264.FrameInfo = undefined;
        frame.init(
            frame_index,
            self.key.gop_size,
            self.parameter_sets.sps.log_2_max_pic_order_cnt_lsb_minus_4,
            self.key.rate_control.disabled_bit_khr,
            if (idr) self.h264_quality_properties.preferred_constant_qp.qp_i else self.h264_quality_properties.preferred_constant_qp.qp_p,
        );

        var current_reference = std.mem.zeroes(vk.StdVideoEncodeH264ReferenceInfo);
        current_reference.primary_pic_type = if (idr) .idr else .p;
        current_reference.frame_num = gop_index;
        const poc_mask: u32 = (@as(u32, 1) << @intCast(self.parameter_sets.sps.log_2_max_pic_order_cnt_lsb_minus_4 + 4)) - 1;
        current_reference.pic_order_cnt = @intCast((gop_index * 2) & poc_mask);
        var previous_reference = std.mem.zeroes(vk.StdVideoEncodeH264ReferenceInfo);
        previous_reference.primary_pic_type = if (gop_index == 1) .idr else .p;
        previous_reference.frame_num = previous_gop_index;
        previous_reference.pic_order_cnt = @intCast((previous_gop_index * 2) & poc_mask);
        const current_codec_slot = vk.VideoEncodeH264DpbSlotInfoKHR{ .p_std_reference_info = &current_reference };
        const previous_codec_slot = vk.VideoEncodeH264DpbSlotInfoKHR{ .p_std_reference_info = &previous_reference };
        const current_picture = pictureResource(self.dpb_views[current_dpb], self.key.extent);
        const previous_picture = pictureResource(self.dpb_views[previous_dpb], self.key.extent);
        var reference_slots = [_]vk.VideoReferenceSlotInfoKHR{
            .{ .p_next = @ptrCast(&current_codec_slot), .slot_index = -1, .p_picture_resource = &current_picture },
            .{ .p_next = @ptrCast(&previous_codec_slot), .slot_index = @intCast(previous_dpb), .p_picture_resource = &previous_picture },
        };

        try device.beginCommandBuffer(slot.encode_command_buffer, &.{ .flags = .{ .one_time_submit_bit = true } });
        device.cmdResetQueryPool(slot.encode_command_buffer, slot.query_pool, 0, 1);
        const h264_layer = vk.VideoEncodeH264RateControlLayerInfoKHR{
            .use_min_qp = .false,
            .min_qp = .{ .qp_i = 0, .qp_p = 0, .qp_b = 0 },
            .use_max_qp = .false,
            .max_qp = .{ .qp_i = 0, .qp_p = 0, .qp_b = 0 },
            .use_max_frame_size = .false,
            .max_frame_size = .{ .frame_i_size = 0, .frame_p_size = 0, .frame_b_size = 0 },
        };
        const max_bitrate = @min(self.support.max_bitrate, @as(u64, self.key.bitrate) * 3 / 2);
        const layer = vk.VideoEncodeRateControlLayerInfoKHR{
            .p_next = @ptrCast(&h264_layer),
            .average_bitrate = self.key.bitrate,
            .max_bitrate = if (self.key.rate_control.cbr_bit_khr) self.key.bitrate else max_bitrate,
            .frame_rate_numerator = self.key.frame_rate.numerator,
            .frame_rate_denominator = self.key.frame_rate.denominator,
        };
        const h264_rate = vk.VideoEncodeH264RateControlInfoKHR{
            .flags = self.rateControlFlags(),
            .gop_frame_count = self.key.gop_size,
            .idr_period = self.key.gop_size,
            .consecutive_b_frame_count = 0,
            .temporal_layer_count = if (self.key.rate_control.disabled_bit_khr) 0 else 1,
        };
        const rate = vk.VideoEncodeRateControlInfoKHR{
            .p_next = @ptrCast(&h264_rate),
            .rate_control_mode = self.key.rate_control,
            .layer_count = if (self.key.rate_control.disabled_bit_khr) 0 else 1,
            .p_layers = if (self.key.rate_control.disabled_bit_khr) null else @ptrCast(&layer),
            .virtual_buffer_size_in_ms = 1000,
            .initial_virtual_buffer_size_in_ms = 500,
        };
        device.cmdBeginVideoCodingKHR(slot.encode_command_buffer, &.{
            .p_next = @ptrCast(&rate),
            .video_session = self.session,
            .video_session_parameters = self.session_parameters,
            .reference_slot_count = if (idr) 1 else 2,
            .p_reference_slots = &reference_slots,
        });
        const input_ready = vk.ImageMemoryBarrier2{
            .src_stage_mask = .{},
            .src_access_mask = .{},
            .dst_stage_mask = .{ .video_encode_bit_khr = true },
            .dst_access_mask = .{ .video_encode_read_bit_khr = true },
            .old_layout = .video_encode_src_khr,
            .new_layout = .video_encode_src_khr,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = slot.encode_input,
            .subresource_range = colorRange(),
        };
        device.cmdPipelineBarrier2(slot.encode_command_buffer, &.{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = @ptrCast(&input_ready),
        });
        const input_picture = pictureResource(slot.encode_input_view, self.key.extent);
        reference_slots[0].slot_index = @intCast(current_dpb);
        const encode = vk.VideoEncodeInfoKHR{
            .p_next = @ptrCast(&frame.picture_info),
            .dst_buffer = slot.bitstream_buffer,
            .dst_buffer_offset = 0,
            .dst_buffer_range = slot.bitstream_size,
            .src_picture_resource = input_picture,
            .p_setup_reference_slot = &reference_slots[0],
            .reference_slot_count = if (idr) 0 else 1,
            .p_reference_slots = if (idr) null else @ptrCast(&reference_slots[1]),
            .preceding_externally_encoded_bytes = 0,
        };
        device.cmdBeginQuery(slot.encode_command_buffer, slot.query_pool, 0, .{});
        device.cmdEncodeVideoKHR(slot.encode_command_buffer, &encode);
        device.cmdEndQuery(slot.encode_command_buffer, slot.query_pool, 0);
        device.cmdEndVideoCodingKHR(slot.encode_command_buffer, &.{});
        try device.endCommandBuffer(slot.encode_command_buffer);
    }

    fn recordEncodeH265(self: *Cache, slot_index: usize, frame_index: u64) !void {
        const device = self.video_device.device();
        const slot = &self.slots[slot_index];
        const gop_index: u32 = @intCast(frame_index % self.key.gop_size);
        const idr = gop_index == 0;
        const current_dpb: usize = gop_index & 1;
        const previous_dpb: usize = if (idr) 0 else (gop_index - 1) & 1;
        const preferred_qp = if (idr) self.h265_quality_properties.preferred_constant_qp.qp_i else self.h265_quality_properties.preferred_constant_qp.qp_p;
        var frame: h265.FrameInfo = undefined;
        frame.init(frame_index, self.key.gop_size, self.key.rate_control.disabled_bit_khr, preferred_qp);

        var current_reference = std.mem.zeroes(vk.StdVideoEncodeH265ReferenceInfo);
        current_reference.pic_type = if (idr) .idr else .p;
        current_reference.pic_order_cnt_val = @intCast(gop_index);
        var previous_reference = std.mem.zeroes(vk.StdVideoEncodeH265ReferenceInfo);
        previous_reference.pic_type = if (gop_index == 1) .idr else .p;
        previous_reference.pic_order_cnt_val = @intCast(if (idr) 0 else gop_index - 1);
        const current_codec_slot = vk.VideoEncodeH265DpbSlotInfoKHR{ .p_std_reference_info = &current_reference };
        const previous_codec_slot = vk.VideoEncodeH265DpbSlotInfoKHR{ .p_std_reference_info = &previous_reference };
        const current_picture = pictureResource(self.dpb_views[current_dpb], self.key.extent);
        const previous_picture = pictureResource(self.dpb_views[previous_dpb], self.key.extent);
        var reference_slots = [_]vk.VideoReferenceSlotInfoKHR{
            .{ .p_next = @ptrCast(&current_codec_slot), .slot_index = -1, .p_picture_resource = &current_picture },
            .{ .p_next = @ptrCast(&previous_codec_slot), .slot_index = @intCast(previous_dpb), .p_picture_resource = &previous_picture },
        };
        const codec_layer = vk.VideoEncodeH265RateControlLayerInfoKHR{
            .use_min_qp = .false,
            .min_qp = .{ .qp_i = 0, .qp_p = 0, .qp_b = 0 },
            .use_max_qp = .false,
            .max_qp = .{ .qp_i = 0, .qp_p = 0, .qp_b = 0 },
            .use_max_frame_size = .false,
            .max_frame_size = .{ .frame_i_size = 0, .frame_p_size = 0, .frame_b_size = 0 },
        };
        const max_bitrate = @min(self.support.max_bitrate, @as(u64, self.key.bitrate) * 3 / 2);
        const layer = vk.VideoEncodeRateControlLayerInfoKHR{
            .p_next = @ptrCast(&codec_layer),
            .average_bitrate = self.key.bitrate,
            .max_bitrate = if (self.key.rate_control.cbr_bit_khr) self.key.bitrate else max_bitrate,
            .frame_rate_numerator = self.key.frame_rate.numerator,
            .frame_rate_denominator = self.key.frame_rate.denominator,
        };
        const codec_rate = vk.VideoEncodeH265RateControlInfoKHR{
            .flags = self.h265RateControlFlags(),
            .gop_frame_count = self.key.gop_size,
            .idr_period = self.key.gop_size,
            .consecutive_b_frame_count = 0,
            .sub_layer_count = if (self.key.rate_control.disabled_bit_khr) 0 else 1,
        };
        const rate = vk.VideoEncodeRateControlInfoKHR{
            .p_next = @ptrCast(&codec_rate),
            .rate_control_mode = self.key.rate_control,
            .layer_count = if (self.key.rate_control.disabled_bit_khr) 0 else 1,
            .p_layers = if (self.key.rate_control.disabled_bit_khr) null else @ptrCast(&layer),
            .virtual_buffer_size_in_ms = 1000,
            .initial_virtual_buffer_size_in_ms = 500,
        };
        try device.beginCommandBuffer(slot.encode_command_buffer, &.{ .flags = .{ .one_time_submit_bit = true } });
        device.cmdResetQueryPool(slot.encode_command_buffer, slot.query_pool, 0, 1);
        device.cmdBeginVideoCodingKHR(slot.encode_command_buffer, &.{
            .p_next = @ptrCast(&rate),
            .video_session = self.session,
            .video_session_parameters = self.session_parameters,
            .reference_slot_count = if (idr) 1 else 2,
            .p_reference_slots = &reference_slots,
        });
        self.recordInputBarrier(slot.encode_command_buffer, slot.encode_input);
        reference_slots[0].slot_index = @intCast(current_dpb);
        const input_picture = pictureResource(slot.encode_input_view, self.key.extent);
        const encode = vk.VideoEncodeInfoKHR{
            .p_next = @ptrCast(&frame.picture_info),
            .dst_buffer = slot.bitstream_buffer,
            .dst_buffer_offset = 0,
            .dst_buffer_range = slot.bitstream_size,
            .src_picture_resource = input_picture,
            .p_setup_reference_slot = &reference_slots[0],
            .reference_slot_count = if (idr) 0 else 1,
            .p_reference_slots = if (idr) null else @ptrCast(&reference_slots[1]),
            .preceding_externally_encoded_bytes = 0,
        };
        device.cmdBeginQuery(slot.encode_command_buffer, slot.query_pool, 0, .{});
        device.cmdEncodeVideoKHR(slot.encode_command_buffer, &encode);
        device.cmdEndQuery(slot.encode_command_buffer, slot.query_pool, 0);
        device.cmdEndVideoCodingKHR(slot.encode_command_buffer, &.{});
        try device.endCommandBuffer(slot.encode_command_buffer);
    }

    fn recordEncodeAV1(self: *Cache, slot_index: usize, frame_index: u64) !void {
        const device = self.video_device.device();
        const slot = &self.slots[slot_index];
        const gop_index: u32 = @intCast(frame_index % self.key.gop_size);
        const key = gop_index == 0;
        const current_dpb: usize = gop_index & 1;
        const previous_dpb: usize = if (key) 0 else (gop_index - 1) & 1;
        const q = if (key) self.av1_quality_properties.preferred_constant_q_index.intra_q_index else self.av1_quality_properties.preferred_constant_q_index.predictive_q_index;
        var frame: av1.FrameInfo = undefined;
        frame.init(frame_index, self.key.gop_size, self.key.rate_control.disabled_bit_khr, q);
        var current_reference = std.mem.zeroes(vk.StdVideoEncodeAV1ReferenceInfo);
        current_reference.frame_type = if (key) .key else .inter;
        current_reference.order_hint = @truncate(gop_index);
        var previous_reference = std.mem.zeroes(vk.StdVideoEncodeAV1ReferenceInfo);
        previous_reference.frame_type = if (gop_index == 1) .key else .inter;
        previous_reference.order_hint = @truncate(if (key) 0 else gop_index - 1);
        const current_codec_slot = vk.VideoEncodeAV1DpbSlotInfoKHR{ .p_std_reference_info = &current_reference };
        const previous_codec_slot = vk.VideoEncodeAV1DpbSlotInfoKHR{ .p_std_reference_info = &previous_reference };
        const current_picture = pictureResource(self.dpb_views[current_dpb], self.key.extent);
        const previous_picture = pictureResource(self.dpb_views[previous_dpb], self.key.extent);
        var reference_slots = [_]vk.VideoReferenceSlotInfoKHR{
            .{ .p_next = @ptrCast(&current_codec_slot), .slot_index = -1, .p_picture_resource = &current_picture },
            .{ .p_next = @ptrCast(&previous_codec_slot), .slot_index = @intCast(previous_dpb), .p_picture_resource = &previous_picture },
        };
        const codec_layer = vk.VideoEncodeAV1RateControlLayerInfoKHR{
            .use_min_q_index = .false,
            .min_q_index = .{ .intra_q_index = 0, .predictive_q_index = 0, .bipredictive_q_index = 0 },
            .use_max_q_index = .false,
            .max_q_index = .{ .intra_q_index = 0, .predictive_q_index = 0, .bipredictive_q_index = 0 },
            .use_max_frame_size = .false,
            .max_frame_size = .{ .intra_frame_size = 0, .predictive_frame_size = 0, .bipredictive_frame_size = 0 },
        };
        const max_bitrate = @min(self.support.max_bitrate, @as(u64, self.key.bitrate) * 3 / 2);
        const layer = vk.VideoEncodeRateControlLayerInfoKHR{
            .p_next = @ptrCast(&codec_layer),
            .average_bitrate = self.key.bitrate,
            .max_bitrate = if (self.key.rate_control.cbr_bit_khr) self.key.bitrate else max_bitrate,
            .frame_rate_numerator = self.key.frame_rate.numerator,
            .frame_rate_denominator = self.key.frame_rate.denominator,
        };
        const codec_rate = vk.VideoEncodeAV1RateControlInfoKHR{
            .flags = self.av1RateControlFlags(),
            .gop_frame_count = self.key.gop_size,
            .key_frame_period = self.key.gop_size,
            .consecutive_bipredictive_frame_count = 0,
            .temporal_layer_count = if (self.key.rate_control.disabled_bit_khr) 0 else 1,
        };
        const rate = vk.VideoEncodeRateControlInfoKHR{
            .p_next = @ptrCast(&codec_rate),
            .rate_control_mode = self.key.rate_control,
            .layer_count = if (self.key.rate_control.disabled_bit_khr) 0 else 1,
            .p_layers = if (self.key.rate_control.disabled_bit_khr) null else @ptrCast(&layer),
            .virtual_buffer_size_in_ms = 1000,
            .initial_virtual_buffer_size_in_ms = 500,
        };
        try device.beginCommandBuffer(slot.encode_command_buffer, &.{ .flags = .{ .one_time_submit_bit = true } });
        device.cmdResetQueryPool(slot.encode_command_buffer, slot.query_pool, 0, 1);
        device.cmdBeginVideoCodingKHR(slot.encode_command_buffer, &.{
            .p_next = @ptrCast(&rate),
            .video_session = self.session,
            .video_session_parameters = self.session_parameters,
            .reference_slot_count = if (key) 1 else 2,
            .p_reference_slots = &reference_slots,
        });
        self.recordInputBarrier(slot.encode_command_buffer, slot.encode_input);
        const input_picture = pictureResource(slot.encode_input_view, self.key.extent);
        reference_slots[0].slot_index = @intCast(current_dpb);
        const encode = vk.VideoEncodeInfoKHR{
            .p_next = @ptrCast(&frame.picture_info),
            .dst_buffer = slot.bitstream_buffer,
            .dst_buffer_offset = 0,
            .dst_buffer_range = slot.bitstream_size,
            .src_picture_resource = input_picture,
            .p_setup_reference_slot = &reference_slots[0],
            .reference_slot_count = if (key) 0 else 1,
            .p_reference_slots = if (key) null else @ptrCast(&reference_slots[1]),
            .preceding_externally_encoded_bytes = 0,
        };
        device.cmdBeginQuery(slot.encode_command_buffer, slot.query_pool, 0, .{});
        device.cmdEncodeVideoKHR(slot.encode_command_buffer, &encode);
        device.cmdEndQuery(slot.encode_command_buffer, slot.query_pool, 0);
        device.cmdEndVideoCodingKHR(slot.encode_command_buffer, &.{});
        try device.endCommandBuffer(slot.encode_command_buffer);
    }

    fn recordInputBarrier(self: *Cache, command_buffer: vk.CommandBuffer, image: vk.Image) void {
        const barrier = vk.ImageMemoryBarrier2{
            .src_stage_mask = .{},
            .src_access_mask = .{},
            .dst_stage_mask = .{ .video_encode_bit_khr = true },
            .dst_access_mask = .{ .video_encode_read_bit_khr = true },
            .old_layout = .video_encode_src_khr,
            .new_layout = .video_encode_src_khr,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresource_range = colorRange(),
        };
        self.video_device.device().cmdPipelineBarrier2(command_buffer, &.{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = @ptrCast(&barrier),
        });
    }
};

const Slot = struct {
    source: vk.Image = .null_handle,
    source_memory: vk.DeviceMemory = .null_handle,
    source_view: vk.ImageView = .null_handle,
    encode_input: vk.Image = .null_handle,
    encode_input_memory: vk.DeviceMemory = .null_handle,
    encode_input_view: vk.ImageView = .null_handle,
    luma_view: vk.ImageView = .null_handle,
    chroma_view: vk.ImageView = .null_handle,
    bitstream_buffer: vk.Buffer = .null_handle,
    bitstream_memory: vk.DeviceMemory = .null_handle,
    bitstream_size: u64 = 0,
    mapped: ?*anyopaque = null,
    host_coherent: bool = false,
    query_pool: vk.QueryPool = .null_handle,
    copy_finished: vk.Semaphore = .null_handle,
    conversion_finished: vk.Semaphore = .null_handle,
    encode_finished: vk.Fence = .null_handle,
    encode_command_buffer: vk.CommandBuffer = .null_handle,
    compute_command_buffer: vk.CommandBuffer = .null_handle,
    pending: bool = false,
    initialized: bool = false,
    frame_index: u64 = 0,
    is_idr: bool = false,
    timestamp_ns: u64 = 0,
    rate_state: ?Recorder.CaptureRateState = null,

    fn create(self: *Slot, cache: *Cache) !void {
        const device = cache.video_device.device();
        const source_queue_families = [_]u32{ cache.graphics_queue_family, cache.video_device.compute_queue_family };
        self.source = try device.createImage(&.{
            .image_type = .@"2d",
            .format = .r8g8b8a8_unorm,
            .extent = .{ .width = cache.key.extent.width, .height = cache.key.extent.height, .depth = 1 },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{ .@"1_bit" = true },
            .tiling = .optimal,
            .usage = .{ .transfer_dst_bit = true, .storage_bit = true },
            .sharing_mode = if (source_queue_families[0] == source_queue_families[1]) .exclusive else .concurrent,
            .queue_family_index_count = if (source_queue_families[0] == source_queue_families[1]) 0 else 2,
            .p_queue_family_indices = if (source_queue_families[0] == source_queue_families[1]) null else &source_queue_families,
            .initial_layout = .undefined,
        }, null);
        const source_requirements = device.getImageMemoryRequirements(self.source);
        self.source_memory = try device.allocateMemory(&.{
            .allocation_size = source_requirements.size,
            .memory_type_index = try cache.video_device.findMemoryType(source_requirements.memory_type_bits, .{}, .{ .device_local_bit = true }),
        }, null);
        try device.bindImageMemory(self.source, self.source_memory, 0);
        self.source_view = try device.createImageView(&.{
            .image = self.source,
            .view_type = .@"2d",
            .format = .r8g8b8a8_unorm,
            .components = identityComponents(),
            .subresource_range = colorRange(),
        }, null);

        const queue_families = [_]u32{ cache.video_device.compute_queue_family, cache.video_device.encode_queue_family };
        self.encode_input = try device.createImage(&.{
            .p_next = @ptrCast(&cache.profile_list),
            .flags = .{ .mutable_format_bit = true, .extended_usage_bit = true },
            .image_type = .@"2d",
            .format = cache.key.input_format,
            .extent = .{ .width = cache.key.extent.width, .height = cache.key.extent.height, .depth = 1 },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{ .@"1_bit" = true },
            .tiling = .optimal,
            .usage = .{ .storage_bit = true, .video_encode_src_bit_khr = true },
            .sharing_mode = if (queue_families[0] == queue_families[1]) .exclusive else .concurrent,
            .queue_family_index_count = if (queue_families[0] == queue_families[1]) 0 else 2,
            .p_queue_family_indices = if (queue_families[0] == queue_families[1]) null else &queue_families,
            .initial_layout = .undefined,
        }, null);
        const input_requirements = device.getImageMemoryRequirements(self.encode_input);
        self.encode_input_memory = try device.allocateMemory(&.{
            .allocation_size = input_requirements.size,
            .memory_type_index = try cache.video_device.findMemoryType(input_requirements.memory_type_bits, .{}, .{ .device_local_bit = true }),
        }, null);
        try device.bindImageMemory(self.encode_input, self.encode_input_memory, 0);
        var encode_usage = vk.ImageViewUsageCreateInfo{ .usage = .{ .video_encode_src_bit_khr = true } };
        self.encode_input_view = try device.createImageView(&.{
            .p_next = @ptrCast(&encode_usage),
            .image = self.encode_input,
            .view_type = .@"2d",
            .format = cache.key.input_format,
            .components = identityComponents(),
            .subresource_range = colorRange(),
        }, null);
        var storage_usage = vk.ImageViewUsageCreateInfo{ .usage = .{ .storage_bit = true } };
        self.luma_view = try device.createImageView(&.{
            .p_next = @ptrCast(&storage_usage),
            .image = self.encode_input,
            .view_type = .@"2d",
            .format = .r8_unorm,
            .components = identityComponents(),
            .subresource_range = planeRange(0),
        }, null);
        self.chroma_view = try device.createImageView(&.{
            .p_next = @ptrCast(&storage_usage),
            .image = self.encode_input,
            .view_type = .@"2d",
            .format = .r8g8_unorm,
            .components = identityComponents(),
            .subresource_range = planeRange(1),
        }, null);

        self.bitstream_size = cache.bitstream_size;
        self.bitstream_buffer = try device.createBuffer(&.{
            .p_next = @ptrCast(&cache.profile_list),
            .size = self.bitstream_size,
            .usage = .{ .video_encode_dst_bit_khr = true },
            .sharing_mode = .exclusive,
        }, null);
        const buffer_requirements = device.getBufferMemoryRequirements(self.bitstream_buffer);
        const memory_type = try cache.video_device.findMemoryType(buffer_requirements.memory_type_bits, .{ .host_visible_bit = true }, .{ .host_coherent_bit = true });
        self.host_coherent = cache.video_device.memory_properties.memory_types[memory_type].property_flags.host_coherent_bit;
        self.bitstream_memory = try device.allocateMemory(&.{
            .allocation_size = buffer_requirements.size,
            .memory_type_index = memory_type,
        }, null);
        try device.bindBufferMemory(self.bitstream_buffer, self.bitstream_memory, 0);
        self.mapped = try device.mapMemory(self.bitstream_memory, 0, self.bitstream_size, .{});

        var feedback = vk.QueryPoolVideoEncodeFeedbackCreateInfoKHR{
            .p_next = @ptrCast(&cache.profile),
            .encode_feedback_flags = .{
                .bitstream_buffer_offset_bit_khr = true,
                .bitstream_bytes_written_bit_khr = true,
            },
        };
        self.query_pool = try device.createQueryPool(&.{
            .p_next = @ptrCast(&feedback),
            .query_type = .video_encode_feedback_khr,
            .query_count = 1,
        }, null);
        self.copy_finished = try device.createSemaphore(&.{}, null);
        self.conversion_finished = try device.createSemaphore(&.{}, null);
        self.encode_finished = try device.createFence(&.{ .flags = .{ .signaled_bit = true } }, null);
    }

    fn deinit(self: *Slot, cache: *Cache) void {
        const device = cache.video_device.device();
        if (self.encode_finished != .null_handle) device.destroyFence(self.encode_finished, null);
        if (self.conversion_finished != .null_handle) device.destroySemaphore(self.conversion_finished, null);
        if (self.copy_finished != .null_handle) device.destroySemaphore(self.copy_finished, null);
        if (self.query_pool != .null_handle) device.destroyQueryPool(self.query_pool, null);
        if (self.mapped != null and self.bitstream_memory != .null_handle) device.unmapMemory(self.bitstream_memory);
        if (self.bitstream_buffer != .null_handle) device.destroyBuffer(self.bitstream_buffer, null);
        if (self.bitstream_memory != .null_handle) device.freeMemory(self.bitstream_memory, null);
        if (self.chroma_view != .null_handle) device.destroyImageView(self.chroma_view, null);
        if (self.luma_view != .null_handle) device.destroyImageView(self.luma_view, null);
        if (self.encode_input_view != .null_handle) device.destroyImageView(self.encode_input_view, null);
        if (self.encode_input != .null_handle) device.destroyImage(self.encode_input, null);
        if (self.encode_input_memory != .null_handle) device.freeMemory(self.encode_input_memory, null);
        if (self.source_view != .null_handle) device.destroyImageView(self.source_view, null);
        if (self.source != .null_handle) device.destroyImage(self.source, null);
        if (self.source_memory != .null_handle) device.freeMemory(self.source_memory, null);
        self.* = .{};
    }

    fn conversionImages(self: *const Slot) conversion.ImageSet {
        return .{
            .source = self.source,
            .source_view = self.source_view,
            .encode_input = self.encode_input,
            .luma_view = self.luma_view,
            .chroma_view = self.chroma_view,
        };
    }
};

fn supportError(reason: ?capabilities.UnsupportedReason) anyerror {
    return switch (reason orelse return error.VideoEncodeUnsupported) {
        .missing_device_extension => error.MissingVideoDeviceExtension,
        .missing_av1_feature => error.MissingVideoDeviceFeature,
        .no_h264_encode_queue, .no_h265_encode_queue, .no_av1_encode_queue => error.MissingVideoEncodeQueue,
        .unsupported_profile => error.UnsupportedVideoProfile,
        .unsupported_extent => error.UnsupportedVideoExtent,
        .no_encode_input_format, .no_dpb_format => error.UnsupportedVideoFormat,
        .no_usable_rate_control_mode => error.UnsupportedRateControl,
    };
}

fn validateRecordingCodec(codec: capabilities.Codec) !void {
    _ = codec;
}

fn sourceFormatSupported(format: low_vk.Format) bool {
    return format == low_vk.format.b8g8r8a8_unorm or
        format == low_vk.format.a2b10g10r10_unorm_pack32 or
        format == low_vk.format.a2r10g10b10_unorm_pack32;
}

fn isSharedError(err: anyerror) bool {
    return err == error.DeviceLost or err == error.OutOfDeviceMemory or err == error.OutOfHostMemory;
}

fn alignedBitstreamSize(extent: vk.Extent2D, alignment_value: u64) !u64 {
    const pixels = try std.math.mul(u64, extent.width, extent.height);
    const conservative = @max(@as(u64, 4 * 1024 * 1024), try std.math.mul(u64, pixels, 4));
    const alignment = @max(alignment_value, 1);
    const remainder = conservative % alignment;
    return if (remainder == 0) conservative else try std.math.add(u64, conservative, alignment - remainder);
}

fn fixedFrameTimestamp(frame_index: u64, frame_rate: capabilities.Rational) !u64 {
    const numerator = @as(u128, frame_index) * frame_rate.denominator * std.time.ns_per_s;
    const rounded = (numerator + frame_rate.numerator / 2) / frame_rate.numerator;
    if (rounded > std.math.maxInt(u64)) return error.FrameTimestampOverflow;
    return @intCast(rounded);
}

fn resolveRateLimit(timing: RecordingTiming, policy: recording_submit.RateLimit) !?Recorder.ResolvedRateLimit {
    const fixed_rate = switch (timing) {
        .fixed_rate => |rate| rate,
        .monotonic => null,
    };
    return switch (policy) {
        .auto => switch (timing) {
            .fixed_rate, .monotonic => |rate| try resolvedFrameRate(rate.numerator, rate.denominator),
        },
        .unlimited => null,
        .frame_rate => |rate| blk: {
            const resolved = try resolvedFrameRate(rate.numerator, rate.denominator);
            if (fixed_rate) |fixed| {
                const expected = try resolvedFrameRate(fixed.numerator, fixed.denominator);
                if (!std.meta.eql(resolved, expected)) return error.FixedRateLimitMismatch;
            }
            break :blk resolved;
        },
        .interval_ns => |interval_ns| blk: {
            if (interval_ns == 0) return error.InvalidRecordingRateLimit;
            if (fixed_rate) |fixed| {
                if (interval_ns != try fixedFrameTimestamp(1, fixed)) return error.FixedRateLimitMismatch;
                break :blk try resolvedFrameRate(fixed.numerator, fixed.denominator);
            }
            break :blk try resolvedFrameRate(std.time.ns_per_s, interval_ns);
        },
    };
}

fn resolvedFrameRate(numerator: u64, denominator: u64) !Recorder.ResolvedRateLimit {
    if (numerator == 0 or denominator == 0) return error.InvalidRecordingRateLimit;
    const divisor = std.math.gcd(numerator, denominator);
    return .{ .numerator = numerator / divisor, .denominator = denominator / divisor };
}

fn selectRateSlot(previous: ?Recorder.CaptureRateState, limit: Recorder.ResolvedRateLimit, timestamp_ns: u64) !?Recorder.CaptureRateState {
    const state = previous orelse return .{ .limit = limit, .origin_ns = timestamp_ns, .slot = 0 };
    if (!std.meta.eql(state.limit, limit)) return .{ .limit = limit, .origin_ns = timestamp_ns, .slot = 0 };
    if (timestamp_ns < state.origin_ns) return error.NonMonotonicFrameTimestamp;
    const elapsed_ns = timestamp_ns - state.origin_ns;
    const numerator = @as(u128, elapsed_ns) * limit.numerator;
    const denominator = @as(u128, limit.denominator) * std.time.ns_per_s;
    const slot = numerator / denominator;
    if (slot <= state.slot) return null;
    if (slot > std.math.maxInt(u64)) return error.FrameTimestampOverflow;
    return .{ .limit = limit, .origin_ns = state.origin_ns, .slot = @intCast(slot) };
}

fn pictureResource(view: vk.ImageView, extent: vk.Extent2D) vk.VideoPictureResourceInfoKHR {
    return .{
        .coded_offset = .{ .x = 0, .y = 0 },
        .coded_extent = extent,
        .base_array_layer = 0,
        .image_view_binding = view,
    };
}

fn dpbInitialBarrier(image: vk.Image) vk.ImageMemoryBarrier2 {
    var result: vk.ImageMemoryBarrier2 = .{
        .src_stage_mask = .{},
        .src_access_mask = .{},
        .dst_stage_mask = .{ .video_encode_bit_khr = true },
        .dst_access_mask = .{ .video_encode_read_bit_khr = true, .video_encode_write_bit_khr = true },
        .old_layout = .undefined,
        .new_layout = .video_encode_dpb_khr,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresource_range = colorRange(),
    };
    result.subresource_range.layer_count = 2;
    return result;
}

fn identityComponents() vk.ComponentMapping {
    return .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity };
}

fn colorRange() vk.ImageSubresourceRange {
    return .{
        .aspect_mask = .{ .color_bit = true },
        .base_mip_level = 0,
        .level_count = 1,
        .base_array_layer = 0,
        .layer_count = 1,
    };
}

fn planeRange(comptime plane: u2) vk.ImageSubresourceRange {
    return .{
        .aspect_mask = if (plane == 0) .{ .plane_0_bit = true } else .{ .plane_1_bit = true },
        .base_mip_level = 0,
        .level_count = 1,
        .base_array_layer = 0,
        .layer_count = 1,
    };
}

fn toCommandBuffer(command_buffer: low_vk.CommandBuffer) vk.CommandBuffer {
    return @enumFromInt(@intFromPtr(command_buffer orelse return .null_handle));
}

fn toLowPhysicalDevice(device: vk.PhysicalDevice) low_vk.PhysicalDevice {
    return @ptrFromInt(@intFromEnum(device));
}

test "encoded feedback ranges cannot overflow the mapped buffer" {
    try std.testing.expectEqual(PacketRange{ .offset = 16, .size = 32 }, try checkedPacketRange(16, 32, 64));
    try std.testing.expectError(error.EncodedPacketOutOfBounds, checkedPacketRange(48, 32, 64));
    try std.testing.expectError(error.EncodedPacketOutOfBounds, checkedPacketRange(0, 0, 64));
}

test "bitstream capacity is conservative and aligned" {
    const size = try alignedBitstreamSize(.{ .width = 1920, .height = 1080 }, 4096);
    try std.testing.expect(size >= 1920 * 1080 * 4);
    try std.testing.expectEqual(@as(u64, 0), size % 4096);
}

test "Annex-B parameter streams accept both standard start codes" {
    try std.testing.expectEqual(@as(?usize, 4), annexBStartCodeLength(&.{ 0, 0, 0, 1, 0x67 }));
    try std.testing.expectEqual(@as(?usize, 3), annexBStartCodeLength(&.{ 0, 0, 1, 0x67 }));
    try std.testing.expectEqual(@as(?usize, null), annexBStartCodeLength(&.{ 0, 1, 0x67 }));
}

test "recorder accepts every advertised recording codec" {
    try validateRecordingCodec(.h264);
    try validateRecordingCodec(.h265);
    try validateRecordingCodec(.av1);
}

test "recorder accepts packed 10-bit UNORM source formats" {
    try std.testing.expect(sourceFormatSupported(low_vk.format.b8g8r8a8_unorm));
    try std.testing.expect(sourceFormatSupported(low_vk.format.a2b10g10r10_unorm_pack32));
    try std.testing.expect(sourceFormatSupported(low_vk.format.a2r10g10b10_unorm_pack32));
    try std.testing.expect(!sourceFormatSupported(.undefined));
}

test "recorder status transitions are non-consuming" {
    var video_device: VideoDevice = undefined;
    var recorder = Recorder.init(std.testing.allocator, &video_device, 0, 2, low_vk.format.b8g8r8a8_unorm);
    try std.testing.expect(recorder.status() == null);
    var writer: std.Io.Writer = .failing;
    recorder.run = .{
        .io = std.Options.debug_io,
        .writer = &writer,
        .timing = .{ .fixed_rate = .fps(60) },
        .bitrate = 1,
        .gop_size = 1,
        .quality = .balanced,
        .resize = .stop_recording,
        .parameter_sets = .stream_start,
        .codec = .h264,
        .format = .raw,
        .start_time_ns = 0,
        .source_extent = .{ .width = 64, .height = 64 },
    };
    try std.testing.expect(recorder.status().? == .recording);
    recorder.run.?.accepting = false;
    recorder.run.?.stopped_resize = true;
    try std.testing.expect(recorder.status().? == .stopped_resize);
    recorder.run.?.sticky_error = error.EncodeFeedbackUnavailable;
    switch (recorder.status().?) {
        .failed => |err| try std.testing.expectEqual(error.EncodeFeedbackUnavailable, err),
        else => return error.TestUnexpectedResult,
    }
    // Status reads do not clear the sticky error.
    try std.testing.expect(recorder.status().? == .failed);
}

test "recording admission throttles monotonic and fixed timing from supplied timestamps" {
    var video_device: VideoDevice = undefined;
    var writer: std.Io.Writer = .failing;

    var monotonic = Recorder.init(std.testing.allocator, &video_device, 0, 2, low_vk.format.b8g8r8a8_unorm);
    monotonic.run = .{
        .io = std.Options.debug_io,
        .writer = &writer,
        .timing = .{ .monotonic = .fps(60) },
        .bitrate = 1,
        .gop_size = 1,
        .quality = .balanced,
        .resize = .stop_recording,
        .parameter_sets = .stream_start,
        .codec = .h264,
        .format = .mkv,
        .start_time_ns = 0,
        .source_extent = .{ .width = 64, .height = 64 },
    };
    const first = (try monotonic.selectFrame(.{ .timestamp_ns = 0 })).?;
    try std.testing.expectEqual(@as(u64, 0), first.timestamp_ns);
    monotonic.run.?.rate_state = first.rate_state;
    monotonic.run.?.last_timestamp_ns = first.timestamp_ns;
    monotonic.run.?.output_frames += 1;
    try std.testing.expectEqual(@as(?Recorder.SelectedFrame, null), try monotonic.selectFrame(.{ .timestamp_ns = 8_000_000 }));
    const second = (try monotonic.selectFrame(.{ .timestamp_ns = 17_000_000 })).?;
    try std.testing.expectEqual(@as(u64, 17_000_000), second.timestamp_ns);

    var fixed = Recorder.init(std.testing.allocator, &video_device, 0, 2, low_vk.format.b8g8r8a8_unorm);
    fixed.run = .{
        .io = std.Options.debug_io,
        .writer = &writer,
        .timing = .{ .fixed_rate = .fps(30) },
        .bitrate = 1,
        .gop_size = 1,
        .quality = .balanced,
        .resize = .stop_recording,
        .parameter_sets = .stream_start,
        .codec = .h264,
        .format = .mkv,
        .start_time_ns = 0,
        .source_extent = .{ .width = 64, .height = 64 },
    };
    const fixed_first = (try fixed.selectFrame(.{ .timestamp_ns = 0 })).?;
    fixed.run.?.rate_state = fixed_first.rate_state;
    fixed.run.?.last_timestamp_ns = fixed_first.timestamp_ns;
    fixed.run.?.output_frames += 1;
    try std.testing.expectEqual(@as(?Recorder.SelectedFrame, null), try fixed.selectFrame(.{ .timestamp_ns = 20_000_000 }));
    const fixed_second = (try fixed.selectFrame(.{ .timestamp_ns = 34_000_000 })).?;
    try std.testing.expectEqual(@as(u64, 33_333_333), fixed_second.timestamp_ns);
    try std.testing.expectError(error.FixedRateLimitMismatch, fixed.selectFrame(.{
        .timestamp_ns = 40_000_000,
        .rate_limit = .fps(15),
    }));
}

test "unlimited monotonic recording accepts custom and automatic timestamps" {
    var video_device: VideoDevice = undefined;
    var writer: std.Io.Writer = .failing;
    var recorder = Recorder.init(std.testing.allocator, &video_device, 0, 2, low_vk.format.b8g8r8a8_unorm);
    recorder.run = .{
        .io = std.Options.debug_io,
        .writer = &writer,
        .timing = .{ .monotonic = .fps(60) },
        .bitrate = 1,
        .gop_size = 1,
        .quality = .balanced,
        .resize = .stop_recording,
        .parameter_sets = .stream_start,
        .codec = .h264,
        .format = .mkv,
        .start_time_ns = std.Io.Timestamp.now(std.Options.debug_io, .awake).nanoseconds,
        .source_extent = .{ .width = 64, .height = 64 },
    };
    try std.testing.expect((try recorder.selectFrame(.{ .rate_limit = .unlimited })) != null);
    try std.testing.expectEqual(@as(?Recorder.SelectedFrame, null), try recorder.selectFrame(.{ .skip_frame = true }));
    const selected = (try recorder.selectFrame(.{ .timestamp_ns = 42, .rate_limit = .unlimited })).?;
    try std.testing.expectEqual(@as(u64, 42), selected.timestamp_ns);
    try std.testing.expectEqual(@as(?Recorder.CaptureRateState, null), selected.rate_state);
}

test "recorder declarations compile" {
    std.testing.refAllDecls(Recorder);
    std.testing.refAllDecls(Cache);
    std.testing.refAllDecls(Slot);
}

test "all codec command recording paths compile" {
    // Keep the condition runtime-visible so Zig analyzes each codec-specific
    // command builder without attempting to execute it in a unit test.
    if (std.testing.random_seed == std.math.maxInt(u32)) {
        var cache: Cache = undefined;
        try cache.recordEncodeH264(0, 0);
        try cache.recordEncodeH265(0, 0);
        try cache.recordEncodeAV1(0, 0);
    }
}
