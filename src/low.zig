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
pub const Context = struct {
    state: runtime.BackendState,

    pub fn init(allocator: @import("std").mem.Allocator, options: InitOptions) Error!@This() {
        return .{ .state = runtime.BackendState.init(try platform.initState(allocator, options)) };
    }

    pub fn deinit(self: *@This()) void {
        self.state.get().deinit();
        self.* = undefined;
    }

    pub fn nativeDisplay(self: *const @This()) *anyopaque {
        return self.state.get().nativeDisplay();
    }

    pub fn requiredVulkanInstanceExtensions(self: *const @This()) []const [*:0]const u8 {
        return self.state.get().requiredVulkanInstanceExtensions();
    }

    pub fn backendKind(self: *const @This()) BackendKind {
        return self.state.get().backendKind();
    }

    pub fn createWindow(self: *const @This(), options: WindowOptions) Error!*Window {
        return self.state.get().createWindow(options);
    }

    pub fn pollEvents(self: *const @This()) void {
        self.state.get().pollEvents();
    }

    pub fn waitEvents(self: *const @This()) Error!void {
        return self.state.get().waitEvents();
    }

    /// Dispatches events until the given window may render again or closes.
    pub fn waitForRender(self: *const @This(), window: *Window) Error!void {
        return self.state.get().waitForRender(window);
    }

    pub fn waitEventsTimeout(self: *const @This(), timeout_ns: u64) Error!bool {
        return self.state.get().waitEventsTimeout(timeout_ns);
    }

    pub fn wake(self: *const @This()) void {
        self.state.get().wake();
    }

    pub fn step(self: *const @This()) Error!void {
        return self.state.get().step();
    }

    pub fn nextFrame(self: *const @This()) Error!void {
        return self.state.get().nextFrame();
    }

    pub fn clipboardText(self: *const @This(), allocator: @import("std").mem.Allocator) @import("std").mem.Allocator.Error![]u8 {
        return self.state.get().clipboardText(allocator);
    }

    pub fn clipboardTextSet(self: *const @This(), text: []const u8) @import("std").mem.Allocator.Error!void {
        return self.state.get().clipboardTextSet(text);
    }

    pub fn preferredColorScheme(self: *const @This()) ?ColorScheme {
        return self.state.get().preferredColorScheme();
    }
};
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
/// Size of a window's drawable content area, in logical content units.
pub const ContentSize = types.ContentSize;
/// Size of a window's framebuffer, in physical pixels.
pub const PixelSize = types.PixelSize;
/// Position or offset in a window's logical content coordinate space.
pub const ContentOffset = types.ContentOffset;
/// Position or offset in physical-pixel space.
pub const PixelOffset = types.PixelOffset;
/// Rectangle in a window's logical content coordinate space.
pub const ContentRect = types.ContentRect;
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
    _ = Context.waitForRender;
    _ = Window.requestFrame;
    _ = Window.cancelFrameRequest;
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
    _ = ContentSize;
    _ = PixelSize;
    _ = ContentOffset;
    _ = PixelOffset;
    _ = ContentRect;
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
