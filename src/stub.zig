const std = @import("std");
const common = @import("common.zig");
const input = @import("input.zig");

pub const BackendRequest = common.BackendRequest;
pub const BackendKind = common.BackendKind;
pub const Environment = common.Environment;
pub const detectBackend = common.detectBackend;
pub const Size = common.Size;
pub const Point = common.Point;
pub const ContentScale = common.ContentScale;

pub const Action = input.Action;
pub const MouseButton = input.MouseButton;
pub const Modifiers = input.Modifiers;
pub const CursorShape = input.CursorShape;
pub const Key = input.Key;
pub const DecorationMode = enum {
    auto,
    server_side,
    client_side,
};
pub const WindowState = enum {
    normal,
    maximize,
    fullscreen,
};

pub const InitOptions = struct {
    backend: BackendRequest = .auto,
    app_name: [:0]const u8 = "low",
};

pub const WindowOptions = struct {
    title: [:0]const u8,
    size: Size = .{ .width = 1280, .height = 720 },
    app_id: ?[:0]const u8 = null,
    resizable: bool = true,
    decorated: bool = true,
    titlebar: DecorationMode = .auto,
    state: WindowState = .normal,
    visible: bool = true,
    min_size: ?Size = null,
    max_size: ?Size = null,
};

pub const WindowCallbacks = struct {};

pub const Context = struct {
    pub fn init(_: std.mem.Allocator, _: InitOptions) !Context {
        return error.UnsupportedPlatform;
    }

    pub fn deinit(_: *Context) void {}

    pub fn createWindow(_: *Context, _: WindowOptions) !*Window {
        return error.UnsupportedPlatform;
    }

    pub fn pollEvents(_: *Context) void {}
    pub fn waitEventsTimeout(_: *Context, _: u64) !bool {
        return error.UnsupportedPlatform;
    }
    pub fn wake(_: *Context) void {}
};

pub const Window = struct {
    pub fn deinit(_: *Window) void {}
};
