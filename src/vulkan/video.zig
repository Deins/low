//! Optional Vulkan Video H.264, H.265, and AV1 recording and capability discovery.
//!
//! This module is reached through `low.vulkan.video()` and is only wired into
//! the build when `-Dvk_video=true` is selected.
pub const api = @import("_vk_video");

const capabilities = @import("video/capabilities.zig");
const h264 = @import("video/h264.zig");
const conversion = @import("video/conversion.zig");
const device = @import("video/device.zig");
const encoder = @import("video/encoder.zig");
const matroska = @import("video/matroska.zig");
const recording_submit = @import("recording_submit.zig");

pub const UnsupportedReason = capabilities.UnsupportedReason;
pub const Codec = capabilities.Codec;
pub const RecordingRequest = capabilities.RecordingRequest;
pub const default_codec_preferences = capabilities.default_codec_preferences;
pub const H264Support = capabilities.H264Support;
pub const H265Support = capabilities.H265Support;
pub const AV1Support = capabilities.AV1Support;
pub const CodecSupport = capabilities.CodecSupport;
pub const DeviceRequirements = capabilities.DeviceRequirements;
pub const DeviceRequirementsOptions = capabilities.DeviceRequirementsOptions;
pub const QueryH264SupportOptions = capabilities.QueryH264SupportOptions;
pub const QueryH265SupportOptions = capabilities.QueryH265SupportOptions;
pub const QueryAV1SupportOptions = capabilities.QueryAV1SupportOptions;
pub const SelectVideoFormatOptions = capabilities.SelectVideoFormatOptions;
pub const SelectedVideoFormat = capabilities.SelectedVideoFormat;
pub const FrameRate = capabilities.FrameRate;
pub const Quality = capabilities.Quality;
pub const ResizePolicy = capabilities.ResizePolicy;
pub const ParameterSetPolicy = capabilities.ParameterSetPolicy;
pub const TuningModeSupport = capabilities.TuningModeSupport;
pub const requiredDeviceExtensions = capabilities.requiredDeviceExtensions;
pub const queryH264Support = capabilities.queryH264Support;
pub const queryH265Support = capabilities.queryH265Support;
pub const queryAV1Support = capabilities.queryAV1Support;
pub const selectVideoFormat = capabilities.selectVideoFormat;
pub const alignCodedExtent = capabilities.alignCodedExtent;
pub const VideoDevice = device.VideoDevice;
pub const RecordingOptions = encoder.RecordingOptions;
pub const RecordingTiming = encoder.RecordingTiming;
pub const RecordingStatus = encoder.RecordingStatus;
pub const RecordingFormat = encoder.RecordingFormat;
pub const RecordingRateLimit = recording_submit.RateLimit;
pub const RecordingFrameOptions = recording_submit.RecordingOptions;
pub const VideoRecorder = encoder.Recorder;

test {
    _ = capabilities;
    _ = h264;
    _ = conversion;
    _ = device;
    _ = encoder;
    _ = matroska;
}
