//! Header-free, runtime-loaded subset of Xlib used by the X11 backend.
//!
//! The declarations below mirror stable public Xlib ABI types.  This keeps a
//! Linux build independent of libX11 development headers while the actual
//! client library remains an optional runtime dependency.
const std = @import("std");

pub const Error = error{ LibraryNotFound, MissingSymbol };

pub const Display = opaque {};
pub const XID = c_ulong;
pub const Window = XID;
pub const Drawable = XID;
pub const Pixmap = XID;
pub const Cursor = XID;
pub const Atom = XID;
pub const KeySym = XID;

pub const XColor = extern struct {
    pixel: c_ulong,
    red: c_ushort,
    green: c_ushort,
    blue: c_ushort,
    flags: c_char,
    pad: c_char,
};

pub const XKeyEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    window: Window,
    root: Window,
    subwindow: Window,
    time: c_ulong,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    keycode: c_uint,
    same_screen: c_int,
};

pub const XButtonEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    window: Window,
    root: Window,
    subwindow: Window,
    time: c_ulong,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    button: c_uint,
    same_screen: c_int,
};

pub const XMotionEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    window: Window,
    root: Window,
    subwindow: Window,
    time: c_ulong,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    is_hint: c_char,
    same_screen: c_int,
};

pub const XCrossingEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    window: Window,
    root: Window,
    subwindow: Window,
    time: c_ulong,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    mode: c_int,
    detail: c_int,
    same_screen: c_int,
    focus: c_int,
    state: c_uint,
};

pub const XFocusChangeEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    window: Window,
    mode: c_int,
    detail: c_int,
};

pub const XConfigureEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    event: Window,
    window: Window,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    border_width: c_int,
    above: Window,
    override_redirect: c_int,
};

pub const XMapEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    event: Window,
    window: Window,
    override_redirect: c_int,
};

pub const XUnmapEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    event: Window,
    window: Window,
    from_configure: c_int,
};

pub const XVisibilityEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    window: Window,
    state: c_int,
};

pub const XClientMessageData = extern union {
    b: [20]u8,
    s: [10]c_short,
    l: [5]c_long,
};

pub const XClientMessageEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    window: Window,
    message_type: Atom,
    format: c_int,
    data: XClientMessageData,
};

/// XEvent is specified as a union with `long pad[24]`; retaining that member
/// is what preserves its ABI size on both 32- and 64-bit Linux targets.
pub const XEvent = extern union {
    type: c_int,
    xkey: XKeyEvent,
    xbutton: XButtonEvent,
    xmotion: XMotionEvent,
    xcrossing: XCrossingEvent,
    xfocus: XFocusChangeEvent,
    xconfigure: XConfigureEvent,
    xmap: XMapEvent,
    xunmap: XUnmapEvent,
    xvisibility: XVisibilityEvent,
    xclient: XClientMessageEvent,
    pad: [24]c_long,
};

pub const XSizeHints = extern struct {
    flags: c_long,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    min_width: c_int,
    min_height: c_int,
    max_width: c_int,
    max_height: c_int,
    width_inc: c_int,
    height_inc: c_int,
    min_aspect: extern struct { x: c_int, y: c_int },
    max_aspect: extern struct { x: c_int, y: c_int },
    base_width: c_int,
    base_height: c_int,
    win_gravity: c_int,
};

pub const Atoms = struct {
    wm_delete_window: Atom = 0,
    wm_protocols: Atom = 0,
    net_wm_state: Atom = 0,
    net_wm_state_fullscreen: Atom = 0,
    net_wm_state_maximized_horz: Atom = 0,
    net_wm_state_maximized_vert: Atom = 0,
    net_wm_name: Atom = 0,
    utf8_string: Atom = 0,
    net_wm_window_type: Atom = 0,
    net_wm_window_type_normal: Atom = 0,
    motif_wm_hints: Atom = 0,
};

pub const KeyPressMask: c_long = 1 << 0;
pub const KeyReleaseMask: c_long = 1 << 1;
pub const ButtonPressMask: c_long = 1 << 2;
pub const ButtonReleaseMask: c_long = 1 << 3;
pub const EnterWindowMask: c_long = 1 << 4;
pub const LeaveWindowMask: c_long = 1 << 5;
pub const PointerMotionMask: c_long = 1 << 6;
pub const VisibilityChangeMask: c_long = 1 << 16;
pub const StructureNotifyMask: c_long = 1 << 17;
pub const SubstructureNotifyMask: c_long = 1 << 19;
pub const SubstructureRedirectMask: c_long = 1 << 20;
pub const FocusChangeMask: c_long = 1 << 21;
pub const PropertyChangeMask: c_long = 1 << 22;

pub const ShiftMask: c_uint = 1 << 0;
pub const LockMask: c_uint = 1 << 1;
pub const ControlMask: c_uint = 1 << 2;
pub const Mod1Mask: c_uint = 1 << 3;
pub const Mod2Mask: c_uint = 1 << 4;
pub const Mod4Mask: c_uint = 1 << 6;

pub const KeyPress: c_int = 2;
pub const KeyRelease: c_int = 3;
pub const ButtonPress: c_int = 4;
pub const ButtonRelease: c_int = 5;
pub const MotionNotify: c_int = 6;
pub const EnterNotify: c_int = 7;
pub const LeaveNotify: c_int = 8;
pub const FocusIn: c_int = 9;
pub const FocusOut: c_int = 10;
pub const UnmapNotify: c_int = 18;
pub const MapNotify: c_int = 19;
pub const ConfigureNotify: c_int = 22;
pub const ClientMessage: c_int = 33;
pub const VisibilityNotify: c_int = 15;

pub const VisibilityUnobscured: c_int = 0;
pub const VisibilityPartiallyObscured: c_int = 1;
pub const VisibilityFullyObscured: c_int = 2;

pub const PropModeReplace: c_int = 0;
pub const XA_ATOM: Atom = 4;
pub const PMinSize: c_long = 1 << 4;
pub const PMaxSize: c_long = 1 << 5;

pub const XC_bottom_left_corner: c_uint = 12;
pub const XC_bottom_right_corner: c_uint = 14;
pub const XC_crosshair: c_uint = 34;
pub const XC_fleur: c_uint = 52;
pub const XC_hand2: c_uint = 60;
pub const XC_left_ptr: c_uint = 68;
pub const XC_pirate: c_uint = 88;
pub const XC_sb_h_double_arrow: c_uint = 108;
pub const XC_sb_v_double_arrow: c_uint = 116;
pub const XC_xterm: c_uint = 152;

const XOpenDisplayFn = *const fn (?[*:0]const u8) callconv(.c) ?*Display;
const XCloseDisplayFn = *const fn (*Display) callconv(.c) c_int;
const XDefaultScreenFn = *const fn (*Display) callconv(.c) c_int;
const XRootWindowFn = *const fn (*Display, c_int) callconv(.c) Window;
const XConnectionNumberFn = *const fn (*Display) callconv(.c) c_int;
const XInternAtomFn = *const fn (*Display, [*:0]const u8, c_int) callconv(.c) Atom;
const XCreateSimpleWindowFn = *const fn (*Display, Window, c_int, c_int, c_uint, c_uint, c_uint, c_ulong, c_ulong) callconv(.c) Window;
const XDestroyWindowFn = *const fn (*Display, Window) callconv(.c) c_int;
const XSelectInputFn = *const fn (*Display, Window, c_long) callconv(.c) c_int;
const XSetWMProtocolsFn = *const fn (*Display, Window, [*]Atom, c_int) callconv(.c) c_int;
const XMapWindowFn = *const fn (*Display, Window) callconv(.c) c_int;
const XUnmapWindowFn = *const fn (*Display, Window) callconv(.c) c_int;
const XFlushFn = *const fn (*Display) callconv(.c) c_int;
const XPendingFn = *const fn (*Display) callconv(.c) c_int;
const XNextEventFn = *const fn (*Display, *XEvent) callconv(.c) c_int;
const XLookupStringFn = *const fn (*XKeyEvent, [*]u8, c_int, ?*KeySym, ?*anyopaque) callconv(.c) c_int;
const XCreateBitmapFromDataFn = *const fn (*Display, Drawable, [*]const u8, c_uint, c_uint) callconv(.c) Pixmap;
const XFreePixmapFn = *const fn (*Display, Pixmap) callconv(.c) c_int;
const XCreatePixmapCursorFn = *const fn (*Display, Pixmap, Pixmap, *XColor, *XColor, c_uint, c_uint) callconv(.c) Cursor;
const XCreateFontCursorFn = *const fn (*Display, c_uint) callconv(.c) Cursor;
const XDefineCursorFn = *const fn (*Display, Window, Cursor) callconv(.c) c_int;
const XUndefineCursorFn = *const fn (*Display, Window) callconv(.c) c_int;
const XSetWMNormalHintsFn = *const fn (*Display, Window, *XSizeHints) callconv(.c) void;
const XChangePropertyFn = *const fn (*Display, Window, Atom, Atom, c_int, c_int, ?*const anyopaque, c_int) callconv(.c) c_int;
const XStoreNameFn = *const fn (*Display, Window, [*:0]const u8) callconv(.c) c_int;
const XSendEventFn = *const fn (*Display, Window, c_int, c_long, *XEvent) callconv(.c) c_int;
const XIconifyWindowFn = *const fn (*Display, Window, c_int) callconv(.c) c_int;
const XFreeCursorFn = *const fn (*Display, Cursor) callconv(.c) c_int;
const XkbSetDetectableAutoRepeatFn = *const fn (*Display, c_int, ?*c_int) callconv(.c) c_int;

const Api = struct {
    open_display: XOpenDisplayFn,
    close_display: XCloseDisplayFn,
    default_screen: XDefaultScreenFn,
    root_window: XRootWindowFn,
    connection_number: XConnectionNumberFn,
    intern_atom: XInternAtomFn,
    create_simple_window: XCreateSimpleWindowFn,
    destroy_window: XDestroyWindowFn,
    select_input: XSelectInputFn,
    set_wm_protocols: XSetWMProtocolsFn,
    map_window: XMapWindowFn,
    unmap_window: XUnmapWindowFn,
    flush: XFlushFn,
    pending: XPendingFn,
    next_event: XNextEventFn,
    lookup_string: XLookupStringFn,
    create_bitmap_from_data: XCreateBitmapFromDataFn,
    free_pixmap: XFreePixmapFn,
    create_pixmap_cursor: XCreatePixmapCursorFn,
    create_font_cursor: XCreateFontCursorFn,
    define_cursor: XDefineCursorFn,
    undefine_cursor: XUndefineCursorFn,
    set_wm_normal_hints: XSetWMNormalHintsFn,
    change_property: XChangePropertyFn,
    store_name: XStoreNameFn,
    send_event: XSendEventFn,
    iconify_window: XIconifyWindowFn,
    free_cursor: XFreeCursorFn,
    set_detectable_auto_repeat: XkbSetDetectableAutoRepeatFn,
};

var library: ?std.DynLib = null;
var api: ?Api = null;
var load_mutex: std.atomic.Mutex = .unlocked;

pub fn ensureLoaded() Error!void {
    while (!load_mutex.tryLock()) std.atomic.spinLoopHint();
    defer load_mutex.unlock();
    if (api != null) return;

    var loaded_library = blk: {
        inline for (&.{ "libX11.so.6", "libX11.so" }) |name| {
            if (std.DynLib.open(name)) |opened| break :blk opened else |_| {}
        }
        return error.LibraryNotFound;
    };
    errdefer loaded_library.close();

    api = .{
        .open_display = loaded_library.lookup(XOpenDisplayFn, "XOpenDisplay") orelse return error.MissingSymbol,
        .close_display = loaded_library.lookup(XCloseDisplayFn, "XCloseDisplay") orelse return error.MissingSymbol,
        .default_screen = loaded_library.lookup(XDefaultScreenFn, "XDefaultScreen") orelse return error.MissingSymbol,
        .root_window = loaded_library.lookup(XRootWindowFn, "XRootWindow") orelse return error.MissingSymbol,
        .connection_number = loaded_library.lookup(XConnectionNumberFn, "XConnectionNumber") orelse return error.MissingSymbol,
        .intern_atom = loaded_library.lookup(XInternAtomFn, "XInternAtom") orelse return error.MissingSymbol,
        .create_simple_window = loaded_library.lookup(XCreateSimpleWindowFn, "XCreateSimpleWindow") orelse return error.MissingSymbol,
        .destroy_window = loaded_library.lookup(XDestroyWindowFn, "XDestroyWindow") orelse return error.MissingSymbol,
        .select_input = loaded_library.lookup(XSelectInputFn, "XSelectInput") orelse return error.MissingSymbol,
        .set_wm_protocols = loaded_library.lookup(XSetWMProtocolsFn, "XSetWMProtocols") orelse return error.MissingSymbol,
        .map_window = loaded_library.lookup(XMapWindowFn, "XMapWindow") orelse return error.MissingSymbol,
        .unmap_window = loaded_library.lookup(XUnmapWindowFn, "XUnmapWindow") orelse return error.MissingSymbol,
        .flush = loaded_library.lookup(XFlushFn, "XFlush") orelse return error.MissingSymbol,
        .pending = loaded_library.lookup(XPendingFn, "XPending") orelse return error.MissingSymbol,
        .next_event = loaded_library.lookup(XNextEventFn, "XNextEvent") orelse return error.MissingSymbol,
        .lookup_string = loaded_library.lookup(XLookupStringFn, "XLookupString") orelse return error.MissingSymbol,
        .create_bitmap_from_data = loaded_library.lookup(XCreateBitmapFromDataFn, "XCreateBitmapFromData") orelse return error.MissingSymbol,
        .free_pixmap = loaded_library.lookup(XFreePixmapFn, "XFreePixmap") orelse return error.MissingSymbol,
        .create_pixmap_cursor = loaded_library.lookup(XCreatePixmapCursorFn, "XCreatePixmapCursor") orelse return error.MissingSymbol,
        .create_font_cursor = loaded_library.lookup(XCreateFontCursorFn, "XCreateFontCursor") orelse return error.MissingSymbol,
        .define_cursor = loaded_library.lookup(XDefineCursorFn, "XDefineCursor") orelse return error.MissingSymbol,
        .undefine_cursor = loaded_library.lookup(XUndefineCursorFn, "XUndefineCursor") orelse return error.MissingSymbol,
        .set_wm_normal_hints = loaded_library.lookup(XSetWMNormalHintsFn, "XSetWMNormalHints") orelse return error.MissingSymbol,
        .change_property = loaded_library.lookup(XChangePropertyFn, "XChangeProperty") orelse return error.MissingSymbol,
        .store_name = loaded_library.lookup(XStoreNameFn, "XStoreName") orelse return error.MissingSymbol,
        .send_event = loaded_library.lookup(XSendEventFn, "XSendEvent") orelse return error.MissingSymbol,
        .iconify_window = loaded_library.lookup(XIconifyWindowFn, "XIconifyWindow") orelse return error.MissingSymbol,
        .free_cursor = loaded_library.lookup(XFreeCursorFn, "XFreeCursor") orelse return error.MissingSymbol,
        .set_detectable_auto_repeat = loaded_library.lookup(XkbSetDetectableAutoRepeatFn, "XkbSetDetectableAutoRepeat") orelse return error.MissingSymbol,
    };
    library = loaded_library;
}

fn loaded() *const Api {
    return &(api orelse @panic("libX11 was used before ensureLoaded"));
}

pub fn XOpenDisplay(name: ?[*:0]const u8) ?*Display {
    return loaded().open_display(name);
}
pub fn XCloseDisplay(display: *Display) c_int {
    return loaded().close_display(display);
}
pub fn XDefaultScreen(display: *Display) c_int {
    return loaded().default_screen(display);
}
pub fn XRootWindow(display: *Display, screen: c_int) Window {
    return loaded().root_window(display, screen);
}
pub fn XConnectionNumber(display: *Display) c_int {
    return loaded().connection_number(display);
}
pub fn XInternAtom(display: *Display, name: [*:0]const u8, only_if_exists: c_int) Atom {
    return loaded().intern_atom(display, name, only_if_exists);
}
pub fn XCreateSimpleWindow(display: *Display, parent: Window, x: c_int, y: c_int, width: c_uint, height: c_uint, border_width: c_uint, border: c_ulong, background: c_ulong) Window {
    return loaded().create_simple_window(display, parent, x, y, width, height, border_width, border, background);
}
pub fn XDestroyWindow(display: *Display, window: Window) c_int {
    return loaded().destroy_window(display, window);
}
pub fn XSelectInput(display: *Display, window: Window, event_mask: c_long) c_int {
    return loaded().select_input(display, window, event_mask);
}
pub fn XSetWMProtocols(display: *Display, window: Window, protocols: [*]Atom, count: c_int) c_int {
    return loaded().set_wm_protocols(display, window, protocols, count);
}
pub fn XMapWindow(display: *Display, window: Window) c_int {
    return loaded().map_window(display, window);
}
pub fn XUnmapWindow(display: *Display, window: Window) c_int {
    return loaded().unmap_window(display, window);
}
pub fn XFlush(display: *Display) c_int {
    return loaded().flush(display);
}
pub fn XPending(display: *Display) c_int {
    return loaded().pending(display);
}
pub fn XNextEvent(display: *Display, event: *XEvent) c_int {
    return loaded().next_event(display, event);
}
pub fn XLookupString(event: *XKeyEvent, buffer: [*]u8, bytes_buffer: c_int, keysym: ?*KeySym, compose: ?*anyopaque) c_int {
    return loaded().lookup_string(event, buffer, bytes_buffer, keysym, compose);
}
pub fn XCreateBitmapFromData(display: *Display, drawable: Drawable, data: [*]const u8, width: c_uint, height: c_uint) Pixmap {
    return loaded().create_bitmap_from_data(display, drawable, data, width, height);
}
pub fn XFreePixmap(display: *Display, pixmap: Pixmap) c_int {
    return loaded().free_pixmap(display, pixmap);
}
pub fn XCreatePixmapCursor(display: *Display, source: Pixmap, mask: Pixmap, foreground: *XColor, background: *XColor, x: c_uint, y: c_uint) Cursor {
    return loaded().create_pixmap_cursor(display, source, mask, foreground, background, x, y);
}
pub fn XCreateFontCursor(display: *Display, shape: c_uint) Cursor {
    return loaded().create_font_cursor(display, shape);
}
pub fn XDefineCursor(display: *Display, window: Window, cursor: Cursor) c_int {
    return loaded().define_cursor(display, window, cursor);
}
pub fn XUndefineCursor(display: *Display, window: Window) c_int {
    return loaded().undefine_cursor(display, window);
}
pub fn XSetWMNormalHints(display: *Display, window: Window, hints: *XSizeHints) void {
    loaded().set_wm_normal_hints(display, window, hints);
}
pub fn XChangeProperty(display: *Display, window: Window, property: Atom, type_: Atom, format: c_int, mode: c_int, data: ?*const anyopaque, elements: c_int) c_int {
    return loaded().change_property(display, window, property, type_, format, mode, data, elements);
}
pub fn XStoreName(display: *Display, window: Window, name: [*:0]const u8) c_int {
    return loaded().store_name(display, window, name);
}
pub fn XSendEvent(display: *Display, window: Window, propagate: c_int, event_mask: c_long, event: *XEvent) c_int {
    return loaded().send_event(display, window, propagate, event_mask, event);
}
pub fn XIconifyWindow(display: *Display, window: Window, screen: c_int) c_int {
    return loaded().iconify_window(display, window, screen);
}
pub fn XFreeCursor(display: *Display, cursor: Cursor) c_int {
    return loaded().free_cursor(display, cursor);
}
pub fn XkbSetDetectableAutoRepeat(display: *Display, detectable: c_int, supported: ?*c_int) c_int {
    return loaded().set_detectable_auto_repeat(display, detectable, supported);
}
