const builtin = @import("builtin");
const types = @import("internal/types.zig");
const input = @import("internal/input.zig");
const runtime = @import("internal/runtime.zig");

const platform = if (builtin.target.os.tag == .linux)
    @import("linux/backend.zig")
else if (builtin.target.os.tag == .windows)
    @import("windows/backend.zig")
else
    @import("stub.zig");

// This module is the complete supported public surface of low. Platform
// modules and the shared runtime are implementation details.
pub const Context = platform.Context;
pub const Window = platform.Window;
pub const Error = runtime.Error;
pub const WindowCallbacks = runtime.WindowCallbacks;

pub const InitOptions = types.InitOptions;
pub const WindowOptions = types.WindowOptions;
pub const BackendRequest = types.BackendRequest;
pub const BackendKind = types.BackendKind;
pub const Environment = types.Environment;
pub const detectBackend = types.detectBackend;
pub const Size = types.Size;
pub const Point = types.Point;
pub const ContentScale = types.ContentScale;
pub const TextInputRect = types.TextInputRect;
pub const ColorScheme = types.ColorScheme;
pub const DecorationMode = types.DecorationMode;
pub const WindowState = types.WindowState;
pub const FrameMode = types.FrameMode;
pub const OffscreenOptions = types.OffscreenOptions;
pub const Event = types.Event;

pub const Action = input.Action;
pub const MouseButton = input.MouseButton;
pub const Modifiers = input.Modifiers;
pub const CursorShape = input.CursorShape;
pub const Key = input.Key;

pub const vulkan = @import("vulkan.zig");

test "root API exposes the supported contract" {
    // These declarations intentionally use only the root module. Keeping this
    // test here catches accidental platform-specific public aliases.
    const callbacks: WindowCallbacks = .{};
    _ = callbacks;
    _ = Context.init;
    _ = Window.deinit;
    _ = Error;
    _ = InitOptions{};
    _ = WindowOptions;
    _ = BackendRequest.auto;
    _ = BackendKind.offscreen;
    _ = Environment{};
    _ = detectBackend;
    _ = Size;
    _ = Point;
    _ = ContentScale;
    _ = TextInputRect;
    _ = ColorScheme;
    _ = DecorationMode.auto;
    _ = WindowState.normal;
    _ = FrameMode.manual;
    _ = OffscreenOptions{};
    _ = Event{ .close = {} };
    _ = Action.press;
    _ = MouseButton.left;
    _ = Modifiers{};
    _ = CursorShape.arrow;
    _ = Key.unknown;
    _ = vulkan;
    try @import("std").testing.expect(@hasDecl(@This(), "Error"));
    try @import("std").testing.expect(@hasDecl(@This(), "WindowCallbacks"));
    try @import("std").testing.expect(!@hasDecl(@This(), "State"));
    try @import("std").testing.expect(!@hasDecl(@This(), "VTable"));
}
