# `low` multi-window Vulkan triangles

This example opens two native `low` windows. Each has its own Vulkan surface
and swapchain, while sharing vulkan device and graphics pipeline.
Close either window independently, or click one to reverse and recolour its
bouncing triangle. With Vulkan Video support, `--record` saves each window to
as encoded .mkv file.

## Run

The Vulkan SDK supplies the registry and `glslc`:

```sh
source ~/tools/vk/1.4.335.0/setup-env.sh
cd examples/multiwindow_triangles
zig build run
```

`low` selects the active desktop backend automatically. Override it with
`--desktop=x11`, `--desktop=wayland`, or `--desktop=offscreen`:

```sh
zig build run -- --desktop=x11
```

The render format prefers packed 10-bit UNORM targets and falls back to 8-bit
BGRA when the surface or device does not advertise a supported 10-bit format.
The preference list is supplied to `low`'s `RenderTarget` API, and selection
is reported as an unsupported-surface-format error when none of the requested
formats is available.

For offscreen or desktop screenshot output, pass `--dump`. This writes each
rendered frame as `tmp/first-0001.bmp`, `tmp/second-0001.bmp`, and so on. BMP
dumping is disabled by default.

```sh
zig build run -- --desktop=offscreen --dump --frames=12
```

## Recording

`--record` creates independent AV1 Matroska recordings for both windows:

```sh
zig build run -- --record
```

Output: `tmp/first.mkv` and `tmp/second.mkv`. Recording uses `low`'s defaults:
60 fps, 12 Mbps, and a 60-frame GOP.

Select AV1, H.265, or H.264 with `--record-codec`:

```sh
zig build run -- --record --record-codec=h265
```

The output remains `tmp/first.mkv` and `tmp/second.mkv`; only the carried codec
changes.

`low` records the frames submitted to each `RenderTarget`; it does not capture
desktop contents and it does not record audio. The default `.mkv` format is the
right choice for most uses. Always stop recording before closing its writer so
the remaining GPU work and container data are finalized.

Recording also supports the packed 10-bit render formats. The Vulkan Video path
normalizes them to RGBA8 before converting to the selected codec's 8-bit 4:2:0
input, so these recordings remain 8-bit video.

See the [Vulkan Video recording guide](../../docs/recording.md) for setup,
timing modes, quality tradeoffs, resizing, and the recording lifecycle.

For automated runs, `--frames` closes the demo after a fixed number of frames:

```sh
zig build run -- --frames=300 --record
```

Inspect either recording:

```sh
ffprobe tmp/first.mkv
```

`glslc` must be on `PATH`. Without `VULKAN_SDK`, bindings use the lazy
`vulkan_headers` dependency; alternatively, provide a registry explicitly:

```sh
zig build -Dvk_registry=/path/to/registry/vk.xml
```

Use `-Dvk_video_registry=/path/to/registry/video.xml` for the Vulkan Video
registry. Otherwise, both registries come from `VULKAN_SDK` or the pinned
lazy headers dependency.

## Implementation notes

`low.vulkan.Loader` dynamically opens the system Vulkan loader.
`Context.requiredVulkanInstanceExtensions()` supplies backend-specific instance
extensions. `RenderTarget` creates the Wayland, Xlib, or Win32 surface and
owns its swapchain and synchronization/recreation resources.
