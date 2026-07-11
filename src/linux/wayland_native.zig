const std = @import("std");
const log = std.log.scoped(.low);
const common = @import("../common.zig");
const input = @import("../input.zig");
const wayland = @import("wayland");
const wayland_ffi = @import("wayland_ffi");
const xkb = @import("xkbcommon.zig");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const zxdg = wayland.client.zxdg;
const cursor_shape = wayland.client.wp;

const c = struct {
    pub const wl_display = wl.Display;
    pub const wl_registry = wl.Registry;
    pub const wl_compositor = wl.Compositor;
    pub const wl_seat = wl.Seat;
    pub const wl_pointer = wl.Pointer;
    pub const wl_keyboard = wl.Keyboard;
    pub const wl_output = wl.Output;
    pub const wl_surface = wl.Surface;
    pub const wl_array = wl.Array;
    pub const wl_fixed_t = wl.Fixed;
    pub const xdg_wm_base = xdg.WmBase;
    pub const xdg_surface = xdg.Surface;
    pub const xdg_toplevel = xdg.Toplevel;
    pub const xdg_positioner = xdg.Positioner;
    pub const zxdg_decoration_manager_v1 = zxdg.DecorationManagerV1;
    pub const zxdg_toplevel_decoration_v1 = zxdg.ToplevelDecorationV1;
    pub const wp_cursor_shape_manager_v1 = cursor_shape.CursorShapeManagerV1;
    pub const wp_cursor_shape_device_v1 = cursor_shape.CursorShapeDeviceV1;
    pub const wp_cursor_shape_device_v1_Shape = cursor_shape.CursorShapeDeviceV1.Shape;

    pub const wl_registry_listener = struct {
        global: ?*const fn (?*anyopaque, ?*wl_registry, u32, [*c]const u8, u32) callconv(.c) void = null,
        global_remove: ?*const fn (?*anyopaque, ?*wl_registry, u32) callconv(.c) void = null,
    };
    pub const xdg_wm_base_listener = struct {
        ping: ?*const fn (?*anyopaque, ?*xdg_wm_base, u32) callconv(.c) void = null,
    };
    pub const wl_seat_listener = struct {
        capabilities: ?*const fn (?*anyopaque, ?*wl_seat, c_uint) callconv(.c) void = null,
    };
    pub const wl_pointer_listener = struct {
        enter: ?*const fn (?*anyopaque, ?*wl_pointer, u32, ?*wl_surface, wl_fixed_t, wl_fixed_t) callconv(.c) void = null,
        leave: ?*const fn (?*anyopaque, ?*wl_pointer, u32, ?*wl_surface) callconv(.c) void = null,
        motion: ?*const fn (?*anyopaque, ?*wl_pointer, u32, wl_fixed_t, wl_fixed_t) callconv(.c) void = null,
        button: ?*const fn (?*anyopaque, ?*wl_pointer, u32, u32, u32, c_uint) callconv(.c) void = null,
        axis: ?*const fn (?*anyopaque, ?*wl_pointer, u32, u32, wl_fixed_t) callconv(.c) void = null,
        frame: ?*const fn (?*anyopaque, ?*wl_pointer) callconv(.c) void = null,
        axis_source: ?*const fn (?*anyopaque, ?*wl_pointer, u32) callconv(.c) void = null,
        axis_stop: ?*const fn (?*anyopaque, ?*wl_pointer, u32, u32) callconv(.c) void = null,
        axis_discrete: ?*const fn (?*anyopaque, ?*wl_pointer, u32, i32) callconv(.c) void = null,
    };
    pub const wl_keyboard_listener = struct {
        keymap: ?*const fn (?*anyopaque, ?*wl_keyboard, u32, c_int, u32) callconv(.c) void = null,
        enter: ?*const fn (?*anyopaque, ?*wl_keyboard, u32, ?*wl_surface, [*c]wl.Array) callconv(.c) void = null,
        leave: ?*const fn (?*anyopaque, ?*wl_keyboard, u32, ?*wl_surface) callconv(.c) void = null,
        key: ?*const fn (?*anyopaque, ?*wl_keyboard, u32, u32, u32, u32) callconv(.c) void = null,
        modifiers: ?*const fn (?*anyopaque, ?*wl_keyboard, u32, u32, u32, u32, u32) callconv(.c) void = null,
        repeat_info: ?*const fn (?*anyopaque, ?*wl_keyboard, i32, i32) callconv(.c) void = null,
    };
    pub const wl_surface_listener = struct {
        enter: ?*const fn (?*anyopaque, ?*wl_surface, ?*wl_output) callconv(.c) void = null,
        leave: ?*const fn (?*anyopaque, ?*wl_surface, ?*wl_output) callconv(.c) void = null,
    };
    pub const wl_output_listener = struct {
        geometry: ?*const fn (?*anyopaque, ?*wl_output, i32, i32, i32, i32, i32, [*c]const u8, [*c]const u8, i32) callconv(.c) void = null,
        mode: ?*const fn (?*anyopaque, ?*wl_output, u32, i32, i32, i32) callconv(.c) void = null,
        done: ?*const fn (?*anyopaque, ?*wl_output) callconv(.c) void = null,
        scale: ?*const fn (?*anyopaque, ?*wl_output, i32) callconv(.c) void = null,
        name: ?*const fn (?*anyopaque, ?*wl_output, [*c]const u8) callconv(.c) void = null,
        description: ?*const fn (?*anyopaque, ?*wl_output, [*c]const u8) callconv(.c) void = null,
    };
    pub const xdg_surface_listener = struct {
        configure: ?*const fn (?*anyopaque, ?*xdg_surface, u32) callconv(.c) void = null,
    };
    pub const xdg_toplevel_listener = struct {
        configure: ?*const fn (?*anyopaque, ?*xdg_toplevel, i32, i32, ?*wl_array) callconv(.c) void = null,
        close: ?*const fn (?*anyopaque, ?*xdg_toplevel) callconv(.c) void = null,
        configure_bounds: ?*const fn (?*anyopaque, ?*xdg_toplevel, i32, i32) callconv(.c) void = null,
        wm_capabilities: ?*const fn (?*anyopaque, ?*xdg_toplevel, ?*wl_array) callconv(.c) void = null,
    };
    pub const zxdg_toplevel_decoration_v1_listener = struct {
        configure: ?*const fn (?*anyopaque, ?*zxdg_toplevel_decoration_v1, u32) callconv(.c) void = null,
    };

    pub const xkb_context = xkb.xkb_context;
    pub const xkb_keymap = xkb.xkb_keymap;
    pub const xkb_state = xkb.xkb_state;
    pub const xkb_keysym_t = xkb.xkb_keysym_t;
    pub const XKB_CONTEXT_NO_FLAGS = xkb.XKB_CONTEXT_NO_FLAGS;
    pub const XKB_KEYMAP_FORMAT_TEXT_V1 = xkb.XKB_KEYMAP_FORMAT_TEXT_V1;
    pub const XKB_KEYMAP_COMPILE_NO_FLAGS = xkb.XKB_KEYMAP_COMPILE_NO_FLAGS;
    pub const XKB_STATE_MODS_EFFECTIVE = xkb.XKB_STATE_MODS_EFFECTIVE;
    pub const XKB_MOD_NAME_SHIFT = xkb.XKB_MOD_NAME_SHIFT;
    pub const XKB_MOD_NAME_CTRL = xkb.XKB_MOD_NAME_CTRL;
    pub const XKB_MOD_NAME_ALT = xkb.XKB_MOD_NAME_ALT;
    pub const XKB_MOD_NAME_LOGO = xkb.XKB_MOD_NAME_LOGO;
    pub const XKB_MOD_NAME_CAPS = xkb.XKB_MOD_NAME_CAPS;
    pub const XKB_MOD_NAME_NUM = xkb.XKB_MOD_NAME_NUM;
    pub const XKB_KEY_F1 = xkb.XKB_KEY_F1;
    pub const XKB_KEY_F2 = xkb.XKB_KEY_F2;
    pub const XKB_KEY_F3 = xkb.XKB_KEY_F3;
    pub const XKB_KEY_F4 = xkb.XKB_KEY_F4;
    pub const XKB_KEY_F5 = xkb.XKB_KEY_F5;
    pub const XKB_KEY_F6 = xkb.XKB_KEY_F6;
    pub const XKB_KEY_F7 = xkb.XKB_KEY_F7;
    pub const XKB_KEY_F8 = xkb.XKB_KEY_F8;
    pub const XKB_KEY_F9 = xkb.XKB_KEY_F9;
    pub const XKB_KEY_F10 = xkb.XKB_KEY_F10;
    pub const XKB_KEY_F11 = xkb.XKB_KEY_F11;
    pub const XKB_KEY_F12 = xkb.XKB_KEY_F12;
    pub const XKB_KEY_F13 = xkb.XKB_KEY_F13;
    pub const XKB_KEY_F14 = xkb.XKB_KEY_F14;
    pub const XKB_KEY_F15 = xkb.XKB_KEY_F15;
    pub const XKB_KEY_F16 = xkb.XKB_KEY_F16;
    pub const XKB_KEY_F17 = xkb.XKB_KEY_F17;
    pub const XKB_KEY_F18 = xkb.XKB_KEY_F18;
    pub const XKB_KEY_F19 = xkb.XKB_KEY_F19;
    pub const XKB_KEY_F20 = xkb.XKB_KEY_F20;
    pub const XKB_KEY_F21 = xkb.XKB_KEY_F21;
    pub const XKB_KEY_F22 = xkb.XKB_KEY_F22;
    pub const XKB_KEY_F23 = xkb.XKB_KEY_F23;
    pub const XKB_KEY_F24 = xkb.XKB_KEY_F24;
    pub const XKB_KEY_F25 = xkb.XKB_KEY_F25;
    pub const XKB_KEY_KP_Divide = xkb.XKB_KEY_KP_Divide;
    pub const XKB_KEY_KP_Multiply = xkb.XKB_KEY_KP_Multiply;
    pub const XKB_KEY_KP_Subtract = xkb.XKB_KEY_KP_Subtract;
    pub const XKB_KEY_KP_Add = xkb.XKB_KEY_KP_Add;
    pub const XKB_KEY_KP_0 = xkb.XKB_KEY_KP_0;
    pub const XKB_KEY_KP_1 = xkb.XKB_KEY_KP_1;
    pub const XKB_KEY_KP_2 = xkb.XKB_KEY_KP_2;
    pub const XKB_KEY_KP_3 = xkb.XKB_KEY_KP_3;
    pub const XKB_KEY_KP_4 = xkb.XKB_KEY_KP_4;
    pub const XKB_KEY_KP_5 = xkb.XKB_KEY_KP_5;
    pub const XKB_KEY_KP_6 = xkb.XKB_KEY_KP_6;
    pub const XKB_KEY_KP_7 = xkb.XKB_KEY_KP_7;
    pub const XKB_KEY_KP_8 = xkb.XKB_KEY_KP_8;
    pub const XKB_KEY_KP_9 = xkb.XKB_KEY_KP_9;
    pub const XKB_KEY_KP_Decimal = xkb.XKB_KEY_KP_Decimal;
    pub const XKB_KEY_KP_Equal = xkb.XKB_KEY_KP_Equal;
    pub const XKB_KEY_KP_Enter = xkb.XKB_KEY_KP_Enter;
    pub const XKB_KEY_Return = xkb.XKB_KEY_Return;
    pub const XKB_KEY_Escape = xkb.XKB_KEY_Escape;
    pub const XKB_KEY_Tab = xkb.XKB_KEY_Tab;
    pub const XKB_KEY_Shift_L = xkb.XKB_KEY_Shift_L;
    pub const XKB_KEY_Shift_R = xkb.XKB_KEY_Shift_R;
    pub const XKB_KEY_Control_L = xkb.XKB_KEY_Control_L;
    pub const XKB_KEY_Control_R = xkb.XKB_KEY_Control_R;
    pub const XKB_KEY_Alt_L = xkb.XKB_KEY_Alt_L;
    pub const XKB_KEY_Alt_R = xkb.XKB_KEY_Alt_R;
    pub const XKB_KEY_Super_L = xkb.XKB_KEY_Super_L;
    pub const XKB_KEY_Super_R = xkb.XKB_KEY_Super_R;
    pub const XKB_KEY_Menu = xkb.XKB_KEY_Menu;
    pub const XKB_KEY_Num_Lock = xkb.XKB_KEY_Num_Lock;
    pub const XKB_KEY_Caps_Lock = xkb.XKB_KEY_Caps_Lock;
    pub const XKB_KEY_Print = xkb.XKB_KEY_Print;
    pub const XKB_KEY_Scroll_Lock = xkb.XKB_KEY_Scroll_Lock;
    pub const XKB_KEY_Pause = xkb.XKB_KEY_Pause;
    pub const XKB_KEY_Delete = xkb.XKB_KEY_Delete;
    pub const XKB_KEY_Home = xkb.XKB_KEY_Home;
    pub const XKB_KEY_End = xkb.XKB_KEY_End;
    pub const XKB_KEY_Page_Up = xkb.XKB_KEY_Page_Up;
    pub const XKB_KEY_Page_Down = xkb.XKB_KEY_Page_Down;
    pub const XKB_KEY_Insert = xkb.XKB_KEY_Insert;
    pub const XKB_KEY_Left = xkb.XKB_KEY_Left;
    pub const XKB_KEY_Right = xkb.XKB_KEY_Right;
    pub const XKB_KEY_Up = xkb.XKB_KEY_Up;
    pub const XKB_KEY_Down = xkb.XKB_KEY_Down;
    pub const XKB_KEY_BackSpace = xkb.XKB_KEY_BackSpace;
    pub const XKB_KEY_space = xkb.XKB_KEY_space;
    pub const XKB_KEY_minus = xkb.XKB_KEY_minus;
    pub const XKB_KEY_equal = xkb.XKB_KEY_equal;
    pub const XKB_KEY_bracketleft = xkb.XKB_KEY_bracketleft;
    pub const XKB_KEY_bracketright = xkb.XKB_KEY_bracketright;
    pub const XKB_KEY_backslash = xkb.XKB_KEY_backslash;
    pub const XKB_KEY_semicolon = xkb.XKB_KEY_semicolon;
    pub const XKB_KEY_apostrophe = xkb.XKB_KEY_apostrophe;
    pub const XKB_KEY_comma = xkb.XKB_KEY_comma;
    pub const XKB_KEY_period = xkb.XKB_KEY_period;
    pub const XKB_KEY_slash = xkb.XKB_KEY_slash;
    pub const XKB_KEY_grave = xkb.XKB_KEY_grave;

    pub fn xkb_context_new(flags: u32) ?*xkb_context {
        return xkb.xkb_context_new(flags);
    }
    pub fn xkb_context_unref(ctx: *xkb_context) void {
        xkb.xkb_context_unref(ctx);
    }
    pub fn xkb_keymap_unref(keymap: *xkb_keymap) void {
        xkb.xkb_keymap_unref(keymap);
    }
    pub fn xkb_keymap_new_from_buffer(ctx: *xkb_context, buffer: [*]const u8, length: usize, format: u32, flags: u32) ?*xkb_keymap {
        return xkb.xkb_keymap_new_from_buffer(ctx, @ptrCast(buffer), length, format, flags);
    }
    pub fn xkb_state_new(keymap: *xkb_keymap) ?*xkb_state {
        return xkb.xkb_state_new(keymap);
    }
    pub fn xkb_state_unref(state: *xkb_state) void {
        xkb.xkb_state_unref(state);
    }
    pub fn xkb_state_mod_name_is_active(state: *xkb_state, name: [*:0]const u8, flags: u32) c_int {
        return xkb.xkb_state_mod_name_is_active(state, name, flags);
    }
    pub fn xkb_state_key_get_one_sym(state: *xkb_state, key: u32) xkb_keysym_t {
        return xkb.xkb_state_key_get_one_sym(state, key);
    }
    pub fn xkb_state_key_get_utf8(state: *xkb_state, key: u32, buffer: [*]u8, size: usize) c_int {
        return xkb.xkb_state_key_get_utf8(state, key, @ptrCast(buffer), size);
    }
    pub fn xkb_state_update_mask(state: *xkb_state, depressed: u32, latched: u32, locked: u32, group: u32, serial: u32, mods: u32) c_uint {
        return xkb.xkb_state_update_mask(state, depressed, latched, locked, group, serial, mods);
    }

    pub fn wl_display_connect(name: ?[*:0]const u8) ?*wl_display {
        return wl.Display.connect(name) catch null;
    }
    pub fn wl_display_disconnect(display: *wl_display) void {
        display.disconnect();
    }
    pub fn wl_display_get_fd(display: *wl_display) c_int {
        return display.getFd();
    }
    pub fn wl_display_get_registry(display: *wl_display) ?*wl_registry {
        return display.getRegistry() catch null;
    }
    pub fn wl_display_roundtrip(display: *wl_display) c_int {
        return if (display.roundtrip() == .SUCCESS) 0 else -1;
    }
    pub fn wl_display_prepare_read(display: *wl_display) c_int {
        return if (display.prepareRead()) 0 else -1;
    }
    pub fn wl_display_flush(display: *wl_display) c_int {
        return if (display.flush() == .SUCCESS) 0 else -1;
    }
    pub fn wl_display_dispatch_pending(display: *wl_display) c_int {
        return if (display.dispatchPending() == .SUCCESS) 0 else -1;
    }
    pub fn wl_display_read_events(display: *wl_display) c_int {
        return if (display.readEvents() == .SUCCESS) 0 else -1;
    }
    pub fn wl_display_cancel_read(display: *wl_display) void {
        display.cancelRead();
    }
    pub fn wl_display_get_error(display: *wl_display) c_int {
        return display.getError();
    }

    pub fn wl_compositor_create_surface(compositor: *wl_compositor) ?*wl_surface {
        return compositor.createSurface() catch null;
    }
    pub fn wl_compositor_destroy(compositor: *wl_compositor) void {
        compositor.destroy();
    }
    pub fn wl_surface_destroy(surface: *wl_surface) void {
        surface.destroy();
    }
    pub fn wl_surface_set_buffer_scale(surface: *wl_surface, scale: c_int) void {
        surface.setBufferScale(scale);
    }
    pub fn wl_surface_commit(surface: *wl_surface) void {
        surface.commit();
    }
    pub fn wl_surface_add_listener(surface: *wl_surface, listener: *const wl_surface_listener, data: ?*anyopaque) c_int {
        _ = listener;
        surface.setListener(?*anyopaque, surfaceDispatch, data);
        return 0;
    }
    fn surfaceDispatch(surface: *wl_surface, event: wl.Surface.Event, data: ?*anyopaque) void {
        switch (event) {
            .enter => |e| surfaceEnter(data, surface, e.output),
            .leave => |e| surfaceLeave(data, surface, e.output),
        }
    }

    pub fn wl_registry_add_listener(registry: *wl_registry, listener: *const wl_registry_listener, data: ?*anyopaque) c_int {
        _ = listener;
        registry.setListener(?*anyopaque, registryDispatch, data);
        return 0;
    }
    fn registryDispatch(registry: *wl_registry, event: wl.Registry.Event, data: ?*anyopaque) void {
        switch (event) {
            .global => |e| registryGlobal(data, registry, e.name, e.interface, e.version),
            .global_remove => |e| registryRemove(data, registry, e.name),
        }
    }

    pub fn wl_registry_destroy(registry: *wl_registry) void {
        registry.destroy();
    }

    pub fn wl_seat_destroy(seat: *wl_seat) void {
        seat.destroy();
    }

    pub fn wl_seat_get_pointer(seat: *wl_seat) ?*wl_pointer {
        return seat.getPointer() catch null;
    }

    pub fn wl_seat_get_keyboard(seat: *wl_seat) ?*wl_keyboard {
        return seat.getKeyboard() catch null;
    }

    pub fn wl_seat_add_listener(seat: *wl_seat, listener: *const wl_seat_listener, data: ?*anyopaque) c_int {
        _ = listener;
        seat.setListener(?*anyopaque, seatDispatch, data);
        return 0;
    }
    fn seatDispatch(seat: *wl_seat, event: wl.Seat.Event, data: ?*anyopaque) void {
        switch (event) {
            .capabilities => |e| seatCapabilities(data, seat, @bitCast(e.capabilities)),
            .name => {},
        }
    }

    pub fn wl_pointer_destroy(pointer: *wl_pointer) void {
        pointer.destroy();
    }

    pub fn wl_pointer_set_cursor(pointer: *wl_pointer, serial: u32, surface: ?*wl_surface, hotspot_x: i32, hotspot_y: i32) void {
        pointer.setCursor(serial, surface, hotspot_x, hotspot_y);
    }

    pub fn wl_pointer_add_listener(pointer: *wl_pointer, listener: *const wl_pointer_listener, data: ?*anyopaque) c_int {
        _ = listener;
        pointer.setListener(?*anyopaque, pointerDispatch, data);
        return 0;
    }
    fn pointerDispatch(pointer: *wl_pointer, event: wl.Pointer.Event, data: ?*anyopaque) void {
        switch (event) {
            .enter => |e| pointerEnter(data, pointer, e.serial, e.surface, e.surface_x, e.surface_y),
            .leave => |e| pointerLeave(data, pointer, e.serial, e.surface),
            .motion => |e| pointerMotion(data, pointer, e.time, e.surface_x, e.surface_y),
            .button => |e| pointerButton(data, pointer, e.serial, e.time, e.button, @as(c_uint, @intCast(@intFromEnum(e.state)))),
            .axis => |e| pointerAxis(data, pointer, e.time, @as(u32, @intCast(@intFromEnum(e.axis))), e.value),
            .frame, .axis_source, .axis_stop, .axis_discrete => {},
        }
    }

    pub fn wl_keyboard_destroy(keyboard: *wl_keyboard) void {
        keyboard.destroy();
    }

    pub fn wl_keyboard_add_listener(keyboard: *wl_keyboard, listener: *const wl_keyboard_listener, data: ?*anyopaque) c_int {
        _ = listener;
        keyboard.setListener(?*anyopaque, keyboardDispatch, data);
        return 0;
    }
    fn keyboardDispatch(keyboard: *wl_keyboard, event: wl.Keyboard.Event, data: ?*anyopaque) void {
        switch (event) {
            .keymap => |e| keyboardKeymap(data, keyboard, @as(u32, @intCast(@intFromEnum(e.format))), e.fd, e.size),
            .enter => |e| keyboardEnter(data, keyboard, e.serial, e.surface, e.keys),
            .leave => |e| keyboardLeave(data, keyboard, e.serial, e.surface),
            .key => |e| keyboardKey(data, keyboard, e.serial, e.time, e.key, @as(u32, @intCast(@intFromEnum(e.state)))),
            .modifiers => |e| keyboardModifiers(data, keyboard, e.serial, e.mods_depressed, e.mods_latched, e.mods_locked, e.group),
            .repeat_info => |e| keyboardRepeatInfo(data, keyboard, e.rate, e.delay),
        }
    }

    pub fn wl_output_destroy(output: *wl_output) void {
        output.destroy();
    }

    pub fn wl_output_add_listener(output: *wl_output, listener: *const wl_output_listener, data: ?*anyopaque) c_int {
        _ = listener;
        output.setListener(?*anyopaque, outputDispatch, data);
        return 0;
    }
    fn outputDispatch(output: *wl_output, event: wl.Output.Event, data: ?*anyopaque) void {
        switch (event) {
            .geometry, .mode, .done, .name, .description => {},
            .scale => |e| outputScale(data, output, e.factor),
        }
    }

    pub fn xdg_wm_base_destroy(wm_base: *xdg_wm_base) void {
        wm_base.destroy();
    }
    pub fn xdg_wm_base_pong(wm_base: *xdg_wm_base, serial: u32) void {
        wm_base.pong(serial);
    }
    pub fn xdg_wm_base_get_xdg_surface(wm_base: *xdg_wm_base, surface: *wl_surface) ?*xdg_surface {
        return wm_base.getXdgSurface(surface) catch null;
    }
    pub fn xdg_wm_base_add_listener(wm_base: *xdg_wm_base, listener: *const xdg_wm_base_listener, data: ?*anyopaque) c_int {
        _ = listener;
        wm_base.setListener(?*anyopaque, wmBaseDispatch, data);
        return 0;
    }
    fn wmBaseDispatch(wm_base: *xdg_wm_base, event: xdg.WmBase.Event, data: ?*anyopaque) void {
        switch (event) {
            .ping => |e| wmBasePing(data, wm_base, e.serial),
        }
    }

    pub fn xdg_surface_destroy(surface: *xdg_surface) void {
        surface.destroy();
    }
    pub fn xdg_surface_get_toplevel(surface: *xdg_surface) ?*xdg_toplevel {
        return surface.getToplevel() catch null;
    }
    pub fn xdg_surface_ack_configure(surface: *xdg_surface, serial: u32) void {
        surface.ackConfigure(serial);
    }
    pub fn xdg_surface_add_listener(surface: *xdg_surface, listener: *const xdg_surface_listener, data: ?*anyopaque) c_int {
        _ = listener;
        surface.setListener(?*anyopaque, xdgSurfaceDispatch, data);
        return 0;
    }
    fn xdgSurfaceDispatch(surface: *xdg_surface, event: xdg.Surface.Event, data: ?*anyopaque) void {
        switch (event) {
            .configure => |e| xdgSurfaceConfigure(data, surface, e.serial),
        }
    }

    pub fn xdg_toplevel_destroy(toplevel: *xdg_toplevel) void {
        toplevel.destroy();
    }
    pub fn xdg_toplevel_set_title(toplevel: *xdg_toplevel, title: [*:0]const u8) void {
        toplevel.setTitle(title);
    }
    pub fn xdg_toplevel_set_app_id(toplevel: *xdg_toplevel, app_id: [*:0]const u8) void {
        toplevel.setAppId(app_id);
    }
    pub fn xdg_toplevel_set_min_size(toplevel: *xdg_toplevel, width: i32, height: i32) void {
        toplevel.setMinSize(width, height);
    }
    pub fn xdg_toplevel_set_max_size(toplevel: *xdg_toplevel, width: i32, height: i32) void {
        toplevel.setMaxSize(width, height);
    }
    pub fn xdg_toplevel_set_maximized(toplevel: *xdg_toplevel) void {
        toplevel.setMaximized();
    }
    pub fn xdg_toplevel_unset_maximized(toplevel: *xdg_toplevel) void {
        toplevel.unsetMaximized();
    }
    pub fn xdg_toplevel_set_fullscreen(toplevel: *xdg_toplevel, output: ?*wl_output) void {
        toplevel.setFullscreen(output);
    }
    pub fn xdg_toplevel_unset_fullscreen(toplevel: *xdg_toplevel) void {
        toplevel.unsetFullscreen();
    }
    pub fn xdg_toplevel_set_minimized(toplevel: *xdg_toplevel) void {
        toplevel.setMinimized();
    }
    pub fn xdg_toplevel_add_listener(toplevel: *xdg_toplevel, listener: *const xdg_toplevel_listener, data: ?*anyopaque) c_int {
        _ = listener;
        toplevel.setListener(?*anyopaque, xdgToplevelDispatch, data);
        return 0;
    }
    fn xdgToplevelDispatch(toplevel: *xdg_toplevel, event: xdg.Toplevel.Event, data: ?*anyopaque) void {
        switch (event) {
            .configure => |e| xdgToplevelConfigure(data, toplevel, e.width, e.height, e.states),
            .close => xdgToplevelClose(data, toplevel),
            .configure_bounds, .wm_capabilities => {},
        }
    }

    pub fn zxdg_decoration_manager_v1_destroy(manager: *zxdg_decoration_manager_v1) void {
        manager.destroy();
    }
    pub fn zxdg_decoration_manager_v1_get_toplevel_decoration(manager: *zxdg_decoration_manager_v1, toplevel: *xdg_toplevel) ?*zxdg_toplevel_decoration_v1 {
        return manager.getToplevelDecoration(toplevel) catch null;
    }

    pub fn zxdg_toplevel_decoration_v1_destroy(decoration: *zxdg_toplevel_decoration_v1) void {
        decoration.destroy();
    }
    pub fn zxdg_toplevel_decoration_v1_set_mode(decoration: *zxdg_toplevel_decoration_v1, mode: zxdg_toplevel_decoration_v1_Mode) void {
        decoration.setMode(mode);
    }
    pub fn zxdg_toplevel_decoration_v1_unset_mode(decoration: *zxdg_toplevel_decoration_v1) void {
        decoration.unsetMode();
    }

    pub fn wp_cursor_shape_manager_v1_destroy(manager: *wp_cursor_shape_manager_v1) void {
        manager.destroy();
    }
    pub fn wp_cursor_shape_manager_v1_get_pointer(manager: *wp_cursor_shape_manager_v1, pointer: *wl_pointer) ?*wp_cursor_shape_device_v1 {
        return manager.getPointer(pointer) catch null;
    }
    pub fn wp_cursor_shape_device_v1_destroy(device: *wp_cursor_shape_device_v1) void {
        device.destroy();
    }
    pub fn wp_cursor_shape_device_v1_set_shape(device: *wp_cursor_shape_device_v1, serial: u32, shape: wp_cursor_shape_device_v1_Shape) void {
        device.setShape(serial, shape);
    }
    pub fn zxdg_toplevel_decoration_v1_add_listener(decoration: *zxdg_toplevel_decoration_v1, listener: *const zxdg_toplevel_decoration_v1_listener, data: ?*anyopaque) c_int {
        _ = listener;
        decoration.setListener(?*anyopaque, decorationDispatch, data);
        return 0;
    }
    fn decorationDispatch(decoration: *zxdg_toplevel_decoration_v1, event: zxdg.ToplevelDecorationV1.Event, data: ?*anyopaque) void {
        switch (event) {
            .configure => |e| decorationConfigure(data, decoration, @as(u32, @intCast(@intFromEnum(e.mode)))),
        }
    }

    pub const zxdg_toplevel_decoration_v1_Mode = zxdg.ToplevelDecorationV1.Mode;

    pub const WL_SEAT_CAPABILITY_POINTER: u32 = 1;
    pub const WL_SEAT_CAPABILITY_KEYBOARD: u32 = 2;
    pub const WL_POINTER_BUTTON_STATE_RELEASED = wl.Pointer.ButtonState.released;
    pub const WL_POINTER_BUTTON_STATE_PRESSED = wl.Pointer.ButtonState.pressed;
    pub const WL_POINTER_AXIS_VERTICAL_SCROLL = wl.Pointer.Axis.vertical_scroll;
    pub const WL_POINTER_AXIS_HORIZONTAL_SCROLL = wl.Pointer.Axis.horizontal_scroll;
    pub const WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1 = wl.Keyboard.KeymapFormat.xkb_v1;
    pub const WL_KEYBOARD_KEY_STATE_RELEASED = wl.Keyboard.KeyState.released;
    pub const WL_KEYBOARD_KEY_STATE_PRESSED = wl.Keyboard.KeyState.pressed;
    // The generated protocol enum leaves newer values open-ended, but the
    // protocol defines repeated as the value immediately after pressed.
    pub const WL_KEYBOARD_KEY_STATE_REPEATED: u32 = 2;
    pub const XDG_TOPLEVEL_STATE_MAXIMIZED = xdg.Toplevel.State.maximized;
    pub const XDG_TOPLEVEL_STATE_FULLSCREEN = xdg.Toplevel.State.fullscreen;
    pub const XDG_TOPLEVEL_STATE_ACTIVATED = xdg.Toplevel.State.activated;
    pub const ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE = zxdg.ToplevelDecorationV1.Mode.client_side;
    pub const ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE = zxdg.ToplevelDecorationV1.Mode.server_side;
};

pub const BackendRequest = common.BackendRequest;
pub const BackendKind = common.BackendKind;
pub const Environment = common.Environment;
pub const detectBackend = common.detectBackend;
pub const Size = common.Size;
pub const Point = common.Point;
pub const ContentScale = common.ContentScale;

pub const Action = input.Action;
pub const MouseButton = input.MouseButton;
pub const Modifiers = input.Modifiers;
pub const CursorShape = input.CursorShape;
pub const Key = input.Key;

/// Requested compositor titlebar/decorations policy.
pub const DecorationMode = enum {
    auto,
    server_side,
    client_side,
};

/// Initial and runtime window state.
pub const WindowState = enum {
    normal,
    maximize,
    fullscreen,
};

pub const Error = error{
    UnsupportedPlatform,
    BackendLibraryUnavailable,
    DisplayConnectionFailed,
    MissingRequiredGlobal,
    OutOfMemory,
    WaylandProtocolError,
    XkbInitFailed,
    SystemResources,
};

pub const InitOptions = struct {
    backend: BackendRequest = .auto,
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

const Output = struct {
    ctx: *State,
    name: u32,
    output: *c.wl_output,
    scale: i32 = 1,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    app_name: [:0]const u8,
    display: *c.wl_display,
    display_fd: c_int,
    wake_fd: std.posix.fd_t,

    registry: ?*c.wl_registry = null,
    compositor: ?*c.wl_compositor = null,
    decoration_manager: ?*c.zxdg_decoration_manager_v1 = null,
    cursor_shape_manager: ?*c.wp_cursor_shape_manager_v1 = null,
    cursor_shape_device: ?*c.wp_cursor_shape_device_v1 = null,
    wm_base: ?*c.xdg_wm_base = null,
    seat: ?*c.wl_seat = null,
    pointer: ?*c.wl_pointer = null,
    keyboard: ?*c.wl_keyboard = null,
    xkb_context: ?*c.xkb_context = null,
    xkb_keymap: ?*c.xkb_keymap = null,
    xkb_state: ?*c.xkb_state = null,
    repeat_delay: u32 = 0,
    repeat_rate: u32 = 0,

    outputs: std.ArrayListUnmanaged(*Output) = .empty,
    windows: std.ArrayListUnmanaged(*Window) = .empty,
    pointer_window: ?*Window = null,
    keyboard_window: ?*Window = null,
    event_error_reported: bool = false,

    pub fn init(allocator: std.mem.Allocator, options: InitOptions) Error!*State {
        return initWayland(allocator, options);
    }

    fn initWayland(allocator: std.mem.Allocator, options: InitOptions) Error!*State {
        wayland_ffi.ensureLoaded() catch |err| return mapLibraryLoadError(err);
        xkb.ensureLoaded() catch |err| return mapLibraryLoadError(err);

        const display = if (options.display_name) |name|
            c.wl_display_connect(name.ptr)
        else
            c.wl_display_connect(null);
        if (display == null) return error.DisplayConnectionFailed;

        const wake_raw = std.c.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
        if (wake_raw < 0) {
            c.wl_display_disconnect(display.?);
            return error.SystemResources;
        }
        const wake_fd: std.posix.fd_t = @intCast(wake_raw);

        const app_name = allocator.dupeZ(u8, options.app_name) catch {
            _ = std.os.linux.close(wake_fd);
            c.wl_display_disconnect(display.?);
            return error.OutOfMemory;
        };
        const self = allocator.create(State) catch {
            allocator.free(app_name);
            _ = std.os.linux.close(wake_fd);
            c.wl_display_disconnect(display.?);
            return error.OutOfMemory;
        };
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .app_name = app_name,
            .display = display.?,
            .display_fd = c.wl_display_get_fd(display.?),
            .wake_fd = wake_fd,
        };
        errdefer self.deinit();

        self.xkb_context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse return error.XkbInitFailed;

        self.registry = c.wl_display_get_registry(self.display);
        if (self.registry == null) return error.WaylandProtocolError;
        _ = c.wl_registry_add_listener(self.registry.?, &registryListener, self);

        if (c.wl_display_roundtrip(self.display) == -1) return error.WaylandProtocolError;
        if (self.compositor == null or self.wm_base == null) return error.MissingRequiredGlobal;

        return self;
    }

    fn mapLibraryLoadError(err: wayland_ffi.Error) Error {
        return switch (err) {
            error.LibraryNotFound, error.MissingSymbol => error.BackendLibraryUnavailable,
        };
    }

    pub fn deinit(self: *State) void {
        while (self.windows.items.len > 0) self.windows.items[self.windows.items.len - 1].deinit();
        self.windows.deinit(self.allocator);
        for (self.outputs.items) |output| {
            c.wl_output_destroy(output.output);
            self.allocator.destroy(output);
        }
        self.outputs.deinit(self.allocator);
        if (self.cursor_shape_device) |device| c.wp_cursor_shape_device_v1_destroy(device);
        if (self.keyboard) |keyboard| c.wl_keyboard_destroy(keyboard);
        if (self.pointer) |pointer| c.wl_pointer_destroy(pointer);
        if (self.seat) |seat| c.wl_seat_destroy(seat);
        if (self.decoration_manager) |manager| c.zxdg_decoration_manager_v1_destroy(manager);
        if (self.cursor_shape_manager) |manager| c.wp_cursor_shape_manager_v1_destroy(manager);
        if (self.wm_base) |wm_base| c.xdg_wm_base_destroy(wm_base);
        if (self.compositor) |compositor| c.wl_compositor_destroy(compositor);
        if (self.registry) |registry| c.wl_registry_destroy(registry);
        c.wl_display_disconnect(self.display);
        if (self.xkb_state) |state| c.xkb_state_unref(state);
        if (self.xkb_keymap) |keymap| c.xkb_keymap_unref(keymap);
        if (self.xkb_context) |ctx| c.xkb_context_unref(ctx);
        _ = std.os.linux.close(self.wake_fd);
        self.allocator.free(self.app_name);
        self.allocator.destroy(self);
    }

    pub fn nativeDisplay(self: *State) *anyopaque {
        return @ptrCast(self.display);
    }

    pub fn backendKind(_: *State) BackendKind {
        return .wayland;
    }

    pub fn requiredVulkanInstanceExtensions(_: *State) []const [*:0]const u8 {
        return &.{ "VK_KHR_surface", "VK_KHR_wayland_surface" };
    }

    pub fn createWindow(self: *State, options: WindowOptions) Error!*Window {
        return self.createWindowWayland(options);
    }

    fn createWindowWayland(self: *State, options: WindowOptions) Error!*Window {
        const surface = c.wl_compositor_create_surface(self.compositor.?) orelse return error.OutOfMemory;
        errdefer c.wl_surface_destroy(surface);

        const xdg_surface = c.xdg_wm_base_get_xdg_surface(self.wm_base.?, surface) orelse return error.OutOfMemory;
        errdefer c.xdg_surface_destroy(xdg_surface);

        const xdg_toplevel = c.xdg_surface_get_toplevel(xdg_surface) orelse return error.OutOfMemory;
        errdefer c.xdg_toplevel_destroy(xdg_toplevel);

        const window = try self.allocator.create(Window);
        errdefer self.allocator.destroy(window);

        const titlebar_mode: DecorationMode = switch (options.titlebar) {
            .auto => if (options.decorated) .server_side else .client_side,
            else => options.titlebar,
        };

        window.* = .{
            .ctx = self,
            .surface = surface,
            .xdg_surface = xdg_surface,
            .xdg_toplevel = xdg_toplevel,
            .size = options.size,
            .framebuffer_size = common.scaledSize(options.size, .{}),
            .content_scale = .{},
            .visible = options.visible,
            .resizable = options.resizable,
            .decorated = titlebar_mode == .server_side,
            .decoration_mode = titlebar_mode,
        };

        _ = c.wl_surface_add_listener(surface, &surfaceListener, window);
        _ = c.xdg_surface_add_listener(xdg_surface, &xdgSurfaceListener, window);
        _ = c.xdg_toplevel_add_listener(xdg_toplevel, &xdgToplevelListener, window);

        if (self.decoration_manager) |manager| {
            window.decoration = c.zxdg_decoration_manager_v1_get_toplevel_decoration(manager, xdg_toplevel) orelse return error.OutOfMemory;
            errdefer c.zxdg_toplevel_decoration_v1_destroy(window.decoration.?);
            _ = c.zxdg_toplevel_decoration_v1_add_listener(window.decoration.?, &decorationListener, window);
            c.zxdg_toplevel_decoration_v1_set_mode(window.decoration.?, switch (titlebar_mode) {
                .server_side => c.ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE,
                .client_side => c.ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE,
                .auto => unreachable,
            });
        }

        c.xdg_toplevel_set_title(xdg_toplevel, options.title.ptr);
        const app_id = if (options.app_id) |v| v else self.app_name;
        c.xdg_toplevel_set_app_id(xdg_toplevel, app_id.ptr);

        if (options.min_size) |min_size| {
            c.xdg_toplevel_set_min_size(xdg_toplevel, min_size.width, min_size.height);
        }
        if (options.max_size) |max_size| {
            c.xdg_toplevel_set_max_size(xdg_toplevel, max_size.width, max_size.height);
        }
        if (!options.resizable) {
            c.xdg_toplevel_set_min_size(xdg_toplevel, options.size.width, options.size.height);
            c.xdg_toplevel_set_max_size(xdg_toplevel, options.size.width, options.size.height);
        }
        if (!options.visible) {
            window.visible = false;
        }

        if (options.state != .normal) {
            window.setState(options.state);
        }

        try self.windows.append(self.allocator, window);
        errdefer _ = self.windows.pop();

        c.wl_surface_set_buffer_scale(surface, 1);
        c.wl_surface_commit(surface);
        if (c.wl_display_roundtrip(self.display) == -1) return error.WaylandProtocolError;

        return window;
    }

    pub fn pollEvents(self: *State) void {
        _ = self.pumpEvents(0) catch |err| {
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
        const timeout_ms: i32 = if (timeout_ns == std.math.maxInt(u64)) -1 else blk: {
            const ms = (timeout_ns + 999_999) / 1_000_000;
            break :blk @intCast(@min(ms, @as(u64, std.math.maxInt(i32))));
        };
        return self.pumpEvents(timeout_ms);
    }

    fn pumpEvents(self: *State, timeout_ms: i32) Error!bool {
        while (c.wl_display_prepare_read(self.display) != 0) {
            if (c.wl_display_dispatch_pending(self.display) == -1) return error.WaylandProtocolError;
        }

        const flush_blocked = try flushWayland(self);

        var display_events: i16 = std.posix.POLL.IN;
        if (flush_blocked) display_events |= std.posix.POLL.OUT;
        var fds = [_]std.posix.pollfd{
            .{ .fd = self.display_fd, .events = display_events, .revents = 0 },
            .{ .fd = self.wake_fd, .events = std.posix.POLL.IN, .revents = 0 },
        };

        const ready = std.posix.poll(fds[0..], timeout_ms) catch |err| switch (err) {
            error.SystemResources => return error.SystemResources,
            else => return error.WaylandProtocolError,
        };
        if (ready == 0) {
            c.wl_display_cancel_read(self.display);
            return false;
        }

        if ((fds[0].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL)) != 0) {
            c.wl_display_cancel_read(self.display);
            return error.WaylandProtocolError;
        }

        if ((fds[1].revents & std.posix.POLL.IN) != 0) {
            self.drainWakeFd();
        }

        if ((fds[0].revents & std.posix.POLL.IN) != 0) {
            if (c.wl_display_read_events(self.display) == -1) return error.WaylandProtocolError;
            if (c.wl_display_dispatch_pending(self.display) == -1) return error.WaylandProtocolError;
        } else {
            c.wl_display_cancel_read(self.display);
        }

        if (flush_blocked and (fds[0].revents & std.posix.POLL.OUT) != 0) {
            _ = try flushWayland(self);
        }

        return true;
    }

    fn flushWayland(self: *State) Error!bool {
        if (c.wl_display_flush(self.display) != -1) return false;
        if (@as(std.c.E, @enumFromInt(std.c._errno().*)) == .AGAIN) return true;
        return error.WaylandProtocolError;
    }

    pub fn wake(self: *State) void {
        const value: u64 = 1;
        _ = std.os.linux.write(self.wake_fd, @as([*]const u8, @ptrCast(std.mem.asBytes(&value).ptr)), @sizeOf(u64));
    }

    fn drainWakeFd(self: *State) void {
        var value: u64 = 0;
        _ = std.posix.read(self.wake_fd, std.mem.asBytes(&value)) catch {};
    }

    fn destroyWindow(self: *State, window: *Window) void {
        if (self.pointer_window == window) self.pointer_window = null;
        if (self.keyboard_window == window) self.keyboard_window = null;
        if (std.mem.indexOfScalar(*Window, self.windows.items, window)) |index| {
            _ = self.windows.swapRemove(index);
        }
        window.deinitNative();
        self.allocator.destroy(window);
    }

    fn updateOutputScale(self: *State, output: *Output) void {
        for (self.windows.items) |window| {
            if (window.current_output == output) {
                window.updateScale(@floatFromInt(output.scale));
            }
        }
    }

    fn removeOutput(self: *State, output: *Output) void {
        for (self.windows.items) |window| {
            if (window.current_output == output) {
                window.current_output = null;
                window.updateScale(1);
            }
        }

        if (std.mem.indexOfScalar(*Output, self.outputs.items, output)) |index| {
            _ = self.outputs.swapRemove(index);
        }
        c.wl_output_destroy(output.output);
        self.allocator.destroy(output);
    }

    fn currentModifiers(self: *State) Modifiers {
        const state = self.xkb_state orelse return .{};
        return .{
            .shift = c.xkb_state_mod_name_is_active(state, c.XKB_MOD_NAME_SHIFT, c.XKB_STATE_MODS_EFFECTIVE) != 0,
            .control = c.xkb_state_mod_name_is_active(state, c.XKB_MOD_NAME_CTRL, c.XKB_STATE_MODS_EFFECTIVE) != 0,
            .alt = c.xkb_state_mod_name_is_active(state, c.XKB_MOD_NAME_ALT, c.XKB_STATE_MODS_EFFECTIVE) != 0,
            .super = c.xkb_state_mod_name_is_active(state, c.XKB_MOD_NAME_LOGO, c.XKB_STATE_MODS_EFFECTIVE) != 0,
            .caps_lock = c.xkb_state_mod_name_is_active(state, c.XKB_MOD_NAME_CAPS, c.XKB_STATE_MODS_EFFECTIVE) != 0,
            .num_lock = c.xkb_state_mod_name_is_active(state, c.XKB_MOD_NAME_NUM, c.XKB_STATE_MODS_EFFECTIVE) != 0,
        };
    }

    fn updateKeymap(self: *State, fd: c_int, size: u32) void {
        defer _ = std.os.linux.close(@intCast(fd));
        if (size == 0) return;

        const len: usize = @intCast(size);
        const mapped = std.posix.mmap(
            null,
            len,
            .{ .READ = true },
            .{ .TYPE = .PRIVATE },
            @intCast(fd),
            0,
        ) catch return;
        defer std.posix.munmap(mapped);

        const keymap = c.xkb_keymap_new_from_buffer(
            self.xkb_context.?,
            @ptrCast(mapped.ptr),
            mapped.len,
            c.XKB_KEYMAP_FORMAT_TEXT_V1,
            c.XKB_KEYMAP_COMPILE_NO_FLAGS,
        ) orelse return;
        const state = c.xkb_state_new(keymap) orelse {
            c.xkb_keymap_unref(keymap);
            return;
        };

        if (self.xkb_state) |old| c.xkb_state_unref(old);
        if (self.xkb_keymap) |old| c.xkb_keymap_unref(old);
        self.xkb_keymap = keymap;
        self.xkb_state = state;
    }

    fn getWindowFromSurface(self: *State, surface: ?*c.wl_surface) ?*Window {
        const s = surface orelse return null;
        for (self.windows.items) |window| {
            if (window.surface == s) return window;
        }
        return null;
    }

    fn getOutputFromNative(self: *State, output: ?*c.wl_output) ?*Output {
        const o = output orelse return null;
        for (self.outputs.items) |item| {
            if (item.output == o) return item;
        }
        return null;
    }
};

pub const Context = struct {
    state: *State,

    pub fn init(allocator: std.mem.Allocator, options: InitOptions) Error!Context {
        return .{ .state = try State.init(allocator, options) };
    }

    pub fn deinit(self: *Context) void {
        const state = self.state;
        state.deinit();
        state.allocator.destroy(state);
        self.state = undefined;
    }

    pub fn nativeDisplay(self: *Context) *anyopaque {
        return self.state.nativeDisplay();
    }

    pub fn requiredVulkanInstanceExtensions(self: *Context) []const [*:0]const u8 {
        return self.state.requiredVulkanInstanceExtensions();
    }

    pub fn backendKind(self: *Context) BackendKind {
        return self.state.backendKind();
    }

    pub fn createWindow(self: *Context, options: WindowOptions) Error!*Window {
        return self.state.createWindow(options);
    }

    pub fn pollEvents(self: *Context) void {
        self.state.pollEvents();
    }

    pub fn waitEvents(self: *Context) Error!void {
        return self.state.waitEvents();
    }

    pub fn waitEventsTimeout(self: *Context, timeout_ns: u64) Error!bool {
        return self.state.waitEventsTimeout(timeout_ns);
    }

    pub fn wake(self: *Context) void {
        self.state.wake();
    }
};

pub const Window = struct {
    ctx: *State,
    surface: *c.wl_surface,
    xdg_surface: *c.xdg_surface,
    xdg_toplevel: *c.xdg_toplevel,

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
    decorated: bool = true,
    decoration_mode: DecorationMode = .auto,
    decoration: ?*c.zxdg_toplevel_decoration_v1 = null,
    cursor_visible: bool = true,
    cursor_shape: CursorShape = .arrow,

    size: Size,
    framebuffer_size: Size,
    content_scale: ContentScale = .{},
    cursor_pos: Point = .{ .x = 0, .y = 0 },

    pressed_keys: std.EnumSet(Key) = .empty,
    pressed_buttons: std.EnumSet(MouseButton) = .empty,

    pointer_serial: u32 = 0,
    current_output: ?*Output = null,
    configured: bool = false,

    pub fn deinit(self: *Window) void {
        self.ctx.destroyWindow(self);
    }

    fn deinitNative(self: *Window) void {
        if (self.ctx.pointer_window == self) self.ctx.pointer_window = null;
        if (self.ctx.keyboard_window == self) self.ctx.keyboard_window = null;
        if (self.decoration) |decoration| c.zxdg_toplevel_decoration_v1_destroy(decoration);
        c.xdg_toplevel_destroy(self.xdg_toplevel);
        c.xdg_surface_destroy(self.xdg_surface);
        c.wl_surface_destroy(self.surface);
    }

    pub fn nativeSurface(self: *Window) usize {
        return @intFromPtr(self.surface);
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

    pub fn setTitle(self: *Window, title: [:0]const u8) void {
        c.xdg_toplevel_set_title(self.xdg_toplevel, title.ptr);
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
    }

    pub fn hide(self: *Window) void {
        self.visible = false;
    }

    pub fn maximize(self: *Window) void {
        c.xdg_toplevel_unset_fullscreen(self.xdg_toplevel);
        c.xdg_toplevel_set_maximized(self.xdg_toplevel);
        self.maximized = true;
        self.fullscreen = false;
        self.minimized = false;
    }

    pub fn setFullscreen(self: *Window) void {
        c.xdg_toplevel_unset_maximized(self.xdg_toplevel);
        c.xdg_toplevel_set_fullscreen(self.xdg_toplevel, null);
        self.maximized = false;
        self.fullscreen = true;
        self.minimized = false;
    }

    pub fn restore(self: *Window) void {
        c.xdg_toplevel_unset_maximized(self.xdg_toplevel);
        c.xdg_toplevel_unset_fullscreen(self.xdg_toplevel);
        self.maximized = false;
        self.fullscreen = false;
        self.minimized = false;
    }

    pub fn iconify(self: *Window) void {
        c.xdg_toplevel_set_minimized(self.xdg_toplevel);
        self.minimized = true;
    }

    pub fn setMinSize(self: *Window, size: ?Size) void {
        if (size) |value| c.xdg_toplevel_set_min_size(self.xdg_toplevel, value.width, value.height) else c.xdg_toplevel_set_min_size(self.xdg_toplevel, -1, -1);
    }

    pub fn setMaxSize(self: *Window, size: ?Size) void {
        if (size) |value| c.xdg_toplevel_set_max_size(self.xdg_toplevel, value.width, value.height) else c.xdg_toplevel_set_max_size(self.xdg_toplevel, -1, -1);
    }

    pub fn setResizable(self: *Window, resizable: bool) void {
        self.resizable = resizable;
        if (resizable) {
            self.setMinSize(null);
            self.setMaxSize(null);
        } else {
            self.setMinSize(self.size);
            self.setMaxSize(self.size);
        }
    }

    pub fn setCursorVisible(self: *Window, visible: bool) void {
        self.cursor_visible = visible;
        if (self.ctx.pointer == null or self.ctx.pointer_window != self) return;
        if (!visible) {
            c.wl_pointer_set_cursor(self.ctx.pointer.?, self.pointer_serial, null, 0, 0);
            return;
        }
        self.applyCursor();
    }

    pub fn setCursor(self: *Window, shape: CursorShape) void {
        self.cursor_shape = shape;
        if (shape == .hidden) {
            self.setCursorVisible(false);
            return;
        }
        self.setCursorVisible(true);
        self.applyCursor();
    }

    fn applyCursor(self: *Window) void {
        if (self.ctx.pointer == null or self.ctx.pointer_window != self) return;
        if (!self.cursor_visible) {
            c.wl_pointer_set_cursor(self.ctx.pointer.?, self.pointer_serial, null, 0, 0);
            return;
        }
        if (self.ctx.cursor_shape_device) |device| {
            c.wp_cursor_shape_device_v1_set_shape(device, self.pointer_serial, waylandCursorShape(self.cursor_shape));
        }
    }

    fn updateScale(self: *Window, scale: f32) void {
        const new_scale: ContentScale = .{ .x = scale, .y = scale };
        if (new_scale.x == self.content_scale.x and new_scale.y == self.content_scale.y) return;
        self.content_scale = new_scale;
        const buffer_scale: c_int = @intFromFloat(@max(1.0, new_scale.x));
        c.wl_surface_set_buffer_scale(self.surface, buffer_scale);
        const old_fb = self.framebuffer_size;
        self.framebuffer_size = common.scaledSize(self.size, self.content_scale);
        if (self.callbacks.scale) |cb| cb(self, self.content_scale);
        if (old_fb.width != self.framebuffer_size.width or old_fb.height != self.framebuffer_size.height) {
            if (self.callbacks.framebuffer_resize) |cb| cb(self, self.framebuffer_size);
        }
    }

    fn updateSize(self: *Window, size: Size) void {
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

    fn updateCursorEnter(self: *Window, entered: bool) void {
        self.hovered = entered;
        if (self.callbacks.cursor_enter) |cb| cb(self, entered);
    }

    fn updateFocus(self: *Window, focused: bool) void {
        self.focused = focused;
        if (self.callbacks.focus) |cb| cb(self, focused);
    }

    fn updateClose(self: *Window) void {
        self.should_close = true;
        if (self.callbacks.close) |cb| cb(self);
    }

    fn updateCursorMotion(self: *Window, x: f64, y: f64) void {
        self.cursor_pos = .{ .x = x, .y = y };
        if (self.callbacks.cursor_motion) |cb| cb(self, self.cursor_pos);
    }

    fn updateMouseButton(self: *Window, button: MouseButton, action: Action, mods: Modifiers) void {
        switch (action) {
            .press => _ = self.pressed_buttons.insert(button),
            .release => _ = self.pressed_buttons.remove(button),
            .repeat => {},
        }
        if (self.callbacks.mouse_button) |cb| cb(self, button, action, mods);
    }

    fn updateScroll(self: *Window, x: f64, y: f64) void {
        if (self.callbacks.scroll) |cb| cb(self, x, y);
    }

    fn updateKey(self: *Window, key: Key, raw_keycode: u32, action: Action, mods: Modifiers) void {
        switch (action) {
            .press => _ = self.pressed_keys.insert(key),
            .release => _ = self.pressed_keys.remove(key),
            .repeat => {},
        }
        if (self.callbacks.key) |cb| cb(self, key, raw_keycode, action, mods);
    }

    fn updateText(self: *Window, bytes: []const u8) void {
        if (self.callbacks.text) |cb| cb(self, bytes);
    }

    fn updateStateFromConfigure(self: *Window, width: i32, height: i32, states: ?*c.wl_array) void {
        const new_size: Size = .{
            .width = if (width > 0) width else self.size.width,
            .height = if (height > 0) height else self.size.height,
        };
        self.updateSize(new_size);

        self.maximized = false;
        self.fullscreen = false;
        self.focused = false;

        if (states) |array| {
            const count = array.size / @sizeOf(u32);
            const items = @as([*]const u32, @ptrCast(@alignCast(array.data)));
            for (items[0..count]) |state| {
                switch (state) {
                    @as(u32, @intCast(@intFromEnum(c.XDG_TOPLEVEL_STATE_MAXIMIZED))) => self.maximized = true,
                    @as(u32, @intCast(@intFromEnum(c.XDG_TOPLEVEL_STATE_FULLSCREEN))) => self.fullscreen = true,
                    @as(u32, @intCast(@intFromEnum(c.XDG_TOPLEVEL_STATE_ACTIVATED))) => self.focused = true,
                    else => {},
                }
            }
        }
    }
};

fn waylandCursorShape(shape: CursorShape) c.wp_cursor_shape_device_v1_Shape {
    return switch (shape) {
        .arrow => .default,
        .crosshair => .crosshair,
        .hand => .pointer,
        .ibeam => .text,
        .not_allowed => .not_allowed,
        .resize_all => .move,
        .resize_ns => .ns_resize,
        .resize_ew => .ew_resize,
        .resize_nesw => .nesw_resize,
        .resize_nwse => .nwse_resize,
        .hidden => .default,
    };
}

fn mapKeysymToKey(sym: c.xkb_keysym_t) Key {
    if (sym >= 'a' and sym <= 'z') {
        return @enumFromInt(@as(u16, @intCast(@intFromEnum(Key.a))) + @as(u16, @intCast(sym - 'a')));
    }
    if (sym >= 'A' and sym <= 'Z') {
        return @enumFromInt(@as(u16, @intCast(@intFromEnum(Key.a))) + @as(u16, @intCast(sym - 'A')));
    }
    if (sym >= '0' and sym <= '9') {
        return @enumFromInt(@as(u16, @intCast(@intFromEnum(Key.zero))) + @as(u16, @intCast(sym - '0')));
    }

    return switch (sym) {
        c.XKB_KEY_F1 => .f1,
        c.XKB_KEY_F2 => .f2,
        c.XKB_KEY_F3 => .f3,
        c.XKB_KEY_F4 => .f4,
        c.XKB_KEY_F5 => .f5,
        c.XKB_KEY_F6 => .f6,
        c.XKB_KEY_F7 => .f7,
        c.XKB_KEY_F8 => .f8,
        c.XKB_KEY_F9 => .f9,
        c.XKB_KEY_F10 => .f10,
        c.XKB_KEY_F11 => .f11,
        c.XKB_KEY_F12 => .f12,
        c.XKB_KEY_F13 => .f13,
        c.XKB_KEY_F14 => .f14,
        c.XKB_KEY_F15 => .f15,
        c.XKB_KEY_F16 => .f16,
        c.XKB_KEY_F17 => .f17,
        c.XKB_KEY_F18 => .f18,
        c.XKB_KEY_F19 => .f19,
        c.XKB_KEY_F20 => .f20,
        c.XKB_KEY_F21 => .f21,
        c.XKB_KEY_F22 => .f22,
        c.XKB_KEY_F23 => .f23,
        c.XKB_KEY_F24 => .f24,
        c.XKB_KEY_F25 => .f25,
        c.XKB_KEY_KP_Divide => .kp_divide,
        c.XKB_KEY_KP_Multiply => .kp_multiply,
        c.XKB_KEY_KP_Subtract => .kp_subtract,
        c.XKB_KEY_KP_Add => .kp_add,
        c.XKB_KEY_KP_0 => .kp_0,
        c.XKB_KEY_KP_1 => .kp_1,
        c.XKB_KEY_KP_2 => .kp_2,
        c.XKB_KEY_KP_3 => .kp_3,
        c.XKB_KEY_KP_4 => .kp_4,
        c.XKB_KEY_KP_5 => .kp_5,
        c.XKB_KEY_KP_6 => .kp_6,
        c.XKB_KEY_KP_7 => .kp_7,
        c.XKB_KEY_KP_8 => .kp_8,
        c.XKB_KEY_KP_9 => .kp_9,
        c.XKB_KEY_KP_Decimal => .kp_decimal,
        c.XKB_KEY_KP_Equal => .kp_equal,
        c.XKB_KEY_KP_Enter => .kp_enter,
        c.XKB_KEY_Return => .enter,
        c.XKB_KEY_Escape => .escape,
        c.XKB_KEY_Tab => .tab,
        c.XKB_KEY_Shift_L => .left_shift,
        c.XKB_KEY_Shift_R => .right_shift,
        c.XKB_KEY_Control_L => .left_control,
        c.XKB_KEY_Control_R => .right_control,
        c.XKB_KEY_Alt_L => .left_alt,
        c.XKB_KEY_Alt_R => .right_alt,
        c.XKB_KEY_Super_L => .left_command,
        c.XKB_KEY_Super_R => .right_command,
        c.XKB_KEY_Menu => .menu,
        c.XKB_KEY_Num_Lock => .num_lock,
        c.XKB_KEY_Caps_Lock => .caps_lock,
        c.XKB_KEY_Print => .print,
        c.XKB_KEY_Scroll_Lock => .scroll_lock,
        c.XKB_KEY_Pause => .pause,
        c.XKB_KEY_Delete => .delete,
        c.XKB_KEY_Home => .home,
        c.XKB_KEY_End => .end,
        c.XKB_KEY_Page_Up => .page_up,
        c.XKB_KEY_Page_Down => .page_down,
        c.XKB_KEY_Insert => .insert,
        c.XKB_KEY_Left => .left,
        c.XKB_KEY_Right => .right,
        c.XKB_KEY_Up => .up,
        c.XKB_KEY_Down => .down,
        c.XKB_KEY_BackSpace => .backspace,
        c.XKB_KEY_space => .space,
        c.XKB_KEY_minus => .minus,
        c.XKB_KEY_equal => .equal,
        c.XKB_KEY_bracketleft => .left_bracket,
        c.XKB_KEY_bracketright => .right_bracket,
        c.XKB_KEY_backslash => .backslash,
        c.XKB_KEY_semicolon => .semicolon,
        c.XKB_KEY_apostrophe => .apostrophe,
        c.XKB_KEY_comma => .comma,
        c.XKB_KEY_period => .period,
        c.XKB_KEY_slash => .slash,
        c.XKB_KEY_grave => .grave,
        else => .unknown,
    };
}

fn registryGlobal(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
    _ = registry;
    const self = @as(*State, @ptrCast(@alignCast(data.?)));
    const iface = std.mem.span(interface);

    if (std.mem.eql(u8, iface, "wl_compositor")) {
        self.compositor = self.registry.?.bind(name, c.wl_compositor, @min(version, 5)) catch return;
        return;
    }
    if (std.mem.eql(u8, iface, "zxdg_decoration_manager_v1")) {
        self.decoration_manager = self.registry.?.bind(name, c.zxdg_decoration_manager_v1, @min(version, 1)) catch return;
        return;
    }
    if (std.mem.eql(u8, iface, "wp_cursor_shape_manager_v1")) {
        self.cursor_shape_manager = self.registry.?.bind(name, c.wp_cursor_shape_manager_v1, @min(version, 1)) catch return;
        if (self.pointer) |pointer| {
            self.cursor_shape_device = c.wp_cursor_shape_manager_v1_get_pointer(self.cursor_shape_manager.?, pointer);
        }
        return;
    }
    if (std.mem.eql(u8, iface, "xdg_wm_base")) {
        self.wm_base = self.registry.?.bind(name, c.xdg_wm_base, @min(version, 1)) catch return;
        _ = c.xdg_wm_base_add_listener(self.wm_base.?, &wmBaseListener, self);
        return;
    }
    if (std.mem.eql(u8, iface, "wl_seat")) {
        self.seat = self.registry.?.bind(name, c.wl_seat, @min(version, 5)) catch return;
        _ = c.wl_seat_add_listener(self.seat.?, &seatListener, self);
        return;
    }
    if (std.mem.eql(u8, iface, "wl_output")) {
        const native = self.registry.?.bind(name, c.wl_output, @min(version, 4)) catch return;
        const output = self.allocator.create(Output) catch {
            c.wl_output_destroy(native);
            return;
        };
        output.* = .{ .ctx = self, .name = name, .output = native };
        _ = c.wl_output_add_listener(output.output, &outputListener, output);
        self.outputs.append(self.allocator, output) catch {
            c.wl_output_destroy(output.output);
            self.allocator.destroy(output);
            return;
        };
        return;
    }
}

fn registryRemove(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32) callconv(.c) void {
    _ = registry;
    const self = @as(*State, @ptrCast(@alignCast(data.?)));
    for (self.outputs.items) |output| {
        if (output.name == name) {
            self.removeOutput(output);
            return;
        }
    }
}

fn wmBasePing(data: ?*anyopaque, wm_base: ?*c.xdg_wm_base, serial: u32) callconv(.c) void {
    const self = @as(*State, @ptrCast(@alignCast(data.?)));
    _ = self;
    c.xdg_wm_base_pong(wm_base.?, serial);
}

fn seatCapabilities(data: ?*anyopaque, seat: ?*c.wl_seat, capabilities: c_uint) callconv(.c) void {
    const self = @as(*State, @ptrCast(@alignCast(data.?)));
    const has_pointer = (capabilities & c.WL_SEAT_CAPABILITY_POINTER) != 0;
    const has_keyboard = (capabilities & c.WL_SEAT_CAPABILITY_KEYBOARD) != 0;

    if (has_pointer and self.pointer == null) {
        self.pointer = c.wl_seat_get_pointer(seat.?) orelse return;
        _ = c.wl_pointer_add_listener(self.pointer.?, &pointerListener, self);
        if (self.cursor_shape_manager) |manager| {
            self.cursor_shape_device = c.wp_cursor_shape_manager_v1_get_pointer(manager, self.pointer.?);
        }
    } else if (!has_pointer) {
        if (self.pointer) |pointer| {
            if (self.pointer_window) |window| {
                window.updateCursorEnter(false);
            }
            c.wl_pointer_destroy(pointer);
            self.pointer = null;
            self.pointer_window = null;
        }
        if (self.cursor_shape_device) |device| {
            c.wp_cursor_shape_device_v1_destroy(device);
            self.cursor_shape_device = null;
        }
    }

    if (has_keyboard and self.keyboard == null) {
        self.keyboard = c.wl_seat_get_keyboard(seat.?) orelse return;
        _ = c.wl_keyboard_add_listener(self.keyboard.?, &keyboardListener, self);
    } else if (!has_keyboard) {
        if (self.keyboard) |keyboard| {
            if (self.keyboard_window) |window| {
                window.updateFocus(false);
            }
            c.wl_keyboard_destroy(keyboard);
            self.keyboard = null;
            self.keyboard_window = null;
        }
    }
}

fn pointerEnter(data: ?*anyopaque, pointer: ?*c.wl_pointer, serial: u32, surface: ?*c.wl_surface, sx: c.wl_fixed_t, sy: c.wl_fixed_t) callconv(.c) void {
    const self = @as(*State, @ptrCast(@alignCast(data.?)));
    _ = pointer;
    _ = sx;
    _ = sy;
    const window = self.getWindowFromSurface(surface) orelse return;
    self.pointer_window = window;
    window.pointer_serial = serial;
    window.updateCursorEnter(true);
    window.applyCursor();
}

fn pointerLeave(data: ?*anyopaque, pointer: ?*c.wl_pointer, serial: u32, surface: ?*c.wl_surface) callconv(.c) void {
    const self = @as(*State, @ptrCast(@alignCast(data.?)));
    _ = pointer;
    _ = serial;
    _ = surface;
    if (self.pointer_window) |window| {
        window.updateCursorEnter(false);
    }
    self.pointer_window = null;
}

fn pointerMotion(data: ?*anyopaque, pointer: ?*c.wl_pointer, time: u32, sx: c.wl_fixed_t, sy: c.wl_fixed_t) callconv(.c) void {
    _ = pointer;
    _ = time;
    const self = @as(*State, @ptrCast(@alignCast(data.?)));
    if (self.pointer_window) |window| {
        window.updateCursorMotion(sx.toDouble(), sy.toDouble());
    }
}

fn pointerButton(data: ?*anyopaque, pointer: ?*c.wl_pointer, serial: u32, time: u32, button: u32, state: c_uint) callconv(.c) void {
    _ = pointer;
    _ = serial;
    _ = time;
    const self = @as(*State, @ptrCast(@alignCast(data.?)));
    const window = self.pointer_window orelse return;
    const btn = switch (button) {
        0x110 => MouseButton.left,
        0x111 => MouseButton.right,
        0x112 => MouseButton.middle,
        0x113 => MouseButton.four,
        0x114 => MouseButton.five,
        0x115 => MouseButton.six,
        0x116 => MouseButton.seven,
        0x117 => MouseButton.eight,
        else => return,
    };
    const action: Action = if (state == @as(c_uint, @intCast(@intFromEnum(c.WL_POINTER_BUTTON_STATE_PRESSED)))) .press else .release;
    window.updateMouseButton(btn, action, self.currentModifiers());
}

fn pointerAxis(data: ?*anyopaque, pointer: ?*c.wl_pointer, time: u32, axis: u32, value: c.wl_fixed_t) callconv(.c) void {
    _ = pointer;
    _ = time;
    const self = @as(*State, @ptrCast(@alignCast(data.?)));
    const window = self.pointer_window orelse return;
    if (axis == @as(u32, @intCast(@intFromEnum(c.WL_POINTER_AXIS_VERTICAL_SCROLL)))) {
        window.updateScroll(0, -value.toDouble());
    } else if (axis == @as(u32, @intCast(@intFromEnum(c.WL_POINTER_AXIS_HORIZONTAL_SCROLL)))) {
        window.updateScroll(-value.toDouble(), 0);
    }
}

fn keyboardKeymap(data: ?*anyopaque, keyboard: ?*c.wl_keyboard, format: u32, fd: c_int, size: u32) callconv(.c) void {
    _ = keyboard;
    const self = @as(*State, @ptrCast(@alignCast(data.?)));
    if (format != @as(u32, @intCast(@intFromEnum(c.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1)))) {
        _ = std.os.linux.close(@intCast(fd));
        return;
    }
    self.updateKeymap(fd, size);
}

fn keyboardEnter(data: ?*anyopaque, keyboard: ?*c.wl_keyboard, serial: u32, surface: ?*c.wl_surface, keys: [*c]c.wl_array) callconv(.c) void {
    _ = keyboard;
    _ = serial;
    _ = keys;
    const self = @as(*State, @ptrCast(@alignCast(data.?)));
    const window = self.getWindowFromSurface(surface) orelse return;
    self.keyboard_window = window;
    window.updateFocus(true);
}

fn keyboardLeave(data: ?*anyopaque, keyboard: ?*c.wl_keyboard, serial: u32, surface: ?*c.wl_surface) callconv(.c) void {
    _ = keyboard;
    _ = serial;
    _ = surface;
    const self = @as(*State, @ptrCast(@alignCast(data.?)));
    if (self.keyboard_window) |window| {
        window.updateFocus(false);
    }
    self.keyboard_window = null;
}

fn keyboardKey(data: ?*anyopaque, keyboard: ?*c.wl_keyboard, serial: u32, time: u32, key: u32, state: u32) callconv(.c) void {
    _ = keyboard;
    _ = serial;
    _ = time;
    const self = @as(*State, @ptrCast(@alignCast(data.?)));
    const window = self.keyboard_window orelse return;
    const xkb_state = self.xkb_state orelse return;
    const sym = c.xkb_state_key_get_one_sym(xkb_state, key + 8);
    const action: Action = switch (state) {
        @as(u32, @intCast(@intFromEnum(c.WL_KEYBOARD_KEY_STATE_RELEASED))) => .release,
        @as(u32, @intCast(@intFromEnum(c.WL_KEYBOARD_KEY_STATE_PRESSED))) => .press,
        c.WL_KEYBOARD_KEY_STATE_REPEATED => .repeat,
        else => return,
    };
    const mods = self.currentModifiers();
    window.updateKey(mapKeysymToKey(sym), key, action, mods);

    if (action != .release and !mods.control) {
        var buf: [64]u8 = undefined;
        const len = c.xkb_state_key_get_utf8(xkb_state, key + 8, &buf, buf.len);
        if (len > 0) {
            const text: []const u8 = buf[0..@intCast(len)];
            if (input.isPrintableText(text)) window.updateText(text);
        }
    }
}

fn keyboardModifiers(data: ?*anyopaque, keyboard: ?*c.wl_keyboard, serial: u32, mods_depressed: u32, mods_latched: u32, mods_locked: u32, group: u32) callconv(.c) void {
    _ = keyboard;
    _ = serial;
    const self = @as(*State, @ptrCast(@alignCast(data.?)));
    const state = self.xkb_state orelse return;
    _ = c.xkb_state_update_mask(state, mods_depressed, mods_latched, mods_locked, 0, 0, group);
}

fn keyboardRepeatInfo(data: ?*anyopaque, keyboard: ?*c.wl_keyboard, rate: i32, delay: i32) callconv(.c) void {
    _ = keyboard;
    const self = @as(*State, @ptrCast(@alignCast(data.?)));
    self.repeat_rate = if (rate > 0) @intCast(rate) else 0;
    self.repeat_delay = if (delay > 0) @intCast(delay) else 0;
}

fn surfaceEnter(data: ?*anyopaque, surface: ?*c.wl_surface, output: ?*c.wl_output) callconv(.c) void {
    const window = @as(*Window, @ptrCast(@alignCast(data.?)));
    _ = surface;
    const out = window.ctx.getOutputFromNative(output) orelse return;
    window.current_output = out;
    window.updateScale(@floatFromInt(out.scale));
}

fn surfaceLeave(data: ?*anyopaque, surface: ?*c.wl_surface, output: ?*c.wl_output) callconv(.c) void {
    _ = surface;
    const window = @as(*Window, @ptrCast(@alignCast(data.?)));
    const out = window.ctx.getOutputFromNative(output) orelse return;
    if (window.current_output == out) {
        window.current_output = null;
        window.updateScale(1);
    }
}

fn outputScale(data: ?*anyopaque, output: ?*c.wl_output, factor: i32) callconv(.c) void {
    const out = @as(*Output, @ptrCast(@alignCast(data.?)));
    out.scale = if (factor > 0) factor else 1;
    _ = output;
    out.ctx.updateOutputScale(out);
}

fn xdgSurfaceConfigure(data: ?*anyopaque, xdg_surface: ?*c.xdg_surface, serial: u32) callconv(.c) void {
    const window = @as(*Window, @ptrCast(@alignCast(data.?)));
    c.xdg_surface_ack_configure(xdg_surface.?, serial);
    window.configured = true;
}

fn xdgToplevelConfigure(data: ?*anyopaque, xdg_toplevel: ?*c.xdg_toplevel, width: i32, height: i32, states: ?*c.wl_array) callconv(.c) void {
    _ = xdg_toplevel;
    const window = @as(*Window, @ptrCast(@alignCast(data.?)));
    window.updateStateFromConfigure(width, height, states);
}

fn xdgToplevelClose(data: ?*anyopaque, xdg_toplevel: ?*c.xdg_toplevel) callconv(.c) void {
    _ = xdg_toplevel;
    const window = @as(*Window, @ptrCast(@alignCast(data.?)));
    window.updateClose();
}

fn decorationConfigure(data: ?*anyopaque, decoration: ?*c.zxdg_toplevel_decoration_v1, mode: u32) callconv(.c) void {
    _ = decoration;
    const window = @as(*Window, @ptrCast(@alignCast(data.?)));
    switch (mode) {
        @as(u32, @intCast(@intFromEnum(c.ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE))) => {
            window.decoration_mode = .server_side;
            window.decorated = true;
        },
        @as(u32, @intCast(@intFromEnum(c.ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE))) => {
            window.decoration_mode = .client_side;
            window.decorated = false;
        },
        else => {},
    }
}

const registryListener = c.wl_registry_listener{
    .global = registryGlobal,
    .global_remove = registryRemove,
};

const wmBaseListener = c.xdg_wm_base_listener{
    .ping = wmBasePing,
};

const seatListener = c.wl_seat_listener{
    .capabilities = seatCapabilities,
};

const pointerListener = c.wl_pointer_listener{
    .enter = pointerEnter,
    .leave = pointerLeave,
    .motion = pointerMotion,
    .button = pointerButton,
    .axis = pointerAxis,
};

const keyboardListener = c.wl_keyboard_listener{
    .keymap = keyboardKeymap,
    .enter = keyboardEnter,
    .leave = keyboardLeave,
    .key = keyboardKey,
    .modifiers = keyboardModifiers,
    .repeat_info = keyboardRepeatInfo,
};

const surfaceListener = c.wl_surface_listener{
    .enter = surfaceEnter,
    .leave = surfaceLeave,
};

const outputListener = c.wl_output_listener{
    .scale = outputScale,
};

const xdgSurfaceListener = c.xdg_surface_listener{
    .configure = xdgSurfaceConfigure,
};

const xdgToplevelListener = c.xdg_toplevel_listener{
    .configure = xdgToplevelConfigure,
    .close = xdgToplevelClose,
};

const decorationListener = c.zxdg_toplevel_decoration_v1_listener{
    .configure = decorationConfigure,
};

test {
    std.testing.refAllDecls(@This());
}
