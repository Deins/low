const std = @import("std");
const types = @import("../internal/types.zig");
const runtime = @import("../internal/runtime.zig");
const input = @import("../internal/input.zig");
const win32 = @import("win32").everything;
const offscreen_backend = @import("../offscreen_backend.zig").Backend(runtime);

pub const BackendKind = types.BackendKind;
pub const Error = runtime.Error;
pub const Point = runtime.Point;
pub const Size = runtime.Size;
pub const Modifiers = runtime.Modifiers;
pub const Key = runtime.Key;
pub const MouseButton = runtime.MouseButton;
pub const Action = runtime.Action;
pub const InitOptions = runtime.InitOptions;
pub const WindowOptions = runtime.WindowOptions;
pub const Context = runtime.Context(@This());
pub const Window = runtime.Window;

const class_name = win32.L("low.window");
var class_registered = false;

const Data = struct {
    allocator: std.mem.Allocator,
    windows: std.ArrayListUnmanaged(*Window) = .empty,
};

pub fn initState(allocator: std.mem.Allocator, options: InitOptions) Error!*runtime.State {
    if (options.backend == .offscreen) return offscreen_backend.init(allocator, options);

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

    const data = allocator.create(Data) catch return error.OutOfMemory;
    errdefer allocator.destroy(data);
    data.* = .{ .allocator = allocator };

    const state = allocator.create(runtime.State) catch return error.OutOfMemory;
    state.* = .{
        .allocator = allocator,
        .backend_kind = .windows,
        .backend_data = data,
        .vtable = &vtable,
    };
    return state;
}

fn stateData(state: *runtime.State) *Data {
    return @ptrCast(@alignCast(state.backend_data));
}

fn windowHandle(window: *Window) win32.HWND {
    return @ptrCast(window.backend_data);
}

fn deinit(state: *runtime.State) void {
    const data = stateData(state);
    while (data.windows.items.len != 0) data.windows.items[data.windows.items.len - 1].deinit();
    data.windows.deinit(data.allocator);
    const allocator = data.allocator;
    state.clipboard.deinit(allocator);
    allocator.destroy(data);
    allocator.destroy(state);
}

fn nativeDisplay(_: *runtime.State) *anyopaque {
    return @ptrCast(win32.GetModuleHandleW(null));
}

fn requiredVulkanExtensions(_: *runtime.State) []const [*:0]const u8 {
    return &.{ "VK_KHR_surface", "VK_KHR_win32_surface" };
}

fn createWindow(state: *runtime.State, options: WindowOptions) Error!*Window {
    const data = stateData(state);
    const window = data.allocator.create(Window) catch return error.OutOfMemory;
    errdefer data.allocator.destroy(window);

    const title = std.unicode.utf8ToUtf16LeAllocZ(data.allocator, options.title) catch return error.OutOfMemory;
    defer data.allocator.free(title);
    const titlebar_mode: types.DecorationMode = switch (options.titlebar) {
        .auto => if (options.decorated) .server_side else .client_side,
        else => options.titlebar,
    };
    // Win32 sends WM_NCCREATE synchronously from CreateWindowExW, so the
    // shared object must already be initialized when the procedure stores
    // its HWND association.
    window.* = .{
        .ctx = state,
        .backend_data = @ptrFromInt(1),
        .size = options.size,
        .framebuffer_size = options.size,
        .visible = options.visible,
        .resizable = options.resizable,
        .min_size = options.min_size,
        .max_size = options.max_size,
        .decorated = options.decorated,
        .decoration_mode = titlebar_mode,
    };
    const style: win32.WINDOW_STYLE = if (options.decorated) win32.WS_OVERLAPPEDWINDOW else .{ .POPUP = 1 };
    const hwnd = win32.CreateWindowExW(
        .{},
        class_name,
        title,
        style,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        @max(1, options.size.width),
        @max(1, options.size.height),
        null,
        null,
        win32.GetModuleHandleW(null),
        window,
    ) orelse return error.WindowCreationFailed;
    window.backend_data = @ptrCast(hwnd);
    data.windows.append(data.allocator, window) catch {
        _ = win32.DestroyWindow(hwnd);
        return error.OutOfMemory;
    };

    if (options.state != .normal) window.setState(options.state);
    if (options.visible) window.show();
    return window;
}

fn destroyWindow(window: *Window) void {
    const data = stateData(window.ctx);
    if (std.mem.indexOfScalar(*Window, data.windows.items, window)) |index| _ = data.windows.swapRemove(index);
    _ = win32.DestroyWindow(windowHandle(window));
    data.allocator.destroy(window);
}

fn nativeSurface(window: *Window) usize {
    return @intFromPtr(windowHandle(window));
}

fn pumpEvents(_: *runtime.State, timeout_ms: i32) Error!bool {
    const timeout: u32 = if (timeout_ms < 0) std.math.maxInt(u32) else @intCast(timeout_ms);
    return dispatchMessages(timeout_ms != 0, timeout);
}

fn wake(_: *runtime.State) void {
    _ = win32.PostMessageW(null, win32.WM_NULL, 0, 0);
}

fn step(_: *runtime.State) Error!void {
    return error.NotOffscreen;
}

fn nextFrame(_: *runtime.State) Error!void {
    return error.NotOffscreen;
}

fn injectEvent(_: *Window, _: runtime.Event) Error!void {
    return error.NotOffscreen;
}

fn setTitle(window: *Window, title: [:0]const u8) void {
    const allocator = window.ctx.allocator;
    const wide = std.unicode.utf8ToUtf16LeAllocZ(allocator, title) catch return;
    defer allocator.free(wide);
    _ = win32.SetWindowTextW(windowHandle(window), wide);
}

fn show(window: *Window) void {
    _ = win32.ShowWindow(windowHandle(window), .{ .SHOWNORMAL = 1 });
}

fn hide(window: *Window) void {
    _ = win32.ShowWindow(windowHandle(window), .{ .HIDE = 1 });
}

fn maximize(window: *Window) void {
    _ = win32.ShowWindow(windowHandle(window), @bitCast(@as(u32, 3)));
}

fn setFullscreen(_: *Window) void {}

fn restore(window: *Window) void {
    _ = win32.ShowWindow(windowHandle(window), @bitCast(@as(u32, 9)));
}

fn iconify(window: *Window) void {
    _ = win32.ShowWindow(windowHandle(window), @bitCast(@as(u32, 6)));
}

fn setMinSize(_: *Window, _: ?runtime.Size) void {}
fn setMaxSize(_: *Window, _: ?runtime.Size) void {}
fn setResizable(_: *Window, _: bool) void {}

fn setCursorVisible(_: *Window, visible: bool) void {
    _ = win32.ShowCursor(if (visible) win32.TRUE else win32.FALSE);
}

fn setCursor(_: *Window, shape: runtime.CursorShape) void {
    _ = win32.ShowCursor(if (shape != .hidden) win32.TRUE else win32.FALSE);
}

fn applyScale(_: *Window, _: f32) void {}

const vtable: runtime.VTable = .{
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
        window.backend_data = @ptrCast(hwnd);
        return win32.DefWindowProcW(hwnd, message, wparam, lparam);
    }
    const window = windowFromHwnd(hwnd) orelse return win32.DefWindowProcW(hwnd, message, wparam, lparam);
    switch (message) {
        win32.WM_CLOSE => {
            window.updateClose();
            return 0;
        },
        win32.WM_SETFOCUS => {
            window.updateFocus(true);
        },
        win32.WM_KILLFOCUS => {
            window.updateFocus(false);
        },
        win32.WM_MOUSEMOVE => {
            const p = Point{ .x = @floatFromInt(win32.xFromLparam(lparam)), .y = @floatFromInt(win32.yFromLparam(lparam)) };
            window.updateCursorMotion(p.x, p.y);
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
            window.updateMouseButton(button, action, modifiers());
            return 0;
        },
        win32.WM_MOUSEWHEEL, win32.WM_MOUSEHWHEEL => {
            const delta: i16 = @bitCast(win32.hiword(wparam));
            window.updateScroll(if (message == win32.WM_MOUSEHWHEEL) @as(f64, @floatFromInt(delta)) / 120.0 else 0, if (message == win32.WM_MOUSEWHEEL) @as(f64, @floatFromInt(delta)) / 120.0 else 0);
            return 0;
        },
        win32.WM_SIZE => {
            var rect: win32.RECT = undefined;
            _ = win32.GetClientRect(hwnd, &rect);
            const size = Size{ .width = rect.right, .height = rect.bottom };
            window.updateSize(size);
        },
        win32.WM_CHAR => {
            var utf8: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(@intCast(wparam), &utf8) catch 0;
            if (len != 0 and input.isPrintableText(utf8[0..len])) {
                window.updateText(utf8[0..len]);
            }
            return 0;
        },
        win32.WM_KEYDOWN, win32.WM_SYSKEYDOWN, win32.WM_KEYUP, win32.WM_SYSKEYUP => {
            const key = virtualKeyToKey(@enumFromInt(wparam));
            const released = message == win32.WM_KEYUP or message == win32.WM_SYSKEYUP;
            const repeated = !released and (@as(usize, @bitCast(lparam)) & 0x4000_0000) != 0;
            const action: Action = if (released) .release else if (repeated) .repeat else .press;
            window.updateKey(key, @intCast(wparam), action, modifiers());
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
