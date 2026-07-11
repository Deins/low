//! Small, process-lifetime dynamic-library helper for optional Linux desktop
//! backends.  Keeping a successfully opened library alive avoids invalidating
//! function pointers held by the generated Wayland bindings or live windows.
const std = @import("std");

pub const Error = error{
    LibraryNotFound,
    MissingSymbol,
};

pub fn openAny(comptime names: []const []const u8) Error!std.DynLib {
    inline for (names) |name| {
        if (std.DynLib.open(name)) |library| return library else |_| {}
    }
    return error.LibraryNotFound;
}

pub fn lookup(library: *std.DynLib, comptime T: type, comptime name: [:0]const u8) Error!T {
    return library.lookup(T, name) orelse error.MissingSymbol;
}
