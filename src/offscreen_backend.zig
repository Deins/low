const std = @import("std");
const common = @import("internal/types.zig");
const api = @import("internal/runtime.zig");

/// The in-process backend deliberately has no OS, display-server, or
/// desktop-library dependency.
pub const Backend = struct {
    const Data = struct {
        allocator: std.mem.Allocator,
        mode: api.FrameMode,
        last_frame_ns: ?i128 = null,
        windows: std.ArrayListUnmanaged(*api.Window) = .empty,
        events: std.ArrayListUnmanaged(Queued) = .empty,
    };

    const Queued = struct {
        window: *api.Window,
        event: QueuedEvent,

        fn deinit(self: *Queued, allocator: std.mem.Allocator) void {
            self.event.deinit(allocator);
        }
    };

    const QueuedEvent = union(enum) {
        close: void,
        resize: api.Size,
        framebuffer_resize: api.Size,
        scale: api.ContentScale,
        focus: bool,
        cursor_enter: bool,
        cursor_motion: api.Point,
        cursor_delta: api.Point,
        mouse_button: struct { button: api.MouseButton, action: api.Action, mods: api.Modifiers },
        scroll: struct { x: f64, y: f64 },
        key: struct { key: api.Key, raw_keycode: u32, action: api.Action, mods: api.Modifiers },
        text: []u8,

        fn deinit(self: *QueuedEvent, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .text => |bytes| allocator.free(bytes),
                else => {},
            }
        }
    };

    pub fn init(allocator: std.mem.Allocator, options: api.OffscreenOptions) api.Error!*api.State {
        const backend_data = allocator.create(Data) catch return error.OutOfMemory;
        errdefer allocator.destroy(backend_data);
        backend_data.* = .{ .allocator = allocator, .mode = options.frame_mode };
        const state = allocator.create(api.State) catch return error.OutOfMemory;
        state.* = .{ .allocator = allocator, .backend_kind = .offscreen, .backend_data = backend_data, .vtable = &vtable };
        return state;
    }

    fn data(state: *api.State) *Data {
        return @ptrCast(@alignCast(state.backend_data));
    }

    fn deinit(state: *api.State) void {
        const d = data(state);
        while (d.windows.items.len != 0) d.windows.items[d.windows.items.len - 1].deinit();
        for (d.events.items) |*event| event.deinit(d.allocator);
        d.events.deinit(d.allocator);
        d.windows.deinit(d.allocator);
        const allocator = d.allocator;
        state.clipboard.deinit(allocator);
        allocator.destroy(d);
        allocator.destroy(state);
    }

    fn nativeDisplay(state: *api.State) *anyopaque {
        return state.backend_data;
    }

    fn vulkanVisualId(_: *api.State) usize {
        return 0;
    }
    fn requiredVulkanExtensions(_: *api.State) []const [*:0]const u8 {
        return &.{};
    }

    fn createWindow(state: *api.State, options: api.WindowOptions) api.Error!*api.Window {
        const d = data(state);
        const window = d.allocator.create(api.Window) catch return error.OutOfMemory;
        errdefer d.allocator.destroy(window);
        window.* = .{
            .ctx = state,
            .backend_data = @ptrCast(window),
            .size = options.size,
            .framebuffer_size = options.size,
            .visible = options.visible,
            .resizable = options.resizable,
            .min_size = options.min_size,
            .max_size = options.max_size,
            .decorated = options.decorated,
            .decoration_mode = options.titlebar,
        };
        d.windows.append(d.allocator, window) catch return error.OutOfMemory;
        switch (options.state) {
            .normal => {},
            .maximize => window.maximize(),
            .fullscreen => window.setFullscreen(),
        }
        return window;
    }

    fn destroyWindow(window: *api.Window) void {
        const d = data(window.ctx);
        if (std.mem.indexOfScalar(*api.Window, d.windows.items, window)) |i| _ = d.windows.swapRemove(i);
        var i = d.events.items.len;
        while (i != 0) {
            i -= 1;
            if (d.events.items[i].window == window) {
                var event = d.events.swapRemove(i);
                event.deinit(d.allocator);
            }
        }
        d.allocator.destroy(window);
    }

    fn nativeSurface(_: *api.Window) usize {
        return 0;
    }
    fn setTitle(_: *api.Window, _: [:0]const u8) void {}
    fn show(_: *api.Window) void {}
    fn hide(_: *api.Window) void {}
    fn maximize(_: *api.Window) void {}
    fn setFullscreen(_: *api.Window) void {}
    fn restore(_: *api.Window) void {}
    fn iconify(_: *api.Window) void {}
    fn setMinSize(_: *api.Window, _: ?api.Size) void {}
    fn setMaxSize(_: *api.Window, _: ?api.Size) void {}
    fn setResizable(_: *api.Window, _: bool) void {}
    fn setCursorVisible(_: *api.Window, _: bool) void {}
    fn setCursor(_: *api.Window, _: api.CursorShape) void {}
    fn setMouseCaptured(_: *api.Window, captured: bool) bool {
        return captured;
    }
    fn applyScale(_: *api.Window, _: f32) void {}
    fn requestFrame(_: *api.Window) bool {
        return true;
    }
    fn cancelFrameRequest(_: *api.Window) void {}

    fn pumpEvents(state: *api.State, _: i32) api.Error!bool {
        try step(state);
        return true;
    }
    fn wake(_: *api.State) void {}

    fn step(state: *api.State) api.Error!void {
        const d = data(state);
        var events = d.events;
        d.events = .empty;
        defer events.deinit(d.allocator);
        for (events.items) |*event| {
            dispatch(event.window, &event.event);
            event.deinit(d.allocator);
        }
    }

    fn nextFrame(state: *api.State) api.Error!void {
        const d = data(state);
        const config = switch (d.mode) {
            .manual => return error.ManualFrameStepping,
            .continuous => |value| value,
        };
        if (config.interval_ns) |interval| if (d.last_frame_ns) |last| {
            const elapsed = std.Io.Timestamp.now(std.Options.debug_io, .awake).nanoseconds - last;
            if (elapsed < @as(i128, interval)) {
                (std.Io.Clock.Duration{
                    .raw = std.Io.Duration.fromNanoseconds(@intCast(@as(i128, interval) - elapsed)),
                    .clock = .awake,
                }).sleep(std.Options.debug_io) catch {};
            }
        };
        try step(state);
        d.last_frame_ns = std.Io.Timestamp.now(std.Options.debug_io, .awake).nanoseconds;
    }

    fn injectEvent(window: *api.Window, event: api.Event) api.Error!void {
        const d = data(window.ctx);
        const queued: QueuedEvent = switch (event) {
            .close => .{ .close = {} },
            .resize => |v| .{ .resize = v },
            .framebuffer_resize => |v| .{ .framebuffer_resize = v },
            .scale => |v| .{ .scale = v },
            .focus => |v| .{ .focus = v },
            .cursor_enter => |v| .{ .cursor_enter = v },
            .cursor_motion => |v| .{ .cursor_motion = v },
            .cursor_delta => |v| .{ .cursor_delta = v },
            .mouse_button => |v| .{ .mouse_button = .{
                .button = v.button,
                .action = v.action,
                .mods = v.mods,
            } },
            .scroll => |v| .{ .scroll = .{ .x = v.x, .y = v.y } },
            .key => |v| .{ .key = .{
                .key = v.key,
                .raw_keycode = v.raw_keycode,
                .action = v.action,
                .mods = v.mods,
            } },
            .text => |v| .{ .text = try d.allocator.dupe(u8, v) },
        };
        d.events.append(d.allocator, .{ .window = window, .event = queued }) catch |err| {
            var owned = queued;
            owned.deinit(d.allocator);
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
            };
        };
    }

    fn dispatch(window: *api.Window, event: *QueuedEvent) void {
        switch (event.*) {
            .close => api.windowUpdateClose(window),
            .resize => |value| api.windowUpdateSize(window, value),
            .framebuffer_resize => |value| {
                window.framebuffer_size = value;
            },
            .scale => |value| {
                window.content_scale = value;
                window.framebuffer_size = common.scaledSize(window.size, value);
            },
            .focus => |value| api.windowUpdateFocus(window, value),
            .cursor_enter => |value| api.windowUpdateCursorEnter(window, value),
            .cursor_motion => |value| api.windowUpdateCursorMotion(window, value.x, value.y),
            .cursor_delta => |value| api.windowUpdateCursorDelta(window, value.x, value.y),
            .mouse_button => |value| api.windowUpdateMouseButton(window, value.button, value.action, value.mods),
            .scroll => |value| api.windowUpdateScroll(window, value.x, value.y),
            .key => |value| api.windowUpdateKey(window, value.key, value.raw_keycode, value.action, value.mods),
            .text => |value| api.windowUpdateText(window, value),
        }
    }

    const vtable: api.VTable = .{
        .deinit = deinit,
        .native_display = nativeDisplay,
        .vulkan_visual_id = vulkanVisualId,
        .required_vulkan_extensions = requiredVulkanExtensions,
        .create_window = createWindow,
        .pump_events = pumpEvents,
        .wake = wake,
        .step = step,
        .next_frame = nextFrame,
        .inject_event = injectEvent,
        .destroy_window = destroyWindow,
        .native_surface = nativeSurface,
        .set_title = setTitle,
        .show = show,
        .hide = hide,
        .maximize = maximize,
        .set_fullscreen = setFullscreen,
        .restore = restore,
        .iconify = iconify,
        .set_min_size = setMinSize,
        .set_max_size = setMaxSize,
        .set_resizable = setResizable,
        .set_cursor_visible = setCursorVisible,
        .set_cursor = setCursor,
        .set_mouse_captured = setMouseCaptured,
        .apply_scale = applyScale,
        .request_frame = requestFrame,
        .cancel_frame_request = cancelFrameRequest,
    };

    test "offscreen queues events until a step" {
        var context = try init(std.testing.allocator, .{});
        defer context.deinit();
        const window = try context.createWindow(.{ .title = "test" });
        try window.injectEvent(.{ .key = .{ .key = .a, .action = .press } });
        try std.testing.expect(!window.getKey(.a));
        try context.step();
        try std.testing.expect(window.getKey(.a));
    }

    test "offscreen manual mode rejects timed frames" {
        var context = try init(std.testing.allocator, .{});
        defer context.deinit();
        try std.testing.expectError(error.ManualFrameStepping, context.nextFrame());
    }

    test "offscreen continuous mode advances a frame" {
        var context = try init(std.testing.allocator, .{ .frame_mode = .{ .continuous = .{} } });
        defer context.deinit();
        try context.nextFrame();
    }

    test "offscreen applies the requested initial window state" {
        var context = try init(std.testing.allocator, .{});
        defer context.deinit();
        const window = try context.createWindow(.{ .title = "test", .state = .fullscreen });
        try std.testing.expect(window.fullscreen);
        try std.testing.expect(!window.maximized);
    }

    test "offscreen toggles fullscreen state" {
        var context = try init(std.testing.allocator, .{});
        defer context.deinit();
        const window = try context.createWindow(.{ .title = "test" });
        try std.testing.expect(!window.isFullscreen());
        window.toggleFullscreen();
        try std.testing.expect(window.isFullscreen());
        window.toggleFullscreen();
        try std.testing.expect(!window.isFullscreen());
    }

    test "offscreen tracks capture and cursor visibility state" {
        var context = try init(std.testing.allocator, .{});
        defer context.deinit();
        const window = try context.createWindow(.{ .title = "test" });
        window.setMouseCaptured(true);
        try std.testing.expect(window.isMouseCaptured());
        window.setMouseCaptured(false);
        try std.testing.expect(!window.isMouseCaptured());
        window.setCursorVisible(false);
        try std.testing.expect(!window.isCursorVisible());
    }

    test "offscreen delivers relative motion without changing absolute position" {
        const Callbacks = struct {
            fn cursorDelta(window: *api.Window, x: f64, y: f64) void {
                const received: *api.Point = @ptrCast(@alignCast(window.getUserData().?));
                received.* = .{ .x = x, .y = y };
            }
        };

        var context = try init(std.testing.allocator, .{});
        defer context.deinit();
        const window = try context.createWindow(.{ .title = "test" });
        api.windowUpdateCursorMotion(window, 10, 20);
        var received: api.Point = .{ .x = 0, .y = 0 };
        window.setUserData(&received);
        window.setCallbacks(.{ .cursor_delta = Callbacks.cursorDelta });

        try window.injectEvent(.{ .cursor_delta = .{ .x = 3, .y = -4 } });
        try context.step();
        try std.testing.expectEqualDeep(api.Point{ .x = 3, .y = -4 }, received);
        try std.testing.expectEqualDeep(api.Point{ .x = 10, .y = 20 }, window.getCursorPos());
    }
};
