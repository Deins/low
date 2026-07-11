const std = @import("std");
const build_options = @import("build_options");
const common = @import("../common.zig");
const api = @import("../api.zig");
const wayland_backend = @import("wayland_backend.zig");
const x11_backend = @import("x11_backend.zig");
const offscreen_backend = @import("../offscreen_backend.zig").Backend(api);

pub const BackendRequest = common.BackendRequest;
pub const BackendKind = api.BackendKind;
pub const Environment = common.Environment;
pub const detectBackend = common.detectBackend;
pub const Size = api.Size;
pub const Point = api.Point;
pub const ContentScale = api.ContentScale;
pub const TextInputRect = api.TextInputRect;
pub const ColorScheme = api.ColorScheme;
pub const Action = api.Action;
pub const MouseButton = api.MouseButton;
pub const Modifiers = api.Modifiers;
pub const CursorShape = api.CursorShape;
pub const Key = api.Key;
pub const DecorationMode = api.DecorationMode;
pub const WindowState = api.WindowState;
pub const Error = api.Error;
pub const FrameMode = api.FrameMode;
pub const OffscreenOptions = api.OffscreenOptions;
pub const Event = api.Event;
pub const InitOptions = api.InitOptions;
pub const WindowOptions = api.WindowOptions;
pub const WindowCallbacks = api.WindowCallbacks;
pub const Window = api.Window;

pub const Context = struct {
    state: *api.State,

    pub fn init(allocator: std.mem.Allocator, options: InitOptions) Error!Context {
        const env: Environment = .{
            .xdg_session_type = environmentValue("XDG_SESSION_TYPE"),
            .wayland_display = environmentValue("WAYLAND_DISPLAY"),
            .display = environmentValue("DISPLAY"),
        };
        const selected = switch (options.backend) {
            .offscreen => return .{ .state = try initBackend(allocator, options, .offscreen) },
            .wayland => return .{ .state = try initBackend(allocator, options, .wayland) },
            .x11 => return .{ .state = try initBackend(allocator, options, .x11) },
            .auto => common.detectBackend(env),
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
                return .{ .state = initBackend(allocator, options, alternate) catch |fallback_error| return fallback_error };
            }
            return first_error;
        };
        return .{ .state = state };
    }

    pub fn deinit(self: *Context) void {
        self.state.deinit();
        self.* = undefined;
    }
    pub fn nativeDisplay(self: *Context) *anyopaque {
        return self.state.nativeDisplay();
    }
    pub fn requiredVulkanInstanceExtensions(self: *Context) []const [*:0]const u8 {
        return self.state.requiredVulkanInstanceExtensions();
    }
    pub fn backendKind(self: *Context) BackendKind {
        return self.state.backendKind();
    }
    pub fn createWindow(self: *Context, options: WindowOptions) Error!*Window {
        return self.state.createWindow(options);
    }
    pub fn pollEvents(self: *Context) void {
        self.state.pollEvents();
    }
    pub fn waitEvents(self: *Context) Error!void {
        return self.state.waitEvents();
    }
    pub fn waitEventsTimeout(self: *Context, timeout_ns: u64) Error!bool {
        return self.state.waitEventsTimeout(timeout_ns);
    }
    pub fn wake(self: *Context) void {
        self.state.wake();
    }
    pub fn step(self: *Context) Error!void {
        return self.state.step();
    }
    pub fn nextFrame(self: *Context) Error!void {
        return self.state.nextFrame();
    }
    pub fn clipboardText(self: *Context, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return self.state.clipboardText(allocator);
    }
    pub fn clipboardTextSet(self: *Context, text: []const u8) std.mem.Allocator.Error!void {
        return self.state.clipboardTextSet(text);
    }
    pub fn preferredColorScheme(self: *Context) ?ColorScheme {
        return self.state.preferredColorScheme();
    }
};

fn initBackend(allocator: std.mem.Allocator, options: InitOptions, selected: BackendKind) Error!*api.State {
    return switch (selected) {
        .wayland => if (build_options.wayland) wayland_backend.init(allocator, options) else error.UnsupportedPlatform,
        .x11 => if (build_options.x11) x11_backend.init(allocator, options) else error.UnsupportedPlatform,
        .offscreen => offscreen_backend.init(allocator, options),
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
