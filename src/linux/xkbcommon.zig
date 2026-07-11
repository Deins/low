//! Header-free, runtime-loaded subset of libxkbcommon used by the Wayland
//! backend.  The public xkbcommon ABI declares these structures opaque.
const std = @import("std");

pub const Error = error{ LibraryNotFound, MissingSymbol };

pub const xkb_context = opaque {};
pub const xkb_keymap = opaque {};
pub const xkb_state = opaque {};
pub const xkb_keysym_t = u32;

pub const XKB_CONTEXT_NO_FLAGS: u32 = 0;
pub const XKB_KEYMAP_FORMAT_TEXT_V1: u32 = 1;
pub const XKB_KEYMAP_COMPILE_NO_FLAGS: u32 = 0;
pub const XKB_STATE_MODS_EFFECTIVE: u32 = 1 << 3;

pub const XKB_MOD_NAME_SHIFT: [*:0]const u8 = "Shift";
pub const XKB_MOD_NAME_CTRL: [*:0]const u8 = "Control";
pub const XKB_MOD_NAME_ALT: [*:0]const u8 = "Mod1";
pub const XKB_MOD_NAME_LOGO: [*:0]const u8 = "Mod4";
pub const XKB_MOD_NAME_CAPS: [*:0]const u8 = "Lock";
pub const XKB_MOD_NAME_NUM: [*:0]const u8 = "Mod2";

// xkbcommon uses the standard X11 keysym values.  Only the subset exposed by
// low's GLFW-like Key enum is needed here.
pub const XKB_KEY_F1: xkb_keysym_t = 0xffbe;
pub const XKB_KEY_F2: xkb_keysym_t = 0xffbf;
pub const XKB_KEY_F3: xkb_keysym_t = 0xffc0;
pub const XKB_KEY_F4: xkb_keysym_t = 0xffc1;
pub const XKB_KEY_F5: xkb_keysym_t = 0xffc2;
pub const XKB_KEY_F6: xkb_keysym_t = 0xffc3;
pub const XKB_KEY_F7: xkb_keysym_t = 0xffc4;
pub const XKB_KEY_F8: xkb_keysym_t = 0xffc5;
pub const XKB_KEY_F9: xkb_keysym_t = 0xffc6;
pub const XKB_KEY_F10: xkb_keysym_t = 0xffc7;
pub const XKB_KEY_F11: xkb_keysym_t = 0xffc8;
pub const XKB_KEY_F12: xkb_keysym_t = 0xffc9;
pub const XKB_KEY_F13: xkb_keysym_t = 0xffca;
pub const XKB_KEY_F14: xkb_keysym_t = 0xffcb;
pub const XKB_KEY_F15: xkb_keysym_t = 0xffcc;
pub const XKB_KEY_F16: xkb_keysym_t = 0xffcd;
pub const XKB_KEY_F17: xkb_keysym_t = 0xffce;
pub const XKB_KEY_F18: xkb_keysym_t = 0xffcf;
pub const XKB_KEY_F19: xkb_keysym_t = 0xffd0;
pub const XKB_KEY_F20: xkb_keysym_t = 0xffd1;
pub const XKB_KEY_F21: xkb_keysym_t = 0xffd2;
pub const XKB_KEY_F22: xkb_keysym_t = 0xffd3;
pub const XKB_KEY_F23: xkb_keysym_t = 0xffd4;
pub const XKB_KEY_F24: xkb_keysym_t = 0xffd5;
pub const XKB_KEY_F25: xkb_keysym_t = 0xffd6;
pub const XKB_KEY_KP_Divide: xkb_keysym_t = 0xffaf;
pub const XKB_KEY_KP_Multiply: xkb_keysym_t = 0xffaa;
pub const XKB_KEY_KP_Subtract: xkb_keysym_t = 0xffad;
pub const XKB_KEY_KP_Add: xkb_keysym_t = 0xffab;
pub const XKB_KEY_KP_0: xkb_keysym_t = 0xffb0;
pub const XKB_KEY_KP_1: xkb_keysym_t = 0xffb1;
pub const XKB_KEY_KP_2: xkb_keysym_t = 0xffb2;
pub const XKB_KEY_KP_3: xkb_keysym_t = 0xffb3;
pub const XKB_KEY_KP_4: xkb_keysym_t = 0xffb4;
pub const XKB_KEY_KP_5: xkb_keysym_t = 0xffb5;
pub const XKB_KEY_KP_6: xkb_keysym_t = 0xffb6;
pub const XKB_KEY_KP_7: xkb_keysym_t = 0xffb7;
pub const XKB_KEY_KP_8: xkb_keysym_t = 0xffb8;
pub const XKB_KEY_KP_9: xkb_keysym_t = 0xffb9;
pub const XKB_KEY_KP_Decimal: xkb_keysym_t = 0xffae;
pub const XKB_KEY_KP_Equal: xkb_keysym_t = 0xffbd;
pub const XKB_KEY_KP_Enter: xkb_keysym_t = 0xff8d;
pub const XKB_KEY_Return: xkb_keysym_t = 0xff0d;
pub const XKB_KEY_Escape: xkb_keysym_t = 0xff1b;
pub const XKB_KEY_Tab: xkb_keysym_t = 0xff09;
pub const XKB_KEY_Shift_L: xkb_keysym_t = 0xffe1;
pub const XKB_KEY_Shift_R: xkb_keysym_t = 0xffe2;
pub const XKB_KEY_Control_L: xkb_keysym_t = 0xffe3;
pub const XKB_KEY_Control_R: xkb_keysym_t = 0xffe4;
pub const XKB_KEY_Alt_L: xkb_keysym_t = 0xffe9;
pub const XKB_KEY_Alt_R: xkb_keysym_t = 0xffea;
pub const XKB_KEY_Super_L: xkb_keysym_t = 0xffeb;
pub const XKB_KEY_Super_R: xkb_keysym_t = 0xffec;
pub const XKB_KEY_Menu: xkb_keysym_t = 0xff67;
pub const XKB_KEY_Num_Lock: xkb_keysym_t = 0xff7f;
pub const XKB_KEY_Caps_Lock: xkb_keysym_t = 0xffe5;
pub const XKB_KEY_Print: xkb_keysym_t = 0xff61;
pub const XKB_KEY_Scroll_Lock: xkb_keysym_t = 0xff14;
pub const XKB_KEY_Pause: xkb_keysym_t = 0xff13;
pub const XKB_KEY_Delete: xkb_keysym_t = 0xffff;
pub const XKB_KEY_Home: xkb_keysym_t = 0xff50;
pub const XKB_KEY_End: xkb_keysym_t = 0xff57;
pub const XKB_KEY_Page_Up: xkb_keysym_t = 0xff55;
pub const XKB_KEY_Page_Down: xkb_keysym_t = 0xff56;
pub const XKB_KEY_Insert: xkb_keysym_t = 0xff63;
pub const XKB_KEY_Left: xkb_keysym_t = 0xff51;
pub const XKB_KEY_Right: xkb_keysym_t = 0xff53;
pub const XKB_KEY_Up: xkb_keysym_t = 0xff52;
pub const XKB_KEY_Down: xkb_keysym_t = 0xff54;
pub const XKB_KEY_BackSpace: xkb_keysym_t = 0xff08;
pub const XKB_KEY_space: xkb_keysym_t = 0x0020;
pub const XKB_KEY_minus: xkb_keysym_t = 0x002d;
pub const XKB_KEY_equal: xkb_keysym_t = 0x003d;
pub const XKB_KEY_bracketleft: xkb_keysym_t = 0x005b;
pub const XKB_KEY_bracketright: xkb_keysym_t = 0x005d;
pub const XKB_KEY_backslash: xkb_keysym_t = 0x005c;
pub const XKB_KEY_semicolon: xkb_keysym_t = 0x003b;
pub const XKB_KEY_apostrophe: xkb_keysym_t = 0x0027;
pub const XKB_KEY_comma: xkb_keysym_t = 0x002c;
pub const XKB_KEY_period: xkb_keysym_t = 0x002e;
pub const XKB_KEY_slash: xkb_keysym_t = 0x002f;
pub const XKB_KEY_grave: xkb_keysym_t = 0x0060;

const ContextNewFn = *const fn (u32) callconv(.c) ?*xkb_context;
const ContextUnrefFn = *const fn (*xkb_context) callconv(.c) void;
const KeymapUnrefFn = *const fn (*xkb_keymap) callconv(.c) void;
const KeymapNewFromBufferFn = *const fn (*xkb_context, [*]const u8, usize, u32, u32) callconv(.c) ?*xkb_keymap;
const StateNewFn = *const fn (*xkb_keymap) callconv(.c) ?*xkb_state;
const StateUnrefFn = *const fn (*xkb_state) callconv(.c) void;
const StateModNameIsActiveFn = *const fn (*xkb_state, [*:0]const u8, u32) callconv(.c) c_int;
const StateKeyGetOneSymFn = *const fn (*xkb_state, u32) callconv(.c) xkb_keysym_t;
const StateKeyGetUtf8Fn = *const fn (*xkb_state, u32, [*]u8, usize) callconv(.c) c_int;
const StateUpdateMaskFn = *const fn (*xkb_state, u32, u32, u32, u32, u32, u32) callconv(.c) u32;

const Api = struct {
    context_new: ContextNewFn,
    context_unref: ContextUnrefFn,
    keymap_unref: KeymapUnrefFn,
    keymap_new_from_buffer: KeymapNewFromBufferFn,
    state_new: StateNewFn,
    state_unref: StateUnrefFn,
    state_mod_name_is_active: StateModNameIsActiveFn,
    state_key_get_one_sym: StateKeyGetOneSymFn,
    state_key_get_utf8: StateKeyGetUtf8Fn,
    state_update_mask: StateUpdateMaskFn,
};

var library: ?std.DynLib = null;
var api: ?Api = null;
var load_mutex: std.atomic.Mutex = .unlocked;

pub fn ensureLoaded() Error!void {
    while (!load_mutex.tryLock()) std.atomic.spinLoopHint();
    defer load_mutex.unlock();
    if (api != null) return;

    var loaded_library = blk: {
        inline for (&.{ "libxkbcommon.so.0", "libxkbcommon.so" }) |name| {
            if (std.DynLib.open(name)) |opened| break :blk opened else |_| {}
        }
        return error.LibraryNotFound;
    };
    errdefer loaded_library.close();

    api = .{
        .context_new = loaded_library.lookup(ContextNewFn, "xkb_context_new") orelse return error.MissingSymbol,
        .context_unref = loaded_library.lookup(ContextUnrefFn, "xkb_context_unref") orelse return error.MissingSymbol,
        .keymap_unref = loaded_library.lookup(KeymapUnrefFn, "xkb_keymap_unref") orelse return error.MissingSymbol,
        .keymap_new_from_buffer = loaded_library.lookup(KeymapNewFromBufferFn, "xkb_keymap_new_from_buffer") orelse return error.MissingSymbol,
        .state_new = loaded_library.lookup(StateNewFn, "xkb_state_new") orelse return error.MissingSymbol,
        .state_unref = loaded_library.lookup(StateUnrefFn, "xkb_state_unref") orelse return error.MissingSymbol,
        .state_mod_name_is_active = loaded_library.lookup(StateModNameIsActiveFn, "xkb_state_mod_name_is_active") orelse return error.MissingSymbol,
        .state_key_get_one_sym = loaded_library.lookup(StateKeyGetOneSymFn, "xkb_state_key_get_one_sym") orelse return error.MissingSymbol,
        .state_key_get_utf8 = loaded_library.lookup(StateKeyGetUtf8Fn, "xkb_state_key_get_utf8") orelse return error.MissingSymbol,
        .state_update_mask = loaded_library.lookup(StateUpdateMaskFn, "xkb_state_update_mask") orelse return error.MissingSymbol,
    };
    library = loaded_library;
}

fn loaded() *const Api {
    return &(api orelse @panic("libxkbcommon was used before ensureLoaded"));
}

pub fn xkb_context_new(flags: u32) ?*xkb_context {
    return loaded().context_new(flags);
}

pub fn xkb_context_unref(context: *xkb_context) void {
    loaded().context_unref(context);
}

pub fn xkb_keymap_unref(keymap: *xkb_keymap) void {
    loaded().keymap_unref(keymap);
}

pub fn xkb_keymap_new_from_buffer(context: *xkb_context, buffer: [*]const u8, length: usize, format: u32, flags: u32) ?*xkb_keymap {
    return loaded().keymap_new_from_buffer(context, buffer, length, format, flags);
}

pub fn xkb_state_new(keymap: *xkb_keymap) ?*xkb_state {
    return loaded().state_new(keymap);
}

pub fn xkb_state_unref(state: *xkb_state) void {
    loaded().state_unref(state);
}

pub fn xkb_state_mod_name_is_active(state: *xkb_state, name: [*:0]const u8, flags: u32) c_int {
    return loaded().state_mod_name_is_active(state, name, flags);
}

pub fn xkb_state_key_get_one_sym(state: *xkb_state, key: u32) xkb_keysym_t {
    return loaded().state_key_get_one_sym(state, key);
}

pub fn xkb_state_key_get_utf8(state: *xkb_state, key: u32, buffer: [*]u8, size: usize) c_int {
    return loaded().state_key_get_utf8(state, key, buffer, size);
}

pub fn xkb_state_update_mask(state: *xkb_state, depressed: u32, latched: u32, locked: u32, group: u32, serial: u32, mods: u32) u32 {
    return loaded().state_update_mask(state, depressed, latched, locked, group, serial, mods);
}
