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

`low` automatically selects the active desktop backend. Override it with
`--desktop=x11`, `--desktop=wayland`, or `--desktop=offscreen`:

```sh
zig build run -- --desktop=x11
```

## Matroska recording

The example is built with Vulkan Video recording enabled. `--record` records
both windows as independent Matroska files containing H.264 video:

```sh
zig build run -- --record
```

It creates `tmp/first.mkv` and `tmp/second.mkv`. The recording configuration
(60 fps, 12 Mbps, and a 60-frame GOP) is kept as compile-time constants near
the top of `src/main.zig` so the example focuses on the two-window lifecycle.

`--frames` makes the demo close itself after a fixed number of frames, which
is useful for automated recording runs:

```sh
zig build run -- --frames 300 --record
```

Inspect either recording:

```sh
ffprobe tmp/first.mkv
```

Without `VULKAN_SDK`, binding generation falls back to the lazy
`vulkan_headers` dependency. You can also point the build at a registry:

```sh
zig build -Dvk_registry=/path/to/registry/vk.xml
```

`-Dvk_video_registry=/path/to/registry/video.xml` selects the Vulkan Video
registry. Both registries otherwise come from `VULKAN_SDK` or the pinned lazy
headers dependency.

`glslc` must still be available on `PATH` to compile the two GLSL shaders.

## Relevant `low` glue

`low.vulkan.Loader` dynamically opens the system Vulkan loader, avoiding a
link-time dependency. `Context.requiredVulkanInstanceExtensions()` supplies
the extensions for the display backend chosen by `low`. `RenderTarget` creates
the matching Wayland, Xlib, or Win32 surface and owns its swapchain, image
views, command buffers, semaphores, fences, and recreation path.
