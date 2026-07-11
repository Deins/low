const std = @import("std");
const runtime = @import("internal/runtime.zig");

pub const Context = runtime.Context(@This());
pub const Window = runtime.Window;

pub fn initState(_: std.mem.Allocator, _: runtime.InitOptions) runtime.Error!*runtime.State {
    return error.UnsupportedPlatform;
}

test {
    std.testing.refAllDecls(@This());
}
