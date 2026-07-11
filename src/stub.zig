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
pub const TextInputRect = common.TextInputRect;
pub const ColorScheme = common.ColorScheme;

pub const Action = input.Action;
pub const MouseButton = input.MouseButton;
pub const Modifiers = input.Modifiers;
pub const CursorShape = input.CursorShape;
pub const Key = input.Key;
pub const DecorationMode = common.DecorationMode;
pub const WindowState = common.WindowState;
pub const FrameMode = common.FrameMode;
pub const OffscreenOptions = common.OffscreenOptions;
pub const Event = common.Event;
pub const InitOptions = common.InitOptions;
pub const WindowOptions = common.WindowOptions;

pub const WindowCallbacks = struct {};

pub const Context = struct {
    allocator: std.mem.Allocator,
    clipboard: common.Clipboard = .{},
    pub fn init(allocator: std.mem.Allocator, _: InitOptions) !Context {
        _ = allocator;
        return error.UnsupportedPlatform;
    }

    pub fn deinit(self: *Context) void {
        self.clipboard.deinit(self.allocator);
    }

    pub fn createWindow(_: *Context, _: WindowOptions) !*Window {
        return error.UnsupportedPlatform;
    }

    pub fn pollEvents(_: *Context) void {}
    pub fn waitEventsTimeout(_: *Context, _: u64) !bool {
        return error.UnsupportedPlatform;
    }
    pub fn wake(_: *Context) void {}
    pub fn step(_: *Context) !void {
        return error.UnsupportedPlatform;
    }
    pub fn nextFrame(_: *Context) !void {
        return error.UnsupportedPlatform;
    }
    pub fn clipboardText(self: *Context, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return self.clipboard.get(allocator);
    }
    pub fn clipboardTextSet(self: *Context, text: []const u8) std.mem.Allocator.Error!void {
        return self.clipboard.set(self.allocator, text);
    }
    pub fn preferredColorScheme(_: *Context) ?ColorScheme {
        return null;
    }
};

pub const Window = struct {
    pub fn deinit(_: *Window) void {}
    pub fn setCallbacks(_: *Window, _: WindowCallbacks) void {}
    pub fn setTextInputRect(_: *Window, _: ?TextInputRect) void {}
    pub fn injectEvent(_: *Window, _: Event) !void {
        return error.UnsupportedPlatform;
    }
};
