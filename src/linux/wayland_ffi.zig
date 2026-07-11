//! Runtime implementation of the libwayland-client FFI expected by
//! zig-wayland's scanner `ffi_import` option.
const std = @import("std");
const runtime = @import("runtime_loader");
const wayland = @import("wayland");

const wl = wayland.client.wl;
const Argument = wl.Argument;
const Interface = wl.Interface;

pub const Error = runtime.Error;

const WlDisplayCancelReadFn = *const fn (*wl.Display) callconv(.c) void;
const WlDisplayConnectToFdFn = *const fn (c_int) callconv(.c) ?*wl.Display;
const WlDisplayConnectFn = *const fn (?[*:0]const u8) callconv(.c) ?*wl.Display;
const WlDisplayCreateQueueFn = *const fn (*wl.Display) callconv(.c) ?*wl.EventQueue;
const WlDisplayDisconnectFn = *const fn (*wl.Display) callconv(.c) void;
const WlDisplayDispatchPendingFn = *const fn (*wl.Display) callconv(.c) c_int;
const WlDisplayDispatchQueuePendingFn = *const fn (*wl.Display, *wl.EventQueue) callconv(.c) c_int;
const WlDisplayDispatchQueueFn = *const fn (*wl.Display, *wl.EventQueue) callconv(.c) c_int;
const WlDisplayDispatchFn = *const fn (*wl.Display) callconv(.c) c_int;
const WlDisplayFlushFn = *const fn (*wl.Display) callconv(.c) c_int;
const WlDisplayGetErrorFn = *const fn (*wl.Display) callconv(.c) c_int;
const WlDisplayGetFdFn = *const fn (*wl.Display) callconv(.c) c_int;
const WlDisplayPrepareReadQueueFn = *const fn (*wl.Display, *wl.EventQueue) callconv(.c) c_int;
const WlDisplayPrepareReadFn = *const fn (*wl.Display) callconv(.c) c_int;
const WlDisplayReadEventsFn = *const fn (*wl.Display) callconv(.c) c_int;
const WlDisplayRoundtripQueueFn = *const fn (*wl.Display, *wl.EventQueue) callconv(.c) c_int;
const WlDisplayRoundtripFn = *const fn (*wl.Display) callconv(.c) c_int;
const WlEventQueueDestroyFn = *const fn (*wl.EventQueue) callconv(.c) void;
const WlProxyAddDispatcherFn = *const fn (*wl.Proxy, *const wl.Proxy.DispatcherFn, ?*const anyopaque, ?*anyopaque) callconv(.c) c_int;
const WlProxyCreateFn = *const fn (*wl.Proxy, *const Interface) callconv(.c) ?*wl.Proxy;
const WlProxyDestroyFn = *const fn (*wl.Proxy) callconv(.c) void;
const WlProxyGetIdFn = *const fn (*wl.Proxy) callconv(.c) u32;
const WlProxyGetUserDataFn = *const fn (*wl.Proxy) callconv(.c) ?*anyopaque;
const WlProxyGetVersionFn = *const fn (*wl.Proxy) callconv(.c) u32;
const WlProxyMarshalArrayFlagsFn = *const fn (*wl.Proxy, u32, ?*const Interface, u32, u32, ?[*]Argument) callconv(.c) ?*wl.Proxy;
const WlProxySetQueueFn = *const fn (*wl.Proxy, *wl.EventQueue) callconv(.c) void;

const Api = struct {
    display_cancel_read: WlDisplayCancelReadFn,
    display_connect_to_fd: WlDisplayConnectToFdFn,
    display_connect: WlDisplayConnectFn,
    display_create_queue: WlDisplayCreateQueueFn,
    display_disconnect: WlDisplayDisconnectFn,
    display_dispatch_pending: WlDisplayDispatchPendingFn,
    display_dispatch_queue_pending: WlDisplayDispatchQueuePendingFn,
    display_dispatch_queue: WlDisplayDispatchQueueFn,
    display_dispatch: WlDisplayDispatchFn,
    display_flush: WlDisplayFlushFn,
    display_get_error: WlDisplayGetErrorFn,
    display_get_fd: WlDisplayGetFdFn,
    display_prepare_read_queue: WlDisplayPrepareReadQueueFn,
    display_prepare_read: WlDisplayPrepareReadFn,
    display_read_events: WlDisplayReadEventsFn,
    display_roundtrip_queue: WlDisplayRoundtripQueueFn,
    display_roundtrip: WlDisplayRoundtripFn,
    event_queue_destroy: WlEventQueueDestroyFn,
    proxy_add_dispatcher: WlProxyAddDispatcherFn,
    proxy_create: WlProxyCreateFn,
    proxy_destroy: WlProxyDestroyFn,
    proxy_get_id: WlProxyGetIdFn,
    proxy_get_user_data: WlProxyGetUserDataFn,
    proxy_get_version: WlProxyGetVersionFn,
    proxy_marshal_array_flags: WlProxyMarshalArrayFlagsFn,
    proxy_set_queue: WlProxySetQueueFn,
};

var library: ?std.DynLib = null;
var api: ?Api = null;
var load_mutex: std.atomic.Mutex = .unlocked;

pub fn ensureLoaded() Error!void {
    while (!load_mutex.tryLock()) std.atomic.spinLoopHint();
    defer load_mutex.unlock();
    if (api != null) return;

    var loaded_library = try runtime.openAny(&.{ "libwayland-client.so.0", "libwayland-client.so" });
    errdefer loaded_library.close();

    api = .{
        .display_cancel_read = try runtime.lookup(&loaded_library, WlDisplayCancelReadFn, "wl_display_cancel_read"),
        .display_connect_to_fd = try runtime.lookup(&loaded_library, WlDisplayConnectToFdFn, "wl_display_connect_to_fd"),
        .display_connect = try runtime.lookup(&loaded_library, WlDisplayConnectFn, "wl_display_connect"),
        .display_create_queue = try runtime.lookup(&loaded_library, WlDisplayCreateQueueFn, "wl_display_create_queue"),
        .display_disconnect = try runtime.lookup(&loaded_library, WlDisplayDisconnectFn, "wl_display_disconnect"),
        .display_dispatch_pending = try runtime.lookup(&loaded_library, WlDisplayDispatchPendingFn, "wl_display_dispatch_pending"),
        .display_dispatch_queue_pending = try runtime.lookup(&loaded_library, WlDisplayDispatchQueuePendingFn, "wl_display_dispatch_queue_pending"),
        .display_dispatch_queue = try runtime.lookup(&loaded_library, WlDisplayDispatchQueueFn, "wl_display_dispatch_queue"),
        .display_dispatch = try runtime.lookup(&loaded_library, WlDisplayDispatchFn, "wl_display_dispatch"),
        .display_flush = try runtime.lookup(&loaded_library, WlDisplayFlushFn, "wl_display_flush"),
        .display_get_error = try runtime.lookup(&loaded_library, WlDisplayGetErrorFn, "wl_display_get_error"),
        .display_get_fd = try runtime.lookup(&loaded_library, WlDisplayGetFdFn, "wl_display_get_fd"),
        .display_prepare_read_queue = try runtime.lookup(&loaded_library, WlDisplayPrepareReadQueueFn, "wl_display_prepare_read_queue"),
        .display_prepare_read = try runtime.lookup(&loaded_library, WlDisplayPrepareReadFn, "wl_display_prepare_read"),
        .display_read_events = try runtime.lookup(&loaded_library, WlDisplayReadEventsFn, "wl_display_read_events"),
        .display_roundtrip_queue = try runtime.lookup(&loaded_library, WlDisplayRoundtripQueueFn, "wl_display_roundtrip_queue"),
        .display_roundtrip = try runtime.lookup(&loaded_library, WlDisplayRoundtripFn, "wl_display_roundtrip"),
        .event_queue_destroy = try runtime.lookup(&loaded_library, WlEventQueueDestroyFn, "wl_event_queue_destroy"),
        .proxy_add_dispatcher = try runtime.lookup(&loaded_library, WlProxyAddDispatcherFn, "wl_proxy_add_dispatcher"),
        .proxy_create = try runtime.lookup(&loaded_library, WlProxyCreateFn, "wl_proxy_create"),
        .proxy_destroy = try runtime.lookup(&loaded_library, WlProxyDestroyFn, "wl_proxy_destroy"),
        .proxy_get_id = try runtime.lookup(&loaded_library, WlProxyGetIdFn, "wl_proxy_get_id"),
        .proxy_get_user_data = try runtime.lookup(&loaded_library, WlProxyGetUserDataFn, "wl_proxy_get_user_data"),
        .proxy_get_version = try runtime.lookup(&loaded_library, WlProxyGetVersionFn, "wl_proxy_get_version"),
        .proxy_marshal_array_flags = try runtime.lookup(&loaded_library, WlProxyMarshalArrayFlagsFn, "wl_proxy_marshal_array_flags"),
        .proxy_set_queue = try runtime.lookup(&loaded_library, WlProxySetQueueFn, "wl_proxy_set_queue"),
    };
    library = loaded_library;
}

fn loaded() *const Api {
    return &(api orelse @panic("libwayland-client was used before ensureLoaded"));
}

pub const client = struct {
    pub fn wl_display_cancel_read(display: *wl.Display) void {
        loaded().display_cancel_read(display);
    }
    pub fn wl_display_connect_to_fd(fd: c_int) ?*wl.Display {
        return loaded().display_connect_to_fd(fd);
    }
    pub fn wl_display_connect(name: ?[*:0]const u8) ?*wl.Display {
        return loaded().display_connect(name);
    }
    pub fn wl_display_create_queue(display: *wl.Display) ?*wl.EventQueue {
        return loaded().display_create_queue(display);
    }
    pub fn wl_display_disconnect(display: *wl.Display) void {
        loaded().display_disconnect(display);
    }
    pub fn wl_display_dispatch_pending(display: *wl.Display) c_int {
        return loaded().display_dispatch_pending(display);
    }
    pub fn wl_display_dispatch_queue_pending(display: *wl.Display, queue: *wl.EventQueue) c_int {
        return loaded().display_dispatch_queue_pending(display, queue);
    }
    pub fn wl_display_dispatch_queue(display: *wl.Display, queue: *wl.EventQueue) c_int {
        return loaded().display_dispatch_queue(display, queue);
    }
    pub fn wl_display_dispatch(display: *wl.Display) c_int {
        return loaded().display_dispatch(display);
    }
    pub fn wl_display_flush(display: *wl.Display) c_int {
        return loaded().display_flush(display);
    }
    pub fn wl_display_get_error(display: *wl.Display) c_int {
        return loaded().display_get_error(display);
    }
    pub fn wl_display_get_fd(display: *wl.Display) c_int {
        return loaded().display_get_fd(display);
    }
    pub fn wl_display_prepare_read_queue(display: *wl.Display, queue: *wl.EventQueue) c_int {
        return loaded().display_prepare_read_queue(display, queue);
    }
    pub fn wl_display_prepare_read(display: *wl.Display) c_int {
        return loaded().display_prepare_read(display);
    }
    pub fn wl_display_read_events(display: *wl.Display) c_int {
        return loaded().display_read_events(display);
    }
    pub fn wl_display_roundtrip_queue(display: *wl.Display, queue: *wl.EventQueue) c_int {
        return loaded().display_roundtrip_queue(display, queue);
    }
    pub fn wl_display_roundtrip(display: *wl.Display) c_int {
        return loaded().display_roundtrip(display);
    }
    pub fn wl_event_queue_destroy(queue: *wl.EventQueue) void {
        loaded().event_queue_destroy(queue);
    }
    pub fn wl_proxy_add_dispatcher(proxy: *wl.Proxy, dispatcher: *const wl.Proxy.DispatcherFn, implementation: ?*const anyopaque, data: ?*anyopaque) c_int {
        return loaded().proxy_add_dispatcher(proxy, dispatcher, implementation, data);
    }
    pub fn wl_proxy_create(factory: *wl.Proxy, interface: *const Interface) ?*wl.Proxy {
        return loaded().proxy_create(factory, interface);
    }
    pub fn wl_proxy_destroy(proxy: *wl.Proxy) void {
        loaded().proxy_destroy(proxy);
    }
    pub fn wl_proxy_get_id(proxy: *wl.Proxy) u32 {
        return loaded().proxy_get_id(proxy);
    }
    pub fn wl_proxy_get_user_data(proxy: *wl.Proxy) ?*anyopaque {
        return loaded().proxy_get_user_data(proxy);
    }
    pub fn wl_proxy_get_version(proxy: *wl.Proxy) u32 {
        return loaded().proxy_get_version(proxy);
    }
    pub fn wl_proxy_marshal_array_flags(proxy: *wl.Proxy, opcode: u32, interface: ?*const Interface, version: u32, flags: u32, args: ?[*]Argument) ?*wl.Proxy {
        return loaded().proxy_marshal_array_flags(proxy, opcode, interface, version, flags, args);
    }
    pub fn wl_proxy_set_queue(proxy: *wl.Proxy, queue: *wl.EventQueue) void {
        loaded().proxy_set_queue(proxy, queue);
    }
};
