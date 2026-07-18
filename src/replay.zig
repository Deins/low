//! Deterministic, frame-based input recording and replay.
//!
//! A recorder groups every observed window event into an application frame and
//! stores the monotonic delta used by that frame. A replayer dispatches the same
//! events through low's normal state/callback path and returns the recorded
//! delta, allowing simulation and rendering to use one deterministic clock.

const std = @import("std");
const runtime = @import("internal/runtime.zig");

pub const Window = runtime.Window;
pub const Event = runtime.Event;
pub const WindowId = u64;

pub const Error = runtime.Error || std.mem.Allocator.Error || error{
    AlreadyAttached,
    DifferentContext,
    FrameAlreadyOpen,
    NoFrameOpen,
    InvalidRecording,
    MissingWindow,
};

/// One application update/render boundary.
pub const Frame = struct {
    index: usize,
    delta_ns: u64,
    elapsed_ns: u64,

    pub fn deltaSeconds(self: Frame, comptime Float: type) Float {
        return @as(Float, @floatFromInt(self.delta_ns)) / 1_000_000_000;
    }
};

pub const FrameRecord = struct {
    delta_ns: u64,
    first_event: usize,
    event_count: usize,
};

pub const RecordedEvent = struct {
    window_id: WindowId,
    event: Event,
};

/// Allocator-owned input timeline. The frame and event slices are public on
/// purpose: debugging tools may inspect, remove, replace, or inject entries.
/// Text event bytes are owned by this value.
pub const Recording = struct {
    allocator: std.mem.Allocator,
    frames: []FrameRecord,
    events: []RecordedEvent,

    pub fn deinit(self: *Recording) void {
        for (self.events) |event| deinitEvent(self.allocator, event.event);
        self.allocator.free(self.events);
        self.allocator.free(self.frames);
        self.* = undefined;
    }

    pub fn durationNs(self: *const Recording) u64 {
        var total: u64 = 0;
        for (self.frames) |frame| total +|= frame.delta_ns;
        return total;
    }

    pub fn clone(self: *const Recording, allocator: std.mem.Allocator) Error!Recording {
        const frames = try allocator.dupe(FrameRecord, self.frames);
        errdefer allocator.free(frames);
        const events = try allocator.alloc(RecordedEvent, self.events.len);
        errdefer allocator.free(events);
        var initialized: usize = 0;
        errdefer for (events[0..initialized]) |event| deinitEvent(allocator, event.event);
        for (self.events, events) |source, *destination| {
            destination.* = .{ .window_id = source.window_id, .event = try cloneEvent(allocator, source.event) };
            initialized += 1;
        }
        return .{ .allocator = allocator, .frames = frames, .events = events };
    }

    /// Writes a portable, versioned binary timeline. The writer remains owned
    /// by the caller and is not flushed or closed.
    pub fn write(self: *const Recording, writer: *std.Io.Writer) !void {
        try validate(self);
        try writer.writeAll(file_magic);
        try writeInt(writer, u64, self.frames.len);
        try writeInt(writer, u64, self.events.len);
        for (self.frames) |frame| {
            try writeInt(writer, u64, frame.delta_ns);
            try writeInt(writer, u64, frame.first_event);
            try writeInt(writer, u64, frame.event_count);
        }
        for (self.events) |recorded| {
            try writeInt(writer, u64, recorded.window_id);
            try writeEvent(writer, recorded.event);
        }
    }

    /// Loads a recording written by `write` from the reader's current
    /// position. All returned storage, including text events, uses `allocator`.
    pub fn read(allocator: std.mem.Allocator, reader: *std.Io.Reader) !Recording {
        var magic: [file_magic.len]u8 = undefined;
        try reader.readSliceAll(&magic);
        if (!std.mem.eql(u8, &magic, file_magic)) return error.InvalidRecording;
        const frame_count = std.math.cast(usize, try readInt(reader, u64)) orelse return error.InvalidRecording;
        const event_count = std.math.cast(usize, try readInt(reader, u64)) orelse return error.InvalidRecording;
        const frames = try allocator.alloc(FrameRecord, frame_count);
        errdefer allocator.free(frames);
        for (frames) |*frame| frame.* = .{
            .delta_ns = try readInt(reader, u64),
            .first_event = std.math.cast(usize, try readInt(reader, u64)) orelse return error.InvalidRecording,
            .event_count = std.math.cast(usize, try readInt(reader, u64)) orelse return error.InvalidRecording,
        };
        const events = try allocator.alloc(RecordedEvent, event_count);
        errdefer allocator.free(events);
        var initialized: usize = 0;
        errdefer for (events[0..initialized]) |event| deinitEvent(allocator, event.event);
        for (events) |*recorded| {
            recorded.* = .{
                .window_id = try readInt(reader, u64),
                .event = try readEvent(allocator, reader),
            };
            initialized += 1;
        }
        const result: Recording = .{ .allocator = allocator, .frames = frames, .events = events };
        try validate(&result);
        return result;
    }
};

const file_magic = "LOWRPL\x01\x00";

/// Clock override for tests, simulations, and application-owned timelines.
pub const Clock = struct {
    context: ?*anyopaque = null,
    read_ns: *const fn (?*anyopaque) u64 = monotonicNow,

    pub fn now(self: Clock) u64 {
        return self.read_ns(self.context);
    }

    fn monotonicNow(_: ?*anyopaque) u64 {
        const value = std.Io.Timestamp.now(std.Options.debug_io, .awake).nanoseconds;
        return if (value <= 0) 0 else @intCast(@min(value, std.math.maxInt(u64)));
    }
};

pub const RecordScope = union(enum) {
    /// Record every window in the context. Window IDs are their deterministic
    /// context creation indexes, so a matching run maps them automatically.
    all,
    /// Record only these windows. IDs are their indexes in this slice.
    windows: []const *Window,
};

pub const RecorderOptions = struct {
    scope: RecordScope = .all,
    clock: Clock = .{},
};

pub const Recorder = struct {
    inner: *Inner,

    const Inner = struct {
        allocator: std.mem.Allocator,
        state: *runtime.State,
        scope: RecordScope,
        selected: []?*Window = &.{},
        clock: Clock,
        last_clock_ns: u64,
        elapsed_ns: u64 = 0,
        frames: std.ArrayListUnmanaged(FrameRecord) = .empty,
        events: std.ArrayListUnmanaged(RecordedEvent) = .empty,
        active_frame: ?usize = null,
        sticky_error: ?anyerror = null,
        attached: bool = false,

        fn observe(observer_context: *anyopaque, window: *Window, event: Event) void {
            const self: *Inner = @ptrCast(@alignCast(observer_context));
            const frame_index = self.active_frame orelse return;
            if (!runtime.isReplayableEvent(event)) return;
            const window_id: WindowId = switch (self.scope) {
                .all => window.serial,
                .windows => blk: {
                    for (self.selected, 0..) |candidate, index| {
                        if (candidate == window) break :blk @intCast(index);
                    }
                    return;
                },
            };
            const owned = cloneEvent(self.allocator, event) catch |err| {
                self.sticky_error = err;
                return;
            };
            self.events.append(self.allocator, .{ .window_id = window_id, .event = owned }) catch |err| {
                deinitEvent(self.allocator, owned);
                self.sticky_error = err;
                return;
            };
            self.frames.items[frame_index].event_count += 1;
        }

        fn windowDestroyed(observer_context: *anyopaque, window: *Window) void {
            const self: *Inner = @ptrCast(@alignCast(observer_context));
            for (self.selected) |*candidate| {
                if (candidate.* == window) candidate.* = null;
            }
        }

        fn observer(self: *Inner) runtime.EventObserver {
            return .{ .context = self, .event = observe, .window_destroyed = windowDestroyed };
        }

        fn detach(self: *Inner) void {
            if (!self.attached) return;
            switch (self.scope) {
                .all => if (self.state.event_observer) |attached_observer| {
                    if (attached_observer.context == @as(*anyopaque, @ptrCast(self))) self.state.event_observer = null;
                },
                .windows => for (self.selected) |candidate| if (candidate) |window| {
                    if (window.event_observer) |attached_observer| {
                        if (attached_observer.context == @as(*anyopaque, @ptrCast(self))) window.event_observer = null;
                    }
                },
            }
            self.attached = false;
        }
    };

    /// Attaches a recorder to a context. By default all of its windows are
    /// included; select `.scope = .{ .windows = ... }` for an editor-style
    /// per-window recording.
    pub fn init(allocator: std.mem.Allocator, context: anytype, options: RecorderOptions) Error!Recorder {
        const state = contextState(context);
        const inner = try allocator.create(Inner);
        errdefer allocator.destroy(inner);
        inner.* = .{
            .allocator = allocator,
            .state = state,
            .scope = options.scope,
            .clock = options.clock,
            .last_clock_ns = options.clock.now(),
        };

        const observer = inner.observer();
        switch (options.scope) {
            .all => {
                if (state.event_observer != null) return error.AlreadyAttached;
                state.event_observer = observer;
            },
            .windows => |windows| {
                inner.selected = try allocator.alloc(?*Window, windows.len);
                errdefer allocator.free(inner.selected);
                for (windows, 0..) |window, index| {
                    if (window.ctx != state) return error.DifferentContext;
                    if (window.event_observer != null) return error.AlreadyAttached;
                    inner.selected[index] = window;
                }
                var attached: usize = 0;
                errdefer for (inner.selected[0..attached]) |candidate| {
                    candidate.?.event_observer = null;
                };
                for (inner.selected) |candidate| {
                    candidate.?.event_observer = observer;
                    attached += 1;
                }
            },
        }
        inner.attached = true;
        return .{ .inner = inner };
    }

    pub fn deinit(self: *Recorder) void {
        const inner = self.inner;
        inner.detach();
        for (inner.events.items) |event| deinitEvent(inner.allocator, event.event);
        inner.events.deinit(inner.allocator);
        inner.frames.deinit(inner.allocator);
        if (inner.selected.len != 0) inner.allocator.free(inner.selected);
        inner.allocator.destroy(inner);
        self.* = undefined;
    }

    /// Samples the configured clock, opens a frame, non-blockingly polls the
    /// context, and closes the frame. Use the returned delta for application
    /// update and video-recording timestamps.
    pub fn nextFrame(self: *Recorder) Error!Frame {
        const inner = self.inner;
        if (inner.sticky_error) |err| return @errorCast(err);
        const now = inner.clock.now();
        const delta = now -| inner.last_clock_ns;
        inner.last_clock_ns = now;
        try self.beginFrame(delta);
        errdefer _ = self.endFrame() catch {};
        _ = try inner.state.waitEventsTimeout(0);
        return self.endFrame();
    }

    /// Opens an application-owned frame. Events dispatched until `endFrame`
    /// are recorded in order. This is the custom-main-loop counterpart to
    /// `nextFrame`.
    pub fn beginFrame(self: *Recorder, delta_ns: u64) Error!void {
        const inner = self.inner;
        if (inner.sticky_error) |err| return @errorCast(err);
        if (inner.active_frame != null) return error.FrameAlreadyOpen;
        try inner.frames.append(inner.allocator, .{
            .delta_ns = delta_ns,
            .first_event = inner.events.items.len,
            .event_count = 0,
        });
        inner.active_frame = inner.frames.items.len - 1;
    }

    pub fn endFrame(self: *Recorder) Error!Frame {
        const inner = self.inner;
        const index = inner.active_frame orelse return error.NoFrameOpen;
        inner.active_frame = null;
        if (inner.sticky_error) |err| return @errorCast(err);
        const delta = inner.frames.items[index].delta_ns;
        inner.elapsed_ns +|= delta;
        return .{ .index = index, .delta_ns = delta, .elapsed_ns = inner.elapsed_ns };
    }

    /// Stops observing input and transfers the accumulated timeline to the
    /// caller. The recorder may still be deinitialized normally afterward.
    pub fn finish(self: *Recorder) Error!Recording {
        const inner = self.inner;
        if (inner.active_frame != null) return error.FrameAlreadyOpen;
        if (inner.sticky_error) |err| return @errorCast(err);
        inner.detach();
        const frames = try inner.frames.toOwnedSlice(inner.allocator);
        errdefer inner.allocator.free(frames);
        const events = try inner.events.toOwnedSlice(inner.allocator);
        return .{ .allocator = inner.allocator, .frames = frames, .events = events };
    }
};

pub const ReplayScope = union(enum) {
    /// Match recorded window IDs to context creation indexes.
    all,
    /// Map IDs 0..N to the supplied windows. Other IDs may be assigned later
    /// with `Replayer.mapWindow`.
    windows: []const *Window,
};

pub const Pace = enum { unpaced, realtime };

pub const ReplayerOptions = struct {
    scope: ReplayScope = .all,
    /// Pump native events before each replay frame. Replay-controlled windows
    /// ignore replayable input from this pump but retain live surface events;
    /// other windows remain fully interactive.
    poll_live: bool = true,
    pace: Pace = .unpaced,
};

pub const Replayer = struct {
    inner: *Inner,

    const Mapping = struct { id: WindowId, window: ?*Window };
    const Inner = struct {
        allocator: std.mem.Allocator,
        state: *runtime.State,
        recording: *const Recording,
        scope: ReplayScope,
        mappings: std.ArrayListUnmanaged(Mapping) = .empty,
        next_frame: usize = 0,
        elapsed_ns: u64 = 0,
        pace_started_ns: ?u64 = null,
        poll_live: bool,
        pace: Pace,
        attached: bool = false,

        fn windowDestroyed(controller_context: *anyopaque, window: *Window) void {
            const self: *Inner = @ptrCast(@alignCast(controller_context));
            for (self.mappings.items) |*mapping| {
                if (mapping.window == window) mapping.window = null;
            }
        }

        fn controller(self: *Inner) runtime.ReplayController {
            return .{ .context = self, .window_destroyed = windowDestroyed };
        }

        fn findWindow(self: *Inner, id: WindowId) ?*Window {
            for (self.mappings.items) |mapping| if (mapping.id == id) return mapping.window;
            if (self.scope == .all) {
                var current = self.state.first_window;
                while (current) |window| : (current = window.context_next) {
                    if (window.serial == id) return window;
                }
            }
            return null;
        }

        fn detach(self: *Inner) void {
            if (!self.attached) return;
            if (self.scope == .all) {
                if (self.state.replay_controller) |attached_controller| {
                    if (attached_controller.context == @as(*anyopaque, @ptrCast(self))) self.state.replay_controller = null;
                }
            }
            for (self.mappings.items) |mapping| if (mapping.window) |window| {
                if (window.replay_controller) |attached_controller| {
                    if (attached_controller.context == @as(*anyopaque, @ptrCast(self))) window.replay_controller = null;
                }
            };
            self.attached = false;
        }
    };

    pub fn init(allocator: std.mem.Allocator, context: anytype, recording: *const Recording, options: ReplayerOptions) Error!Replayer {
        try validate(recording);
        const state = contextState(context);
        const inner = try allocator.create(Inner);
        errdefer allocator.destroy(inner);
        inner.* = .{
            .allocator = allocator,
            .state = state,
            .recording = recording,
            .scope = options.scope,
            .poll_live = options.poll_live,
            .pace = options.pace,
        };
        errdefer inner.mappings.deinit(allocator);
        inner.attached = true;
        errdefer inner.detach();

        switch (options.scope) {
            .all => {
                if (state.replay_controller != null) return error.AlreadyAttached;
                state.replay_controller = inner.controller();
            },
            .windows => |windows| {
                for (windows, 0..) |window, index| {
                    if (window.ctx != state) return error.DifferentContext;
                    try attachMapping(inner, @intCast(index), window);
                }
            },
        }
        return .{ .inner = inner };
    }

    pub fn deinit(self: *Replayer) void {
        const inner = self.inner;
        inner.detach();
        inner.mappings.deinit(inner.allocator);
        inner.allocator.destroy(inner);
        self.* = undefined;
    }

    /// Dispatches the next recorded frame and returns its deterministic time.
    /// `null` means the recording is complete.
    pub fn nextFrame(self: *Replayer) Error!?Frame {
        const inner = self.inner;
        if (inner.next_frame == inner.recording.frames.len) return null;
        const index = inner.next_frame;
        const record = inner.recording.frames[index];
        if (inner.pace == .realtime) {
            const now = Clock.monotonicNow(null);
            const started = inner.pace_started_ns orelse blk: {
                inner.pace_started_ns = now;
                break :blk now;
            };
            const target = started +| (inner.elapsed_ns +| record.delta_ns);
            if (now < target) {
                (std.Io.Clock.Duration{
                    .raw = std.Io.Duration.fromNanoseconds(target - now),
                    .clock = .awake,
                }).sleep(std.Options.debug_io) catch {};
            }
        }
        if (inner.poll_live) _ = try inner.state.waitEventsTimeout(0);
        try self.dispatchFrame(index);
        inner.next_frame += 1;
        inner.elapsed_ns +|= record.delta_ns;
        return .{ .index = index, .delta_ns = record.delta_ns, .elapsed_ns = inner.elapsed_ns };
    }

    /// Dispatches a frame without moving the playback cursor. This is useful
    /// for custom schedulers, event filtering, and timeline editors.
    pub fn dispatchFrame(self: *Replayer, index: usize) Error!void {
        const inner = self.inner;
        if (index >= inner.recording.frames.len) return error.InvalidRecording;
        const frame = inner.recording.frames[index];
        for (inner.recording.events[frame.first_event..][0..frame.event_count]) |recorded| {
            // Version 1 recordings may contain compositor-owned window events.
            // Ignore them so older files cannot overwrite live surface state.
            if (!runtime.isReplayableEvent(recorded.event)) continue;
            const window = inner.findWindow(recorded.window_id) orelse return error.MissingWindow;
            runtime.dispatchEvent(window, recorded.event, .replay);
        }
    }

    /// Overrides or adds a recorded-window mapping. This also makes the window
    /// ignore native input until the replayer is deinitialized.
    pub fn mapWindow(self: *Replayer, id: WindowId, window: *Window) Error!void {
        if (window.ctx != self.inner.state) return error.DifferentContext;
        return attachMapping(self.inner, id, window);
    }

    /// Rewinds the timeline cursor. Reset application/window state separately
    /// when replaying the same recording again.
    pub fn reset(self: *Replayer) void {
        self.inner.next_frame = 0;
        self.inner.elapsed_ns = 0;
        self.inner.pace_started_ns = null;
    }
};

fn attachMapping(inner: *Replayer.Inner, id: WindowId, window: *Window) Error!void {
    if (window.replay_controller) |controller| {
        if (controller.context != @as(*anyopaque, @ptrCast(inner))) return error.AlreadyAttached;
    }
    for (inner.mappings.items) |*mapping| if (mapping.id == id) {
        if (mapping.window) |old| {
            if (old != window) old.replay_controller = null;
        }
        mapping.window = window;
        window.replay_controller = inner.controller();
        return;
    };
    try inner.mappings.append(inner.allocator, .{ .id = id, .window = window });
    window.replay_controller = inner.controller();
}

fn validate(recording: *const Recording) Error!void {
    for (recording.frames) |frame| {
        if (frame.first_event > recording.events.len) return error.InvalidRecording;
        if (frame.event_count > recording.events.len - frame.first_event) return error.InvalidRecording;
    }
}

fn contextState(context: anytype) *runtime.State {
    const Context = @TypeOf(context);
    if (comptime Context == *runtime.State) return context;
    if (comptime Context == *const runtime.State) return @constCast(context);
    return context.state.get();
}

fn cloneEvent(allocator: std.mem.Allocator, event: Event) std.mem.Allocator.Error!Event {
    return switch (event) {
        .text => |bytes| .{ .text = try allocator.dupe(u8, bytes) },
        else => event,
    };
}

fn deinitEvent(allocator: std.mem.Allocator, event: Event) void {
    switch (event) {
        .text => |bytes| allocator.free(bytes),
        else => {},
    }
}

fn writeInt(writer: *std.Io.Writer, comptime Int: type, value: anytype) !void {
    var bytes: [@sizeOf(Int)]u8 = undefined;
    std.mem.writeInt(Int, &bytes, @intCast(value), .little);
    try writer.writeAll(&bytes);
}

fn readInt(reader: *std.Io.Reader, comptime Int: type) !Int {
    var bytes: [@sizeOf(Int)]u8 = undefined;
    try reader.readSliceAll(&bytes);
    return std.mem.readInt(Int, &bytes, .little);
}

fn writeBool(writer: *std.Io.Writer, value: bool) !void {
    try writeInt(writer, u8, @intFromBool(value));
}

fn readBool(reader: *std.Io.Reader) !bool {
    return switch (try readInt(reader, u8)) {
        0 => false,
        1 => true,
        else => error.InvalidRecording,
    };
}

fn writeF32(writer: *std.Io.Writer, value: f32) !void {
    try writeInt(writer, u32, @as(u32, @bitCast(value)));
}

fn readF32(reader: *std.Io.Reader) !f32 {
    return @bitCast(try readInt(reader, u32));
}

fn writeF64(writer: *std.Io.Writer, value: f64) !void {
    try writeInt(writer, u64, @as(u64, @bitCast(value)));
}

fn readF64(reader: *std.Io.Reader) !f64 {
    return @bitCast(try readInt(reader, u64));
}

fn writeModifiers(writer: *std.Io.Writer, mods: runtime.Modifiers) !void {
    const bits: u6 = @bitCast(mods);
    try writeInt(writer, u8, bits);
}

fn readModifiers(reader: *std.Io.Reader) !runtime.Modifiers {
    const byte = try readInt(reader, u8);
    if (byte > std.math.maxInt(u6)) return error.InvalidRecording;
    const bits: u6 = @intCast(byte);
    return @bitCast(bits);
}

fn writeEvent(writer: *std.Io.Writer, event: Event) !void {
    switch (event) {
        .close => try writeInt(writer, u8, 0),
        .resize => |value| {
            try writeInt(writer, u8, 1);
            try writeInt(writer, i32, value.width);
            try writeInt(writer, i32, value.height);
        },
        .framebuffer_resize => |value| {
            try writeInt(writer, u8, 2);
            try writeInt(writer, i32, value.width);
            try writeInt(writer, i32, value.height);
        },
        .scale => |value| {
            try writeInt(writer, u8, 3);
            try writeF32(writer, value.x);
            try writeF32(writer, value.y);
        },
        .focus => |value| {
            try writeInt(writer, u8, 4);
            try writeBool(writer, value);
        },
        .cursor_enter => |value| {
            try writeInt(writer, u8, 5);
            try writeBool(writer, value);
        },
        .cursor_motion => |value| {
            try writeInt(writer, u8, 6);
            try writeF64(writer, value.x);
            try writeF64(writer, value.y);
        },
        .cursor_delta => |value| {
            try writeInt(writer, u8, 7);
            try writeF64(writer, value.x);
            try writeF64(writer, value.y);
        },
        .mouse_button => |value| {
            try writeInt(writer, u8, 8);
            try writeInt(writer, u8, @intFromEnum(value.button));
            try writeInt(writer, u8, @intFromEnum(value.action));
            try writeModifiers(writer, value.mods);
        },
        .scroll => |value| {
            try writeInt(writer, u8, 9);
            try writeF64(writer, value.x);
            try writeF64(writer, value.y);
        },
        .key => |value| {
            try writeInt(writer, u8, 10);
            try writeInt(writer, u16, @intFromEnum(value.key));
            try writeInt(writer, u32, value.raw_keycode);
            try writeInt(writer, u8, @intFromEnum(value.action));
            try writeModifiers(writer, value.mods);
        },
        .text => |bytes| {
            try writeInt(writer, u8, 11);
            try writeInt(writer, u64, bytes.len);
            try writer.writeAll(bytes);
        },
        .render_suspended => |value| {
            try writeInt(writer, u8, 12);
            try writeBool(writer, value);
        },
        .frame_ready => |value| {
            try writeInt(writer, u8, 13);
            try writeInt(writer, u32, value);
        },
    }
}

fn readEvent(allocator: std.mem.Allocator, reader: *std.Io.Reader) !Event {
    return switch (try readInt(reader, u8)) {
        0 => .{ .close = {} },
        1 => .{ .resize = .{ .width = try readInt(reader, i32), .height = try readInt(reader, i32) } },
        2 => .{ .framebuffer_resize = .{ .width = try readInt(reader, i32), .height = try readInt(reader, i32) } },
        3 => .{ .scale = .{ .x = try readF32(reader), .y = try readF32(reader) } },
        4 => .{ .focus = try readBool(reader) },
        5 => .{ .cursor_enter = try readBool(reader) },
        6 => .{ .cursor_motion = .{ .x = try readF64(reader), .y = try readF64(reader) } },
        7 => .{ .cursor_delta = .{ .x = try readF64(reader), .y = try readF64(reader) } },
        8 => .{ .mouse_button = .{
            .button = std.enums.fromInt(runtime.MouseButton, try readInt(reader, u8)) orelse return error.InvalidRecording,
            .action = std.enums.fromInt(runtime.Action, try readInt(reader, u8)) orelse return error.InvalidRecording,
            .mods = try readModifiers(reader),
        } },
        9 => .{ .scroll = .{ .x = try readF64(reader), .y = try readF64(reader) } },
        10 => .{ .key = .{
            .key = std.enums.fromInt(runtime.Key, try readInt(reader, u16)) orelse return error.InvalidRecording,
            .raw_keycode = try readInt(reader, u32),
            .action = std.enums.fromInt(runtime.Action, try readInt(reader, u8)) orelse return error.InvalidRecording,
            .mods = try readModifiers(reader),
        } },
        11 => blk: {
            const length = std.math.cast(usize, try readInt(reader, u64)) orelse return error.InvalidRecording;
            const bytes = try allocator.alloc(u8, length);
            errdefer allocator.free(bytes);
            try reader.readSliceAll(bytes);
            break :blk .{ .text = bytes };
        },
        12 => .{ .render_suspended = try readBool(reader) },
        13 => .{ .frame_ready = try readInt(reader, u32) },
        else => error.InvalidRecording,
    };
}

test "global recording round trips and replays input with frame timing" {
    const Offscreen = @import("offscreen_backend.zig").Backend;
    const allocator = std.testing.allocator;

    var record_state = try Offscreen.init(allocator, .{});
    defer record_state.deinit();
    var recorder = try Recorder.init(allocator, record_state, .{});
    defer recorder.deinit();
    const first = try record_state.createWindow(.{ .title = "first" });
    const second = try record_state.createWindow(.{ .title = "second" });
    try recorder.beginFrame(10);
    try first.injectEvent(.{ .key = .{ .key = .a, .raw_keycode = 38, .action = .press, .mods = .{ .shift = true } } });
    try first.injectEvent(.{ .text = "A" });
    try second.injectEvent(.{ .cursor_motion = .{ .x = 12.5, .y = 7.25 } });
    _ = try recorder.endFrame();
    try recorder.beginFrame(25);
    try first.injectEvent(.{ .key = .{ .key = .a, .raw_keycode = 38, .action = .release } });
    try second.injectEvent(.{ .resize = .{ .width = 800, .height = 450 } });
    try second.injectEvent(.{ .focus = true });
    _ = try recorder.endFrame();

    var captured = try recorder.finish();
    defer captured.deinit();
    try std.testing.expectEqual(@as(usize, 2), captured.frames.len);
    try std.testing.expectEqual(@as(usize, 5), captured.events.len);
    try std.testing.expectEqual(@as(WindowId, 0), captured.events[0].window_id);
    try std.testing.expectEqual(@as(WindowId, 1), captured.events[2].window_id);

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try captured.write(&output.writer);
    var input = std.Io.Reader.fixed(output.written());
    var loaded = try Recording.read(allocator, &input);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(u64, 35), loaded.durationNs());
    try std.testing.expectEqualStrings("A", loaded.events[1].event.text);

    var replay_state = try Offscreen.init(allocator, .{});
    defer replay_state.deinit();
    var replayer = try Replayer.init(allocator, replay_state, &loaded, .{ .poll_live = false });
    defer replayer.deinit();
    const replay_first = try replay_state.createWindow(.{ .title = "first" });
    const replay_second = try replay_state.createWindow(.{ .title = "second" });

    const frame0 = (try replayer.nextFrame()).?;
    try std.testing.expectEqual(@as(u64, 10), frame0.delta_ns);
    try std.testing.expect(replay_first.getKey(.a));
    try std.testing.expectEqualDeep(runtime.ContentOffset{ .x = 12.5, .y = 7.25 }, replay_second.getCursorPos());
    const frame1 = (try replayer.nextFrame()).?;
    try std.testing.expectEqual(@as(u64, 35), frame1.elapsed_ns);
    try std.testing.expect(!replay_first.getKey(.a));
    try std.testing.expect(replay_second.isFocused());
    try std.testing.expectEqualDeep(runtime.ContentSize{ .width = 1280, .height = 720 }, replay_second.getSize());
    try std.testing.expect((try replayer.nextFrame()) == null);
}

test "replay ignores compositor-owned events from existing recordings" {
    const Offscreen = @import("offscreen_backend.zig").Backend;
    const allocator = std.testing.allocator;
    var state = try Offscreen.init(allocator, .{});
    defer state.deinit();
    const window = try state.createWindow(.{ .title = "controlled" });

    const frames = try allocator.dupe(FrameRecord, &.{.{ .delta_ns = 1, .first_event = 0, .event_count = 3 }});
    const events = try allocator.dupe(RecordedEvent, &.{
        .{ .window_id = 0, .event = .{ .resize = .{ .width = 3840, .height = 2160 } } },
        .{ .window_id = 0, .event = .{ .frame_ready = 123 } },
        .{ .window_id = 0, .event = .{ .key = .{ .key = .a, .action = .press } } },
    });
    var recording: Recording = .{ .allocator = allocator, .frames = frames, .events = events };
    defer recording.deinit();
    var replayer = try Replayer.init(allocator, state, &recording, .{ .poll_live = false });
    defer replayer.deinit();

    window.frame_ready = false;
    _ = try replayer.nextFrame();
    try std.testing.expectEqualDeep(runtime.ContentSize{ .width = 1280, .height = 720 }, window.getSize());
    try std.testing.expect(!window.frame_ready);
    try std.testing.expect(window.getKey(.a));
}

test "per-window recorder excludes unselected windows" {
    const Offscreen = @import("offscreen_backend.zig").Backend;
    const allocator = std.testing.allocator;
    var state = try Offscreen.init(allocator, .{});
    defer state.deinit();
    const selected = try state.createWindow(.{ .title = "selected" });
    const ignored = try state.createWindow(.{ .title = "ignored" });
    var recorder = try Recorder.init(allocator, state, .{ .scope = .{ .windows = &.{selected} } });
    defer recorder.deinit();
    try recorder.beginFrame(1);
    try ignored.injectEvent(.{ .key = .{ .key = .a, .action = .press } });
    try selected.injectEvent(.{ .key = .{ .key = .b, .action = .press } });
    _ = try recorder.endFrame();
    var recording = try recorder.finish();
    defer recording.deinit();
    try std.testing.expectEqual(@as(usize, 1), recording.events.len);
    try std.testing.expectEqual(@as(WindowId, 0), recording.events[0].window_id);
    try std.testing.expectEqual(runtime.Key.b, recording.events[0].event.key.key);
}

test "per-window replay ignores native input only for the controlled window" {
    const Offscreen = @import("offscreen_backend.zig").Backend;
    const allocator = std.testing.allocator;
    var state = try Offscreen.init(allocator, .{});
    defer state.deinit();
    const live = try state.createWindow(.{ .title = "live" });
    const controlled = try state.createWindow(.{ .title = "controlled" });

    const frames = try allocator.dupe(FrameRecord, &.{.{ .delta_ns = 1, .first_event = 0, .event_count = 1 }});
    const events = try allocator.dupe(RecordedEvent, &.{.{
        .window_id = 0,
        .event = .{ .key = .{ .key = .a, .action = .press } },
    }});
    var recording: Recording = .{ .allocator = allocator, .frames = frames, .events = events };
    defer recording.deinit();
    var replayer = try Replayer.init(allocator, state, &recording, .{
        .scope = .{ .windows = &.{controlled} },
        .poll_live = false,
    });
    defer replayer.deinit();

    runtime.windowUpdateKey(controlled, .b, 0, .press, .{});
    runtime.windowUpdateKey(live, .b, 0, .press, .{});
    runtime.windowUpdateSize(controlled, .{ .width = 800, .height = 450 });
    try std.testing.expect(!controlled.getKey(.b));
    try std.testing.expect(live.getKey(.b));
    try std.testing.expectEqualDeep(runtime.ContentSize{ .width = 800, .height = 450 }, controlled.getSize());
    _ = try replayer.nextFrame();
    try std.testing.expect(controlled.getKey(.a));

    // Explicit synthetic injection remains available while native input is
    // suppressed, which lets a debugger alter the replay timeline.
    try controlled.injectEvent(.{ .key = .{ .key = .c, .action = .press } });
    try std.testing.expect(controlled.getKey(.c));
}

test "recorder nextFrame uses the configured deterministic clock" {
    const Offscreen = @import("offscreen_backend.zig").Backend;
    const TestClock = struct {
        values: [3]u64 = .{ 100, 116, 149 },
        index: usize = 0,

        fn read(context: ?*anyopaque) u64 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const value = self.values[self.index];
            self.index += 1;
            return value;
        }
    };

    var state = try Offscreen.init(std.testing.allocator, .{});
    defer state.deinit();
    var clock: TestClock = .{};
    var recorder = try Recorder.init(std.testing.allocator, state, .{
        .clock = .{ .context = &clock, .read_ns = TestClock.read },
    });
    defer recorder.deinit();
    try std.testing.expectEqual(@as(u64, 16), (try recorder.nextFrame()).delta_ns);
    const second = try recorder.nextFrame();
    try std.testing.expectEqual(@as(u64, 33), second.delta_ns);
    try std.testing.expectEqual(@as(u64, 49), second.elapsed_ns);
}
