const std = @import("std");
const vk = @import("_vk_video");
const Vulkan = @import("../../vulkan.zig");
const low_vk = @import("../api.zig");

const base_device_extensions = [_][*:0]const u8{
    "VK_KHR_video_queue",
    "VK_KHR_video_encode_queue",
};

/// Video codec operation selected for device discovery. The codec extension is
/// deliberately selected per codec: requiring every codec would make a
/// perfectly usable H.264 device appear unsupported.
pub const Codec = enum { h264, h265, av1 };

const h264_device_extensions = [_][*:0]const u8{
    base_device_extensions[0],
    base_device_extensions[1],
    "VK_KHR_video_encode_h264",
};
const h265_device_extensions = [_][*:0]const u8{
    base_device_extensions[0],
    base_device_extensions[1],
    "VK_KHR_video_encode_h265",
};
const av1_device_extensions = [_][*:0]const u8{
    base_device_extensions[0],
    base_device_extensions[1],
    "VK_KHR_video_encode_av1",
};

/// Extensions needed to create a device for `codec`.
pub fn requiredDeviceExtensions(codec: Codec) []const [*:0]const u8 {
    return switch (codec) {
        .h264 => &h264_device_extensions,
        .h265 => &h265_device_extensions,
        .av1 => &av1_device_extensions,
    };
}

/// Backward-compatible H.264 requirements. Use `requiredDeviceExtensions` for
/// new code that selects a codec at runtime.
pub const required_device_extensions = requiredDeviceExtensions(.h264);

pub const UnsupportedReason = enum {
    missing_device_extension,
    no_h264_encode_queue,
    no_h265_encode_queue,
    no_av1_encode_queue,
    unsupported_profile,
    unsupported_extent,
    no_encode_input_format,
    no_dpb_format,
    no_usable_rate_control_mode,
};

pub const Quality = enum {
    /// Prefer low end-to-end delay. Requires device support for the Vulkan
    /// low-latency tuning mode and CBR rate control.
    low_latency,
    /// A practical default that selects the best generally available rate
    /// control mode and a middle quality level.
    balanced,
    /// Prefer compression efficiency. Requires the device's high-quality
    /// tuning mode and VBR rate control.
    high_quality,
};

pub const ResizePolicy = enum {
    /// Keep the original encoded dimensions and fit the new source into them,
    /// adding letterboxing where necessary. This keeps a single video track.
    scale_and_letterbox,
    /// Reconfigure the encoder and emit a new Matroska track description.
    /// Best when preserving the new source dimensions matters.
    change_resolution,
    /// Stop accepting frames when the source size changes. Inspect
    /// `recordingStatus` for `.stopped_resize` and start a new recording.
    stop_recording,
};

pub const ParameterSetPolicy = enum {
    /// Write H.264 SPS/PPS or H.265 VPS/SPS/PPS only at stream start.
    stream_start,
    /// Repeat codec parameter sets at every IDR/key frame. This costs a small
    /// amount of space but improves resilience for streamed or cut segments.
    every_idr,
};
/// A video frame rate: `frames / seconds`.
///
/// Use `.fps(60)` for ordinary rates. Fractional rates are exact: for example,
/// NTSC 29.97 fps is `.init(30_000, 1001)`. The recorder reduces the fraction
/// before passing it to the selected codec.
pub const FrameRate = struct {
    numerator: u32,
    denominator: u32,

    /// Creates an exact frame rate of `frames / seconds`.
    pub fn init(frames: u32, seconds: u32) FrameRate {
        return .{ .numerator = frames, .denominator = seconds };
    }

    /// Creates a whole-number frame rate, such as `.fps(60)`.
    pub fn fps(frames_per_second: u32) FrameRate {
        return .init(frames_per_second, 1);
    }

    pub fn validate(self: FrameRate) !void {
        if (self.numerator == 0 or self.denominator == 0) return error.InvalidFrameRate;
    }

    pub fn reduced(self: FrameRate) !FrameRate {
        try self.validate();
        const divisor = std.math.gcd(self.numerator, self.denominator);
        return .{ .numerator = self.numerator / divisor, .denominator = self.denominator / divisor };
    }
};

/// Backward-compatible name for `FrameRate`.
pub const Rational = FrameRate;

pub const TuningModeSupport = packed struct(u8) {
    default: bool = false,
    low_latency: bool = false,
    high_quality: bool = false,
    _padding: u5 = 0,
};

pub const QueryH264SupportOptions = struct {
    instance: *const Vulkan.Instance,
    physical_device: low_vk.PhysicalDevice,
    extent: low_vk.Extent2D,
    allocator: std.mem.Allocator = std.heap.page_allocator,
};

pub const QueryH265SupportOptions = QueryH264SupportOptions;
pub const QueryAV1SupportOptions = QueryH264SupportOptions;
pub const SelectVideoFormatOptions = QueryH264SupportOptions;

pub const DeviceRequirementsOptions = struct {
    graphics_queue_family: u32,
    allocator: std.mem.Allocator = std.heap.page_allocator,
    queue_priority: f32 = 1.0,
};

pub const H264Support = struct {
    available: bool = false,
    reason: ?UnsupportedReason = null,
    encode_queue_family: ?u32 = null,
    required_device_extensions: []const [*:0]const u8 = capabilities_required_extensions,
    input_format: ?vk.Format = null,
    dpb_format: ?vk.Format = null,
    coded_extent: vk.Extent2D = .{ .width = 0, .height = 0 },
    max_extent: vk.Extent2D = .{ .width = 0, .height = 0 },
    min_extent: vk.Extent2D = .{ .width = 0, .height = 0 },
    picture_access_granularity: vk.Extent2D = .{ .width = 1, .height = 1 },
    encode_input_granularity: vk.Extent2D = .{ .width = 1, .height = 1 },
    max_dpb_slots: u32 = 0,
    max_active_reference_pictures: u32 = 0,
    min_bitstream_buffer_offset_alignment: u64 = 1,
    min_bitstream_buffer_size_alignment: u64 = 1,
    rate_control_modes: vk.VideoEncodeRateControlModeFlagsKHR = .{},
    encode_feedback_flags: vk.VideoEncodeFeedbackFlagsKHR = .{},
    tuning_modes: TuningModeSupport = .{},
    max_quality_levels: u32 = 0,
    max_bitrate: u64 = 0,
    profile: vk.StdVideoH264ProfileIdc = .invalid,
    max_level: vk.StdVideoH264LevelIdc = .invalid,
    std_header_version: vk.ExtensionProperties = std.mem.zeroes(vk.ExtensionProperties),

    const capabilities_required_extensions = required_device_extensions;

    pub fn deviceRequirements(self: H264Support, options: DeviceRequirementsOptions) !DeviceRequirements {
        if (!self.available) return error.VideoEncodeUnsupported;
        const encode_family = self.encode_queue_family orelse return error.MissingVideoEncodeQueue;
        return DeviceRequirements.init(
            options.allocator,
            options.graphics_queue_family,
            encode_family,
            options.queue_priority,
        );
    }
};

/// Capabilities shared by the H.265 and AV1 discovery APIs. `profile` and
/// `max_level` are the numeric values from the respective StdVideo enum; this
/// keeps callers that only need device/queue/image requirements independent of
/// codec-specific encode syntax.
pub const CodecSupport = struct {
    available: bool = false,
    reason: ?UnsupportedReason = null,
    encode_queue_family: ?u32 = null,
    codec: Codec,
    required_device_extensions: []const [*:0]const u8,
    input_format: ?vk.Format = null,
    dpb_format: ?vk.Format = null,
    coded_extent: vk.Extent2D = .{ .width = 0, .height = 0 },
    max_extent: vk.Extent2D = .{ .width = 0, .height = 0 },
    min_extent: vk.Extent2D = .{ .width = 0, .height = 0 },
    picture_access_granularity: vk.Extent2D = .{ .width = 1, .height = 1 },
    encode_input_granularity: vk.Extent2D = .{ .width = 1, .height = 1 },
    max_dpb_slots: u32 = 0,
    max_active_reference_pictures: u32 = 0,
    min_bitstream_buffer_offset_alignment: u64 = 1,
    min_bitstream_buffer_size_alignment: u64 = 1,
    rate_control_modes: vk.VideoEncodeRateControlModeFlagsKHR = .{},
    encode_feedback_flags: vk.VideoEncodeFeedbackFlagsKHR = .{},
    tuning_modes: TuningModeSupport = .{},
    max_quality_levels: u32 = 0,
    max_bitrate: u64 = 0,
    profile: i32 = 0,
    max_level: i32 = 0,
    std_header_version: vk.ExtensionProperties = std.mem.zeroes(vk.ExtensionProperties),

    pub fn deviceRequirements(self: CodecSupport, options: DeviceRequirementsOptions) !DeviceRequirements {
        if (!self.available) return error.VideoEncodeUnsupported;
        const encode_family = self.encode_queue_family orelse return error.MissingVideoEncodeQueue;
        return DeviceRequirements.init(options.allocator, options.graphics_queue_family, encode_family, options.queue_priority);
    }
};

pub const H265Support = CodecSupport;
pub const AV1Support = CodecSupport;

/// The first available format returned by `selectVideoFormat`. The selected
/// support object is retained so its exact queue and device requirements can
/// be applied without issuing a second capability query.
pub const SelectedVideoFormat = union(Codec) {
    h264: H264Support,
    h265: H265Support,
    av1: AV1Support,

    pub fn codec(self: SelectedVideoFormat) Codec {
        return std.meta.activeTag(self);
    }

    pub fn deviceRequirements(self: SelectedVideoFormat, options: DeviceRequirementsOptions) !DeviceRequirements {
        return switch (self) {
            inline else => |support| support.deviceRequirements(options),
        };
    }

    pub fn encodeQueueFamily(self: SelectedVideoFormat) ?u32 {
        return switch (self) {
            inline else => |support| support.encode_queue_family,
        };
    }

    pub fn codedExtent(self: SelectedVideoFormat) vk.Extent2D {
        return switch (self) {
            inline else => |support| support.coded_extent,
        };
    }
};

/// Selects the first desired codec that is fully usable for `options.extent`.
/// The desired slice is ordered by preference, for example
/// `&.{ .av1, .h265, .h264 }`. An empty result means none of the requested
/// codecs has a compatible extension, queue, profile, image format, and rate
/// control mode on the physical device.
pub fn selectVideoFormat(options: SelectVideoFormatOptions, desired: []const Codec) !?SelectedVideoFormat {
    for (desired) |codec| {
        switch (codec) {
            .h264 => {
                const support = try queryH264Support(options);
                if (support.available) return .{ .h264 = support };
            },
            .h265 => {
                const support = try queryH265Support(options);
                if (support.available) return .{ .h265 = support };
            },
            .av1 => {
                const support = try queryAV1Support(options);
                if (support.available) return .{ .av1 = support };
            },
        }
    }
    return null;
}

pub const DeviceRequirements = struct {
    queue_create_infos: []vk.DeviceQueueCreateInfo,
    priorities: []f32,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, graphics_family: u32, encode_family: u32, priority: f32) !DeviceRequirements {
        if (!std.math.isFinite(priority) or priority < 0.0 or priority > 1.0) return error.InvalidQueuePriority;
        const count: usize = if (graphics_family == encode_family) 1 else 2;
        const priorities = try allocator.alloc(f32, count);
        errdefer allocator.free(priorities);
        @memset(priorities, priority);
        const infos = try allocator.alloc(vk.DeviceQueueCreateInfo, count);
        errdefer allocator.free(infos);
        infos[0] = .{
            .queue_family_index = graphics_family,
            .queue_count = 1,
            .p_queue_priorities = priorities[0..].ptr,
        };
        if (count == 2) infos[1] = .{
            .queue_family_index = encode_family,
            .queue_count = 1,
            .p_queue_priorities = priorities[1..].ptr,
        };
        return .{ .queue_create_infos = infos, .priorities = priorities, .allocator = allocator };
    }

    pub fn deinit(self: *DeviceRequirements, _: std.mem.Allocator) void {
        self.allocator.free(self.queue_create_infos);
        self.allocator.free(self.priorities);
        self.* = undefined;
    }
};

pub fn queryH264Support(options: QueryH264SupportOptions) !H264Support {
    const instance_handle = toInstance(options.instance.handle);
    const physical_device = toPhysicalDevice(options.physical_device);
    const get_instance_proc_addr: vk.PfnGetInstanceProcAddr = @ptrCast(options.instance.get_instance_proc_addr);
    const instance = vk.InstanceWrapper.load(instance_handle, get_instance_proc_addr);

    var support = H264Support{};
    if (instance.dispatch.vkEnumerateDeviceExtensionProperties == null) return error.VulkanFunctionUnavailable;
    const extensions = try instance.enumerateDeviceExtensionPropertiesAlloc(physical_device, null, options.allocator);
    defer options.allocator.free(extensions);
    if (!hasRequiredDeviceExtensions(extensions, requiredDeviceExtensions(.h264))) {
        support.reason = .missing_device_extension;
        return support;
    }

    if (instance.dispatch.vkGetPhysicalDeviceQueueFamilyProperties2 == null or
        instance.dispatch.vkGetPhysicalDeviceVideoCapabilitiesKHR == null or
        instance.dispatch.vkGetPhysicalDeviceVideoFormatPropertiesKHR == null)
    {
        return error.VulkanFunctionUnavailable;
    }

    support.encode_queue_family = try findEncodeQueueFamily(instance, physical_device, .h264, options.allocator);
    if (support.encode_queue_family == null) {
        support.reason = .no_h264_encode_queue;
        return support;
    }

    const profiles = [_]vk.StdVideoH264ProfileIdc{ .high, .main, .baseline };
    var selected_profile: ?ProfileCapabilities = null;
    for (profiles) |profile_idc| {
        selected_profile = queryProfileCapabilities(instance, physical_device, profile_idc, .default_khr) catch |err| switch (err) {
            error.VideoProfileOperationNotSupportedKHR,
            error.VideoProfileFormatNotSupportedKHR,
            error.VideoPictureLayoutNotSupportedKHR,
            error.VideoProfileCodecNotSupportedKHR,
            => null,
            else => return err,
        };
        if (selected_profile != null) break;
    }
    const selected = selected_profile orelse {
        support.reason = .unsupported_profile;
        return support;
    };

    support.profile = selected.profile;
    support.max_level = selected.h264.max_level_idc;
    support.min_extent = selected.generic.min_coded_extent;
    support.max_extent = selected.generic.max_coded_extent;
    support.picture_access_granularity = selected.generic.picture_access_granularity;
    support.encode_input_granularity = selected.encode.encode_input_picture_granularity;
    support.max_dpb_slots = selected.generic.max_dpb_slots;
    support.max_active_reference_pictures = selected.generic.max_active_reference_pictures;
    support.min_bitstream_buffer_offset_alignment = selected.generic.min_bitstream_buffer_offset_alignment;
    support.min_bitstream_buffer_size_alignment = selected.generic.min_bitstream_buffer_size_alignment;
    support.rate_control_modes = selected.encode.rate_control_modes;
    support.encode_feedback_flags = selected.encode.supported_encode_feedback_flags;
    support.max_quality_levels = selected.encode.max_quality_levels;
    support.max_bitrate = selected.encode.max_bitrate;
    support.std_header_version = selected.generic.std_header_version;
    support.tuning_modes.default = true;
    support.tuning_modes.low_latency = tuningModeSupported(instance, physical_device, selected.profile, .low_latency_khr);
    support.tuning_modes.high_quality = tuningModeSupported(instance, physical_device, selected.profile, .high_quality_khr);

    support.coded_extent = alignCodedExtent(
        .{ .width = options.extent.width, .height = options.extent.height },
        support.min_extent,
        support.max_extent,
        support.picture_access_granularity,
        support.encode_input_granularity,
    ) orelse {
        support.reason = .unsupported_extent;
        return support;
    };

    var profile_info: ProfileChain = undefined;
    profile_info.init(selected.profile, .default_khr);
    support.input_format = try chooseVideoFormat(
        instance,
        physical_device,
        &profile_info.profile,
        .{ .storage_bit = true, .video_encode_src_bit_khr = true },
        true,
        options.allocator,
    );
    if (support.input_format == null) {
        support.reason = .no_encode_input_format;
        return support;
    }
    support.dpb_format = try chooseVideoFormat(
        instance,
        physical_device,
        &profile_info.profile,
        .{ .video_encode_dpb_bit_khr = true },
        false,
        options.allocator,
    );
    if (support.dpb_format == null) {
        support.reason = .no_dpb_format;
        return support;
    }
    if (!support.rate_control_modes.cbr_bit_khr and
        !support.rate_control_modes.vbr_bit_khr and
        !support.rate_control_modes.disabled_bit_khr)
    {
        support.reason = .no_usable_rate_control_mode;
        return support;
    }

    support.available = true;
    support.reason = null;
    return support;
}

/// Queries H.265/HEVC encode support for a 4:2:0 8-bit recording profile.
/// This validates the queue, profile, extent, input image, DPB image, and
/// rate-control requirements used by a Vulkan Video encoder.
pub fn queryH265Support(options: QueryH265SupportOptions) !H265Support {
    const instance_handle = toInstance(options.instance.handle);
    const physical_device = toPhysicalDevice(options.physical_device);
    const get_instance_proc_addr: vk.PfnGetInstanceProcAddr = @ptrCast(options.instance.get_instance_proc_addr);
    const instance = vk.InstanceWrapper.load(instance_handle, get_instance_proc_addr);
    var support = CodecSupport{ .codec = .h265, .required_device_extensions = requiredDeviceExtensions(.h265) };
    if (instance.dispatch.vkEnumerateDeviceExtensionProperties == null) return error.VulkanFunctionUnavailable;
    const extensions = try instance.enumerateDeviceExtensionPropertiesAlloc(physical_device, null, options.allocator);
    defer options.allocator.free(extensions);
    if (!hasRequiredDeviceExtensions(extensions, support.required_device_extensions)) {
        support.reason = .missing_device_extension;
        return support;
    }
    if (instance.dispatch.vkGetPhysicalDeviceQueueFamilyProperties2 == null or
        instance.dispatch.vkGetPhysicalDeviceVideoCapabilitiesKHR == null or
        instance.dispatch.vkGetPhysicalDeviceVideoFormatPropertiesKHR == null) return error.VulkanFunctionUnavailable;
    support.encode_queue_family = try findEncodeQueueFamily(instance, physical_device, .h265, options.allocator);
    if (support.encode_queue_family == null) {
        support.reason = .no_h265_encode_queue;
        return support;
    }
    const profiles = [_]vk.StdVideoH265ProfileIdc{.main};
    var selected_profile: ?H265ProfileCapabilities = null;
    for (profiles) |profile| {
        selected_profile = queryH265ProfileCapabilities(instance, physical_device, profile, .default_khr) catch |err| switch (err) {
            error.VideoProfileOperationNotSupportedKHR, error.VideoProfileFormatNotSupportedKHR, error.VideoPictureLayoutNotSupportedKHR, error.VideoProfileCodecNotSupportedKHR => null,
            else => return err,
        };
        if (selected_profile != null) break;
    }
    const selected = selected_profile orelse {
        support.reason = .unsupported_profile;
        return support;
    };
    populateCodecSupport(&support, selected.generic, selected.encode, @intFromEnum(selected.profile), @intFromEnum(selected.h265.max_level_idc));
    support.tuning_modes.low_latency = h265TuningModeSupported(instance, physical_device, selected.profile, .low_latency_khr);
    support.tuning_modes.high_quality = h265TuningModeSupported(instance, physical_device, selected.profile, .high_quality_khr);
    if (!try finishCodecSupport(instance, physical_device, &support, options.extent, options.allocator, H265ProfileChain)) return support;
    return support;
}

/// Queries AV1 encode support for the Main, 4:2:0 8-bit recording profile.
pub fn queryAV1Support(options: QueryAV1SupportOptions) !AV1Support {
    const instance_handle = toInstance(options.instance.handle);
    const physical_device = toPhysicalDevice(options.physical_device);
    const get_instance_proc_addr: vk.PfnGetInstanceProcAddr = @ptrCast(options.instance.get_instance_proc_addr);
    const instance = vk.InstanceWrapper.load(instance_handle, get_instance_proc_addr);
    var support = CodecSupport{ .codec = .av1, .required_device_extensions = requiredDeviceExtensions(.av1) };
    if (instance.dispatch.vkEnumerateDeviceExtensionProperties == null) return error.VulkanFunctionUnavailable;
    const extensions = try instance.enumerateDeviceExtensionPropertiesAlloc(physical_device, null, options.allocator);
    defer options.allocator.free(extensions);
    if (!hasRequiredDeviceExtensions(extensions, support.required_device_extensions)) {
        support.reason = .missing_device_extension;
        return support;
    }
    if (instance.dispatch.vkGetPhysicalDeviceQueueFamilyProperties2 == null or
        instance.dispatch.vkGetPhysicalDeviceVideoCapabilitiesKHR == null or
        instance.dispatch.vkGetPhysicalDeviceVideoFormatPropertiesKHR == null) return error.VulkanFunctionUnavailable;
    support.encode_queue_family = try findEncodeQueueFamily(instance, physical_device, .av1, options.allocator);
    if (support.encode_queue_family == null) {
        support.reason = .no_av1_encode_queue;
        return support;
    }
    const profiles = [_]vk.StdVideoAV1Profile{.main};
    var selected_profile: ?AV1ProfileCapabilities = null;
    for (profiles) |profile| {
        selected_profile = queryAV1ProfileCapabilities(instance, physical_device, profile, .default_khr) catch |err| switch (err) {
            error.VideoProfileOperationNotSupportedKHR, error.VideoProfileFormatNotSupportedKHR, error.VideoPictureLayoutNotSupportedKHR, error.VideoProfileCodecNotSupportedKHR => null,
            else => return err,
        };
        if (selected_profile != null) break;
    }
    const selected = selected_profile orelse {
        support.reason = .unsupported_profile;
        return support;
    };
    populateCodecSupport(&support, selected.generic, selected.encode, @intFromEnum(selected.profile), @intFromEnum(selected.av1.max_level));
    support.tuning_modes.low_latency = av1TuningModeSupported(instance, physical_device, selected.profile, .low_latency_khr);
    support.tuning_modes.high_quality = av1TuningModeSupported(instance, physical_device, selected.profile, .high_quality_khr);
    if (!try finishCodecSupport(instance, physical_device, &support, options.extent, options.allocator, AV1ProfileChain)) return support;
    return support;
}

fn populateCodecSupport(support: *CodecSupport, generic: vk.VideoCapabilitiesKHR, encode: vk.VideoEncodeCapabilitiesKHR, profile: i32, max_level: i32) void {
    support.profile = profile;
    support.max_level = max_level;
    support.min_extent = generic.min_coded_extent;
    support.max_extent = generic.max_coded_extent;
    support.picture_access_granularity = generic.picture_access_granularity;
    support.encode_input_granularity = encode.encode_input_picture_granularity;
    support.max_dpb_slots = generic.max_dpb_slots;
    support.max_active_reference_pictures = generic.max_active_reference_pictures;
    support.min_bitstream_buffer_offset_alignment = generic.min_bitstream_buffer_offset_alignment;
    support.min_bitstream_buffer_size_alignment = generic.min_bitstream_buffer_size_alignment;
    support.rate_control_modes = encode.rate_control_modes;
    support.encode_feedback_flags = encode.supported_encode_feedback_flags;
    support.max_quality_levels = encode.max_quality_levels;
    support.max_bitrate = encode.max_bitrate;
    support.std_header_version = generic.std_header_version;
    support.tuning_modes.default = true;
}

fn finishCodecSupport(
    instance: vk.InstanceWrapper,
    physical_device: vk.PhysicalDevice,
    support: *CodecSupport,
    extent: low_vk.Extent2D,
    allocator: std.mem.Allocator,
    comptime Chain: type,
) !bool {
    support.coded_extent = alignCodedExtent(.{ .width = extent.width, .height = extent.height }, support.min_extent, support.max_extent, support.picture_access_granularity, support.encode_input_granularity) orelse {
        support.reason = .unsupported_extent;
        return false;
    };
    var chain: Chain = undefined;
    chain.init(@enumFromInt(support.profile), .default_khr);
    support.input_format = try chooseVideoFormat(instance, physical_device, &chain.profile, .{ .storage_bit = true, .video_encode_src_bit_khr = true }, true, allocator);
    if (support.input_format == null) {
        support.reason = .no_encode_input_format;
        return false;
    }
    support.dpb_format = try chooseVideoFormat(instance, physical_device, &chain.profile, .{ .video_encode_dpb_bit_khr = true }, false, allocator);
    if (support.dpb_format == null) {
        support.reason = .no_dpb_format;
        return false;
    }
    if (!support.rate_control_modes.cbr_bit_khr and !support.rate_control_modes.vbr_bit_khr and !support.rate_control_modes.disabled_bit_khr) {
        support.reason = .no_usable_rate_control_mode;
        return false;
    }
    support.available = true;
    return true;
}

const ProfileChain = struct {
    usage: vk.VideoEncodeUsageInfoKHR,
    h264: vk.VideoEncodeH264ProfileInfoKHR,
    profile: vk.VideoProfileInfoKHR,
    fn init(self: *ProfileChain, profile_idc: vk.StdVideoH264ProfileIdc, tuning: vk.VideoEncodeTuningModeKHR) void {
        self.* = .{
            .usage = .{ .tuning_mode = tuning },
            .h264 = .{ .std_profile_idc = profile_idc },
            .profile = .{
                .video_codec_operation = .{ .encode_h264_bit_khr = true },
                .chroma_subsampling = .{ .@"420_bit_khr" = true },
                .luma_bit_depth = .{ .@"8_bit_khr" = true },
                .chroma_bit_depth = .{ .@"8_bit_khr" = true },
            },
        };
        self.h264.p_next = @ptrCast(&self.usage);
        self.profile.p_next = @ptrCast(&self.h264);
    }
};

const ProfileCapabilities = struct {
    profile: vk.StdVideoH264ProfileIdc,
    generic: vk.VideoCapabilitiesKHR,
    encode: vk.VideoEncodeCapabilitiesKHR,
    h264: vk.VideoEncodeH264CapabilitiesKHR,
};

const H265ProfileChain = struct {
    usage: vk.VideoEncodeUsageInfoKHR,
    h265: vk.VideoEncodeH265ProfileInfoKHR,
    profile: vk.VideoProfileInfoKHR,

    fn init(self: *H265ProfileChain, profile_idc: vk.StdVideoH265ProfileIdc, tuning: vk.VideoEncodeTuningModeKHR) void {
        self.* = .{
            .usage = .{ .tuning_mode = tuning },
            .h265 = .{ .std_profile_idc = profile_idc },
            .profile = .{
                .video_codec_operation = .{ .encode_h265_bit_khr = true },
                .chroma_subsampling = .{ .@"420_bit_khr" = true },
                .luma_bit_depth = .{ .@"8_bit_khr" = true },
                .chroma_bit_depth = .{ .@"8_bit_khr" = true },
            },
        };
        self.h265.p_next = @ptrCast(&self.usage);
        self.profile.p_next = @ptrCast(&self.h265);
    }
};

const H265ProfileCapabilities = struct {
    profile: vk.StdVideoH265ProfileIdc,
    generic: vk.VideoCapabilitiesKHR,
    encode: vk.VideoEncodeCapabilitiesKHR,
    h265: vk.VideoEncodeH265CapabilitiesKHR,
};

fn queryH265ProfileCapabilities(instance: vk.InstanceWrapper, physical_device: vk.PhysicalDevice, profile_idc: vk.StdVideoH265ProfileIdc, tuning: vk.VideoEncodeTuningModeKHR) !H265ProfileCapabilities {
    var chain: H265ProfileChain = undefined;
    chain.init(profile_idc, tuning);
    var h265: vk.VideoEncodeH265CapabilitiesKHR = undefined;
    h265.s_type = .video_encode_h265_capabilities_khr;
    h265.p_next = null;
    var encode: vk.VideoEncodeCapabilitiesKHR = undefined;
    encode.s_type = .video_encode_capabilities_khr;
    encode.p_next = @ptrCast(&h265);
    var generic: vk.VideoCapabilitiesKHR = undefined;
    generic.s_type = .video_capabilities_khr;
    generic.p_next = @ptrCast(&encode);
    try instance.getPhysicalDeviceVideoCapabilitiesKHR(physical_device, &chain.profile, &generic);
    generic.p_next = null;
    encode.p_next = null;
    h265.p_next = null;
    return .{ .profile = profile_idc, .generic = generic, .encode = encode, .h265 = h265 };
}

fn h265TuningModeSupported(instance: vk.InstanceWrapper, physical_device: vk.PhysicalDevice, profile: vk.StdVideoH265ProfileIdc, tuning: vk.VideoEncodeTuningModeKHR) bool {
    _ = queryH265ProfileCapabilities(instance, physical_device, profile, tuning) catch return false;
    return true;
}

const AV1ProfileChain = struct {
    usage: vk.VideoEncodeUsageInfoKHR,
    av1: vk.VideoEncodeAV1ProfileInfoKHR,
    profile: vk.VideoProfileInfoKHR,

    fn init(self: *AV1ProfileChain, profile_idc: vk.StdVideoAV1Profile, tuning: vk.VideoEncodeTuningModeKHR) void {
        self.* = .{
            .usage = .{ .tuning_mode = tuning },
            .av1 = .{ .std_profile = profile_idc },
            .profile = .{
                .video_codec_operation = .{ .encode_av1_bit_khr = true },
                .chroma_subsampling = .{ .@"420_bit_khr" = true },
                .luma_bit_depth = .{ .@"8_bit_khr" = true },
                .chroma_bit_depth = .{ .@"8_bit_khr" = true },
            },
        };
        self.av1.p_next = @ptrCast(&self.usage);
        self.profile.p_next = @ptrCast(&self.av1);
    }
};

const AV1ProfileCapabilities = struct {
    profile: vk.StdVideoAV1Profile,
    generic: vk.VideoCapabilitiesKHR,
    encode: vk.VideoEncodeCapabilitiesKHR,
    av1: vk.VideoEncodeAV1CapabilitiesKHR,
};

fn queryAV1ProfileCapabilities(instance: vk.InstanceWrapper, physical_device: vk.PhysicalDevice, profile_idc: vk.StdVideoAV1Profile, tuning: vk.VideoEncodeTuningModeKHR) !AV1ProfileCapabilities {
    var chain: AV1ProfileChain = undefined;
    chain.init(profile_idc, tuning);
    var av1: vk.VideoEncodeAV1CapabilitiesKHR = undefined;
    av1.s_type = .video_encode_av1_capabilities_khr;
    av1.p_next = null;
    var encode: vk.VideoEncodeCapabilitiesKHR = undefined;
    encode.s_type = .video_encode_capabilities_khr;
    encode.p_next = @ptrCast(&av1);
    var generic: vk.VideoCapabilitiesKHR = undefined;
    generic.s_type = .video_capabilities_khr;
    generic.p_next = @ptrCast(&encode);
    try instance.getPhysicalDeviceVideoCapabilitiesKHR(physical_device, &chain.profile, &generic);
    generic.p_next = null;
    encode.p_next = null;
    av1.p_next = null;
    return .{ .profile = profile_idc, .generic = generic, .encode = encode, .av1 = av1 };
}

fn av1TuningModeSupported(instance: vk.InstanceWrapper, physical_device: vk.PhysicalDevice, profile: vk.StdVideoAV1Profile, tuning: vk.VideoEncodeTuningModeKHR) bool {
    _ = queryAV1ProfileCapabilities(instance, physical_device, profile, tuning) catch return false;
    return true;
}

fn queryProfileCapabilities(
    instance: vk.InstanceWrapper,
    physical_device: vk.PhysicalDevice,
    profile_idc: vk.StdVideoH264ProfileIdc,
    tuning: vk.VideoEncodeTuningModeKHR,
) !ProfileCapabilities {
    var chain: ProfileChain = undefined;
    chain.init(profile_idc, tuning);
    var h264: vk.VideoEncodeH264CapabilitiesKHR = undefined;
    h264.s_type = .video_encode_h264_capabilities_khr;
    h264.p_next = null;
    var encode: vk.VideoEncodeCapabilitiesKHR = undefined;
    encode.s_type = .video_encode_capabilities_khr;
    encode.p_next = @ptrCast(&h264);
    var generic: vk.VideoCapabilitiesKHR = undefined;
    generic.s_type = .video_capabilities_khr;
    generic.p_next = @ptrCast(&encode);
    try instance.getPhysicalDeviceVideoCapabilitiesKHR(physical_device, &chain.profile, &generic);
    generic.p_next = null;
    encode.p_next = null;
    h264.p_next = null;
    return .{ .profile = profile_idc, .generic = generic, .encode = encode, .h264 = h264 };
}

fn tuningModeSupported(instance: vk.InstanceWrapper, physical_device: vk.PhysicalDevice, profile: vk.StdVideoH264ProfileIdc, tuning: vk.VideoEncodeTuningModeKHR) bool {
    _ = queryProfileCapabilities(instance, physical_device, profile, tuning) catch return false;
    return true;
}

fn findEncodeQueueFamily(instance: vk.InstanceWrapper, physical_device: vk.PhysicalDevice, codec: Codec, allocator: std.mem.Allocator) !?u32 {
    var count: u32 = 0;
    instance.getPhysicalDeviceQueueFamilyProperties2(physical_device, &count, null);
    if (count == 0) return null;
    const properties = try allocator.alloc(vk.QueueFamilyProperties2, count);
    defer allocator.free(properties);
    const video = try allocator.alloc(vk.QueueFamilyVideoPropertiesKHR, count);
    defer allocator.free(video);
    for (properties, video) |*property, *video_property| {
        property.* = .{ .queue_family_properties = undefined };
        video_property.* = .{ .video_codec_operations = .{} };
        property.p_next = @ptrCast(video_property);
    }
    instance.getPhysicalDeviceQueueFamilyProperties2(physical_device, &count, properties.ptr);

    var fallback: ?u32 = null;
    for (properties[0..count], video[0..count], 0..) |property, video_property, index| {
        if (property.queue_family_properties.queue_count == 0 or
            !property.queue_family_properties.queue_flags.video_encode_bit_khr or
            !queueSupportsCodec(video_property.video_codec_operations, codec)) continue;
        if (property.queue_family_properties.queue_flags.compute_bit) return @intCast(index);
        if (fallback == null) fallback = @intCast(index);
    }
    return fallback;
}

fn queueSupportsCodec(operations: vk.VideoCodecOperationFlagsKHR, codec: Codec) bool {
    return switch (codec) {
        .h264 => operations.encode_h264_bit_khr,
        .h265 => operations.encode_h265_bit_khr,
        .av1 => operations.encode_av1_bit_khr,
    };
}

fn chooseVideoFormat(
    instance: vk.InstanceWrapper,
    physical_device: vk.PhysicalDevice,
    profile: *const vk.VideoProfileInfoKHR,
    usage: vk.ImageUsageFlags,
    require_nv12: bool,
    allocator: std.mem.Allocator,
) !?vk.Format {
    const profile_list = vk.VideoProfileListInfoKHR{ .profile_count = 1, .p_profiles = @ptrCast(profile) };
    const info = vk.PhysicalDeviceVideoFormatInfoKHR{ .p_next = @ptrCast(&profile_list), .image_usage = usage };
    var count: u32 = 0;
    _ = try instance.getPhysicalDeviceVideoFormatPropertiesKHR(physical_device, &info, &count, null);
    if (count == 0) return null;
    var properties: []vk.VideoFormatPropertiesKHR = &.{};
    defer allocator.free(properties);
    var result: vk.Result = .incomplete;
    while (result == .incomplete) {
        properties = try allocator.realloc(properties, count);
        for (properties) |*property| {
            property.* = undefined;
            property.s_type = .video_format_properties_khr;
            property.p_next = null;
        }
        result = try instance.getPhysicalDeviceVideoFormatPropertiesKHR(physical_device, &info, &count, properties.ptr);
    }
    const returned = properties[0..@min(properties.len, count)];
    for (returned) |property| if (property.format == .g8_b8r8_2plane_420_unorm) return property.format;
    if (require_nv12) return null;
    return if (returned.len == 0) null else returned[0].format;
}

fn hasRequiredDeviceExtensions(properties: []const vk.ExtensionProperties, requirements: []const [*:0]const u8) bool {
    for (requirements) |required| {
        var found = false;
        for (properties) |property| {
            const end = std.mem.indexOfScalar(u8, property.extension_name[0..], 0) orelse property.extension_name.len;
            if (std.mem.eql(u8, std.mem.span(required), property.extension_name[0..end])) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

pub fn alignCodedExtent(
    requested: vk.Extent2D,
    minimum: vk.Extent2D,
    maximum: vk.Extent2D,
    picture_granularity: vk.Extent2D,
    input_granularity: vk.Extent2D,
) ?vk.Extent2D {
    if (requested.width == 0 or requested.height == 0) return null;
    // 4:2:0 chroma requires complete 2x2 luma sample groups even when the
    // implementation reports a unit video-picture granularity.
    const width_alignment = lcmNonZero(lcmNonZero(picture_granularity.width, input_granularity.width) orelse return null, 2) orelse return null;
    const height_alignment = lcmNonZero(lcmNonZero(picture_granularity.height, input_granularity.height) orelse return null, 2) orelse return null;
    const width = alignForward(@max(requested.width, minimum.width), width_alignment) orelse return null;
    const height = alignForward(@max(requested.height, minimum.height), height_alignment) orelse return null;
    if (width > maximum.width or height > maximum.height) return null;
    return .{ .width = width, .height = height };
}

fn lcmNonZero(a_value: u32, b_value: u32) ?u32 {
    const a = @max(a_value, 1);
    const b = @max(b_value, 1);
    const divisor = std.math.gcd(a, b);
    return std.math.mul(u32, a / divisor, b) catch null;
}

fn alignForward(value: u32, alignment: u32) ?u32 {
    const remainder = value % alignment;
    if (remainder == 0) return value;
    return std.math.add(u32, value, alignment - remainder) catch null;
}

fn toInstance(handle: low_vk.InstanceHandle) vk.Instance {
    return @enumFromInt(@intFromPtr(handle orelse return .null_handle));
}

fn toPhysicalDevice(handle: low_vk.PhysicalDevice) vk.PhysicalDevice {
    return @enumFromInt(@intFromPtr(handle orelse return .null_handle));
}

test "coded extents combine both video granularities" {
    const extent = alignCodedExtent(
        .{ .width = 1919, .height = 1079 },
        .{ .width = 64, .height = 64 },
        .{ .width = 3840, .height = 2160 },
        .{ .width = 16, .height = 16 },
        .{ .width = 8, .height = 32 },
    ).?;
    try std.testing.expectEqual(@as(u32, 1920), extent.width);
    try std.testing.expectEqual(@as(u32, 1088), extent.height);
    try std.testing.expect(alignCodedExtent(
        .{ .width = 3840, .height = 2160 },
        .{ .width = 64, .height = 64 },
        .{ .width = 3840, .height = 2160 },
        .{ .width = 16, .height = 16 },
        .{ .width = 8, .height = 32 },
    ) == null);
}

test "device requirements merge duplicate queue families" {
    const support = H264Support{ .available = true, .encode_queue_family = 4 };
    var same = try support.deviceRequirements(.{ .allocator = std.testing.allocator, .graphics_queue_family = 4, .queue_priority = 0.75 });
    defer same.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), same.queue_create_infos.len);
    try std.testing.expectEqual(@as(u32, 4), same.queue_create_infos[0].queue_family_index);
    try std.testing.expectEqual(@as(f32, 0.75), same.queue_create_infos[0].p_queue_priorities[0]);

    var separate = try support.deviceRequirements(.{ .allocator = std.testing.allocator, .graphics_queue_family = 2 });
    defer separate.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), separate.queue_create_infos.len);
    try std.testing.expectEqual(@as(u32, 2), separate.queue_create_infos[0].queue_family_index);
    try std.testing.expectEqual(@as(u32, 4), separate.queue_create_infos[1].queue_family_index);
}

test "frame rate rejects zero and reduces exactly" {
    try std.testing.expectError(error.InvalidFrameRate, FrameRate.fps(0).validate());
    try std.testing.expectEqual(FrameRate.init(30_000, 1001), try FrameRate.init(60_000, 2002).reduced());
}

test "required extension intersection reports omissions" {
    var properties: [3]vk.ExtensionProperties = @splat(std.mem.zeroes(vk.ExtensionProperties));
    for (required_device_extensions, &properties) |name, *property| {
        const bytes = std.mem.span(name);
        @memcpy(property.extension_name[0..bytes.len], bytes);
    }
    try std.testing.expect(hasRequiredDeviceExtensions(&properties, required_device_extensions));
    properties[2] = std.mem.zeroes(vk.ExtensionProperties);
    @memcpy(properties[2].extension_name[0..12], "VK_EXT_other");
    try std.testing.expect(!hasRequiredDeviceExtensions(&properties, required_device_extensions));
}

test "each codec requests only its own device extension" {
    try std.testing.expectEqual(@as(usize, 3), requiredDeviceExtensions(.h264).len);
    try std.testing.expectEqual(@as(usize, 3), requiredDeviceExtensions(.h265).len);
    try std.testing.expectEqual(@as(usize, 3), requiredDeviceExtensions(.av1).len);
    try std.testing.expect(std.mem.eql(u8, std.mem.span(requiredDeviceExtensions(.h265)[2]), "VK_KHR_video_encode_h265"));
    try std.testing.expect(std.mem.eql(u8, std.mem.span(requiredDeviceExtensions(.av1)[2]), "VK_KHR_video_encode_av1"));
}

test "HEVC and AV1 profile chains select their codec operation" {
    var h265: H265ProfileChain = undefined;
    h265.init(.main, .default_khr);
    try std.testing.expect(h265.profile.video_codec_operation.encode_h265_bit_khr);
    try std.testing.expect(!h265.profile.video_codec_operation.encode_av1_bit_khr);

    var av1: AV1ProfileChain = undefined;
    av1.init(.main, .default_khr);
    try std.testing.expect(av1.profile.video_codec_operation.encode_av1_bit_khr);
    try std.testing.expect(!av1.profile.video_codec_operation.encode_h265_bit_khr);
}

test "selected format retains the codec and queue requirements" {
    const selected = SelectedVideoFormat{ .h264 = .{ .available = true, .encode_queue_family = 3 } };
    try std.testing.expectEqual(Codec.h264, selected.codec());
    try std.testing.expectEqual(@as(?u32, 3), selected.encodeQueueFamily());
    var requirements = try selected.deviceRequirements(.{ .allocator = std.testing.allocator, .graphics_queue_family = 3 });
    defer requirements.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), requirements.queue_create_infos.len);
}
