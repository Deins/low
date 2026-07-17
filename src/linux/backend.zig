const std = @import("std");
const build_options = @import("build_options");
const types = @import("../internal/types.zig");
const runtime = @import("../internal/runtime.zig");
const wayland_backend = if (build_options.wayland) @import("wayland_backend.zig") else struct {};
const x11_backend = @import("x11_backend.zig");
const offscreen_backend = @import("../offscreen_backend.zig").Backend;

pub const BackendRequest = types.BackendRequest;
pub const BackendKind = types.BackendKind;
pub const Environment = types.Environment;
pub const detectBackend = types.detectBackend;
pub const Size = runtime.Size;
pub const Point = runtime.Point;
pub const ContentScale = runtime.ContentScale;
pub const TextInputRect = runtime.TextInputRect;
pub const ColorScheme = runtime.ColorScheme;
pub const Action = runtime.Action;
pub const MouseButton = runtime.MouseButton;
pub const Modifiers = runtime.Modifiers;
pub const CursorShape = runtime.CursorShape;
pub const Key = runtime.Key;
pub const DecorationMode = runtime.DecorationMode;
pub const WindowState = runtime.WindowState;
pub const Error = runtime.Error;
pub const FrameMode = runtime.FrameMode;
pub const OffscreenOptions = runtime.OffscreenOptions;
pub const Event = runtime.Event;
pub const InitOptions = runtime.InitOptions;
pub const WindowOptions = runtime.WindowOptions;
pub const Window = runtime.Window;

pub fn initState(allocator: std.mem.Allocator, options: InitOptions) Error!*runtime.State {
    const env: Environment = .{
        .xdg_session_type = environmentValue("XDG_SESSION_TYPE"),
        .wayland_display = environmentValue("WAYLAND_DISPLAY"),
        .display = environmentValue("DISPLAY"),
    };
    const selected = switch (options.backend) {
        .offscreen => |offscreen| return offscreen_backend.init(allocator, offscreen),
        .wayland => return initBackend(allocator, options, .wayland),
        .x11 => return initBackend(allocator, options, .x11),
        .auto => types.detectBackend(env),
    };
    const state = initBackend(allocator, options, selected) catch |first_error| {
        const alternate: BackendKind = switch (selected) {
            .wayland => .x11,
            .x11 => .wayland,
            .offscreen => unreachable,
            .windows => unreachable,
        };
        const available = switch (alternate) {
            .wayland => env.wayland_display != null and build_options.wayland,
            .x11 => env.display != null and build_options.x11,
            .offscreen => true,
            .windows => false,
        };
        if (available and shouldFallback(first_error)) {
            return initBackend(allocator, options, alternate) catch |fallback_error| return fallback_error;
        }
        return first_error;
    };
    return state;
}

fn initBackend(allocator: std.mem.Allocator, options: InitOptions, selected: BackendKind) Error!*runtime.State {
    return switch (selected) {
        .wayland => if (build_options.wayland) wayland_backend.init(allocator, options) else error.UnsupportedPlatform,
        .x11 => if (build_options.x11) x11_backend.init(allocator, options) else error.UnsupportedPlatform,
        .offscreen => unreachable,
        .windows => error.UnsupportedPlatform,
    };
}

fn shouldFallback(err: Error) bool {
    return switch (err) {
        error.BackendLibraryUnavailable,
        error.DisplayConnectionFailed,
        error.MissingRequiredGlobal,
        error.WaylandProtocolError,
        error.XkbInitFailed,
        => true,
        else => false,
    };
}

fn environmentValue(name: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    const result = std.mem.span(value);
    return if (result.len == 0) null else result;
}

test {
    std.testing.refAllDecls(@This());
}
