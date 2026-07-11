const std = @import("std");
const common = @import("../common.zig");
const input = @import("../input.zig");

const log = std.log.scoped(.low);

pub const BackendKind = common.BackendKind;
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

pub const Error = error{
    UnsupportedPlatform,
    BackendLibraryUnavailable,
    StaticExecutableUnsupported,
    DisplayConnectionFailed,
    MissingRequiredGlobal,
    OutOfMemory,
    WaylandProtocolError,
    XkbInitFailed,
    SystemResources,
};

pub const InitOptions = struct {
    backend: common.BackendRequest = .auto,
    app_name: [:0]const u8 = "low",
    display_name: ?[:0]const u8 = null,
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

pub const WindowCallbacks = struct {
    close: ?*const fn (*Window) void = null,
    resize: ?*const fn (*Window, Size) void = null,
    framebuffer_resize: ?*const fn (*Window, Size) void = null,
    scale: ?*const fn (*Window, ContentScale) void = null,
    focus: ?*const fn (*Window, bool) void = null,
    cursor_enter: ?*const fn (*Window, bool) void = null,
    cursor_motion: ?*const fn (*Window, Point) void = null,
    mouse_button: ?*const fn (*Window, MouseButton, Action, Modifiers) void = null,
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
};

pub const State = struct {
    allocator: std.mem.Allocator,
    backend_kind: BackendKind,
    backend_data: *anyopaque,
    vtable: *const VTable,
    event_error_reported: bool = false,

    pub fn deinit(self: *State) void {
        self.vtable.deinit(self);
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
    hovered: bool = false,
    resizable: bool = true,
    min_size: ?Size = null,
    max_size: ?Size = null,
    decorated: bool = true,
    decoration_mode: DecorationMode = .auto,
    cursor_visible: bool = true,
    cursor_shape: CursorShape = .arrow,
    size: Size,
    framebuffer_size: Size,
    content_scale: ContentScale = .{},
    cursor_pos: Point = .{ .x = 0, .y = 0 },
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

    pub fn getSize(self: *const Window) Size {
        return self.size;
    }

    pub fn getFramebufferSize(self: *const Window) Size {
        return self.framebuffer_size;
    }

    pub fn getContentScale(self: *const Window) ContentScale {
        return self.content_scale;
    }

    pub fn getCursorPos(self: *const Window) Point {
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
        self.ctx.vtable.show(self);
    }

    pub fn hide(self: *Window) void {
        self.visible = false;
        self.ctx.vtable.hide(self);
    }

    pub fn maximize(self: *Window) void {
        self.ctx.vtable.maximize(self);
        self.maximized = true;
        self.fullscreen = false;
        self.minimized = false;
    }

    pub fn setFullscreen(self: *Window) void {
        self.ctx.vtable.set_fullscreen(self);
        self.maximized = false;
        self.fullscreen = true;
        self.minimized = false;
    }

    pub fn restore(self: *Window) void {
        self.ctx.vtable.restore(self);
        self.maximized = false;
        self.fullscreen = false;
        self.minimized = false;
    }

    pub fn iconify(self: *Window) void {
        self.ctx.vtable.iconify(self);
        self.minimized = true;
    }

    pub fn setMinSize(self: *Window, size: ?Size) void {
        self.min_size = size;
        self.ctx.vtable.set_min_size(self, size);
    }

    pub fn setMaxSize(self: *Window, size: ?Size) void {
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

    pub fn updateScale(self: *Window, scale: f32) void {
        const new_scale: ContentScale = .{ .x = scale, .y = scale };
        if (new_scale.x == self.content_scale.x and new_scale.y == self.content_scale.y) return;
        self.content_scale = new_scale;
        self.ctx.vtable.apply_scale(self, scale);
        const old_fb = self.framebuffer_size;
        self.framebuffer_size = common.scaledSize(self.size, self.content_scale);
        if (self.callbacks.scale) |cb| cb(self, self.content_scale);
        if (old_fb.width != self.framebuffer_size.width or old_fb.height != self.framebuffer_size.height) {
            if (self.callbacks.framebuffer_resize) |cb| cb(self, self.framebuffer_size);
        }
    }

    pub fn updateSize(self: *Window, size: Size) void {
        const old_size = self.size;
        const old_fb = self.framebuffer_size;
        self.size = size;
        self.framebuffer_size = common.scaledSize(size, self.content_scale);
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
