const builtin = @import("builtin");
const common = @import("common.zig");
const input = @import("input.zig");

pub const BackendRequest = common.BackendRequest;
pub const BackendKind = impl.BackendKind;
pub const Environment = common.Environment;
pub const detectBackend = common.detectBackend;
pub const Size = common.Size;
pub const Point = common.Point;
pub const ContentScale = common.ContentScale;
pub const TextInputRect = common.TextInputRect;
pub const ColorScheme = common.ColorScheme;
pub const FrameMode = common.FrameMode;
pub const OffscreenOptions = common.OffscreenOptions;
pub const Event = common.Event;
pub const vulkan = @import("vulkan.zig");

pub const Action = input.Action;
pub const MouseButton = input.MouseButton;
pub const Modifiers = input.Modifiers;
pub const CursorShape = input.CursorShape;
pub const Key = input.Key;

const impl = if (builtin.target.os.tag == .linux)
    @import("linux/backend.zig")
else if (builtin.target.os.tag == .windows)
    @import("windows/backend.zig")
else
    @import("stub.zig");

pub const DecorationMode = common.DecorationMode;
pub const WindowState = common.WindowState;
pub const InitOptions = common.InitOptions;
pub const WindowOptions = common.WindowOptions;
pub const WindowCallbacks = impl.WindowCallbacks;
pub const Context = impl.Context;
pub const Window = impl.Window;
