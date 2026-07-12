const std = @import("std");
const types = @import("types.zig");
const input = @import("input.zig");

const log = std.log.scoped(.low);

pub const BackendKind = types.BackendKind;
pub const Size = types.Size;
pub const Point = types.Point;
pub const ContentSize = types.ContentSize;
pub const PixelSize = types.PixelSize;
pub const ContentOffset = types.ContentOffset;
pub const PixelOffset = types.PixelOffset;
pub const ContentRect = types.ContentRect;
pub const ContentScale = types.ContentScale;
pub const TextInputRect = types.TextInputRect;
pub const ColorScheme = types.ColorScheme;
pub const Action = input.Action;
pub const MouseButton = input.MouseButton;
pub const Modifiers = input.Modifiers;
pub const CursorShape = input.CursorShape;
pub const Key = input.Key;

pub const DecorationMode = types.DecorationMode;
pub const WindowState = types.WindowState;

pub const Error = error{
    UnsupportedPlatform,
    BackendLibraryUnavailable,
    DisplayConnectionFailed,
    MissingRequiredGlobal,
    OutOfMemory,
    WaylandProtocolError,
    XkbInitFailed,
    SystemResources,
    NotOffscreen,
    ManualFrameStepping,
    WindowClassRegistrationFailed,
    WindowCreationFailed,
};

/// How an offscreen context advances rendering boundaries. Rendering remains
/// application-owned: call `nextFrame` before each rendered frame, or call
/// `step` explicitly in manual mode.
pub const FrameMode = types.FrameMode;
pub const OffscreenOptions = types.OffscreenOptions;
pub const InitOptions = types.InitOptions;

/// An event injected into an offscreen window. Text is copied when queued, so
/// its bytes need only remain valid for the duration of `injectEvent`.
pub const Event = types.Event;
pub const WindowOptions = types.WindowOptions;

pub const WindowCallbacks = struct {
    close: ?*const fn (*Window) void = null,
    /// Drawable content size changed, in logical content units. Use this for
    /// layout; it may differ from the framebuffer size on high-DPI displays.
    resize: ?*const fn (*Window, ContentSize) void = null,
    /// Framebuffer size changed, in physical pixels. Use this for
    /// pixel-addressed rendering resources and viewport dimensions.
    framebuffer_resize: ?*const fn (*Window, PixelSize) void = null,
    scale: ?*const fn (*Window, ContentScale) void = null,
    /// The platform has determined that rendering this window is currently
    /// unnecessary.  `false` means rendering may resume.  This is a hint: a
    /// compositor may omit it, and it does not mean the window was destroyed.
    /// The offscreen backend never emits this callback.
    render_suspended: ?*const fn (*Window, bool) void = null,
    /// The compositor has permitted one more frame. On Wayland this is backed
    /// by `wl_surface.frame`; other desktop backends are always frame-ready
    /// unless their render-suspension hint is active.
    /// `time_ms` has an unspecified epoch and is suitable only for measuring
    /// elapsed time between successive frame callbacks.
    frame: ?*const fn (*Window, u32) void = null,
    focus: ?*const fn (*Window, bool) void = null,
    cursor_enter: ?*const fn (*Window, bool) void = null,
    /// Pointer location in logical content units, relative to the content
    /// area's top-left corner.
    cursor_motion: ?*const fn (*Window, ContentOffset) void = null,
    mouse_button: ?*const fn (*Window, MouseButton, Action, Modifiers) void = null,
    /// Scroll delta in platform-defined scroll units; it is neither content
    /// units nor physical pixels.
    scroll: ?*const fn (*Window, f64, f64) void = null,
    key: ?*const fn (*Window, Key, u32, Action, Modifiers) void = null,
    text: ?*const fn (*Window, []const u8) void = null,
};

pub const VTable = struct {
    deinit: *const fn (*State) void,
    native_display: *const fn (*State) *anyopaque,
    required_vulkan_extensions: *const fn (*State) []const [*:0]const u8,
    create_window: *const fn (*State, WindowOptions) Error!*Window,
    pump_events: *const fn (*State, i32) Error!bool,
    wake: *const fn (*State) void,
    step: *const fn (*State) Error!void,
    next_frame: *const fn (*State) Error!void,
    inject_event: *const fn (*Window, Event) Error!void,

    destroy_window: *const fn (*Window) void,
    native_surface: *const fn (*Window) usize,
    set_title: *const fn (*Window, [:0]const u8) void,
    show: *const fn (*Window) void,
    hide: *const fn (*Window) void,
    maximize: *const fn (*Window) void,
    set_fullscreen: *const fn (*Window) void,
    restore: *const fn (*Window) void,
    iconify: *const fn (*Window) void,
    set_min_size: *const fn (*Window, ?Size) void,
    set_max_size: *const fn (*Window, ?Size) void,
    set_resizable: *const fn (*Window, bool) void,
    set_cursor_visible: *const fn (*Window, bool) void,
    set_cursor: *const fn (*Window, CursorShape) void,
    apply_scale: *const fn (*Window, f32) void,
    request_frame: *const fn (*Window) bool,
    cancel_frame_request: *const fn (*Window) void,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    backend_kind: BackendKind,
    backend_data: *anyopaque,
    vtable: *const VTable,
    event_error_reported: bool = false,
    clipboard: types.Clipboard = .{},

    pub fn deinit(self: *State) void {
        self.vtable.deinit(self);
    }

    pub fn clipboardText(self: *State, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return self.clipboard.get(allocator);
    }

    pub fn clipboardTextSet(self: *State, text: []const u8) std.mem.Allocator.Error!void {
        return self.clipboard.set(self.allocator, text);
    }

    pub fn preferredColorScheme(_: *State) ?ColorScheme {
        // Desktop portals and toolkit settings are backend-specific.  The
        // explicit environment override is useful for minimal compositors and
        // keeps the result deterministic for headless integration tests.
        const value = std.mem.span(std.c.getenv("COLORSCHEME") orelse return null);
        if (std.ascii.eqlIgnoreCase(value, "dark")) return .dark;
        if (std.ascii.eqlIgnoreCase(value, "light")) return .light;
        return null;
    }

    pub fn nativeDisplay(self: *State) *anyopaque {
        return self.vtable.native_display(self);
    }

    pub fn backendKind(self: *State) BackendKind {
        return self.backend_kind;
    }

    pub fn requiredVulkanInstanceExtensions(self: *State) []const [*:0]const u8 {
        return self.vtable.required_vulkan_extensions(self);
    }

    pub fn createWindow(self: *State, options: WindowOptions) Error!*Window {
        return self.vtable.create_window(self, options);
    }

    pub fn pollEvents(self: *State) void {
        _ = self.vtable.pump_events(self, 0) catch |err| {
            if (!self.event_error_reported) {
                log.err("event polling failed: {}", .{err});
                self.event_error_reported = true;
            }
        };
    }

    pub fn waitEvents(self: *State) Error!void {
        _ = try self.waitEventsTimeout(std.math.maxInt(u64));
    }

    /// Dispatches events until `window` has a render permit or is closing.
    /// This filters unrelated input/configuration events that can otherwise
    /// wake a frame-paced render loop before it is allowed to draw.
    pub fn waitForRender(self: *State, window: *Window) Error!void {
        while (!window.shouldRender() and !window.shouldClose()) try self.waitEvents();
    }

    pub fn waitEventsTimeout(self: *State, timeout_ns: u64) Error!bool {
        const timeout_ms: i32 = if (timeout_ns == std.math.maxInt(u64))
            -1
        else blk: {
            const ms = (timeout_ns + 999_999) / 1_000_000;
            break :blk @intCast(@min(ms, @as(u64, std.math.maxInt(i32))));
        };
        return self.vtable.pump_events(self, timeout_ms);
    }

    pub fn wake(self: *State) void {
        self.vtable.wake(self);
    }

    /// Delivers all queued offscreen events without waiting for a frame.
    pub fn step(self: *State) Error!void {
        return self.vtable.step(self);
    }

    /// Waits for the configured offscreen frame deadline, then delivers queued
    /// events. In manual mode use `step` instead.
    pub fn nextFrame(self: *State) Error!void {
        return self.vtable.next_frame(self);
    }
};

pub const Window = struct {
    ctx: *State,
    backend_data: *anyopaque,
    callbacks: WindowCallbacks = .{},
    user_data: ?*anyopaque = null,

    should_close: bool = false,
    visible: bool = true,
    focused: bool = false,
    maximized: bool = false,
    fullscreen: bool = false,
    minimized: bool = false,
    render_suspended: bool = false,
    frame_ready: bool = true,
    hovered: bool = false,
    resizable: bool = true,
    min_size: ?Size = null,
    max_size: ?Size = null,
    decorated: bool = true,
    decoration_mode: DecorationMode = .auto,
    cursor_visible: bool = true,
    cursor_shape: CursorShape = .arrow,
    size: ContentSize,
    framebuffer_size: PixelSize,
    content_scale: ContentScale = .{},
    cursor_pos: ContentOffset = .{ .x = 0, .y = 0 },
    text_input_rect: ?TextInputRect = null,
    pressed_keys: std.EnumSet(Key) = .empty,
    pressed_buttons: std.EnumSet(MouseButton) = .empty,

    pub fn deinit(self: *Window) void {
        self.ctx.vtable.destroy_window(self);
    }

    pub fn nativeSurface(self: *Window) usize {
        return self.ctx.vtable.native_surface(self);
    }

    pub fn nativeDisplay(self: *Window) *anyopaque {
        return self.ctx.nativeDisplay();
    }

    pub fn setUserData(self: *Window, ptr: ?*anyopaque) void {
        self.user_data = ptr;
    }

    pub fn getUserData(self: *Window) ?*anyopaque {
        return self.user_data;
    }

    /// Replaces all window event callbacks. Callbacks execute during
    /// `Context.pollEvents` or `Context.waitEvents` on the calling thread.
    pub fn setCallbacks(self: *Window, callbacks: WindowCallbacks) void {
        self.callbacks = callbacks;
    }

    /// Queues a synthetic event for an offscreen window. It is delivered by
    /// `Context.step`, `Context.nextFrame`, or event polling.
    pub fn injectEvent(self: *Window, event: Event) Error!void {
        return self.ctx.vtable.inject_event(self, event);
    }

    pub fn setTitle(self: *Window, title: [:0]const u8) void {
        self.ctx.vtable.set_title(self, title);
    }

    pub fn setState(self: *Window, state: WindowState) void {
        switch (state) {
            .normal => self.restore(),
            .maximize => self.maximize(),
            .fullscreen => self.setFullscreen(),
        }
    }

    pub fn setShouldClose(self: *Window, value: bool) void {
        self.should_close = value;
    }

    pub fn shouldClose(self: *const Window) bool {
        return self.should_close;
    }

    /// Returns the drawable content size in logical content units.
    pub fn getSize(self: *const Window) ContentSize {
        return self.size;
    }

    /// Returns the framebuffer size in physical pixels.
    pub fn getFramebufferSize(self: *const Window) PixelSize {
        return self.framebuffer_size;
    }

    pub fn getContentScale(self: *const Window) ContentScale {
        return self.content_scale;
    }

    /// Converts a logical content extent to a physical-pixel extent using the
    /// current content scale. This matches framebuffer-size calculation.
    pub fn contentToPixelSize(self: *const Window, size: ContentSize) PixelSize {
        return types.scaledSize(size, self.content_scale);
    }

    /// Converts a physical-pixel extent to the nearest logical content extent
    /// using the current content scale. Fractional scaling can make this a
    /// lossy conversion.
    pub fn pixelToContentSize(self: *const Window, size: PixelSize) ContentSize {
        return .{
            .width = @intFromFloat(@round(@as(f64, @floatFromInt(size.width)) / @as(f64, self.content_scale.x))),
            .height = @intFromFloat(@round(@as(f64, @floatFromInt(size.height)) / @as(f64, self.content_scale.y))),
        };
    }

    /// Converts an offset from logical content units to physical-pixel space.
    /// Fractional pixel offsets are preserved.
    pub fn contentToPixelOffset(self: *const Window, offset: ContentOffset) PixelOffset {
        return .{
            .x = offset.x * @as(f64, self.content_scale.x),
            .y = offset.y * @as(f64, self.content_scale.y),
        };
    }

    /// Converts an offset from physical-pixel space to logical content units.
    pub fn pixelToContentOffset(self: *const Window, offset: PixelOffset) ContentOffset {
        return .{
            .x = offset.x / @as(f64, self.content_scale.x),
            .y = offset.y / @as(f64, self.content_scale.y),
        };
    }

    /// Returns the pointer location in logical content units, relative to the
    /// content area's top-left corner.
    pub fn getCursorPos(self: *const Window) ContentOffset {
        return self.cursor_pos;
    }

    pub fn isFocused(self: *const Window) bool {
        return self.focused;
    }

    pub fn isVisible(self: *const Window) bool {
        return self.visible;
    }

    pub fn isMaximized(self: *const Window) bool {
        return self.maximized;
    }

    pub fn isFullscreen(self: *const Window) bool {
        return self.fullscreen;
    }

    pub fn isIconified(self: *const Window) bool {
        return self.minimized;
    }

    /// Returns whether the platform currently advises pausing rendering for
    /// this window.  It is a best-effort signal, not an exact visibility test.
    pub fn isRenderSuspended(self: *const Window) bool {
        return self.render_suspended;
    }

    /// Whether the window currently has a permit to render a frame. On
    /// Wayland, call `requestFrame` immediately before presenting to wait for
    /// the compositor's next frame callback.
    pub fn shouldRender(self: *const Window) bool {
        return !self.render_suspended and self.frame_ready;
    }

    /// Arms the next frame permit. This is a no-op on backends without a
    /// native frame callback. Call it immediately before presentation.
    pub fn requestFrame(self: *Window) void {
        if (self.ctx.backend_kind != .wayland or !self.frame_ready) return;
        if (self.ctx.vtable.request_frame(self)) self.frame_ready = false;
    }

    /// Releases a frame permit armed by `requestFrame` after presentation
    /// fails before committing the Wayland surface. This lets the application
    /// recreate its swapchain and render again instead of waiting forever for
    /// a callback that may never arrive.
    pub fn cancelFrameRequest(self: *Window) void {
        if (self.ctx.backend_kind != .wayland or self.frame_ready) return;
        self.ctx.vtable.cancel_frame_request(self);
        self.frame_ready = true;
    }

    pub fn isHovered(self: *const Window) bool {
        return self.hovered;
    }

    pub fn getKey(self: *const Window, key: Key) bool {
        return self.pressed_keys.contains(key);
    }

    pub fn getMouseButton(self: *const Window, button: MouseButton) bool {
        return self.pressed_buttons.contains(button);
    }

    pub fn show(self: *Window) void {
        self.visible = true;
        if (self.ctx.backend_kind != .offscreen) self.updateRenderSuspended(false);
        self.ctx.vtable.show(self);
    }

    pub fn hide(self: *Window) void {
        self.visible = false;
        if (self.ctx.backend_kind != .offscreen) self.updateRenderSuspended(true);
        self.ctx.vtable.hide(self);
    }

    pub fn maximize(self: *Window) void {
        self.ctx.vtable.maximize(self);
        self.maximized = true;
        self.fullscreen = false;
        self.minimized = false;
        if (self.ctx.backend_kind != .offscreen) self.updateRenderSuspended(false);
    }

    pub fn setFullscreen(self: *Window) void {
        self.ctx.vtable.set_fullscreen(self);
        self.maximized = false;
        self.fullscreen = true;
        self.minimized = false;
        if (self.ctx.backend_kind != .offscreen) self.updateRenderSuspended(false);
    }

    pub fn restore(self: *Window) void {
        self.ctx.vtable.restore(self);
        self.maximized = false;
        self.fullscreen = false;
        self.minimized = false;
        if (self.ctx.backend_kind != .offscreen) self.updateRenderSuspended(false);
    }

    pub fn iconify(self: *Window) void {
        self.ctx.vtable.iconify(self);
        self.minimized = true;
        if (self.ctx.backend_kind != .offscreen) self.updateRenderSuspended(true);
    }

    /// Sets the minimum drawable content size in logical content units.
    pub fn setMinSize(self: *Window, size: ?ContentSize) void {
        self.min_size = size;
        self.ctx.vtable.set_min_size(self, size);
    }

    /// Sets the maximum drawable content size in logical content units.
    pub fn setMaxSize(self: *Window, size: ?ContentSize) void {
        self.max_size = size;
        self.ctx.vtable.set_max_size(self, size);
    }

    pub fn setResizable(self: *Window, resizable: bool) void {
        self.resizable = resizable;
        self.ctx.vtable.set_resizable(self, resizable);
    }

    pub fn setCursorVisible(self: *Window, visible: bool) void {
        self.cursor_visible = visible;
        self.ctx.vtable.set_cursor_visible(self, visible);
    }

    pub fn setCursor(self: *Window, shape: CursorShape) void {
        self.cursor_shape = shape;
        self.ctx.vtable.set_cursor(self, shape);
    }

    /// Sets the active text field rectangle in logical content units. Platform
    /// text-input UI, such as an IME candidate window, is positioned from it.
    pub fn setTextInputRect(self: *Window, rect: ?TextInputRect) void {
        self.text_input_rect = rect;
    }

    pub fn updateScale(self: *Window, scale: f32) void {
        const new_scale: ContentScale = .{ .x = scale, .y = scale };
        if (new_scale.x == self.content_scale.x and new_scale.y == self.content_scale.y) return;
        self.content_scale = new_scale;
        self.ctx.vtable.apply_scale(self, scale);
        const old_fb = self.framebuffer_size;
        self.framebuffer_size = types.scaledSize(self.size, self.content_scale);
        if (self.callbacks.scale) |cb| cb(self, self.content_scale);
        if (old_fb.width != self.framebuffer_size.width or old_fb.height != self.framebuffer_size.height) {
            if (self.callbacks.framebuffer_resize) |cb| cb(self, self.framebuffer_size);
        }
    }

    pub fn updateSize(self: *Window, size: ContentSize) void {
        const old_size = self.size;
        const old_fb = self.framebuffer_size;
        self.size = size;
        self.framebuffer_size = types.scaledSize(size, self.content_scale);
        if (old_size.width != size.width or old_size.height != size.height) {
            if (self.callbacks.resize) |cb| cb(self, size);
        }
        if (old_fb.width != self.framebuffer_size.width or old_fb.height != self.framebuffer_size.height) {
            if (self.callbacks.framebuffer_resize) |cb| cb(self, self.framebuffer_size);
        }
    }

    pub fn updateCursorEnter(self: *Window, entered: bool) void {
        self.hovered = entered;
        if (self.callbacks.cursor_enter) |cb| cb(self, entered);
    }

    pub fn updateFocus(self: *Window, focused: bool) void {
        self.focused = focused;
        if (self.callbacks.focus) |cb| cb(self, focused);
    }

    pub fn updateRenderSuspended(self: *Window, suspended: bool) void {
        if (self.render_suspended == suspended) return;
        self.render_suspended = suspended;
        if (self.callbacks.render_suspended) |cb| cb(self, suspended);
    }

    pub fn updateFrameReady(self: *Window, time_ms: u32) void {
        self.frame_ready = true;
        if (self.callbacks.frame) |cb| cb(self, time_ms);
    }

    pub fn updateClose(self: *Window) void {
        self.should_close = true;
        if (self.callbacks.close) |cb| cb(self);
    }

    pub fn updateCursorMotion(self: *Window, x: f64, y: f64) void {
        self.cursor_pos = .{ .x = x, .y = y };
        if (self.callbacks.cursor_motion) |cb| cb(self, self.cursor_pos);
    }

    pub fn updateMouseButton(self: *Window, button: MouseButton, action: Action, mods: Modifiers) void {
        switch (action) {
            .press => _ = self.pressed_buttons.insert(button),
            .release => _ = self.pressed_buttons.remove(button),
            .repeat => {},
        }
        if (self.callbacks.mouse_button) |cb| cb(self, button, action, mods);
    }

    pub fn updateScroll(self: *Window, x: f64, y: f64) void {
        if (self.callbacks.scroll) |cb| cb(self, x, y);
    }

    pub fn updateKey(self: *Window, key: Key, raw_keycode: u32, action: Action, mods: Modifiers) void {
        switch (action) {
            .press => _ = self.pressed_keys.insert(key),
            .release => _ = self.pressed_keys.remove(key),
            .repeat => {},
        }
        if (self.callbacks.key) |cb| cb(self, key, raw_keycode, action, mods);
    }

    pub fn updateText(self: *Window, bytes: []const u8) void {
        if (self.callbacks.text) |cb| cb(self, bytes);
    }
};

/// The active backend behind a public context. Every variant uses the shared
/// runtime state, but the tag makes the selected backend explicit without a
/// compile-time context wrapper.
pub const BackendState = union(BackendKind) {
    wayland: *State,
    x11: *State,
    offscreen: *State,
    windows: *State,

    pub fn init(state: *State) BackendState {
        return switch (state.backend_kind) {
            .wayland => .{ .wayland = state },
            .x11 => .{ .x11 = state },
            .offscreen => .{ .offscreen = state },
            .windows => .{ .windows = state },
        };
    }

    pub fn get(self: *const BackendState) *State {
        return switch (self.*) {
            inline else => |state| state,
        };
    }
};

test "window converts between content and pixel spaces" {
    const window: Window = .{
        .ctx = undefined,
        .backend_data = undefined,
        .size = .{ .width = 100, .height = 50 },
        .framebuffer_size = .{ .width = 150, .height = 100 },
        .content_scale = .{ .x = 1.5, .y = 2.0 },
    };

    try std.testing.expectEqualDeep(
        PixelSize{ .width = 150, .height = 100 },
        window.contentToPixelSize(.{ .width = 100, .height = 50 }),
    );
    try std.testing.expectEqualDeep(
        ContentSize{ .width = 100, .height = 50 },
        window.pixelToContentSize(.{ .width = 150, .height = 100 }),
    );
    try std.testing.expectEqualDeep(
        PixelOffset{ .x = 15, .y = 10 },
        window.contentToPixelOffset(.{ .x = 10, .y = 5 }),
    );
    try std.testing.expectEqualDeep(
        ContentOffset{ .x = 10, .y = 5 },
        window.pixelToContentOffset(.{ .x = 15, .y = 10 }),
    );
}

test "render gate follows frame readiness and suspension" {
    var window: Window = .{
        .ctx = undefined,
        .backend_data = undefined,
        .size = .{ .width = 1, .height = 1 },
        .framebuffer_size = .{ .width = 1, .height = 1 },
    };
    try std.testing.expect(window.shouldRender());
    window.frame_ready = false;
    try std.testing.expect(!window.shouldRender());
    window.updateFrameReady(0);
    window.updateRenderSuspended(true);
    try std.testing.expect(!window.shouldRender());
    window.updateRenderSuspended(false);
    try std.testing.expect(window.shouldRender());
}
