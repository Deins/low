const std = @import("std");
const api = @import("api.zig");
const input = @import("../input.zig");
const x11 = @import("x11.zig");

const Data = struct {
    allocator: std.mem.Allocator,
    display: *x11.Display,
    screen: c_int,
    root: x11.Window,
    fd: c_int,
    wake_fd: std.posix.fd_t,
    atoms: x11.Atoms,
    cursor_cache: std.EnumArray(api.CursorShape, x11.Cursor) = .initFill(0),
    empty_cursor: x11.Cursor = 0,
    windows: std.ArrayListUnmanaged(*api.Window) = .empty,
};

const WindowData = struct { handle: x11.Window };
const NetWmState = enum { maximize, fullscreen };

pub fn init(allocator: std.mem.Allocator, options: api.InitOptions) api.Error!*api.State {
    x11.ensureLoaded() catch |err| return mapLibraryLoadError(err);
    const display = x11.XOpenDisplay(if (options.display_name) |name| name.ptr else null) orelse
        return error.DisplayConnectionFailed;
    errdefer _ = x11.XCloseDisplay(display);

    const wake_raw = std.c.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
    if (wake_raw < 0) return error.SystemResources;
    const wake_fd: std.posix.fd_t = @intCast(wake_raw);
    errdefer _ = std.os.linux.close(wake_fd);

    const data = allocator.create(Data) catch return error.OutOfMemory;
    errdefer allocator.destroy(data);
    const screen = x11.XDefaultScreen(display);
    data.* = .{
        .allocator = allocator,
        .display = display,
        .screen = screen,
        .root = x11.XRootWindow(display, screen),
        .fd = x11.XConnectionNumber(display),
        .wake_fd = wake_fd,
        .atoms = undefined,
    };
    data.atoms = .{
        .wm_delete_window = x11.XInternAtom(display, "WM_DELETE_WINDOW", 0),
        .wm_protocols = x11.XInternAtom(display, "WM_PROTOCOLS", 0),
        .net_wm_state = x11.XInternAtom(display, "_NET_WM_STATE", 0),
        .net_wm_state_fullscreen = x11.XInternAtom(display, "_NET_WM_STATE_FULLSCREEN", 0),
        .net_wm_state_maximized_horz = x11.XInternAtom(display, "_NET_WM_STATE_MAXIMIZED_HORZ", 0),
        .net_wm_state_maximized_vert = x11.XInternAtom(display, "_NET_WM_STATE_MAXIMIZED_VERT", 0),
        .net_wm_name = x11.XInternAtom(display, "_NET_WM_NAME", 0),
        .utf8_string = x11.XInternAtom(display, "UTF8_STRING", 0),
        .net_wm_window_type = x11.XInternAtom(display, "_NET_WM_WINDOW_TYPE", 0),
        .net_wm_window_type_normal = x11.XInternAtom(display, "_NET_WM_WINDOW_TYPE_NORMAL", 0),
        .motif_wm_hints = x11.XInternAtom(display, "_MOTIF_WM_HINTS", 0),
    };
    data.empty_cursor = createEmptyCursor(data) orelse 0;
    _ = x11.XkbSetDetectableAutoRepeat(display, 1, null);
    _ = x11.XFlush(display);

    const state = allocator.create(api.State) catch return error.OutOfMemory;
    state.* = .{ .allocator = allocator, .backend_kind = .x11, .backend_data = data, .vtable = &vtable };
    return state;
}

fn mapLibraryLoadError(err: anyerror) api.Error {
    return switch (err) {
        error.StaticExecutableUnsupported => error.StaticExecutableUnsupported,
        else => error.BackendLibraryUnavailable,
    };
}

fn stateData(state: *api.State) *Data {
    return @ptrCast(@alignCast(state.backend_data));
}

fn windowData(window: *api.Window) *WindowData {
    return @ptrCast(@alignCast(window.backend_data));
}

fn deinit(state: *api.State) void {
    const data = stateData(state);
    while (data.windows.items.len != 0) data.windows.items[data.windows.items.len - 1].deinit();
    data.windows.deinit(data.allocator);
    for (&data.cursor_cache.values) |*cursor| if (cursor.* != 0) {
        _ = x11.XFreeCursor(data.display, cursor.*);
        cursor.* = 0;
    };
    if (data.empty_cursor != 0) _ = x11.XFreeCursor(data.display, data.empty_cursor);
    _ = std.os.linux.close(data.wake_fd);
    _ = x11.XCloseDisplay(data.display);
    const allocator = data.allocator;
    state.clipboard.deinit(allocator);
    allocator.destroy(data);
    allocator.destroy(state);
}

fn nativeDisplay(state: *api.State) *anyopaque {
    return stateData(state).display;
}

fn requiredVulkanExtensions(_: *api.State) []const [*:0]const u8 {
    return &.{ "VK_KHR_surface", "VK_KHR_xlib_surface" };
}

fn createWindow(state: *api.State, options: api.WindowOptions) api.Error!*api.Window {
    const data = stateData(state);
    const win = x11.XCreateSimpleWindow(data.display, data.root, 0, 0, @intCast(options.size.width), @intCast(options.size.height), 0, 0, 0);
    if (win == 0) return error.OutOfMemory;
    errdefer _ = x11.XDestroyWindow(data.display, win);

    const mask = x11.KeyPressMask | x11.KeyReleaseMask | x11.ButtonPressMask | x11.ButtonReleaseMask |
        x11.PointerMotionMask | x11.EnterWindowMask | x11.LeaveWindowMask | x11.FocusChangeMask |
        x11.StructureNotifyMask | x11.PropertyChangeMask;
    _ = x11.XSelectInput(data.display, win, mask);
    var protocols = [_]x11.Atom{data.atoms.wm_delete_window};
    _ = x11.XSetWMProtocols(data.display, win, &protocols, protocols.len);

    const mode: api.DecorationMode = switch (options.titlebar) {
        .auto => if (options.decorated) .server_side else .client_side,
        else => options.titlebar,
    };
    setDecorations(data, win, mode == .server_side);
    setWindowType(data, win);
    setTitleNative(data, win, options.title);
    updateSizeHints(data, win, options.size, options.min_size, options.max_size, options.resizable);

    const native = data.allocator.create(WindowData) catch return error.OutOfMemory;
    errdefer data.allocator.destroy(native);
    native.* = .{ .handle = win };
    const window = data.allocator.create(api.Window) catch return error.OutOfMemory;
    errdefer data.allocator.destroy(window);
    window.* = .{
        .ctx = state,
        .backend_data = native,
        .size = options.size,
        .framebuffer_size = options.size,
        .visible = options.visible,
        .resizable = options.resizable,
        .min_size = options.min_size,
        .max_size = options.max_size,
        .decorated = options.decorated,
        .decoration_mode = mode,
    };
    try data.windows.append(data.allocator, window);
    errdefer _ = data.windows.pop();

    if (options.visible) _ = x11.XMapWindow(data.display, win);
    switch (options.state) {
        .normal => {},
        .maximize => window.maximize(),
        .fullscreen => window.setFullscreen(),
    }
    _ = x11.XFlush(data.display);
    return window;
}

fn destroyWindow(window: *api.Window) void {
    const data = stateData(window.ctx);
    for (data.windows.items, 0..) |candidate, i| if (candidate == window) {
        _ = data.windows.swapRemove(i);
        break;
    };
    _ = x11.XDestroyWindow(data.display, windowData(window).handle);
    data.allocator.destroy(windowData(window));
    data.allocator.destroy(window);
    _ = x11.XFlush(data.display);
}

fn nativeSurface(window: *api.Window) usize {
    return windowData(window).handle;
}
fn setTitle(window: *api.Window, title: [:0]const u8) void {
    setTitleNative(stateData(window.ctx), windowData(window).handle, title);
}
fn show(window: *api.Window) void {
    const d = stateData(window.ctx);
    _ = x11.XMapWindow(d.display, windowData(window).handle);
    _ = x11.XFlush(d.display);
}
fn hide(window: *api.Window) void {
    const d = stateData(window.ctx);
    _ = x11.XUnmapWindow(d.display, windowData(window).handle);
    _ = x11.XFlush(d.display);
}
fn maximize(window: *api.Window) void {
    setNetWmState(window, true, .maximize);
}
fn setFullscreen(window: *api.Window) void {
    setNetWmState(window, true, .fullscreen);
}
fn restore(window: *api.Window) void {
    setNetWmState(window, false, .fullscreen);
    setNetWmState(window, false, .maximize);
}
fn iconify(window: *api.Window) void {
    const d = stateData(window.ctx);
    _ = x11.XIconifyWindow(d.display, windowData(window).handle, d.screen);
    _ = x11.XFlush(d.display);
}
fn setMinSize(window: *api.Window, _: ?api.Size) void {
    updateWindowSizeHints(window);
}
fn setMaxSize(window: *api.Window, _: ?api.Size) void {
    updateWindowSizeHints(window);
}
fn setResizable(window: *api.Window, _: bool) void {
    updateWindowSizeHints(window);
}
fn setCursorVisible(window: *api.Window, _: bool) void {
    applyCursor(window);
}
fn setCursor(window: *api.Window, shape: api.CursorShape) void {
    window.cursor_visible = shape != .hidden;
    applyCursor(window);
}
fn applyScale(_: *api.Window, _: f32) void {}

fn pumpEvents(state: *api.State, timeout_ms: i32) api.Error!bool {
    const data = stateData(state);
    if (x11.XPending(data.display) > 0) {
        handlePendingEvents(data);
        return true;
    }
    var fds = [_]std.posix.pollfd{
        .{ .fd = data.fd, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = data.wake_fd, .events = std.posix.POLL.IN, .revents = 0 },
    };
    const ready = std.posix.poll(&fds, timeout_ms) catch return error.SystemResources;
    if (ready == 0) return false;
    if ((fds[1].revents & std.posix.POLL.IN) != 0) drainWakeFd(data);
    if ((fds[0].revents & std.posix.POLL.IN) != 0) handlePendingEvents(data);
    return true;
}

fn wake(state: *api.State) void {
    const value: u64 = 1;
    _ = std.os.linux.write(stateData(state).wake_fd, @ptrCast(std.mem.asBytes(&value).ptr), @sizeOf(u64));
}

fn drainWakeFd(data: *Data) void {
    var value: u64 = 0;
    _ = std.posix.read(data.wake_fd, std.mem.asBytes(&value)) catch {};
}

fn handlePendingEvents(data: *Data) void {
    while (x11.XPending(data.display) > 0) {
        var event: x11.XEvent = std.mem.zeroes(x11.XEvent);
        _ = x11.XNextEvent(data.display, &event);
        handleEvent(data, &event);
    }
}

fn handleEvent(data: *Data, event: *x11.XEvent) void {
    switch (event.type) {
        x11.ClientMessage => if (event.xclient.message_type == data.atoms.wm_protocols and @as(x11.Atom, @intCast(event.xclient.data.l[0])) == data.atoms.wm_delete_window) {
            if (findWindow(data, event.xclient.window)) |w| w.updateClose();
        },
        x11.ConfigureNotify => if (findWindow(data, event.xconfigure.window)) |w| w.updateSize(.{ .width = event.xconfigure.width, .height = event.xconfigure.height }),
        x11.FocusIn => if (findWindow(data, event.xfocus.window)) |w| w.updateFocus(true),
        x11.FocusOut => if (findWindow(data, event.xfocus.window)) |w| w.updateFocus(false),
        x11.EnterNotify => if (findWindow(data, event.xcrossing.window)) |w| {
            w.updateCursorEnter(true);
            applyCursor(w);
        },
        x11.LeaveNotify => if (findWindow(data, event.xcrossing.window)) |w| w.updateCursorEnter(false),
        x11.MotionNotify => if (findWindow(data, event.xmotion.window)) |w| w.updateCursorMotion(@floatFromInt(event.xmotion.x), @floatFromInt(event.xmotion.y)),
        x11.ButtonPress => handleButton(data, event.xbutton, true),
        x11.ButtonRelease => handleButton(data, event.xbutton, false),
        x11.KeyPress => handleKey(data, event.xkey, true),
        x11.KeyRelease => handleKey(data, event.xkey, false),
        x11.MapNotify => if (findWindow(data, event.xmap.window)) |w| {
            w.visible = true;
            w.minimized = false;
        },
        x11.UnmapNotify => if (findWindow(data, event.xunmap.window)) |w| {
            w.visible = false;
            w.minimized = true;
        },
        else => {},
    }
}

fn handleButton(data: *Data, event: x11.XButtonEvent, pressed: bool) void {
    const window = findWindow(data, event.window) orelse return;
    const mods = modifiers(event.state);
    switch (event.button) {
        4 => if (pressed) window.updateScroll(0, 1),
        5 => if (pressed) window.updateScroll(0, -1),
        6 => if (pressed) window.updateScroll(-1, 0),
        7 => if (pressed) window.updateScroll(1, 0),
        else => {
            const button: api.MouseButton = switch (event.button) {
                1 => .left,
                2 => .middle,
                3 => .right,
                8 => .four,
                9 => .five,
                10 => .six,
                11 => .seven,
                12 => .eight,
                else => return,
            };
            window.updateMouseButton(button, if (pressed) .press else .release, mods);
        },
    }
}

fn handleKey(data: *Data, event: x11.XKeyEvent, pressed: bool) void {
    const window = findWindow(data, event.window) orelse return;
    var bytes: [64]u8 = undefined;
    var keysym: x11.KeySym = 0;
    const len = x11.XLookupString(@constCast(&event), &bytes, bytes.len, &keysym, null);
    const key = mapKeysym(keysym);
    const action: api.Action = if (pressed and window.pressed_keys.contains(key)) .repeat else if (pressed) .press else .release;
    const mods = modifiers(event.state);
    window.updateKey(key, @intCast(event.keycode), action, mods);
    if (pressed and !mods.control and len > 0) {
        const text = bytes[0..@intCast(len)];
        if (input.isPrintableText(text)) window.updateText(text);
    }
}

fn modifiers(state: c_uint) api.Modifiers {
    return .{ .shift = state & x11.ShiftMask != 0, .control = state & x11.ControlMask != 0, .alt = state & x11.Mod1Mask != 0, .super = state & x11.Mod4Mask != 0, .caps_lock = state & x11.LockMask != 0, .num_lock = state & x11.Mod2Mask != 0 };
}

fn findWindow(data: *Data, handle: x11.Window) ?*api.Window {
    for (data.windows.items) |window| if (windowData(window).handle == handle) return window;
    return null;
}

fn createEmptyCursor(data: *Data) ?x11.Cursor {
    const bytes = [_]u8{0};
    const pixmap = x11.XCreateBitmapFromData(data.display, data.root, &bytes, 1, 1);
    if (pixmap == 0) return null;
    defer _ = x11.XFreePixmap(data.display, pixmap);
    var color: x11.XColor = std.mem.zeroes(x11.XColor);
    return x11.XCreatePixmapCursor(data.display, pixmap, pixmap, &color, &color, 0, 0);
}

fn createFontCursor(data: *Data, shape: api.CursorShape) x11.Cursor {
    const native: c_uint = switch (shape) {
        .arrow => x11.XC_left_ptr,
        .crosshair => x11.XC_crosshair,
        .hand => x11.XC_hand2,
        .ibeam => x11.XC_xterm,
        .resize_all => x11.XC_fleur,
        .resize_ns => x11.XC_sb_v_double_arrow,
        .resize_ew => x11.XC_sb_h_double_arrow,
        .resize_nesw => x11.XC_bottom_left_corner,
        .resize_nwse => x11.XC_bottom_right_corner,
        .not_allowed => x11.XC_pirate,
        .hidden => return data.empty_cursor,
    };
    return x11.XCreateFontCursor(data.display, native);
}

fn applyCursor(window: *api.Window) void {
    const data = stateData(window.ctx);
    const cursor = if (!window.cursor_visible) data.empty_cursor else blk: {
        const entry = &data.cursor_cache.values[@intFromEnum(window.cursor_shape)];
        if (entry.* == 0) entry.* = createFontCursor(data, window.cursor_shape);
        break :blk entry.*;
    };
    if (cursor != 0) _ = x11.XDefineCursor(data.display, windowData(window).handle, cursor) else _ = x11.XUndefineCursor(data.display, windowData(window).handle);
    _ = x11.XFlush(data.display);
}

fn updateWindowSizeHints(window: *api.Window) void {
    updateSizeHints(stateData(window.ctx), windowData(window).handle, window.size, window.min_size, window.max_size, window.resizable);
}
fn updateSizeHints(data: *Data, handle: x11.Window, size: api.Size, min_size: ?api.Size, max_size: ?api.Size, resizable: bool) void {
    var hints: x11.XSizeHints = std.mem.zeroes(x11.XSizeHints);
    const min = if (resizable) min_size else size;
    const max = if (resizable) max_size else size;
    if (min) |s| {
        hints.flags |= x11.PMinSize;
        hints.min_width = s.width;
        hints.min_height = s.height;
    }
    if (max) |s| {
        hints.flags |= x11.PMaxSize;
        hints.max_width = s.width;
        hints.max_height = s.height;
    }
    x11.XSetWMNormalHints(data.display, handle, &hints);
}

fn setDecorations(data: *Data, handle: x11.Window, decorated: bool) void {
    const hints = [_]c_long{ 2, 0, if (decorated) 1 else 0, 0, 0 };
    _ = x11.XChangeProperty(data.display, handle, data.atoms.motif_wm_hints, data.atoms.motif_wm_hints, 32, x11.PropModeReplace, @ptrCast(&hints), hints.len);
}
fn setWindowType(data: *Data, handle: x11.Window) void {
    var value = [_]x11.Atom{data.atoms.net_wm_window_type_normal};
    _ = x11.XChangeProperty(data.display, handle, data.atoms.net_wm_window_type, x11.XA_ATOM, 32, x11.PropModeReplace, @ptrCast(&value), value.len);
}
fn setTitleNative(data: *Data, handle: x11.Window, title: [:0]const u8) void {
    _ = x11.XStoreName(data.display, handle, title.ptr);
    _ = x11.XChangeProperty(data.display, handle, data.atoms.net_wm_name, data.atoms.utf8_string, 8, x11.PropModeReplace, title.ptr, @intCast(title.len));
}

fn setNetWmState(window: *api.Window, add: bool, requested: NetWmState) void {
    const data = stateData(window.ctx);
    var event: x11.XEvent = std.mem.zeroes(x11.XEvent);
    event.xclient.type = x11.ClientMessage;
    event.xclient.send_event = 1;
    event.xclient.window = windowData(window).handle;
    event.xclient.message_type = data.atoms.net_wm_state;
    event.xclient.format = 32;
    event.xclient.data.l[0] = if (add) 1 else 0;
    switch (requested) {
        .maximize => {
            event.xclient.data.l[1] = @intCast(data.atoms.net_wm_state_maximized_horz);
            event.xclient.data.l[2] = @intCast(data.atoms.net_wm_state_maximized_vert);
        },
        .fullscreen => event.xclient.data.l[1] = @intCast(data.atoms.net_wm_state_fullscreen),
    }
    event.xclient.data.l[3] = 1;
    _ = x11.XSendEvent(data.display, data.root, 0, x11.SubstructureRedirectMask | x11.SubstructureNotifyMask, &event);
    _ = x11.XFlush(data.display);
}

fn mapKeysym(sym: x11.KeySym) api.Key {
    if (sym >= 0xffbe and sym <= 0xffd6) return @enumFromInt(@intFromEnum(api.Key.f1) + @as(u16, @intCast(sym - 0xffbe)));
    if (sym >= 'a' and sym <= 'z') {
        return @enumFromInt(@as(u16, @intFromEnum(api.Key.a)) + @as(u16, @intCast(sym - 'a')));
    }
    if (sym >= 'A' and sym <= 'Z') {
        return @enumFromInt(@as(u16, @intFromEnum(api.Key.a)) + @as(u16, @intCast(sym - 'A')));
    }
    if (sym >= '0' and sym <= '9') {
        return @enumFromInt(@as(u16, @intFromEnum(api.Key.zero)) + @as(u16, @intCast(sym - '0')));
    }
    return switch (sym) {
        0xffaf => .kp_divide,
        0xffaa => .kp_multiply,
        0xffad => .kp_subtract,
        0xffab => .kp_add,
        0xffb0 => .kp_0,
        0xffb1 => .kp_1,
        0xffb2 => .kp_2,
        0xffb3 => .kp_3,
        0xffb4 => .kp_4,
        0xffb5 => .kp_5,
        0xffb6 => .kp_6,
        0xffb7 => .kp_7,
        0xffb8 => .kp_8,
        0xffb9 => .kp_9,
        0xffae => .kp_decimal,
        0xffbd => .kp_equal,
        0xff8d => .kp_enter,
        0xff0d => .enter,
        0xff1b => .escape,
        0xff09 => .tab,
        0xffe1 => .left_shift,
        0xffe2 => .right_shift,
        0xffe3 => .left_control,
        0xffe4 => .right_control,
        0xffe9 => .left_alt,
        0xffea => .right_alt,
        0xffeb => .left_command,
        0xffec => .right_command,
        0xff67 => .menu,
        0xff7f => .num_lock,
        0xffe5 => .caps_lock,
        0xff61 => .print,
        0xff14 => .scroll_lock,
        0xff13 => .pause,
        0xffff => .delete,
        0xff50 => .home,
        0xff57 => .end,
        0xff55 => .page_up,
        0xff56 => .page_down,
        0xff63 => .insert,
        0xff51 => .left,
        0xff53 => .right,
        0xff52 => .up,
        0xff54 => .down,
        0xff08 => .backspace,
        0x20 => .space,
        0x2d => .minus,
        0x3d => .equal,
        0x5b => .left_bracket,
        0x5d => .right_bracket,
        0x5c => .backslash,
        0x3b => .semicolon,
        0x27 => .apostrophe,
        0x2c => .comma,
        0x2e => .period,
        0x2f => .slash,
        0x60 => .grave,
        else => .unknown,
    };
}

test "X11 maps alphanumeric keysyms" {
    try std.testing.expectEqual(api.Key.a, mapKeysym('a'));
    try std.testing.expectEqual(api.Key.a, mapKeysym('A'));
    try std.testing.expectEqual(api.Key.zero, mapKeysym('0'));
    try std.testing.expectEqual(api.Key.nine, mapKeysym('9'));
}

const vtable: api.VTable = .{
    .deinit = deinit,
    .native_display = nativeDisplay,
    .required_vulkan_extensions = requiredVulkanExtensions,
    .create_window = createWindow,
    .pump_events = pumpEvents,
    .wake = wake,
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
