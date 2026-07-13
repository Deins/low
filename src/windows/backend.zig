const std = @import("std");
const types = @import("../internal/types.zig");
const runtime = @import("../internal/runtime.zig");
const input = @import("../internal/input.zig");
const win32 = @import("win32").everything;
const offscreen_backend = @import("../offscreen_backend.zig").Backend;

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
pub const Window = runtime.Window;

const class_name = win32.L("low.window");
var class_registered = false;

const Data = struct {
    allocator: std.mem.Allocator,
    windows: std.ArrayListUnmanaged(*Window) = .empty,
};

const WindowedState = struct {
    style: win32.WINDOW_STYLE,
    rect: win32.RECT,
};

const WindowData = struct {
    handle: win32.HWND,
    /// The style and bounds to reinstate after borderless fullscreen.
    windowed: ?WindowedState = null,
};

pub fn initState(allocator: std.mem.Allocator, options: InitOptions) Error!*runtime.State {
    if (options.backend == .offscreen) return offscreen_backend.init(allocator, options);

    if (!class_registered) {
        // This is process-wide and deliberately best-effort: a host may have
        // already selected its own DPI context before constructing low.
        _ = win32.SetProcessDpiAwarenessContext(win32.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
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

fn windowData(window: *Window) *WindowData {
    return @ptrCast(@alignCast(window.backend_data));
}

fn windowHandle(window: *Window) win32.HWND {
    return windowData(window).handle;
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

    const native = data.allocator.create(WindowData) catch return error.OutOfMemory;
    errdefer data.allocator.destroy(native);

    const title = std.unicode.utf8ToUtf16LeAllocZ(data.allocator, options.title) catch return error.OutOfMemory;
    defer data.allocator.free(title);
    const titlebar_mode: types.DecorationMode = switch (options.titlebar) {
        .auto => if (options.decorated) .server_side else .client_side,
        else => options.titlebar,
    };
    // Win32 sends WM_NCCREATE synchronously from CreateWindowExW, so the
    // shared object must already be initialized when the procedure stores
    // its HWND association.
    const style = windowStyle(options.decorated, options.resizable);
    const dpi = win32.GetDpiForSystem();
    const scale = dpiScale(dpi);
    const client_size = types.scaledSize(options.size, scale);
    const outer_size = adjustedOuterSize(client_size, style, .{}, dpi);
    native.* = .{ .handle = undefined };
    window.* = .{
        .ctx = state,
        .backend_data = @ptrCast(native),
        .size = options.size,
        .framebuffer_size = client_size,
        .content_scale = scale,
        .visible = options.visible,
        .resizable = options.resizable,
        .min_size = options.min_size,
        .max_size = options.max_size,
        .decorated = options.decorated,
        .decoration_mode = titlebar_mode,
    };
    const hwnd = win32.CreateWindowExW(
        .{},
        class_name,
        title,
        style,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        outer_size.width,
        outer_size.height,
        null,
        null,
        win32.GetModuleHandleW(null),
        window,
    ) orelse return error.WindowCreationFailed;
    native.handle = hwnd;
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
    data.allocator.destroy(windowData(window));
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
    _ = win32.ShowWindow(windowHandle(window), win32.SW_HIDE);
}

fn maximize(window: *Window) void {
    restoreWindowedState(window);
    _ = win32.ShowWindow(windowHandle(window), @bitCast(@as(u32, 3)));
}

fn setFullscreen(window: *Window) void {
    const native = windowData(window);
    if (native.windowed != null) return;

    var rect: win32.RECT = undefined;
    _ = win32.GetWindowRect(native.handle, &rect);
    const style: win32.WINDOW_STYLE = @bitCast(@as(u32, @truncate(@as(usize, @bitCast(win32.GetWindowLongPtrW(native.handle, ._STYLE))))));
    native.windowed = .{ .style = style, .rect = rect };

    _ = win32.SetWindowLongPtrW(native.handle, ._STYLE, @intCast(@as(u32, @bitCast(win32.WS_POPUP))));
    var monitor_info: win32.MONITORINFO = .{
        .cbSize = @sizeOf(win32.MONITORINFO),
        .rcMonitor = undefined,
        .rcWork = undefined,
        .dwFlags = 0,
    };
    const monitor = win32.MonitorFromWindow(native.handle, win32.MONITOR_DEFAULTTONEAREST);
    const bounds = if (monitor != null and win32.GetMonitorInfoW(monitor, &monitor_info) != 0)
        monitor_info.rcMonitor
    else
        win32.RECT{
            .left = win32.GetSystemMetrics(win32.SM_XVIRTUALSCREEN),
            .top = win32.GetSystemMetrics(win32.SM_YVIRTUALSCREEN),
            .right = win32.GetSystemMetrics(win32.SM_XVIRTUALSCREEN) + win32.GetSystemMetrics(win32.SM_CXVIRTUALSCREEN),
            .bottom = win32.GetSystemMetrics(win32.SM_YVIRTUALSCREEN) + win32.GetSystemMetrics(win32.SM_CYVIRTUALSCREEN),
        };
    _ = win32.SetWindowPos(
        native.handle,
        null,
        bounds.left,
        bounds.top,
        bounds.right - bounds.left,
        bounds.bottom - bounds.top,
        .{ .DRAWFRAME = 1, .NOOWNERZORDER = 1 },
    );
}

fn restore(window: *Window) void {
    restoreWindowedState(window);
    _ = win32.ShowWindow(windowHandle(window), @bitCast(@as(u32, 9)));
}

fn iconify(window: *Window) void {
    _ = win32.ShowWindow(windowHandle(window), @bitCast(@as(u32, 6)));
}

fn setMinSize(window: *Window, _: ?runtime.Size) void {
    refreshWindowFrame(window);
}
fn setMaxSize(window: *Window, _: ?runtime.Size) void {
    refreshWindowFrame(window);
}
fn setResizable(window: *Window, resizable: bool) void {
    const native = windowData(window);
    var style: win32.WINDOW_STYLE = if (native.windowed) |saved|
        saved.style
    else
        @bitCast(@as(u32, @truncate(@as(usize, @bitCast(win32.GetWindowLongPtrW(native.handle, ._STYLE))))));
    if (!window.decorated) return;
    style.THICKFRAME = @intFromBool(resizable);
    // MAXIMIZEBOX shares bit 16 with TABSTOP in the generated bindings.
    style.TABSTOP = @intFromBool(resizable);
    if (native.windowed) |*saved| {
        saved.style = style;
    } else {
        _ = win32.SetWindowLongPtrW(native.handle, ._STYLE, @intCast(@as(u32, @bitCast(style))));
        refreshWindowFrame(window);
    }
}

fn setCursorVisible(window: *Window, _: bool) void {
    applyCursor(window);
}

fn setCursor(window: *Window, _: runtime.CursorShape) void {
    applyCursor(window);
}

fn windowStyle(decorated: bool, resizable: bool) win32.WINDOW_STYLE {
    if (!decorated) return win32.WS_POPUP;
    var style = win32.WS_OVERLAPPEDWINDOW;
    if (!resizable) {
        style.THICKFRAME = 0;
        // MAXIMIZEBOX shares bit 16 with TABSTOP in the generated bindings.
        style.TABSTOP = 0;
    }
    return style;
}

fn dpiScale(dpi: u32) runtime.ContentScale {
    const value: f32 = @as(f32, @floatFromInt(if (dpi == 0) 96 else dpi)) / 96.0;
    return .{ .x = value, .y = value };
}

fn adjustedOuterSize(client: runtime.Size, style: win32.WINDOW_STYLE, ex_style: win32.WINDOW_EX_STYLE, dpi: u32) runtime.Size {
    var rect: win32.RECT = .{
        .left = 0,
        .top = 0,
        .right = @max(1, client.width),
        .bottom = @max(1, client.height),
    };
    _ = win32.AdjustWindowRectExForDpi(&rect, style, win32.FALSE, ex_style, dpi);
    return .{ .width = rect.right - rect.left, .height = rect.bottom - rect.top };
}

fn currentOuterSizeForContent(window: *Window, content: runtime.Size) runtime.Size {
    const hwnd = windowHandle(window);
    const style: win32.WINDOW_STYLE = @bitCast(@as(u32, @truncate(@as(usize, @bitCast(win32.GetWindowLongPtrW(hwnd, ._STYLE))))));
    const ex_style: win32.WINDOW_EX_STYLE = @bitCast(@as(u32, @truncate(@as(usize, @bitCast(win32.GetWindowLongPtrW(hwnd, ._EXSTYLE))))));
    return adjustedOuterSize(types.scaledSize(content, window.content_scale), style, ex_style, win32.GetDpiForWindow(hwnd));
}

fn refreshWindowFrame(window: *Window) void {
    const hwnd = windowHandle(window);
    _ = win32.SetWindowPos(hwnd, null, 0, 0, 0, 0, .{
        .NOSIZE = 1,
        .NOMOVE = 1,
        .NOZORDER = 1,
        .NOACTIVATE = 1,
        .DRAWFRAME = 1,
    });
}

fn restoreWindowedState(window: *Window) void {
    const native = windowData(window);
    const saved = native.windowed orelse return;
    _ = win32.SetWindowLongPtrW(native.handle, ._STYLE, @intCast(@as(u32, @bitCast(saved.style))));
    _ = win32.SetWindowPos(
        native.handle,
        null,
        saved.rect.left,
        saved.rect.top,
        saved.rect.right - saved.rect.left,
        saved.rect.bottom - saved.rect.top,
        .{ .DRAWFRAME = 1, .NOOWNERZORDER = 1 },
    );
    native.windowed = null;
}

fn cursorResource(shape: runtime.CursorShape) [*:0]align(1) const u16 {
    return switch (shape) {
        .arrow => win32.IDC_ARROW,
        .crosshair => win32.IDC_CROSS,
        .hand => win32.IDC_HAND,
        .ibeam => win32.IDC_IBEAM,
        .not_allowed => win32.IDC_NO,
        .resize_all => win32.IDC_SIZEALL,
        .resize_ns => win32.IDC_SIZENS,
        .resize_ew => win32.IDC_SIZEWE,
        .resize_nesw => win32.IDC_SIZENESW,
        .resize_nwse => win32.IDC_SIZENWSE,
        .hidden => win32.IDC_ARROW,
    };
}

fn applyCursor(window: *Window) void {
    if (!window.cursor_visible or window.cursor_shape == .hidden) {
        _ = win32.SetCursor(null);
        return;
    }
    _ = win32.SetCursor(win32.LoadCursorW(null, cursorResource(window.cursor_shape)));
}

fn applyScale(_: *Window, _: f32) void {}
fn requestFrame(_: *Window) bool {
    return true;
}
fn cancelFrameRequest(_: *Window) void {}

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
    .request_frame = requestFrame,
    .cancel_frame_request = cancelFrameRequest,
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
        windowData(window).handle = hwnd;
        return win32.DefWindowProcW(hwnd, message, wparam, lparam);
    }
    const window = windowFromHwnd(hwnd) orelse return win32.DefWindowProcW(hwnd, message, wparam, lparam);
    switch (message) {
        win32.WM_GETMINMAXINFO => {
            const info: *win32.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (window.min_size) |size| {
                const outer = currentOuterSizeForContent(window, size);
                info.ptMinTrackSize.x = outer.width;
                info.ptMinTrackSize.y = outer.height;
            }
            if (window.max_size) |size| {
                const outer = currentOuterSizeForContent(window, size);
                info.ptMaxTrackSize.x = outer.width;
                info.ptMaxTrackSize.y = outer.height;
            }
            return 0;
        },
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
        win32.WM_SETCURSOR => {
            if (win32.loword(lparam) == win32.HTCLIENT) {
                applyCursor(window);
                return 1;
            }
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
            const minimized = wparam == @as(win32.WPARAM, win32.SIZE_MINIMIZED);
            window.minimized = minimized;
            updateRenderSuspension(window, minimized);
            var rect: win32.RECT = undefined;
            _ = win32.GetClientRect(hwnd, &rect);
            const size = window.pixelToContentSize(.{ .width = rect.right, .height = rect.bottom });
            window.updateSize(size);
        },
        win32.WM_DPICHANGED => {
            window.updateScale(dpiScale(win32.loword(wparam)).x);
            const suggested: *const win32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = win32.SetWindowPos(
                hwnd,
                null,
                suggested.left,
                suggested.top,
                suggested.right - suggested.left,
                suggested.bottom - suggested.top,
                .{ .NOZORDER = 1, .NOACTIVATE = 1 },
            );
            var rect: win32.RECT = undefined;
            _ = win32.GetClientRect(hwnd, &rect);
            window.updateSize(window.pixelToContentSize(.{ .width = rect.right, .height = rect.bottom }));
            return 0;
        },
        win32.WM_SHOWWINDOW => {
            updateRenderSuspension(window, wparam == 0);
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
            const key = virtualKeyToKey(@enumFromInt(wparam), lparam);
            const released = message == win32.WM_KEYUP or message == win32.WM_SYSKEYUP;
            const repeated = !released and (@as(usize, @bitCast(lparam)) & 0x4000_0000) != 0;
            const action: Action = if (released) .release else if (repeated) .repeat else .press;
            const repeat_count: usize = if (action == .repeat) @max(1, @as(usize, @bitCast(lparam)) & 0xffff) else 1;
            for (0..repeat_count) |_| window.updateKey(key, @intCast(wparam), action, modifiers());
            if (message == win32.WM_KEYDOWN or message == win32.WM_KEYUP) return 0;
        },
        else => {},
    }
    return win32.DefWindowProcW(hwnd, message, wparam, lparam);
}

fn updateRenderSuspension(window: *Window, fallback_suspended: bool) void {
    var cloaked: u32 = 0;
    const result = win32.DwmGetWindowAttribute(
        windowHandle(window),
        win32.DWMWA_CLOAKED,
        @ptrCast(&cloaked),
        @sizeOf(@TypeOf(cloaked)),
    );
    // DWM also reports windows cloaked by the shell. If it is unavailable or
    // declines the query, retain the state inferred from the window message.
    window.updateRenderSuspended(fallback_suspended or result == 0 and cloaked != 0);
}

fn modifiers() Modifiers {
    return .{
        .shift = win32.GetKeyState(@intFromEnum(win32.VK_SHIFT)) < 0,
        .control = win32.GetKeyState(@intFromEnum(win32.VK_CONTROL)) < 0,
        .alt = win32.GetKeyState(@intFromEnum(win32.VK_MENU)) < 0,
        .super = win32.GetKeyState(@intFromEnum(win32.VK_LWIN)) < 0 or win32.GetKeyState(@intFromEnum(win32.VK_RWIN)) < 0,
        .caps_lock = win32.GetKeyState(@intFromEnum(win32.VK_CAPITAL)) & 1 != 0,
        .num_lock = win32.GetKeyState(@intFromEnum(win32.VK_NUMLOCK)) & 1 != 0,
    };
}

fn virtualKeyToKey(vkey: win32.VIRTUAL_KEY, lparam: win32.LPARAM) Key {
    const bits: usize = @bitCast(lparam);
    const extended = bits & 0x0100_0000 != 0;
    const scan_code = (bits >> 16) & 0xff;
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
        .RETURN => if (extended) .kp_enter else .enter,
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
        .SHIFT => if (scan_code == 0x36) .right_shift else .left_shift,
        .LSHIFT => .left_shift,
        .RSHIFT => .right_shift,
        .CONTROL => if (extended) .right_control else .left_control,
        .LCONTROL => .left_control,
        .RCONTROL => .right_control,
        .MENU => if (extended) .right_alt else .left_alt,
        .LMENU => .left_alt,
        .RMENU => .right_alt,
        .LWIN => .left_command,
        .RWIN => .right_command,
        .APPS => .menu,
        .NUMLOCK => .num_lock,
        .CAPITAL => .caps_lock,
        .SNAPSHOT => .print,
        .SCROLL => .scroll_lock,
        .PAUSE => .pause,
        .NUMPAD0 => .kp_0,
        .NUMPAD1 => .kp_1,
        .NUMPAD2 => .kp_2,
        .NUMPAD3 => .kp_3,
        .NUMPAD4 => .kp_4,
        .NUMPAD5 => .kp_5,
        .NUMPAD6 => .kp_6,
        .NUMPAD7 => .kp_7,
        .NUMPAD8 => .kp_8,
        .NUMPAD9 => .kp_9,
        .DIVIDE => .kp_divide,
        .MULTIPLY => .kp_multiply,
        .SUBTRACT => .kp_subtract,
        .ADD => .kp_add,
        .DECIMAL => .kp_decimal,
        .OEM_NEC_EQUAL => .kp_equal,
        .F13 => .f13,
        .F14 => .f14,
        .F15 => .f15,
        .F16 => .f16,
        .F17 => .f17,
        .F18 => .f18,
        .F19 => .f19,
        .F20 => .f20,
        .F21 => .f21,
        .F22 => .f22,
        .F23 => .f23,
        .F24 => .f24,
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
        .OEM_COMMA => .comma,
        .OEM_PERIOD => .period,
        .OEM_2 => .slash,
        .OEM_3 => .grave,
        .OEM_4 => .left_bracket,
        .OEM_5 => .backslash,
        .OEM_6 => .right_bracket,
        .OEM_7 => .apostrophe,
        else => .unknown,
    };
}
