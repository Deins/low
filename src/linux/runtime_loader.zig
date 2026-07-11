//! Small, process-lifetime dynamic-library helper for optional Linux desktop
//! backends.  Keeping a successfully opened library alive avoids invalidating
//! function pointers held by the generated Wayland bindings or live windows.
const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{
    LibraryNotFound,
    MissingSymbol,
    StaticExecutableUnsupported,
};

pub fn openAny(comptime names: []const []const u8) Error!std.DynLib {
    // A static Linux executable cannot reliably load ordinary shared desktop
    // libraries: musl has no usable runtime loader in this mode, and glibc
    // still needs a matching dynamic loader and dependency graph. Do not let
    // std.DynLib's limited static ELF path produce callable-but-unrelocated
    // function pointers.
    if (comptime builtin.target.os.tag == .linux and builtin.link_mode == .static) {
        return error.StaticExecutableUnsupported;
    }

    inline for (names) |name| {
        if (std.DynLib.open(name)) |library| return library else |_| {}
    }
    return error.LibraryNotFound;
}

pub fn lookup(library: *std.DynLib, comptime T: type, comptime name: [:0]const u8) Error!T {
    return library.lookup(T, name) orelse error.MissingSymbol;
}

test "static Linux executable rejects runtime loading" {
    if (comptime builtin.target.os.tag == .linux and builtin.link_mode == .static) {
        try std.testing.expectError(error.StaticExecutableUnsupported, openAny(&.{"libdoes-not-matter.so"}));
    }
}
