# Vulkan Video recording

`low` can encode frames submitted to a Vulkan `RenderTarget` as AV1, H.265, or H.264. The
feature is optional: build with `-Dvk_video=true`, then access it through
`low.vulkan.video()`.

The module can query and select the host's AV1, H.265, and H.264 Vulkan Video
encode capabilities. Pass
the formats in preference order; the returned support object carries the exact
queue requirements for the selected codec:

```zig
const video = low.vulkan.video();
const selected = try video.selectVideoFormat(.{
    .instance = &instance,
    .physical_device = physical_device,
    .extent = .{ .width = 1920, .height = 1080 },
}, &.{ .av1, .h265, .h264 }) orelse return error.NoRequestedVideoFormat;
```

Use `video.requiredDeviceExtensions(selected.codec())` and
`selected.deviceRequirements(...)` when building the matching logical device.
H.264's existing `required_device_extensions` value remains available for
compatibility.

The recorder captures the render target's submitted BGRA frames on the GPU. It
does not capture the desktop, other application windows, or audio. Frames are
converted to a video input format on the GPU, encoded with Vulkan Video, and
written to a caller-owned `std.Io.Writer`.

The recorder accepts `VK_FORMAT_B8G8R8A8_UNORM` (BGRA8) and the packed 10-bit
UNORM render-target formats `VK_FORMAT_A2B10G10R10_UNORM_PACK32` and
`VK_FORMAT_A2R10G10B10_UNORM_PACK32`. Packed 10-bit sources are normalized to
RGBA8 during the GPU conversion path before being converted to the selected
8-bit 4:2:0 codec input. Recording a 10-bit render target therefore preserves
the renderer's framebuffer precision up to that conversion, but it does not
produce 10-bit video with the recorder's existing codec profiles.

## Before creating the Vulkan device

Vulkan Video extensions and an encode queue must be enabled when the device is
created. Query support after selecting a physical device, then merge the
reported extensions and queue requirements into the application's device
creation data:

```zig
const video = low.vulkan.video();

const support = try video.queryH264Support(.{
    .instance = &instance,
    .physical_device = physical_device,
    .extent = .{ .width = 1920, .height = 1080 },
});
if (!support.available) return error.H264EncodingUnavailable;

var requirements = try support.deviceRequirements(.{
    .graphics_queue_family = graphics_queue_family,
});
defer requirements.deinit(allocator);

// Add support.required_device_extensions and
// requirements.queue_create_infos to VkDeviceCreateInfo.
```

Capability queries are also the normal unsupported-hardware path: an
unavailable result carries a reason instead of requiring device creation to
fail. The query checks the codec extension, an encode queue for that codec,
the supported profile, coded extent and alignment, encode-input and DPB image
formats, and at least one usable rate-control mode. For a runtime codec
choice, use `selectVideoFormat` with the preferred order; apply the returned
support object's extensions and queue requirements to the same device.

Create `VideoDevice` from the resulting Vulkan device and supply it through
`targets().RenderContext.video_device`. The target must be deinitialized
before its `VideoDevice`. The encode queue is owned by `low` for the lifetime
of the `VideoDevice`; do not submit application work to that queue directly.

## Minimal recording lifecycle

Use Matroska unless a downstream consumer specifically requires a raw codec
stream. Start recording before submitting frames, then end it before closing the
writer:

```zig
try target.beginRecording(.{
    .allocator = allocator,
    .io = io,
    .writer = writer,
});
defer target.endRecording() catch {};

var frame = try target.acquire();
// Record application rendering commands into frame.command_buffer.
try frame.submitAndPresent();

try target.endRecording();
```

`endRecording` waits for submitted frames to encode and writes remaining
container data. Check `recordingStatus` while recording if the application
needs to surface asynchronous encoding failures. It returns `null` when
inactive, `.recording` while active, `.stopped_resize` after a configured
resize stop, or `.failed` with the retained error.

`releaseRecordingResources` is optional: it frees cached video-session and
conversion resources after recording stops. Target deinitialization does this
automatically.

## Choosing output format

`.mkv` is the default and recommended format. It is forward-only, so the
writer does not need seeking, and it supports variable frame timestamps and
Matroska track updates for resize handling.

`.raw` writes the selected codec's native elementary stream (Annex-B for H.264
and H.265, OBU stream for AV1). Choose it only when the consumer expects that codec. It
has no container timestamps, so it only accepts fixed-rate timing. Set
`RecordingOptions.codec`; unsupported recorder codecs are rejected before any
output is written.

## Timing

`RecordingOptions.timing` combines timestamp behavior with the nominal frame
rate needed to configure H.264 and Vulkan rate control:

```zig
// Evenly spaced 60 fps timestamps. This is the default.
.timing = .{ .fixed_rate = .fps(60) },

// Variable timestamps taken when each frame is submitted.
.timing = .{ .monotonic = .fps(60) },

// Variable timestamps supplied by the application.
.timing = .{ .explicit = .init(30_000, 1001) },
```

Use `.fixed_rate` for a conventional recording where every submitted frame
should play at an even interval. `submitAndPresentAt` is rejected in this mode.

Use `.monotonic` for a variable-rate recording driven by normal rendering.
`submitAndPresent` timestamps each frame using the monotonic clock. The carried
frame rate is a nominal encoder setting; it does not force frames to that
cadence.

Use `.explicit` when timestamps come from an application clock, a media source,
or another external scheduler. Submit every recorded frame with
`submitAndPresentAt(timestamp_ns)`. Timestamps are nanoseconds on the recording
timeline and must be strictly increasing. The carried frame rate remains a
nominal encoder setting because the Vulkan Video session is configured before
future timestamps are known.

`.fps(60)` is the clearest choice for whole-number rates. Use
`.init(30_000, 1001)` for exact fractional rates such as NTSC 29.97 fps;
fractions avoid accumulated rounding error from a nanosecond interval.

## Quality and file-size tradeoffs

`bitrate` is the target number of bits per second. More bitrate generally
preserves more detail and produces larger output. The 12 Mbps default is a good
1080p starting point; fast motion, high resolutions, or text-heavy captures may
need more.

`gop_size` is the maximum number of frames between IDR keyframes. A shorter
GOP improves seeking, recovery after corruption, and the usefulness of stream
segments, but costs bitrate. A value of 60 is about one second at 60 fps.

Use `.quality = .balanced` unless a specific tradeoff is required.
`.low_latency` requires the device's low-latency tuning and CBR support;
`.high_quality` requires high-quality tuning and VBR support. Either specialized
mode can be unavailable on a given driver.

Keep `.parameter_sets = .every_idr` for streaming or independently cut
segments. It repeats H.264 SPS/PPS or H.265 VPS/SPS/PPS at keyframes, adding a small
amount of data but making those segments easier to decode independently.

## Resizing

`resize` controls what happens when the render target's source size changes:

- `.scale_and_letterbox` keeps the original encoded dimensions, fitting the new
  image within them. This maintains one video track.
- `.change_resolution` reconfigures the encoder and writes a new Matroska track
  description, preserving the new source dimensions.
- `.stop_recording` stops accepting frames at the resize boundary. Observe
  `.stopped_resize`, finish the current file, then start a new recording.

For the broadest player compatibility when sizes may change, prefer `.mkv`.

## Example

[`examples/multiwindow_triangles`](../examples/multiwindow_triangles/README.md)
can record both of its windows with `zig build run -- --record`.
