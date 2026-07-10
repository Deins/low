pub const c = @cImport({
    @cDefine("XKB_COMMON_NO_DEPRECATED", "1");
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xutil.h");
    @cInclude("X11/Xatom.h");
    @cInclude("X11/XKBlib.h");
    @cInclude("X11/cursorfont.h");
    @cInclude("X11/keysym.h");
});

pub const Atoms = struct {
    wm_delete_window: c.Atom = 0,
    wm_protocols: c.Atom = 0,
    net_wm_state: c.Atom = 0,
    net_wm_state_fullscreen: c.Atom = 0,
    net_wm_state_maximized_horz: c.Atom = 0,
    net_wm_state_maximized_vert: c.Atom = 0,
    net_wm_name: c.Atom = 0,
    utf8_string: c.Atom = 0,
    net_wm_window_type: c.Atom = 0,
    net_wm_window_type_normal: c.Atom = 0,
    motif_wm_hints: c.Atom = 0,
};
