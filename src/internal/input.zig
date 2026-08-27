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
    left_shift: bool = false,
    right_shift: bool = false,
    left_control: bool = false,
    right_control: bool = false,
    left_alt: bool = false,
    right_alt: bool = false,
    left_super: bool = false,
    right_super: bool = false,
};

/// Updates the physical side represented by a modifier key. Aggregate fields
/// remain backend-owned because layouts can activate them through mechanisms
/// such as AltGr and latched modifiers.
pub fn setModifierSide(mods: *Modifiers, key: Key, active: bool) void {
    switch (key) {
        .left_shift => mods.left_shift = active,
        .right_shift => mods.right_shift = active,
        .left_control => mods.left_control = active,
        .right_control => mods.right_control = active,
        .left_alt => mods.left_alt = active,
        .right_alt => mods.right_alt = active,
        .left_command => mods.left_super = active,
        .right_command => mods.right_super = active,
        else => {},
    }
}

pub fn clearModifierSides(mods: *Modifiers) void {
    mods.left_shift = false;
    mods.right_shift = false;
    mods.left_control = false;
    mods.right_control = false;
    mods.left_alt = false;
    mods.right_alt = false;
    mods.left_super = false;
    mods.right_super = false;
}

/// Correct the aggregate whose key event precedes the platform's aggregate
/// modifier update. Side state already reflects the key transition.
pub fn modifiersAfterKeyTransition(mods_before: Modifiers, sides: Modifiers, key: Key) Modifiers {
    var mods = mods_before;
    switch (key) {
        .left_shift, .right_shift => mods.shift = sides.left_shift or sides.right_shift,
        .left_control, .right_control => mods.control = sides.left_control or sides.right_control,
        .left_alt, .right_alt => mods.alt = sides.left_alt or sides.right_alt,
        .left_command, .right_command => mods.super = sides.left_super or sides.right_super,
        else => {},
    }
    return mods;
}

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

test "modifier side helpers preserve aggregate state" {
    var mods: Modifiers = .{ .shift = true, .control = true };
    setModifierSide(&mods, .right_shift, true);
    setModifierSide(&mods, .left_alt, true);
    try std.testing.expect(mods.right_shift);
    try std.testing.expect(mods.left_alt);
    try std.testing.expect(mods.shift);
    try std.testing.expect(mods.control);
    clearModifierSides(&mods);
    try std.testing.expect(!mods.right_shift);
    try std.testing.expect(!mods.left_alt);
    try std.testing.expect(mods.shift);
    try std.testing.expect(mods.control);
}

test "modifier transition replaces the stale aggregate for its key" {
    const released = modifiersAfterKeyTransition(.{ .shift = true }, .{}, .left_shift);
    try std.testing.expect(!released.shift);

    const other_side_held = modifiersAfterKeyTransition(
        .{ .shift = true },
        .{ .right_shift = true },
        .left_shift,
    );
    try std.testing.expect(other_side_held.shift);
}

pub const CursorShape = enum {
    arrow,
    crosshair,
    hand,
    ibeam,
    wait,
    progress,
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
