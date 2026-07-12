# `low` multi-window Vulkan triangles

This directory is a standalone Zig project: it depends on `low` through the
local `../..` path and otherwise only fetches `vulkan-zig` and lazy Vulkan
headers. It uses `low.vulkan.targets().RenderTarget` for target and frame
lifecycle while keeping shaders and rendering commands in the example.

It opens two native `low` windows. Each has an independent Vulkan surface and
swapchain while sharing one Vulkan 1.3 device and graphics pipeline. Either
window can be closed independently; the remaining window keeps animating until
it too is closed. Click either window to reverse and recolour its bouncing
triangle.

## Run

The Vulkan SDK provides the registry and `glslc` shader compiler:

```sh
source ~/tools/vk/1.4.335.0/setup-env.sh
cd examples/multiwindow_triangles
zig build run
```

Choose a specific Linux window-system backend at runtime when testing both
paths (the default is `low`'s automatic selection):

```sh
zig build run -- --wayland
zig build run -- --x11
zig build run -- --offscreen
```

`--offscreen` renders ten frames into direct Vulkan images (no surface or
swapchain), reads each completed image back to the CPU, and writes
`tmp/first-0001.bmp` through `tmp/second-0010.bmp` before exiting.
`RenderTarget` manages the offscreen image ring, device-local allocation, and
staging-buffer readback.

## H.264 and MKV recording

Build the optional recorder and write either window, or both windows, to
independent raw Annex-B streams:

```sh
zig build run -Dvk_video=true -- --offscreen \
  --record tmp/first.h264 \
  --record-second tmp/second.h264
```

Use a `.mkv` filename to select the streaming Matroska container. Other
extensions retain the raw Annex-B H.264 output:

```sh
zig build run -Dvk_video=true -- --offscreen \
  --record tmp/first.mkv \
  --record-second tmp/second.mkv
```

Recording can also be exercised through a WSI path. `--frames` makes the demo
close itself after a fixed number of frames:

```sh
zig build run -Dvk_video=true -- --x11 --frames 300 \
  --record tmp/first.h264
```

Additional options are:

```text
--record-fps 60
--record-bitrate 12000000
--record-gop 60
--restart-recording-at 150
```

The restart option demonstrates stopping and beginning raw H.264 again while
reusing compatible cached GPU resources. It is rejected for `.mkv` paths
because each MKV recording starts an independent timeline and therefore needs
a fresh writer. The example owns and closes its files;
`RenderTarget.endRecording` only flushes the supplied writer. Matroska is
written as a forward-only stream without Cues or a declared Segment duration,
so seeking metadata is intentionally omitted. Inspect either format, or remux
the elementary stream without re-encoding, for example:

```sh
ffprobe tmp/first.h264
ffmpeg -i tmp/first.h264 -c copy tmp/first.mp4
ffprobe tmp/first.mkv
```

Without `VULKAN_SDK`, binding generation falls back to the lazy
`vulkan_headers` dependency. You can also point the build at a registry:

```sh
zig build -Dvk_registry=/path/to/registry/vk.xml
```

For recording builds, `-Dvk_video_registry=/path/to/registry/video.xml` can be
used as well. Both registries otherwise come from `VULKAN_SDK` or the pinned
lazy headers dependency.

`glslc` must still be available on `PATH` to compile the two GLSL shaders.

## Relevant `low` glue

`low.vulkan.Loader` dynamically opens the system Vulkan loader, avoiding a
link-time dependency. `low.vulkan.requiredInstanceExtensions(&context)` uses
the backend chosen by `low`. `RenderTarget` creates the matching Wayland,
Xlib, or Win32 surface and owns its swapchain, image views, command buffers,
semaphores, fences, and recreation path.
