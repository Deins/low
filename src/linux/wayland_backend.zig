const std = @import("std");
const api = @import("../internal/runtime.zig");
const native = @import("wayland_native.zig");

const Data = struct {
    allocator: std.mem.Allocator,
    native_state: *native.State,
    windows: std.ArrayListUnmanaged(*api.Window) = .empty,
};

pub fn init(allocator: std.mem.Allocator, options: api.InitOptions) api.Error!*api.State {
    const native_options: native.InitOptions = .{
        .backend = .wayland,
        .app_name = options.app_name,
        .display_name = options.display_name,
    };
    const native_state = native.State.init(allocator, native_options) catch |err| return mapError(err);
    errdefer native_state.deinit();

    const backend_data = allocator.create(Data) catch return error.OutOfMemory;
    errdefer allocator.destroy(backend_data);
    backend_data.* = .{ .allocator = allocator, .native_state = native_state };

    const state = allocator.create(api.State) catch return error.OutOfMemory;
    state.* = .{ .allocator = allocator, .backend_kind = .wayland, .backend_data = backend_data, .vtable = &vtable };
    return state;
}

fn mapError(err: anyerror) api.Error {
    return switch (err) {
        error.UnsupportedPlatform => error.UnsupportedPlatform,
        error.BackendLibraryUnavailable => error.BackendLibraryUnavailable,
        error.DisplayConnectionFailed => error.DisplayConnectionFailed,
        error.MissingRequiredGlobal => error.MissingRequiredGlobal,
        error.OutOfMemory => error.OutOfMemory,
        error.WaylandProtocolError => error.WaylandProtocolError,
        error.XkbInitFailed => error.XkbInitFailed,
        error.SystemResources => error.SystemResources,
        else => error.SystemResources,
    };
}

fn data(state: *api.State) *Data {
    return @ptrCast(@alignCast(state.backend_data));
}

fn nativeWindow(window: *api.Window) *native.Window {
    return @ptrCast(@alignCast(window.backend_data));
}

fn publicWindow(window: *native.Window) *api.Window {
    return @ptrCast(@alignCast(window.getUserData().?));
}

fn deinit(state: *api.State) void {
    const d = data(state);
    while (d.windows.items.len != 0) d.windows.items[d.windows.items.len - 1].deinit();
    d.windows.deinit(d.allocator);
    d.native_state.deinit();
    const allocator = d.allocator;
    state.clipboard.deinit(allocator);
    allocator.destroy(d);
    allocator.destroy(state);
}

fn nativeDisplay(state: *api.State) *anyopaque {
    return data(state).native_state.nativeDisplay();
}

fn requiredVulkanExtensions(state: *api.State) []const [*:0]const u8 {
    return data(state).native_state.requiredVulkanInstanceExtensions();
}

fn createWindow(state: *api.State, options: api.WindowOptions) api.Error!*api.Window {
    const d = data(state);
    const inner = d.native_state.createWindow(.{
        .title = options.title,
        .size = options.size,
        .app_id = options.app_id,
        .resizable = options.resizable,
        .decorated = options.decorated,
        .titlebar = switch (options.titlebar) {
            .auto => .auto,
            .server_side => .server_side,
            .client_side => .client_side,
        },
        .state = switch (options.state) {
            .normal => .normal,
            .maximize => .maximize,
            .fullscreen => .fullscreen,
        },
        .visible = options.visible,
        .min_size = options.min_size,
        .max_size = options.max_size,
    }) catch |err| return mapError(err);
    errdefer inner.deinit();

    const window = d.allocator.create(api.Window) catch return error.OutOfMemory;
    errdefer d.allocator.destroy(window);
    window.* = .{
        .ctx = state,
        .backend_data = inner,
        .size = inner.getSize(),
        .framebuffer_size = inner.getFramebufferSize(),
        .content_scale = inner.getContentScale(),
        .visible = inner.isVisible(),
        .focused = inner.isFocused(),
        .maximized = inner.isMaximized(),
        .fullscreen = inner.isFullscreen(),
        .minimized = inner.isIconified(),
        .hovered = inner.isHovered(),
        .resizable = options.resizable,
        .min_size = options.min_size,
        .max_size = options.max_size,
        .decorated = options.decorated,
        .decoration_mode = options.titlebar,
    };
    inner.setUserData(window);
    inner.callbacks = callbacks;
    try d.windows.append(d.allocator, window);
    return window;
}

fn destroyWindow(window: *api.Window) void {
    const d = data(window.ctx);
    for (d.windows.items, 0..) |candidate, i| if (candidate == window) {
        _ = d.windows.swapRemove(i);
        break;
    };
    nativeWindow(window).deinit();
    d.allocator.destroy(window);
}

fn nativeSurface(window: *api.Window) usize {
    return nativeWindow(window).nativeSurface();
}
fn step(_: *api.State) api.Error!void {
    return error.NotOffscreen;
}
fn nextFrame(_: *api.State) api.Error!void {
    return error.NotOffscreen;
}
fn injectEvent(_: *api.Window, _: api.Event) api.Error!void {
    return error.NotOffscreen;
}

fn setTitle(window: *api.Window, title: [:0]const u8) void {
    nativeWindow(window).setTitle(title);
}
fn show(window: *api.Window) void {
    nativeWindow(window).show();
}
fn hide(window: *api.Window) void {
    nativeWindow(window).hide();
}
fn maximize(window: *api.Window) void {
    nativeWindow(window).maximize();
}
fn setFullscreen(window: *api.Window) void {
    nativeWindow(window).setFullscreen();
}
fn restore(window: *api.Window) void {
    nativeWindow(window).restore();
}
fn iconify(window: *api.Window) void {
    nativeWindow(window).iconify();
}
fn setMinSize(window: *api.Window, size: ?api.Size) void {
    nativeWindow(window).setMinSize(size);
}
fn setMaxSize(window: *api.Window, size: ?api.Size) void {
    nativeWindow(window).setMaxSize(size);
}
fn setResizable(window: *api.Window, resizable: bool) void {
    nativeWindow(window).setResizable(resizable);
}
fn setCursorVisible(window: *api.Window, visible: bool) void {
    nativeWindow(window).setCursorVisible(visible);
}
fn setCursor(window: *api.Window, shape: api.CursorShape) void {
    nativeWindow(window).setCursor(@enumFromInt(@intFromEnum(shape)));
}
fn applyScale(_: *api.Window, _: f32) void {}

fn pumpEvents(state: *api.State, timeout_ms: i32) api.Error!bool {
    const inner = data(state).native_state;
    if (timeout_ms == 0) {
        inner.pollEvents();
        return true;
    }
    const timeout_ns: u64 = if (timeout_ms < 0) std.math.maxInt(u64) else @as(u64, @intCast(timeout_ms)) * std.time.ns_per_ms;
    return inner.waitEventsTimeout(timeout_ns) catch |err| return mapError(err);
}

fn wake(state: *api.State) void {
    data(state).native_state.wake();
}

fn close(inner: *native.Window) void {
    publicWindow(inner).updateClose();
}
fn resize(inner: *native.Window, size: native.Size) void {
    publicWindow(inner).updateSize(size);
}
fn framebufferResize(inner: *native.Window, _: native.Size) void {
    const window = publicWindow(inner);
    window.framebuffer_size = inner.getFramebufferSize();
    if (window.callbacks.framebuffer_resize) |cb| cb(window, window.framebuffer_size);
}
fn scale(inner: *native.Window, value: native.ContentScale) void {
    const window = publicWindow(inner);
    window.content_scale = value;
    if (window.callbacks.scale) |cb| cb(window, value);
}
fn focus(inner: *native.Window, focused: bool) void {
    publicWindow(inner).updateFocus(focused);
}
fn cursorEnter(inner: *native.Window, entered: bool) void {
    publicWindow(inner).updateCursorEnter(entered);
}
fn cursorMotion(inner: *native.Window, point: native.Point) void {
    publicWindow(inner).updateCursorMotion(point.x, point.y);
}
fn mouseButton(inner: *native.Window, button: native.MouseButton, action: native.Action, mods: native.Modifiers) void {
    publicWindow(inner).updateMouseButton(@enumFromInt(@intFromEnum(button)), @enumFromInt(@intFromEnum(action)), mods);
}
fn scroll(inner: *native.Window, x: f64, y: f64) void {
    publicWindow(inner).updateScroll(x, y);
}
fn key(inner: *native.Window, key_value: native.Key, raw: u32, action: native.Action, mods: native.Modifiers) void {
    publicWindow(inner).updateKey(@enumFromInt(@intFromEnum(key_value)), raw, @enumFromInt(@intFromEnum(action)), mods);
}
fn text(inner: *native.Window, bytes: []const u8) void {
    publicWindow(inner).updateText(bytes);
}

const callbacks: native.WindowCallbacks = .{
    .close = close,
    .resize = resize,
    .framebuffer_resize = framebufferResize,
    .scale = scale,
    .focus = focus,
    .cursor_enter = cursorEnter,
    .cursor_motion = cursorMotion,
    .mouse_button = mouseButton,
    .scroll = scroll,
    .key = key,
    .text = text,
};

const vtable: api.VTable = .{
    .deinit = deinit,
    .native_display = nativeDisplay,
    .required_vulkan_extensions = requiredVulkanExtensions,
    .create_window = createWindow,
    .pump_events = pumpEvents,
    .wake = wake,
    .step = step,
    .next_frame = nextFrame,
    .inject_event = injectEvent,
    .destroy_window = destroyWindow,
    .native_surface = nativeSurface,
    .set_title = setTitle,
    .show = show,
    .hide = hide,
    .maximize = maximize,
    .set_fullscreen = setFullscreen,
    .restore = restore,
    .iconify = iconify,
    .set_min_size = setMinSize,
    .set_max_size = setMaxSize,
    .set_resizable = setResizable,
    .set_cursor_visible = setCursorVisible,
    .set_cursor = setCursor,
    .apply_scale = applyScale,
};

test {
    std.testing.refAllDecls(@This());
}
