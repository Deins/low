const builtin = @import("builtin");
const types = @import("internal/types.zig");
const input = @import("internal/input.zig");
const runtime = @import("internal/runtime.zig");
const Vulkan = @import("vulkan.zig");

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

    /// Returns the native context data used to select a Vulkan queue with
    /// presentation support before creating a window or surface. Offscreen
    /// contexts do not require presentation support and return null.
    pub fn vulkanPresentationSupport(self: *const @This()) ?Vulkan.PresentationSupport {
        return switch (self.backendKind()) {
            .wayland => .{ .wayland = self.nativeDisplay() },
            .x11 => .{ .xlib = .{
                .display = self.nativeDisplay(),
                .visual_id = @intCast(self.state.get().vulkanVisualId()),
            } },
            .windows => .{ .win32 = {} },
            .offscreen => null,
        };
    }

    /// Creates a Vulkan presentation surface for a low window.
    ///
    /// The Vulkan instance must already have been created with
    /// `requiredVulkanInstanceExtensions()` enabled. Offscreen contexts do
    /// not have native surfaces and return `error.OffscreenSurfaceUnavailable`.
    pub fn createVulkanSurface(self: *const @This(), instance: *const Vulkan.Instance, window: *Window) !Vulkan.api.SurfaceKHR {
        return Vulkan.createSurface(instance, self.backendKind(), self.nativeDisplay(), window.nativeSurface());
    }

    /// Creates an owned Vulkan presentation surface for a low window.
    ///
    /// The returned surface may be borrowed by `vulkan.targets().RenderTarget`
    /// through `RenderTarget.Options.surface`; destroy the target before calling
    /// `PresentationSurface.deinit`. Alternatively, pass the value through
    /// `RenderTarget.Options.presentation_surface` to transfer ownership.
    pub fn createVulkanPresentationSurface(self: *const @This(), instance: *const Vulkan.Instance, window: *Window) !Vulkan.PresentationSurface {
        return Vulkan.PresentationSurface.init(instance, self.backendKind(), self.nativeDisplay(), window.nativeSurface());
    }

    pub fn backendKind(self: *const @This()) BackendKind {
        return self.state.get().backendKind();
    }

    pub fn createWindow(self: *const @This(), options: WindowOptions) Error!*Window {
        const window = try self.state.get().createWindow(options.runtimeOptions());
        errdefer window.deinit();
        if (options.vulkan) |vulkan_options| {
            if (self.backendKind() != .offscreen) {
                const surface = Vulkan.createSurface(
                    vulkan_options,
                    self.backendKind(),
                    self.nativeDisplay(),
                    window.nativeSurface(),
                ) catch return error.PresentationSurfaceCreationFailed;
                window.vulkan_surface = .{
                    .handle = surface,
                    .context = vulkan_options,
                    .destroy_fn = destroyWindowVulkanSurface,
                };
            }
        }
        return window;
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

    /// Dispatches events until at least one window may render again or closes.
    /// An empty slice returns immediately.
    pub fn waitForAnyRender(self: *const @This(), windows: []const *Window) Error!void {
        while (true) {
            for (windows) |window| if (window.shouldRender() or window.shouldClose()) return;
            if (windows.len == 0) return;
            try self.waitEvents();
        }
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

fn destroyWindowVulkanSurface(context: *const anyopaque, surface: u64) void {
    const instance: *const Vulkan.Instance = @ptrCast(@alignCast(context));
    instance.destroySurfaceKHR(surface);
}

pub const Window = platform.Window;
pub const Error = runtime.Error;
pub const WindowCallbacks = runtime.WindowCallbacks;

pub const InitOptions = types.InitOptions;
/// Native window configuration. Supplying `.vulkan` creates a window-owned
/// presentation surface automatically on desktop backends.
pub const WindowOptions = struct {
    title: [:0]const u8,
    size: ContentSize = .{ .width = 1280, .height = 720 },
    app_id: ?[:0]const u8 = null,
    resizable: bool = true,
    decorated: bool = true,
    titlebar: DecorationMode = .auto,
    state: WindowState = .normal,
    visible: bool = true,
    min_size: ?ContentSize = null,
    max_size: ?ContentSize = null,
    /// The Vulkan instance used to create a window-owned presentation surface.
    /// The instance must outlive the window and must enable the extensions
    /// returned by `Context.requiredVulkanInstanceExtensions()`.
    vulkan: ?*const Vulkan.Instance = null,

    fn runtimeOptions(self: @This()) types.WindowOptions {
        return .{
            .title = self.title,
            .size = self.size,
            .app_id = self.app_id,
            .resizable = self.resizable,
            .decorated = self.decorated,
            .titlebar = self.titlebar,
            .state = self.state,
            .visible = self.visible,
            .min_size = self.min_size,
            .max_size = self.max_size,
        };
    }
};
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
    _ = Context.waitForAnyRender;
    _ = Context.vulkanPresentationSupport;
    _ = Context.createVulkanSurface;
    _ = Context.createVulkanPresentationSurface;
    _ = Window.requestFrame;
    _ = Window.cancelFrameRequest;
    _ = Window.toggleFullscreen;
    _ = Window.vulkanSurface;
    _ = Window.setMouseCaptured;
    _ = Window.isMouseCaptured;
    _ = Window.isCursorVisible;
    _ = Window.deinit;
    _ = Error;
    _ = InitOptions{};
    _ = InitOptions{ .backend = .{ .offscreen = .{} } };
    _ = WindowOptions;
    _ = BackendRequest{ .auto = {} };
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
    _ = vulkan.PresentationSupport;
    try @import("std").testing.expect(@hasDecl(@This(), "Error"));
    try @import("std").testing.expect(@hasDecl(@This(), "WindowCallbacks"));
    try @import("std").testing.expect(!@hasField(WindowCallbacks, "close"));
    try @import("std").testing.expect(!@hasField(WindowCallbacks, "resize"));
    try @import("std").testing.expect(!@hasField(WindowCallbacks, "framebuffer_resize"));
    try @import("std").testing.expect(!@hasField(WindowCallbacks, "scale"));
    try @import("std").testing.expect(!@hasField(WindowCallbacks, "focus"));
    try @import("std").testing.expect(!@hasField(WindowCallbacks, "cursor_enter"));
    try @import("std").testing.expect(@hasField(WindowCallbacks, "cursor_motion"));
    try @import("std").testing.expect(@hasField(WindowCallbacks, "cursor_delta"));
    try @import("std").testing.expect(!@hasField(WindowCallbacks, "render_suspended"));
    try @import("std").testing.expect(!@hasField(WindowCallbacks, "frame"));
    try @import("std").testing.expect(!@hasDecl(@This(), "State"));
    try @import("std").testing.expect(!@hasDecl(@This(), "VTable"));
    try @import("std").testing.expect(!@hasDecl(Window, "updateScale"));
    try @import("std").testing.expect(!@hasDecl(Window, "updateSize"));
    try @import("std").testing.expect(!@hasDecl(Window, "updateFrameReady"));
    try @import("std").testing.expect(!@hasDecl(Window, "updateClose"));
    try @import("std").testing.expect(!@hasDecl(Window, "updateKey"));
    try @import("std").testing.expect(!@hasDecl(Window, "updateText"));
}
