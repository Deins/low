const std = @import("std");

pub const BackendRequest = enum {
    auto,
    wayland,
    x11,
};

pub const BackendKind = enum {
    wayland,
    x11,
};

pub const Environment = struct {
    wayland_display: ?[]const u8 = null,
    display: ?[]const u8 = null,
    xdg_session_type: ?[]const u8 = null,
};

pub fn detectBackend(env: Environment) BackendKind {
    if (env.xdg_session_type) |session| {
        if (std.ascii.eqlIgnoreCase(session, "wayland")) return .wayland;
        if (std.ascii.eqlIgnoreCase(session, "x11")) return .x11;
    }

    if (env.wayland_display != null and env.display == null) return .wayland;
    if (env.display != null and env.wayland_display == null) return .x11;
    if (env.wayland_display != null) return .wayland;
    if (env.display != null) return .x11;

    return .wayland;
}

pub const Size = struct {
    width: i32,
    height: i32,
};

pub const Point = struct {
    x: f64,
    y: f64,
};

pub const ContentScale = struct {
    x: f32 = 1,
    y: f32 = 1,
};

pub fn scaledSize(size: Size, scale: ContentScale) Size {
    return .{
        .width = @intFromFloat(@max(1.0, @as(f64, @floatFromInt(size.width)) * @as(f64, scale.x))),
        .height = @intFromFloat(@max(1.0, @as(f64, @floatFromInt(size.height)) * @as(f64, scale.y))),
    };
}

test "detectBackend" {
    try std.testing.expectEqual(
        BackendKind.wayland,
        detectBackend(.{ .xdg_session_type = "wayland" }),
    );
    try std.testing.expectEqual(
        BackendKind.x11,
        detectBackend(.{ .xdg_session_type = "x11" }),
    );
    try std.testing.expectEqual(
        BackendKind.wayland,
        detectBackend(.{ .wayland_display = "wayland-0" }),
    );
    try std.testing.expectEqual(
        BackendKind.x11,
        detectBackend(.{ .display = ":0" }),
    );
}

test "scaledSize" {
    const size = scaledSize(.{ .width = 100, .height = 50 }, .{ .x = 1.5, .y = 2.0 });
    try std.testing.expectEqual(@as(i32, 150), size.width);
    try std.testing.expectEqual(@as(i32, 100), size.height);
}
