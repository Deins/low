# low implementation notes

This document is for contributors and for applications that need to understand
the platform boundary. The supported application API is documented in the
[main README](../README.md).

## Backend selection and loading

On Linux, `InitOptions.backend` is a tagged union accepting `.auto`, `.wayland`,
`.x11`, or `.offscreen`. The offscreen variant carries its `OffscreenOptions`;
the other variants currently have no backend-specific settings. Automatic
selection gives `XDG_SESSION_TYPE` precedence. When it is unset,
`WAYLAND_DISPLAY` and `DISPLAY` are used. If both desktop sockets are available,
automatic selection may try the other enabled backend after a library or
connection failure; explicit backend requests remain strict.

```zig
var context = try low.Context.init(allocator, .{
    .backend = .{ .offscreen = .{
        .frame_mode = .{ .continuous = .{ .interval_ns = 16_666_667 } },
    } },
});
```

The Linux desktop backends load their system libraries at runtime:

- Wayland loads `libwayland-client.so.0` and `libxkbcommon.so.0`.
- X11 loads `libX11.so.6`.

This keeps the unused desktop stack out of startup and allows one executable to
run on Wayland-only or X11-only systems. Missing libraries and failed display
connections are reported through `low.Error`. Loaded libraries remain alive for
the process lifetime because generated protocol calls and live windows retain
function pointers into them.

The offscreen backend is entirely in-process: it creates logical windows,
dispatches synthetic events, and never loads or connects to a desktop library.

All platform input and window-state notifications converge on the shared
runtime event dispatcher. Deterministic input recording observes replay-safe
input events immediately before state/callback delivery. Replay uses that
dispatcher directly and can suppress native input for either selected windows
or the full context. Compositor-owned configure and frame-pacing events remain
live and are never replayed; explicit synthetic injection remains available on
every backend. The public frame timeline and persistence format are documented
in
[the input replay guide](input-replay.md).

## Vulkan layer

`low.vulkan` always exposes the small loader and surface helpers. The optional
render-target layer is compiled only with `-Dvk_extras=true`:

```zig
const RenderTarget = low.vulkan.targets().RenderTarget;
```

`RenderTarget` owns desktop surface/swapchain setup, frame command buffers,
synchronization, resize recreation, layout transitions, and presentation frame
pacing. The application still owns the Vulkan instance, physical-device
selection, queues, command pool, and rendering commands. Use
`targets().RenderContext` to share those low Vulkan resources across multiple
targets. Set its optional `present_queue` when presentation uses a queue family
different from graphics; the target configures concurrent
swapchain sharing in that case. It can use any Vulkan binding alongside low's
binding-agnostic ABI. When `DeviceSelectionSettings.presentation` is set, the
helper automatically checks and enables `VK_KHR_swapchain`; list it manually
only when using a custom selection path.

Create Vulkan windows with the low instance after enabling the context's
required instance extensions:

```zig
const window = try context.createWindow(.{
    .title = "low Vulkan window",
    .vulkan = &low_instance,
});
const surface = @enumFromInt(window.vulkanSurface().?);
```

The window owns this surface and destroys it before its native handle. The low
Vulkan instance must outlive the window. A render target automatically borrows
the window surface:

```zig
var target = try RenderTarget.init(allocator, .{
    .window = window,
    .context = &render_context,
});
defer target.deinit();
```

When `WindowOptions.vulkan` is omitted, onscreen targets create and own a surface
from the low window handles as a fallback. Set `RenderTarget.Options.surface`
to supply another existing surface instead; the caller retains ownership and
must destroy it after the target is deinitialized. The advanced
`presentation_surface` option still transfers an existing low surface to the
target, but cannot be combined with a window-owned surface.

`RenderTarget.Options.color_formats` is an ordered preference slice. WSI
targets choose the first requested surface format, while offscreen targets
check image-format features; `targets().default_color_formats` tries packed
10-bit UNORM formats before BGRA8. `chooseColorFormat` is available when an
application must choose its pipeline format before creating a target;
`chooseSurfaceFormat` and `chooseOffscreenFormat` remain available for more
specific selection. `RenderTarget.colorFormat()` reports the selected format
after initialization. Presentation defaults to `.vsync = .on`, which uses
FIFO. `.relaxed` prefers FIFO-relaxed and falls back to FIFO. `.off` prefers
immediate, then mailbox, FIFO-relaxed, and finally FIFO. `Options.present_modes`
can replace the standard policy with a custom ordered preference;
`setVSync` changes standard policy at runtime, while advanced `setPresentModes`
replaces it with a raw preference list for a later swapchain recreation. Screenshot
readback is disabled by default; set `Options.readback` when it is needed. A
configured Vulkan Video device enables the required transfer usage independently.

`Context.createVulkanSurface()` and `createVulkanPresentationSurface()` remain
advanced explicit helpers. Normal applications request the surface through
`WindowOptions.vulkan`. Before creating a window,
`Context.vulkanPresentationSupport()` supplies the backend-native descriptor
used by `Instance.findPresentQueueFamilyKHR()`. The latter calls
`vkGetPhysicalDeviceWaylandPresentationSupportKHR`,
`vkGetPhysicalDeviceWin32PresentationSupportKHR`, or
`vkGetPhysicalDeviceXlibPresentationSupportKHR` as appropriate. Xlib uses the
context's default visual. This lets device and queue selection precede native
window and Vulkan surface creation. A target still validates the selected queue
against its actual surface with `vkGetPhysicalDeviceSurfaceSupportKHR`.
`low.vulkan` also exposes handle conversion helpers for bridging generated
Vulkan bindings to its ABI.

For projects using a generated Vulkan binding, `targets()` also provides
binding-aware bootstrap helpers. `createInstance` loads an owned instance
wrapper. `findDevice` accepts `DeviceSelectionSettings(Vk)`, whose
`requirements` validate and enable core/Vulkan-versioned features and required
extensions. It independently selects graphics, presentation, compute,
transfer, and optional video-encode families. `createDevice` consumes that
selection, enables the same requirements (including selected video extensions),
and returns every selected queue plus the generated dispatch wrapper and low ABI
device view. `extra_features` and `extra_feature_support` cover arbitrary
extension feature pNext chains without coupling low to one Vulkan binding.
Pass the generated binding as the `Vk` comptime argument; the helpers do not
impose a particular binding or command-pool ownership model. Use
`RenderContext.init` to assemble the low render context from those resources.

For example, an application that needs independent asynchronous queues and
specific renderer capabilities can express all of them in the one selection
value:

```zig
const selection = try Targets.findDevice(vk, allocator, instance, &low_instance, .{
    .presentation = context.vulkanPresentationSupport(),
    .requirements = .{
        .required_extensions = &.{
            vk.extensions.khr_fragment_shader_barycentric.name,
        },
        .required_features = .{
            .multi_draw_indirect = .true,
            .wide_lines = .true,
            .geometry_shader = .true,
        },
        .required_features_12 = .{ .timeline_semaphore = .true },
    },
    .transfer_queue = .separate,
    .compute_queue = .separate,
});
var device_resources = try Targets.createDevice(vk, allocator, instance, &low_instance, selection);
```

The default Vulkan 1.3 requirements enable synchronization2 and dynamic
rendering. Add extension feature structs through `extra_features`, and validate
them through `extra_feature_support`, when an extension requires a feature bit.
When video selection chooses AV1, `selectVideoFormat` has already validated its
required feature and `createDevice` enables it without replacing the caller's
extra feature chain.

`Device.acquireNextImageKHR()` returns `null` for `VK_NOT_READY` and
`VK_TIMEOUT`; neither outcome acquires an image or supplies an image index.
`RenderTarget.acquire()` translates those normal WSI outcomes to
`error.FrameSkipped`.

Vulkan Video recording is enabled separately and implies `vk_extras`:

```zig
const video = low.vulkan.video(); // build with -Dvk_video=true
```

The option lazily generates a private binding from pinned Vulkan and Vulkan
Video registries. Capability discovery happens before device creation. A
`.on` `RecordingRequest` tries AV1, H.265, and H.264 automatically; `.codec`
and `.preferred` provide explicit control. Applications merge the selected
codec's device extensions and unique graphics / encode queue requirements.
`VideoDevice` then retains that codec as the default and coordinates one
exclusively owned encode queue across independently admitted render-target
recorders.

Each recorder copies the completed target into a private image before WSI
presentation, converts that image to BT.709 limited-range NV12 on the compute
queue, and submits selected-codec encode work through a per-frame
semaphore/fence ring.
Only feedback-selected compressed ranges are mapped and written on the CPU.
Compatible sessions, DPB storage, pipelines, and per-flight resources stay
cached after `endRecording`; `releaseRecordingResources` returns that memory
early.

Recording behavior and public API usage are documented in the
[Vulkan Video recording guide](recording.md). Matroska output uses an
unknown-sized streaming Segment and retains the recorder's non-seeking
`std.Io.Writer` contract. Each MKV `beginRecording` starts a new timeline, so
applications starting another MKV recording must supply a fresh writer rather
than append it to the previous file.

For an offscreen target, provide `memory_allocator` callbacks to allocate and
bind the target's images. Offscreen targets never create a surface or swapchain.
When readback or recording copies the rendered image, it is left in
`transfer_src_optimal` after submission; otherwise it remains in
`color_attachment_optimal`.

### Vulkan Video implementation invariants

Recording is deliberately separate from screenshot readback. The recorded
frame path is:

```text
completed BGRA8 render target
    -> recorder-owned source image
GPU color conversion to the selected codec input format
    -> Vulkan Video encode
feedback-selected compressed byte range
    -> caller-owned writer
```

The source contract is `VK_FORMAT_B8G8R8A8_UNORM`; packed 10-bit render
formats are not recordable until a separate source-conversion path exists.
The common conversion path uses BT.709 limited-range 4:2:0 data, and the
codec's color metadata must agree with the shader conversion. Swapchain images
are copied to private recorder images before conversion so recording does not
depend on swapchain sampling or storage usage. The normal rendering and
readback paths must not allocate video resources, submit conversion or video
commands, or wait on recorder fences.

Each target has at most one recorder. A `VideoDevice` may serve multiple
targets, but its encode queue is exclusively submitted by `low` while the
device is alive; targets must detach before `VideoDevice.deinit`. There is no
portable concurrent-session limit, so each `beginRecording` admits a stream
only after creating its session, session memory, DPB, conversion ring,
bitstream ring, and synchronization resources. A failed later admission must
not stop already-running recorders.

Recorder resources are organized as a per-frame ring. A slot is reused only
after its encode fence completes, feedback reports a bounded offset and size,
and the selected packet has been written. `endRecording` drains all submitted
slots and flushes the writer; it never closes the caller-owned writer.
Compatible GPU resources may remain cached between runs, while writer state,
packet state, frame/GOP counters, sticky errors, and incompatible session
parameters are reset. `releaseRecordingResources` explicitly drops that cache.

When conversion and encode use the same queue family, submission ordering and
per-slot semaphores are sufficient. Separate families require explicit
release/acquire ownership transfers for intermediate images and semaphores
between queue submissions. Fence waits belong at slot reuse or recording end,
not once per submitted frame, so the ring can absorb normal GPU latency.

## Vulkan Video validation and maintenance

The implementation should remain testable without video hardware. Unit tests
belong around extension and queue requirement merging, coded-extent alignment,
frame-rate calculations, codec parameter-set construction, GOP/reference-slot
state, feedback range bounds, raw stream headers, Matroska encoding, and the
recorder state machine. Compile coverage must include the default build with
video disabled and the optional video build on supported target platforms.

Hardware validation should exercise both offscreen and WSI targets, more
frames than the ring size, resize policies, fixed/monotonic timing,
unsupported-device paths, and same-family and separate-family queues where
available. Run with Vulkan validation layers, then verify output with a media
probe and decoder. Hardware tests should be skipped with an explicit reason
when no Vulkan Video encode device is present.

The BGRA-to-NV12 GLSL source and checked-in SPIR-V are kept together under
`src/vulkan/video/shaders`. Normal consumers use the checked-in binary; the
maintainer-only `check-vk-video-shader` and `regenerate-vk-video-shader` build
steps are used when `glslc` is available.

The Vulkan Video implementation follows the [Vulkan video coding
specification](https://docs.vulkan.org/spec/latest/chapters/videocoding.html),
the [`VK_KHR_video_encode_queue` proposal](https://docs.vulkan.org/features/latest/features/proposals/VK_KHR_video_encode_queue.html),
and the codec-specific encode proposals. Matroska details follow
[RFC 9559](https://www.rfc-editor.org/rfc/rfc9559.html) and the
[Vulkan/Matroska codec mapping](https://datatracker.ietf.org/doc/draft-ietf-cellar-codec/).
These references are useful when changing synchronization, codec headers, or
the forward-only muxer.

## Platform behavior

- Wayland `show()` and `hide()` record requested visibility. The renderer owns
  the surface buffer and therefore controls when the surface is actually mapped.
- Desktop windows expose `Window.isRenderSuspended()`. Applications can use it
  to pause rendering while a window is not being presented, but must
  treat it as a best-effort hint rather than an exact visibility query.
  Wayland reports the optional `xdg_toplevel.state.suspended` state when a
  compositor supports xdg-shell v6 or newer; it may still omit the hint.
  X11 uses map/unmap plus `VisibilityNotify`; a window moved to another virtual desktop is
  normally unmapped by its window manager. Win32 uses minimization/window-
  position messages plus DWM's `DWMWA_CLOAKED` state for shell- or
  application-cloaked windows. Other compositor/window-manager decisions may
  not generate a signal, so an application must remain correct if it continues
  to render. Offscreen windows never report suspension.
- `Window.shouldRender()` is the portable rendering gate. On Wayland it is
  initially true and becomes false after a presented `RenderTarget` arms the
  next frame; the next `wl_surface.frame` callback makes it true again. Raw
  Vulkan presentation still calls `requestFrame()` immediately before the WSI
  presentation which commits the surface. Use
  `Context.waitForRender(window)` or `Context.waitForAnyRender(windows)` to
  filter unrelated event wakeups until a permit arrives. A compositor may
  suppress callbacks for an entirely occluded surface, but this is a pacing
  optimization rather than a visibility guarantee. X11 and Win32 keep the gate
  open unless their suspension hint is active. Offscreen always keeps it open.
  `RenderTarget` cancels its frame request if presentation fails before the
  surface is committed; raw presenters should call
  `Window.cancelFrameRequest()` in the same situation.
- Cursor shape requests use `wp_cursor_shape_manager_v1` when the compositor
  advertises it; otherwise the compositor's default cursor remains active.
- Unsupported operating systems build the stub backend and return
  `error.UnsupportedPlatform` when initialized.

## Build options and portability

Linux builds enable both desktop backends by default. Disable either one when a
smaller binary or a single runtime path is desired:

```sh
zig build -Dx11=false       # Wayland-only
zig build -Dwayland=false   # X11-only
zig build -Dvk_extras=true  # optional Vulkan targets
zig build -Dvk_video=true   # targets plus Vulkan Video H.264 recording
```

The Linux runtime bindings are header-free and are loaded through `dlopen`.
The resulting executable does not have `DT_NEEDED` entries for X11, Wayland,
or xkbcommon; those libraries are required only when the corresponding backend
is selected at runtime. A glibc baseline can be selected when cross-compiling,
for example:

```sh
zig build -Dtarget=x86_64-linux-gnu.2.17
```

Wayland protocol sources are vendored under `src/wayland/protocols` and are
used to generate the client bindings during the build. Platform implementations
live under `src/linux` and `src/windows`; shared runtime types live under
`src/internal`. These modules are implementation details and should not be
imported by applications.
