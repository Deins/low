//! Optional Vulkan Video H.264 recording support.
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

pub const UnsupportedReason = capabilities.UnsupportedReason;
pub const H264Support = capabilities.H264Support;
pub const DeviceRequirements = capabilities.DeviceRequirements;
pub const QueryH264SupportOptions = capabilities.QueryH264SupportOptions;
pub const Rational = capabilities.Rational;
pub const Quality = capabilities.Quality;
pub const ResizePolicy = capabilities.ResizePolicy;
pub const ParameterSetPolicy = capabilities.ParameterSetPolicy;
pub const TimestampMode = capabilities.TimestampMode;
pub const TuningModeSupport = capabilities.TuningModeSupport;
pub const required_device_extensions = capabilities.required_device_extensions;
pub const queryH264Support = capabilities.queryH264Support;
pub const alignCodedExtent = capabilities.alignCodedExtent;
pub const VideoDevice = device.VideoDevice;
pub const RecordingOptions = encoder.RecordingOptions;
pub const RecordingStatus = encoder.RecordingStatus;
pub const RecordingFormat = encoder.RecordingFormat;
pub const VideoRecorder = encoder.Recorder;

test {
    _ = capabilities;
    _ = h264;
    _ = conversion;
    _ = device;
    _ = encoder;
    _ = matroska;
}
