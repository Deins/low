# Deterministic input recording and replay

`low.replay` captures the two inputs a deterministic application loop needs:
the ordered window events observed in each frame and that frame's monotonic
delta. Use the returned delta for simulation instead of reading wall time.
With the same code and deterministic application state, replay then takes the
same update and rendering path.

The library does not replace application randomness, worker scheduling, file
I/O, or other external state. Seed or capture those separately when they affect
rendering.

## Default whole-application loop

Create the recorder after the context and deinitialize it before the context.
Its default scope observes every existing or future window in that context:

```zig
var recorder = try low.replay.Recorder.init(allocator, &context, .{});
defer recorder.deinit();

while (!window.shouldClose()) {
    const frame = try recorder.nextFrame(); // samples time and polls events
    update(frame.deltaSeconds(f32));
    try draw();
}

var recording = try recorder.finish();
defer recording.deinit();
```

`nextFrame` is the normal replacement for `Context.pollEvents`. The first
delta is measured from recorder initialization. `Frame.elapsed_ns` is the sum
of all returned deltas and is the deterministic application timestamp.

Replay uses the same loop shape and does not sleep by default:

```zig
var replayer = try low.replay.Replayer.init(allocator, &context, &recording, .{});
defer replayer.deinit();

while (try replayer.nextFrame()) |frame| {
    update(frame.deltaSeconds(f32));
    try draw();
}
```

Native input events are ignored for replay-controlled windows. Live resize,
framebuffer-size, content-scale, render-suspension, and frame-pacing events are
still delivered because they describe the current native surface and are not
recorded or replayed. In particular, an input callback may safely request
fullscreen during replay without stale recorded configure events replacing the
compositor's response. Explicit `Window.injectEvent` calls still work, allowing
a debugger to change state or branch from the recorded timeline. Set
`.pace = .realtime` to reproduce the wall-clock cadence as well; this does not
change the deltas returned to the application.

## Per-window recording and mixed live/replay

Pass a window slice to record only selected windows. Their recording IDs are
the indexes in the slice:

```zig
var recorder = try low.replay.Recorder.init(allocator, &context, .{
    .scope = .{ .windows = &.{preview_window} },
});
```

Use the matching scope during replay:

```zig
var replayer = try low.replay.Replayer.init(allocator, &context, &recording, .{
    .scope = .{ .windows = &.{preview_window} },
});
```

`Replayer.nextFrame` still pumps native events by default. Only
`preview_window` suppresses native input, so other editor windows remain
interactive. Native surface/configuration events remain live for every window.
For non-positional or dynamic mappings, call `replayer.mapWindow(id, window)`.

Whole-context recordings identify windows by their context creation index.
Creating windows in the same order maps a multi-window application
automatically, including windows created after recording or replay starts.

## Saving and loading

`Recording.write(*std.Io.Writer)` emits a versioned, portable binary stream.
`Recording.read(allocator, *std.Io.Reader)` reconstructs an allocator-owned
timeline. Writers and readers remain caller-owned:

```zig
try recording.write(writer);
var loaded = try low.replay.Recording.read(allocator, reader);
defer loaded.deinit();
```

Frame and event slices are public so timeline tools can inspect or modify them.
Text bytes inside a `RecordedEvent` are owned by the recording.

## Custom main loops and clocks

Applications that already calculate their own delta can explicitly delimit
the event-polling portion of a frame:

```zig
try recorder.beginFrame(delta_ns);
context.pollEvents();
const frame = try recorder.endFrame();
```

Events injected or dispatched between `beginFrame` and `endFrame` are captured
in order. A custom `low.replay.Clock` can instead make `Recorder.nextFrame`
sample an application-owned clock.

For custom replay scheduling, `Replayer.dispatchFrame(index)` dispatches events
without moving the replay cursor. `Replayer.reset()` rewinds the cursor but
intentionally does not reset application or window state.

`Window.injectEvent` is backend-neutral and immediate. It uses the same state
and callback dispatcher as native and replayed input, and is available on
desktop as well as offscreen contexts.

## Screenshots and Vulkan Video recording

Use the replay frame's delta for every simulation update that affects pixels.
For Vulkan Video's monotonic timing, also pass the deterministic elapsed time:

```zig
const frame = try recorder.nextFrame(); // or replayer.nextFrame().?
update(frame.deltaSeconds(f32));

var render_frame = try target.acquire();
// Record rendering commands.
try render_frame.submitAndPresent(.{
    .recording = .{ .timestamp_ns = frame.elapsed_ns },
});
```

The same event sequence, update deltas, frame admission decisions, and video
timestamps then reach screenshot/readback and recording paths. Fixed-rate video
recording may use its normal fixed timestamp policy; the replay timestamp still
drives identical rate admission.

The [`multiwindow_triangles`](../examples/multiwindow_triangles/README.md#input-timeline-recording-and-replay)
example is the complete reference implementation. Its `--record-input` path
wraps polling and compositor waits with explicit frame boundaries, while
`--replay-input` drives both windows until timeline exhaustion. Combining it
with `--desktop=offscreen --dump-frames` demonstrates byte-identical frame
output.
