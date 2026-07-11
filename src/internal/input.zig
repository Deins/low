const std = @import("std");

pub const Action = enum {
    release,
    press,
    repeat,
};

pub const MouseButton = enum {
    left,
    right,
    middle,
    four,
    five,
    six,
    seven,
    eight,
};

pub const Modifiers = packed struct {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    super: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
};

/// Keyboard text callbacks carry text input, not the control bytes generated
/// by keys such as Backspace, Enter, and Tab.  Those keys are delivered by the
/// key callback instead.
pub fn isPrintableText(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    for (bytes) |byte| {
        if (byte < 0x20 or byte == 0x7f) return false;
    }
    return true;
}

test "control bytes are not text input" {
    try std.testing.expect(isPrintableText("a"));
    try std.testing.expect(isPrintableText("ä"));
    try std.testing.expect(!isPrintableText("\x08"));
    try std.testing.expect(!isPrintableText("\x01"));
    try std.testing.expect(!isPrintableText("\x7f"));
}

pub const CursorShape = enum {
    arrow,
    crosshair,
    hand,
    ibeam,
    hidden,
    not_allowed,
    resize_all,
    resize_ns,
    resize_ew,
    resize_nesw,
    resize_nwse,
};

pub const Key = enum(u16) {
    unknown = 0,

    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,

    zero,
    one,
    two,
    three,
    four,
    five,
    six,
    seven,
    eight,
    nine,

    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    f13,
    f14,
    f15,
    f16,
    f17,
    f18,
    f19,
    f20,
    f21,
    f22,
    f23,
    f24,
    f25,

    kp_divide,
    kp_multiply,
    kp_subtract,
    kp_add,
    kp_0,
    kp_1,
    kp_2,
    kp_3,
    kp_4,
    kp_5,
    kp_6,
    kp_7,
    kp_8,
    kp_9,
    kp_decimal,
    kp_equal,
    kp_enter,

    enter,
    escape,
    tab,
    left_shift,
    right_shift,
    left_control,
    right_control,
    left_alt,
    right_alt,
    left_command,
    right_command,
    menu,
    num_lock,
    caps_lock,
    print,
    scroll_lock,
    pause,
    delete,
    home,
    end,
    page_up,
    page_down,
    insert,
    left,
    right,
    up,
    down,
    backspace,
    space,
    minus,
    equal,
    left_bracket,
    right_bracket,
    backslash,
    semicolon,
    apostrophe,
    comma,
    period,
    slash,
    grave,
};
