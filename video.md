# Vulkan H.264 recording plan

## Status and scope

This document plans an optional Vulkan Video recorder for `low`. It does not
describe a CPU screenshot-to-encoder path. Rendered images remain on the GPU,
are converted from the render target's BGRA format to a driver-supported video
input format, encoded by Vulkan Video, and only the compressed H.264 bytes are
read by the CPU.

The implementation supports:

- encode H.264/AVC through `VK_KHR_video_encode_h264`;
- write either raw Annex-B H.264 or streaming Matroska to a caller-owned
  `std.Io.Writer`;
- work with offscreen and WSI-backed `RenderTarget` instances;
- remain optional at build time and runtime;
- detect unsupported devices without enabling unsupported device extensions;
- leave ordinary `submitAndPresent` and `submitAndReadback` behavior unchanged;
- support one recorder per render target and multiple targets recording through
  the same device, subject to successful driver resource/session allocation;
- optimize for correctness and validation-clean execution before pipelining.

MP4 muxing, audio, decode, network streaming protocols, H.265, and AV1 remain
out of scope. Matroska support is deliberately forward-only and video-only.

## Why this is separate from readback

Screenshot readback transitions the rendered BGRA image to transfer-source,
copies every pixel to a host-visible buffer, and waits for that copy. Recording
should avoid that bandwidth. Its frame path is instead:

```text
BGRA render target
    -> GPU RGB-to-YCbCr conversion
NV12-like encode-input image
    -> Vulkan Video H.264 encode
host-visible compressed bitstream buffer
    -> append encoded byte range to .h264 file
```

Vulkan Video requires a video profile, a compatible encode queue, video
session memory, session parameters, encode-input images, DPB/reference images,
bitstream buffers, and encode-feedback queries. Those resources are unrelated
to the existing CPU readback staging buffers.

## Build integration

Add a separate build option:

```text
-Dvk_video=true
```

`vk_video` will imply or require `vk_extras`. It must default to `false`.
Normal builds must not fetch Vulkan bindings or headers.

When enabled:

1. Lazily resolve the same pinned `vulkan-zig` revision currently used by
   `examples/multiwindow_triangles`.
2. Lazily resolve pinned Vulkan headers for registry-driven binding generation.
3. Add the generated binding to `low` under a private import name.
4. Compile and embed RGB-to-YCbCr compute shaders. Prefer checked-in SPIR-V so
   consumers do not need `glslc`; keep GLSL sources and a reproducible shader
   regeneration build step for maintainers.
5. Export the recorder only through `low.vulkan.video()` or a similarly lazy
   accessor, matching `low.vulkan.targets()`. Calling it without `vk_video`
   should produce a targeted compile error.

The example should use the recorder exposed by `low`, not a second independent
implementation. Its direct `vulkan-zig` dependency remains useful for its
renderer and device creation.

## Public API proposal

### Capability discovery before device creation

The application owns Vulkan instance/device creation, so discovery must happen
before `VideoRecorder.init`.

```zig
const video = low.vulkan.video();

const support = try video.queryH264Support(.{
    .instance = instance,
    .physical_device = physical_device,
    .extent = .{ .width = width, .height = height },
});

if (!support.available) {
    // support.reason explains the first failed requirement.
}

for (support.required_device_extensions) |extension| {
    // Merge into VkDeviceCreateInfo extensions.
}

// Include this family in VkDeviceCreateInfo queue create infos.
const encode_family = support.encode_queue_family;
```

Proposed public types:

```zig
pub const H264Support = struct {
    available: bool,
    reason: ?UnsupportedReason,
    encode_queue_family: ?u32,
    required_device_extensions: []const [*:0]const u8,
    input_format: ?vk.Format,
    dpb_format: ?vk.Format,
    max_extent: vk.Extent2D,
    min_extent: vk.Extent2D,
    picture_access_granularity: vk.Extent2D,
    max_dpb_slots: u32,
    max_active_reference_pictures: u32,
    rate_control_modes: vk.VideoEncodeRateControlModeFlagsKHR,
};

pub const UnsupportedReason = enum {
    missing_device_extension,
    no_h264_encode_queue,
    unsupported_profile,
    unsupported_extent,
    no_encode_input_format,
    no_dpb_format,
    no_usable_rate_control_mode,
};
```

Discovery should provide structured diagnostics rather than treating normal
hardware absence as a generic Vulkan error. Allocation failures and malformed
driver responses remain errors.

Required device extensions initially are:

- `VK_KHR_video_queue`
- `VK_KHR_video_encode_queue`
- `VK_KHR_video_encode_h264`

Vulkan 1.3 supplies synchronization2. If the implementation is ever relaxed
to Vulkan 1.2, discovery must additionally account for the appropriate
synchronization extension.

The helper must:

1. Enumerate device extensions.
2. Enumerate queue families with `VkQueueFamilyProperties2` and
   `VkQueueFamilyVideoPropertiesKHR`.
3. Require `VK_QUEUE_VIDEO_ENCODE_BIT_KHR` and
   `VK_VIDEO_CODEC_OPERATION_ENCODE_H264_BIT_KHR` on the selected family.
4. Query an H.264 profile with 4:2:0 chroma and 8-bit luma/chroma.
5. Query generic, encode, and H.264 capabilities.
6. Query encode-input and DPB formats for that exact profile.
7. Validate the requested extent and required alignments.
8. Choose a rate-control mode supported by the driver.

The helper should prefer a queue family that also supports compute, since that
can avoid ownership transfers between RGB conversion and encoding. It must
still support separate compute/graphics and video-encode families.

### Device requirements utility

Provide a helper which merges queue requirements without creating the device:

```zig
const requirements = support.deviceRequirements(.{
    .graphics_queue_family = graphics_family,
    .queue_priority = 1.0,
});
defer requirements.deinit(allocator);

// requirements.queue_create_infos contains one entry when graphics and video
// use the same family, otherwise one per unique family.
```

The application remains responsible for merging unrelated extensions and queue
requirements. The helper must not return pointers into temporary stack data.

### Video queue ownership and recorder lifecycle

Configure video support once, near render-target/device initialization:

```zig
var video_device = try video.VideoDevice.init(.{
    .allocator = allocator,
    .instance = instance,
    .physical_device = physical_device,
    .device = device,
    .encode_queue = encode_queue,
    .encode_queue_family = encode_queue_family,
    .compute_queue = graphics_queue,
    .compute_queue_family = graphics_queue_family,
});
defer video_device.deinit();

var target = try RenderTarget.init(allocator, .{
    // Existing target options...
    .video_device = &video_device,
});
```

`VkQueue` handles are owned by their `VkDevice` and are not destroyed by
`VideoDevice`. "Queue ownership" here means exclusive submission ownership:
from `VideoDevice.init` until `deinit`, the caller promises not to submit work
to the supplied encode queue directly. `low` owns queue synchronization,
submission ordering, command pools, and all recorder resources. This avoids
requiring callers to externally synchronize a shared queue and gives multiple
recorders one submission coordinator.

Every attached target must be destroyed before `VideoDevice.deinit`. The video
device may assert this ordering in safety builds; it remains a documented
lifetime requirement in all build modes.

If exclusive ownership is too restrictive later, a callback-based submit lock
can be added as an advanced option. It should not be part of the first API.

Prefer explicit target-level begin/end calls:

```zig
try target.beginRecording(.{
    .allocator = allocator,
    .io = io,
    .writer = output_writer,
    .frame_rate = .{ .numerator = 60, .denominator = 1 },
    .bitrate = 12_000_000,
});
defer target.endRecording() catch {};

// Existing call records automatically while recording is active.
try frame.submitAndPresent();

try target.endRecording();
```

Reasons to prefer `beginRecording`/`endRecording` over an init-time feature
flag:

- recording can start and stop during a target's lifetime;
- expensive video resources exist only while recording;
- output and encoding parameters belong to a recording session, not target
  creation;
- existing frame call sites need no conditional submission method;
- the target can enforce that resize/session recreation and frame submission
  are coordinated.

`beginRecording` must fail if a frame is currently acquired. `endRecording`
must drain submitted encode work, write remaining packets, flush the
caller-owned writer, and place compatible recorder resources into the target
cache. It never closes the writer. Calling it when not recording is idempotent.

Resource allocation and compatibility checks happen in `beginRecording`.
Failure to create the session, bind session memory, allocate DPB/conversion/
bitstream rings, or configure the requested output returns immediately and
leaves the target non-recording. Once begin succeeds, normal capacity failures
should not occur because all per-flight resources are preallocated.

Bitstream buffers should be conservatively sized from coded extent rather than
expected average bitrate, so a large IDR packet cannot overflow merely because
rate control temporarily exceeds its target. Feedback ranges are still checked
before every host read.

`endRecording` stops accepting frames, drains every submitted encode, consumes
the final feedback queries, writes remaining packets, flushes the output, and
returns any sticky recording error captured since begin. It is therefore the
authoritative result of the complete recording.

Errors are divided into two classes:

- **Recording-local asynchronous errors** (encode feedback failure, packet
  bounds failure, or output I/O failure) are stored as the recorder's first
  sticky error. Further encode work for that recorder stops, ordinary rendering
  continues where safe, and `endRecording` returns the stored error.
- **Shared-device/render errors** (notably device loss, graphics submission
  failure, or synchronization failure that makes continued resource use
  unsafe) are returned immediately by the frame submission call and also stored
  for `endRecording`. They cannot safely be hidden until the end.

Expose non-consuming status for applications that want early notification:

```zig
if (target.recordingStatus()) |status| switch (status) {
    .recording => {},
    .failed => |err| log.err("recording stopped: {}", .{err}),
};
```

The status query does not replace `endRecording`, which performs draining and
cleanup and returns the authoritative error.

### Resource caching between recording runs

`endRecording` should retain compatible GPU-only recorder resources by default:

- video session and bound session memory;
- DPB images;
- private BGRA and YCbCr conversion rings;
- bitstream buffers, queries, command buffers, and synchronization objects;
- conversion pipeline and descriptor infrastructure.

It must release or reset run-specific state:

- output file/writer association;
- encoded packets and feedback state;
- frame/GOP/reference-slot counters;
- sticky error;
- rate-control state that cannot be safely reused;
- session parameters when changed options require replacement.

`beginRecording` reuses the cache only when profile, coded extent, format,
frames-in-flight, and relevant session options are compatible. Otherwise it
builds a replacement transactionally, then destroys the old cache after the
new resources succeed. Provide:

```zig
target.releaseRecordingResources();
```

for applications that want memory returned before target destruction. Target
destruction always releases the cache. Capability/resource admission is still
performed on every begin; a cached session for one target does not guarantee a
new concurrent session for another target.

Encoded data leaves the recorder through a caller-provided `std.Io.Writer` in
the selected recording format:

```zig
.writer = output_writer,
```

A `std.Io.File` uses its writer and needs no recorder-specific path API. The
example opens its own output file and supplies that writer. The recorder never
closes a caller-owned writer, does not require seeking, and flushes it during
`endRecording`. Writer errors become sticky recording-local errors and are
returned by `endRecording`.

Raw mode writes one continuous Annex-B elementary stream. Matroska mode writes
an unknown-sized Segment, AVC configuration in `CodecPrivate`, and one
H.264 picture per block. Each Matroska recording starts an
independent timeline and therefore needs a fresh writer rather than appending
to an earlier MKV recording.

### Container scope

H.264 is the encoded video codec. Names such as MPEG-TS, MPEG-PS, MP4, and MKV
refer to containers or transport formats around encoded packets. A container
can store timestamps and additional streams, but requires muxing tables,
packetization, finalization, and often seeking. It does not simplify Vulkan
Video encoding. Raw Annex-B remains the smallest output and can be played by
tools such as `ffplay` or remuxed later without re-encoding. The built-in MKV
path adds fixed-rate or clock/caller-driven timestamps and standard AVC framing without seeking,
audio, Cues, or general-purpose muxing machinery. MP4 still requires a
seekable/finalizable muxing design and remains out of scope.

### Recording options

Proposed initial options:

```zig
pub const RecordingOptions = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,

    frame_rate: Rational = .{ .numerator = 60, .denominator = 1 },
    bitrate: u32 = 12_000_000,
    gop_size: u32 = 60,
    quality: Quality = .balanced,
    resize: ResizePolicy = .scale_and_letterbox,
    timestamp_mode: TimestampMode = .fixed_rate,
    parameter_sets: ParameterSetPolicy = .every_idr,
    format: RecordingFormat = .h264,
};

pub const Quality = enum { low_latency, balanced, high_quality };
pub const Rational = struct { numerator: u32, denominator: u32 };
pub const ResizePolicy = enum { scale_and_letterbox, change_resolution, stop_recording };
pub const TimestampMode = enum { fixed_rate, monotonic, explicit };
pub const ParameterSetPolicy = enum { stream_start, every_idr };
pub const RecordingFormat = enum { h264, mkv };
```

Avoid exposing raw codec structures in the basic API. An advanced options
escape hatch can be added after the initial implementation has stable defaults.

## Internal module layout

Suggested files:

```text
src/vulkan/video.zig             public discovery and recorder facade
src/vulkan/video/capabilities.zig
src/vulkan/video/encoder.zig     session, DPB, encode commands, feedback
src/vulkan/video/conversion.zig  BGRA-to-YCbCr resources and compute dispatch
src/vulkan/video/h264.zig        SPS/PPS/session-parameter construction
src/vulkan/video/matroska.zig    forward-only EBML/Matroska muxing
src/vulkan/video/shaders/*.comp
src/vulkan/video/shaders/*.spv
```

Keep `targets.zig` changes limited to recorder attachment and submission hooks.
Do not place the video implementation in platform backends: it is Vulkan and
render-target functionality shared by offscreen, Wayland, X11, and Windows.

## Encoder resource model

`VideoRecorder` should own:

- the selected video profile and queried capabilities;
- a command pool and command buffers for the encode queue;
- conversion pipeline, descriptors, and per-frame descriptor sets;
- one or more driver-supported YCbCr encode-input images;
- image views for the combined multi-planar image and individual planes;
- DPB images/views and slot bookkeeping;
- the `VkVideoSessionKHR` and all required bound session memory;
- `VkVideoSessionParametersKHR` with H.264 SPS/PPS data;
- encode-feedback query pools;
- host-visible compressed-bitstream buffers;
- per-flight fences/semaphores and queue-family ownership state;
- the output writer/file;
- frame number, IDR/GOP state, and resize state.

Allocate resources as a per-frame ring. Reuse a slot only after its encode
fence has completed and its compressed packet has been written. Start with the
same number of slots as the target's frames in flight.

### Multiple simultaneous streams

Vulkan does not expose a portable maximum-concurrent-video-session count.
`VkVideoCapabilitiesKHR` describes an individual profile/session (extent,
alignment, DPB/reference limits, and related requirements), not how many such
sessions can run concurrently or sustain a requested frame rate. Concurrent
limits may also depend on resolution, bitrate, codec settings, memory pressure,
driver policy, and hardware scheduling.

Accordingly, `low` should not advertise a guessed stream count. Each target may
own one independent recorder, and callers may start recorders on as many
targets as desired. Admission succeeds only after that recorder's video
session, bound session memory, DPB, conversion ring, and bitstream ring have all
been created. If another stream exceeds driver or resource limits,
`beginRecording` returns the underlying allocation/session error without
stopping recorders that are already active.

Recorders may share one encode queue. Submissions on that queue must be
serialized as Vulkan requires; per-recorder command pools, command buffers,
semaphores, fences, DPB state, feedback queries, and output writers remain
independent. The first implementation may assume all calls occur on the same
application thread. A later thread-safe queue-submit coordinator can be added
without changing the recorder API.

Capability discovery can answer whether a device supports the requested H.264
profile, format, and extent, but cannot promise real-time throughput. Expose
per-recorder dropped/backpressured-frame statistics later if non-blocking frame
dropping is introduced.

## RGB-to-YCbCr conversion

The target currently renders BGRA8. H.264 implementations commonly expose a
4:2:0 8-bit multi-planar encode input such as
`VK_FORMAT_G8_B8R8_2PLANE_420_UNORM`; the actual format must come from
`vkGetPhysicalDeviceVideoFormatPropertiesKHR`.

The compute conversion must:

- sample or load the completed BGRA render image;
- write full-resolution luma and half-resolution interleaved chroma planes;
- use a documented color matrix and range;
- handle odd target dimensions according to video capability granularity,
  either by rejecting them or padding the coded extent;
- use separate plane views where required;
- transition the result to `VK_IMAGE_LAYOUT_VIDEO_ENCODE_SRC_KHR`;
- include the video profile list in image creation chains where required.

Do not assume a swapchain image can be sampled or used as storage. The robust
common path is to copy the completed render target into a recorder-owned BGRA
image with transfer usage, return WSI images to presentation promptly, and run
conversion from that private image. A direct sampling optimization may be used
only when image usage and synchronization make it valid. Offscreen targets
should use the same private-source ring initially so both paths share one
tested synchronization model.

Default recommendation: BT.709 limited range for normal desktop/game output.
Color metadata in SPS/VUI must agree with the shader conversion.

Checked-in SPIR-V should be generated from small, readable GLSL compute
shaders. A build/test utility should regenerate and compare the binaries when
the SDK is available.

## H.264 stream construction

Use an H.264 4:2:0 8-bit profile supported by the device. Prefer High profile,
then Main, then Baseline if capability queries require fallback.

At recording start:

1. Construct SPS/PPS standard-video structures consistent with extent, frame
   rate, GOP, profile, level, and color metadata.
2. Create video session parameters.
3. Retrieve encoded session parameters with
   `vkGetEncodedVideoSessionParametersKHR` when supported/required.
4. Write SPS/PPS as Annex-B headers in raw mode or as an
   AVCDecoderConfigurationRecord in Matroska `CodecPrivate`.

For frames:

- frame zero is IDR;
- force a new IDR at each GOP boundary;
- start with I/P-only encoding and no B frames;
- maintain one reference picture initially;
- supply codec-specific picture and reference-list structures;
- obtain the actual encoded offset/size from a video encode feedback query;
- append exactly that byte range, never the entire destination buffer;
- repeat SPS/PPS before IDR frames only if needed for robust standalone
  playback; make the final policy explicit.

Raw `.h264` has no timestamps or audio. Its configured frame rate is signaled
through SPS/VUI and rate control, while playback timing depends on that
metadata/player behavior. Matroska supports three timestamp modes.
`.fixed_rate` derives timestamps from the rational frame rate. `.monotonic`
records elapsed monotonic time from `beginRecording`, so an application stall
remains a gap in playback. `.explicit` requires
`Frame.submitAndPresentAt(timestamp_ns)` or
`Frame.submitAndReadbackAt(allocator, timestamp_ns)`; timestamps are relative
to the recording timeline and must increase strictly. The `At` methods may
also override individual timestamps in `.monotonic` mode. Variable timestamp
modes are rejected for raw H.264, which has no container timestamps.

## Frame submission and synchronization

### Same queue family

When the selected queue supports graphics/compute and video encode, use queue
submission ordering plus semaphores to keep conversion and encode asynchronous.
The sequence for a recorded onscreen frame is:

1. Render to the swapchain/offscreen image.
2. Copy it into a recorder-owned BGRA source image.
3. Transition the rendered WSI image back to present layout when applicable.
4. Dispatch BGRA-to-YCbCr conversion from the private source image.
5. Transition the YCbCr image to video encode source.
6. Signal conversion completion.
7. Begin video coding, encode, end video coding on the video-capable queue.
8. Signal the per-slot encode fence.
9. Present independently once the render-target copy is complete.
10. Before reusing a recorder slot, wait for its encode fence, query the packet
    range, and write compressed bytes.

Do not block the CPU once per submitted frame. Fence waits belong at slot reuse
or `endRecording`, allowing multiple frames in flight.

### Separate queue families

When conversion and encoding use different families:

- create YCbCr resources with exclusive sharing unless measurements justify
  concurrent sharing;
- use explicit release/acquire barriers for ownership transfer;
- synchronize queues with per-slot semaphores;
- transfer ownership back before the conversion slot is reused;
- use video encode pipeline stage/access flags, not generic transfer flags;
- keep swapchain images on the graphics family; only the intermediate YCbCr
  resources cross to the video family.

Timeline semaphores would simplify this but add another requirement. The first
implementation can use binary semaphores because the existing target already
uses them and Vulkan Video requires Vulkan 1.3-class synchronization support.

### Non-recording path

When no recorder is attached, the generated command buffers and submissions
must remain byte-for-byte equivalent where practical. No YCbCr images,
descriptor updates, conversion dispatches, video barriers, video queue
submissions, or recorder fence waits may occur.

## Resize behavior

Video sessions have coded-extent constraints, while desktop targets can resize
at any time.

Available policies:

- `.scale_and_letterbox` locks the coded extent selected at `beginRecording`;
- `.stop_recording` records until the first target resize;
- `.change_resolution` drains pending frames, recreates the Vulkan Video
  session and extent-dependent resources, forces an IDR with new SPS/PPS, and
  continues the same recording timeline.

For MKV, a resolution transition emits an updated Track entry and AVC
`CodecState` on the first new-resolution block. Raw H.264 emits new Annex-B
SPS/PPS before that IDR. The actual coded dimensions can be rounded to the
encoder's picture-access granularity, as with the initial extent.

## Rate control and quality

Capability discovery must intersect requested policy with driver support.

Suggested mapping:

- `low_latency`: low-latency tuning, CBR when supported, no B frames;
- `balanced`: default tuning, VBR preferred, no B frames initially;
- `high_quality`: high-quality tuning, VBR preferred.

Capability utilities must expose supported tuning modes, rate-control modes,
quality levels, and their recommended settings before recording begins. An
explicitly requested unsupported setting returns an error; the library does
not silently substitute policy. If a capability cannot be queried reliably,
the driver may still reject session creation and that error is returned from
`beginRecording`.

Use `vkGetPhysicalDeviceVideoEncodeQualityLevelPropertiesKHR` to choose a valid
quality level and recommended rate-control settings when available.

## Errors and diagnostics

Proposed recorder-specific errors:

```zig
error{
    VideoEncodeUnsupported,
    MissingVideoDeviceExtension,
    MissingVideoEncodeQueue,
    UnsupportedVideoProfile,
    UnsupportedVideoFormat,
    UnsupportedVideoExtent,
    UnsupportedRateControl,
    RecordingAlreadyActive,
    NotRecording,
    FrameAlreadyAcquired,
    VideoSessionCreationFailed,
    EncodeFeedbackUnavailable,
    EncodedPacketOutOfBounds,
};
```

Where Vulkan calls provide useful errors, preserve them rather than collapsing
everything into this set. Capability absence should be queryable without log
spam. Once recording begins, fatal encode errors should leave the recorder in a
state where `endRecording` can safely release resources and report the stored
failure.

## Example integration

Extend `multiwindow_triangles` with command-line recording options, for example:

```text
--record path.h264
--record-fps 60
--record-bitrate 12000000
```

The example should:

1. Enumerate normal graphics/presentation requirements.
2. Call `queryH264Support` for each candidate physical device when recording
   was requested.
3. Select a device supporting both rendering and H.264 encode.
4. Merge the required device extensions and unique queue families.
5. Retrieve both graphics and encode queues after device creation.
6. Start recording every selected window/target independently.
7. Keep the existing BMP offscreen dump as a separate demonstration.
8. End recording before target/device destruction.
9. Print a clear message and exit cleanly if recording was requested on an
   unsupported driver.

The example should support recording both windows simultaneously to separate
elementary streams. Start them independently and report which stream failed if
the driver cannot allocate the second session; do not tear down the first
successful recorder unless the CLI requests all-or-nothing behavior.

## Validation and testing

### Unit tests without video hardware

- extension-list intersection and missing-extension diagnostics;
- unique queue-family merge logic;
- extent alignment/padding calculations;
- frame-rate rational and H.264 timing calculations;
- SPS/PPS structure construction where values can be checked independently;
- GOP/IDR/reference-slot state transitions;
- encode feedback offset/range bounds checks;
- Annex-B start-code/session-header assembly;
- EBML size encoding, AVC configuration, Annex-B-to-length-prefix conversion,
  and fractional Matroska timestamps;
- recorder state machine (`idle -> recording -> draining -> idle/failed`);
- resize-to-fixed-coded-extent transform calculations.

### Compile tests

- default build does not resolve Vulkan Video dependencies;
- `-Dvk_extras=true -Dvk_video=true` compiles on Linux and Windows targets;
- public declarations remain lazy when video is disabled;
- example compiles with and without recording CLI support.

### Hardware integration tests

On a Vulkan Video-capable machine:

- run with `VK_LAYER_KHRONOS_validation` and fail on any validation message;
- record offscreen and WSI targets;
- exercise same-family and separate-family encode queues when hardware permits;
- record more frames than the resource-ring size;
- record across target resize with fixed and changing coded extents;
- verify fixed-rate, monotonic, and explicit timestamp modes, including a
  deliberate submission gap;
- verify `ffprobe` recognizes H.264 profile, dimensions, and frame rate;
- decode with `ffmpeg` and compare selected frames against screenshot readback
  within expected lossy compression tolerance;
- ensure normal rendering performance is unchanged when not recording;
- measure recording without per-frame CPU stalls;
- test unsupported hardware and missing-extension paths.

The CI suite should skip hardware tests with an explicit reason when no encode
device is present. Software Vulkan implementations generally cannot be assumed
to expose H.264 encode.

## Delivery phases

1. **Build and discovery**
   - lazy dependencies and build option;
   - public support query;
   - queue/device requirement utilities;
   - example device selection diagnostics.

2. **Video session and elementary stream**
   - profile/format selection;
   - session memory and parameters;
   - DPB and bitstream resources;
   - encode an already-compatible YCbCr test image;
   - produce a validator-clean single-frame `.h264` stream.

3. **GPU color conversion**
   - embedded compute shaders;
   - multi-planar image creation and plane views;
   - BGRA conversion;
   - encode deterministic test frames.

4. **RenderTarget integration**
   - begin/end state machine;
   - automatic per-frame recording hook;
   - onscreen presentation and offscreen support;
   - separate-queue ownership transfers;
   - asynchronous frame ring.

5. **Example and hardening**
   - CLI and device creation changes;
   - resize handling;
   - rate-control/quality selection;
   - validation, ffprobe/decode checks, docs, and performance measurement.

Each phase should land with tests and avoid exposing placeholder APIs that claim
recording works before a valid stream can be produced.

## Resolved decisions

1. Multiple requested streams start independently. Failure to admit a later
   stream does not stop streams already running.
2. Resize behavior is selected at `beginRecording`: fixed coded extent with
   scaling/letterboxing, a mid-stream session/codec-state transition, or stop
   accepting frames and drain the recording. Resize-stop is a normal stop
   reason rather than an encode error;
   `recordingStatus` exposes `.stopped_resize` and `endRecording` finalizes it
   successfully.
3. The recorder writes raw Annex-B H.264 or forward-only Matroska to a
   caller-provided `std.Io.Writer`, including a file writer. It does not own or
   close it. Each MKV recording requires a fresh writer.
4. `endRecording` is idempotent and `isRecording`/`recordingStatus` expose state.
5. Capability helpers expose rate-control and quality support. Explicitly
   unsupported settings fail instead of silently falling back.
6. SPS/PPS policy is configurable as stream-start-only or every-IDR, defaulting
   to every IDR.
7. Every submitted frame is encoded in submission order. Fixed mode derives
   Matroska timestamps from `RecordingOptions.frame_rate`; monotonic mode uses
   elapsed recording time; explicit mode accepts strictly increasing
   nanosecond timestamps from the frame submission API.
8. GLSL and generated SPIR-V live together in the source tree. SPIR-V is
   checked in and loaded with `@embedFile`; downstream builds do not run shader
   generation. Regeneration is a documented maintainer command, not part of the
   normal build graph.

## Remaining decisions

None currently. Both outputs preserve the forward-only
`std.Io.Writer` contract.

## References

- Vulkan video coding specification:
  <https://docs.vulkan.org/spec/latest/chapters/videocoding.html>
- `VK_KHR_video_encode_queue` proposal and examples:
  <https://docs.vulkan.org/features/latest/features/proposals/VK_KHR_video_encode_queue.html>
- `VK_KHR_video_encode_h264` proposal:
  <https://docs.vulkan.org/features/latest/features/proposals/VK_KHR_video_encode_h264.html>
- Matroska container specification:
  <https://www.rfc-editor.org/rfc/rfc9559.html>
- Matroska codec mapping for `V_MPEG4/ISO/AVC`:
  <https://datatracker.ietf.org/doc/draft-ietf-cellar-codec/>
- Small MIT-licensed reference implementation used to validate the resource
  inventory and BGRA-to-YCbCr requirement:
  <https://github.com/clemy/vulkan-video-encode-simple>
