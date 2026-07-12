# low — let me open window

A cross-platform desktop windowing library for Vulkan applications written in Zig.
The main goal is to be as **portable** and **cross-compilable** as possible.
Supports multiple windows, keyboard and mouse input, clipboard access, and more.

## Platforms

- Linux Wayland
- Linux X11
- Windows (Win32)
- Offscreen - no desktop at all. Render to vulkan texture and inject your own events for testing etc.

## Build and examples

From this directory:

```sh
zig build test
zig build run --build-file ./examples/multiwindow_triangles/build.zig
zig build run --build-file ./examples/basic_low_level/build.zig
# alternatively
cd ./examples/$EXAMPLE && zig build run
```

The examples are standalone Zig packages. See their READMEs for Vulkan SDK,
shader compiler, and run instructions.

Optional Vulkan render-target helpers are enabled with `-Dvk_extras=true`.
Vulkan Video H.264 recording is a separate, lazy feature and implies those
helpers:

```sh
zig build -Dvk_video=true
zig build run --build-file ./examples/multiwindow_triangles/build.zig \
  -- --frames 300 --record
```

The recorder keeps rendered pixels on the GPU, converts BGRA to BT.709 NV12,
and writes streaming Matroska by default (or raw Annex-B H.264 when selected)
through a caller-owned `std.Io.Writer`. Vulkan Video dependencies are not
resolved by normal builds.

### Deployment & cross-compilation
Zig builds & optimizes for specific hostmachine. For portable deployments or cross-compilation specify target such as `-Dtarget=x86_64-windows-gnu` or `-Dtarget=x86_64-linux-gnu`.
