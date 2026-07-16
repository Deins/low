const std = @import("std");

/// Per-frame recording rate policy. Rate limiting drops recording frames; it
/// never delays or skips presentation.
pub const RateLimit = union(enum) {
    /// Use the recording timing's configured rate.
    auto,
    /// Accept every submitted frame.
    unlimited,
    /// Accept at most `frames / seconds` frames per second.
    frame_rate: FrameRate,
    /// Accept at most one frame per interval.
    interval_ns: u64,

    pub const FrameRate = struct {
        numerator: u32,
        denominator: u32,
    };

    pub fn init(frames: u32, seconds: u32) RateLimit {
        return .{ .frame_rate = .{ .numerator = frames, .denominator = seconds } };
    }

    pub fn fps(frames_per_second: u32) RateLimit {
        return .init(frames_per_second, 1);
    }

    pub fn interval(interval_ns: u64) RateLimit {
        return .{ .interval_ns = interval_ns };
    }
};

/// Recording behavior for one submitted frame.
pub const RecordingOptions = struct {
    /// Present the frame normally but omit it from the recording.
    skip_frame: bool = false,
    /// Nanoseconds on the recording timeline. When omitted, the recorder
    /// samples its monotonic clock.
    timestamp_ns: ?u64 = null,
    /// `.auto` uses the configured recording rate. A custom fixed-timing limit
    /// must match its output rate; use `.unlimited` only when time scaling is
    /// intentional.
    /// Changing this policy accepts the current frame and starts a new cadence.
    rate_limit: RateLimit = .auto,
};

/// Options shared by presentation and readback submission.
pub const SubmitOptions = struct {
    recording: RecordingOptions = .{},
};

test "recording submission options have conservative defaults" {
    const options: SubmitOptions = .{};
    try std.testing.expect(!options.recording.skip_frame);
    try std.testing.expectEqual(@as(?u64, null), options.recording.timestamp_ns);
    try std.testing.expect(options.recording.rate_limit == .auto);
}
