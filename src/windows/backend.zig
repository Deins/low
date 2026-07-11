const std = @import("std");
const common = @import("../common.zig");
const input = @import("../input.zig");
const win32 = @import("win32").everything;

pub const BackendRequest = common.BackendRequest;
pub const BackendKind = common.BackendKind;
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
pub const Error = error{ UnsupportedPlatform, OutOfMemory, WindowClassRegistrationFailed, WindowCreationFailed };
pub const FrameMode = common.FrameMode;
pub const OffscreenOptions = common.OffscreenOptions;
pub const Event = common.Event;
pub const InitOptions = common.InitOptions;
pub const WindowOptions = common.WindowOptions;

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

const class_name = win32.L("low.window");
var class_registered = false;

pub const Context = struct {
    allocator: std.mem.Allocator,
    windows: std.ArrayListUnmanaged(*Window) = .empty,
    clipboard: common.Clipboard = .{},

    pub fn init(allocator: std.mem.Allocator, options: InitOptions) Error!Context {
        if (options.backend == .offscreen) return error.UnsupportedPlatform;
        if (!class_registered) {
            const wc: win32.WNDCLASSEXW = .{
                .cbSize = @sizeOf(win32.WNDCLASSEXW),
                .style = .{ .HREDRAW = 1, .VREDRAW = 1, .DBLCLKS = 1 },
                .lpfnWndProc = wndProc,
                .cbClsExtra = 0,
                .cbWndExtra = @sizeOf(usize),
                .hInstance = win32.GetModuleHandleW(null),
                .hIcon = null,
                .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
                .hbrBackground = null,
                .lpszMenuName = null,
                .lpszClassName = class_name,
                .hIconSm = null,
            };
            if (win32.RegisterClassExW(&wc) == 0) return error.WindowClassRegistrationFailed;
            class_registered = true;
        }
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Context) void {
        while (self.windows.items.len != 0) self.windows.items[self.windows.items.len - 1].deinit();
        self.windows.deinit(self.allocator);
        self.clipboard.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn backendKind(_: *Context) BackendKind {
        return .windows;
    }
    pub fn nativeDisplay(_: *Context) *anyopaque {
        return @ptrCast(win32.GetModuleHandleW(null));
    }
    pub fn requiredVulkanInstanceExtensions(_: *Context) []const [*:0]const u8 {
        return &.{ "VK_KHR_surface", "VK_KHR_win32_surface" };
    }

    pub fn createWindow(self: *Context, options: WindowOptions) Error!*Window {
        const window = self.allocator.create(Window) catch return error.OutOfMemory;
        errdefer self.allocator.destroy(window);
        window.* = .{ .ctx = self, .size = options.size, .framebuffer_size = options.size, .resizable = options.resizable, .decorated = options.decorated };
        const title = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, options.title) catch return error.OutOfMemory;
        defer self.allocator.free(title);
        const style: win32.WINDOW_STYLE = if (options.decorated) win32.WS_OVERLAPPEDWINDOW else .{ .POPUP = 1 };
        const hwnd = win32.CreateWindowExW(.{}, class_name, title, style, win32.CW_USEDEFAULT, win32.CW_USEDEFAULT, @max(1, options.size.width), @max(1, options.size.height), null, null, win32.GetModuleHandleW(null), window) orelse return error.WindowCreationFailed;
        window.hwnd = hwnd;
        self.windows.append(self.allocator, window) catch return error.OutOfMemory;
        if (!options.resizable) window.setResizable(false);
        if (options.min_size) |size| window.setMinSize(size);
        if (options.max_size) |size| window.setMaxSize(size);
        window.setState(options.state);
        if (options.visible) window.show();
        return window;
    }

    pub fn pollEvents(_: *Context) void {
        _ = dispatchMessages(false, 0);
    }
    pub fn waitEvents(_: *Context) Error!void {
        dispatchMessages(true, std.math.maxInt(u32));
    }
    pub fn waitEventsTimeout(_: *Context, timeout_ns: u64) Error!bool {
        const ms: u32 = @intCast(@min(std.math.maxInt(u32), (timeout_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms));
        return dispatchMessages(true, ms);
    }
    pub fn wake(_: *Context) void {
        _ = win32.PostMessageW(null, win32.WM_NULL, 0, 0);
    }
    pub fn step(_: *Context) Error!void {
        return error.UnsupportedPlatform;
    }
    pub fn nextFrame(_: *Context) Error!void {
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

    fn removeWindow(self: *Context, window: *Window) void {
        if (std.mem.indexOfScalar(*Window, self.windows.items, window)) |index| _ = self.windows.swapRemove(index);
    }
};

pub const Window = struct {
    ctx: *Context,
    hwnd: ?win32.HWND = null,
    callbacks: WindowCallbacks = .{},
    user_data: ?*anyopaque = null,
    should_close: bool = false,
    visible: bool = false,
    focused: bool = false,
    maximized: bool = false,
    fullscreen: bool = false,
    minimized: bool = false,
    hovered: bool = false,
    resizable: bool,
    decorated: bool,
    cursor_visible: bool = true,
    cursor_shape: CursorShape = .arrow,
    size: Size,
    framebuffer_size: Size,
    content_scale: ContentScale = .{},
    cursor_pos: Point = .{ .x = 0, .y = 0 },
    text_input_rect: ?TextInputRect = null,
    pressed_keys: std.EnumSet(Key) = .empty,
    pressed_buttons: std.EnumSet(MouseButton) = .empty,
    min_size: ?Size = null,
    max_size: ?Size = null,

    pub fn deinit(self: *Window) void {
        self.ctx.removeWindow(self);
        if (self.hwnd) |hwnd| {
            _ = win32.DestroyWindow(hwnd);
        }
        self.ctx.allocator.destroy(self);
    }
    pub fn nativeSurface(self: *Window) usize {
        return @intFromPtr(self.hwnd.?);
    }
    pub fn nativeDisplay(_: *Window) *anyopaque {
        return @ptrCast(win32.GetModuleHandleW(null));
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
    pub fn injectEvent(_: *Window, _: Event) Error!void {
        return error.UnsupportedPlatform;
    }
    pub fn setTitle(self: *Window, title: [:0]const u8) void {
        const wide = std.unicode.utf8ToUtf16LeAllocZ(self.ctx.allocator, title) catch return;
        defer self.ctx.allocator.free(wide);
        _ = win32.SetWindowTextW(self.hwnd, wide);
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
        _ = win32.ShowWindow(self.hwnd, .{ .SHOWNORMAL = 1 });
        self.visible = true;
    }
    pub fn hide(self: *Window) void {
        _ = win32.ShowWindow(self.hwnd, .{ .HIDE = 1 });
        self.visible = false;
    }
    pub fn maximize(self: *Window) void {
        _ = win32.ShowWindow(self.hwnd, @bitCast(@as(u32, 3)));
        self.maximized = true;
        self.fullscreen = false;
    }
    pub fn setFullscreen(self: *Window) void {
        self.fullscreen = true;
        self.maximized = false;
    }
    pub fn restore(self: *Window) void {
        _ = win32.ShowWindow(self.hwnd, @bitCast(@as(u32, 9)));
        self.maximized = false;
        self.fullscreen = false;
        self.minimized = false;
    }
    pub fn iconify(self: *Window) void {
        _ = win32.ShowWindow(self.hwnd, @bitCast(@as(u32, 6)));
        self.minimized = true;
    }
    pub fn setMinSize(self: *Window, size: ?Size) void {
        self.min_size = size;
    }
    pub fn setMaxSize(self: *Window, size: ?Size) void {
        self.max_size = size;
    }
    pub fn setResizable(self: *Window, resizable: bool) void {
        self.resizable = resizable;
    }
    pub fn setCursorVisible(self: *Window, visible: bool) void {
        self.cursor_visible = visible;
        _ = win32.ShowCursor(if (visible) win32.TRUE else win32.FALSE);
    }
    pub fn setCursor(self: *Window, shape: CursorShape) void {
        self.cursor_shape = shape;
        self.setCursorVisible(shape != .hidden);
    }
    pub fn setTextInputRect(self: *Window, rect: ?TextInputRect) void {
        self.text_input_rect = rect;
    }
};

fn dispatchMessages(wait: bool, timeout_ms: u32) bool {
    if (wait) _ = win32.MsgWaitForMultipleObjectsEx(0, null, timeout_ms, win32.QS_ALLINPUT, win32.MWMO_INPUTAVAILABLE);
    var had_events = false;
    var message: win32.MSG = undefined;
    while (win32.PeekMessageW(&message, null, 0, 0, win32.PM_REMOVE) != 0) {
        had_events = true;
        _ = win32.TranslateMessage(&message);
        _ = win32.DispatchMessageW(&message);
    }
    return had_events;
}

fn windowFromHwnd(hwnd: win32.HWND) ?*Window {
    const value: usize = @bitCast(win32.GetWindowLongPtrW(hwnd, win32.WINDOW_LONG_PTR_INDEX._USERDATA));
    return if (value == 0) null else @ptrFromInt(value);
}

fn wndProc(hwnd: win32.HWND, message: u32, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.winapi) win32.LRESULT {
    if (message == win32.WM_NCCREATE) {
        const cs: *win32.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        const window: *Window = @ptrCast(@alignCast(cs.lpCreateParams));
        _ = win32.SetWindowLongPtrW(hwnd, win32.WINDOW_LONG_PTR_INDEX._USERDATA, @bitCast(@intFromPtr(window)));
        window.hwnd = hwnd;
        return win32.DefWindowProcW(hwnd, message, wparam, lparam);
    }
    const window = windowFromHwnd(hwnd) orelse return win32.DefWindowProcW(hwnd, message, wparam, lparam);
    switch (message) {
        win32.WM_CLOSE => {
            window.should_close = true;
            if (window.callbacks.close) |cb| cb(window);
            return 0;
        },
        win32.WM_SETFOCUS => {
            window.focused = true;
            if (window.callbacks.focus) |cb| cb(window, true);
        },
        win32.WM_KILLFOCUS => {
            window.focused = false;
            if (window.callbacks.focus) |cb| cb(window, false);
        },
        win32.WM_MOUSEMOVE => {
            const p = Point{ .x = @floatFromInt(win32.xFromLparam(lparam)), .y = @floatFromInt(win32.yFromLparam(lparam)) };
            window.cursor_pos = p;
            if (window.callbacks.cursor_motion) |cb| cb(window, p);
        },
        win32.WM_LBUTTONDOWN, win32.WM_LBUTTONUP, win32.WM_RBUTTONDOWN, win32.WM_RBUTTONUP, win32.WM_MBUTTONDOWN, win32.WM_MBUTTONUP, win32.WM_XBUTTONDOWN, win32.WM_XBUTTONUP => {
            const button: MouseButton = switch (message) {
                win32.WM_LBUTTONDOWN, win32.WM_LBUTTONUP => .left,
                win32.WM_RBUTTONDOWN, win32.WM_RBUTTONUP => .right,
                win32.WM_MBUTTONDOWN, win32.WM_MBUTTONUP => .middle,
                win32.WM_XBUTTONDOWN, win32.WM_XBUTTONUP => if (win32.hiword(wparam) == 1) .four else .five,
                else => unreachable,
            };
            const action: Action = switch (message) {
                win32.WM_LBUTTONDOWN, win32.WM_RBUTTONDOWN, win32.WM_MBUTTONDOWN, win32.WM_XBUTTONDOWN => .press,
                else => .release,
            };
            switch (action) {
                .press => _ = window.pressed_buttons.insert(button),
                .release => _ = window.pressed_buttons.remove(button),
                .repeat => {},
            }
            if (window.callbacks.mouse_button) |cb| cb(window, button, action, modifiers());
            return 0;
        },
        win32.WM_MOUSEWHEEL, win32.WM_MOUSEHWHEEL => {
            const delta: i16 = @bitCast(win32.hiword(wparam));
            if (window.callbacks.scroll) |cb| cb(window, if (message == win32.WM_MOUSEHWHEEL) @as(f64, @floatFromInt(delta)) / 120.0 else 0, if (message == win32.WM_MOUSEWHEEL) @as(f64, @floatFromInt(delta)) / 120.0 else 0);
            return 0;
        },
        win32.WM_SIZE => {
            var rect: win32.RECT = undefined;
            _ = win32.GetClientRect(hwnd, &rect);
            const size = Size{ .width = rect.right, .height = rect.bottom };
            window.size = size;
            window.framebuffer_size = size;
            if (window.callbacks.resize) |cb| cb(window, size);
            if (window.callbacks.framebuffer_resize) |cb| cb(window, size);
        },
        win32.WM_CHAR => {
            var utf8: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(@intCast(wparam), &utf8) catch 0;
            if (len != 0 and input.isPrintableText(utf8[0..len])) {
                if (window.callbacks.text) |cb| cb(window, utf8[0..len]);
            }
            return 0;
        },
        win32.WM_KEYDOWN, win32.WM_SYSKEYDOWN, win32.WM_KEYUP, win32.WM_SYSKEYUP => {
            const key = virtualKeyToKey(@enumFromInt(wparam));
            const released = message == win32.WM_KEYUP or message == win32.WM_SYSKEYUP;
            const repeated = !released and (@as(usize, @bitCast(lparam)) & 0x4000_0000) != 0;
            const action: Action = if (released) .release else if (repeated) .repeat else .press;
            switch (action) {
                .press => _ = window.pressed_keys.insert(key),
                .release => _ = window.pressed_keys.remove(key),
                .repeat => {},
            }
            if (window.callbacks.key) |cb| cb(window, key, @intCast(wparam), action, modifiers());
            if (message == win32.WM_KEYDOWN or message == win32.WM_KEYUP) return 0;
        },
        else => {},
    }
    return win32.DefWindowProcW(hwnd, message, wparam, lparam);
}

fn modifiers() Modifiers {
    return .{
        .shift = win32.GetKeyState(@intFromEnum(win32.VK_SHIFT)) < 0,
        .control = win32.GetKeyState(@intFromEnum(win32.VK_CONTROL)) < 0,
        .alt = win32.GetKeyState(@intFromEnum(win32.VK_MENU)) < 0,
        .super = win32.GetKeyState(@intFromEnum(win32.VK_LWIN)) < 0 or win32.GetKeyState(@intFromEnum(win32.VK_RWIN)) < 0,
    };
}

fn virtualKeyToKey(vkey: win32.VIRTUAL_KEY) Key {
    return switch (vkey) {
        .A => .a,
        .B => .b,
        .C => .c,
        .D => .d,
        .E => .e,
        .F => .f,
        .G => .g,
        .H => .h,
        .I => .i,
        .J => .j,
        .K => .k,
        .L => .l,
        .M => .m,
        .N => .n,
        .O => .o,
        .P => .p,
        .Q => .q,
        .R => .r,
        .S => .s,
        .T => .t,
        .U => .u,
        .V => .v,
        .W => .w,
        .X => .x,
        .Y => .y,
        .Z => .z,
        .@"0" => .zero,
        .@"1" => .one,
        .@"2" => .two,
        .@"3" => .three,
        .@"4" => .four,
        .@"5" => .five,
        .@"6" => .six,
        .@"7" => .seven,
        .@"8" => .eight,
        .@"9" => .nine,
        .RETURN => .enter,
        .ESCAPE => .escape,
        .TAB => .tab,
        .BACK => .backspace,
        .SPACE => .space,
        .LEFT => .left,
        .RIGHT => .right,
        .UP => .up,
        .DOWN => .down,
        .HOME => .home,
        .END => .end,
        .PRIOR => .page_up,
        .NEXT => .page_down,
        .INSERT => .insert,
        .DELETE => .delete,
        .SHIFT, .LSHIFT => .left_shift,
        .RSHIFT => .right_shift,
        .CONTROL, .LCONTROL => .left_control,
        .RCONTROL => .right_control,
        .LMENU => .left_alt,
        .RMENU => .right_alt,
        .LWIN => .left_command,
        .RWIN => .right_command,
        .F1 => .f1,
        .F2 => .f2,
        .F3 => .f3,
        .F4 => .f4,
        .F5 => .f5,
        .F6 => .f6,
        .F7 => .f7,
        .F8 => .f8,
        .F9 => .f9,
        .F10 => .f10,
        .F11 => .f11,
        .F12 => .f12,
        .OEM_MINUS => .minus,
        .OEM_PLUS => .equal,
        .OEM_1 => .semicolon,
        .OEM_2 => .slash,
        .OEM_3 => .grave,
        .OEM_4 => .left_bracket,
        .OEM_5 => .backslash,
        .OEM_6 => .right_bracket,
        .OEM_7 => .apostrophe,
        else => .unknown,
    };
}
