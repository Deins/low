# low — let me open window

A cross-platform desktop windowing library for Vulkan applications written in Zig.
With the goal of being **portable** and **cross-compilable**.

## features

* multiple native windows and event loop
* window management, keyboard, text input, mouse, scroll, cursor control
* clipboard text access
* Vulkan loader, instance extension, presentation support, and surface helpers

## optional features

* Vulkan render targets with `-Dvk_extras=true`
  * surface, swapchain, synchronization, resize, and vsync
  * screenshot readback as raw BGRA8 CPU pixels and utilities to write BMP files
  * video capture with `-Dvk_video=true`: encode submitted render-target frames
    using Vulkan Video, with AV1, H.265, or H.264, either raw or in Matroska
* deterministic event recording and replay with frame timing, per-window
  scopes, persistence, custom clocks, and event injection

## Platforms

- Linux Wayland
- Linux X11
- Windows (Win32)
- Offscreen - no desktop at all. Render to vulkan texture and inject your own events for testing etc.

### Dependencies
#### Runtime
- Vulkan loader (`libvulkan.so.1` on Linux or `vulkan-1.dll` on Windows)
- On Linux, the selected backend’s runtime libraries:
  - Wayland: `libwayland-client` and `libxkbcommon`
  - X11: `libX11`
- For GNU/Linux targets, `glibc` at least as new as the version specified by `-Dtarget`
  (for example, `x86_64-linux-gnu.2.17` requires glibc 2.17+).
- On Windows: Win32 system APIs and `dwmapi.dll`
#### Build-time
See [build.zig.zon](./build.zig.zon). Depends on configuration.
For full additional functionality:
- With `-Dvk_video=true`, the build lazily fetches [vulkan-zig](https://github.com/Snektron/vulkan-zig)
  and Vulkan-Headers to generate the Vulkan Video bindings.

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
Vulkan Video recording is a separate, lazy feature and implies those helpers:

```sh
zig build test -Dvk_video=true
zig build run --build-file ./examples/multiwindow_triangles/build.zig \
  -- --frames 300 --record-video
```

Vulkan Video recording captures submitted render-target frames on the GPU and
writes Matroska by default. Recording support must be selected before creating
the Vulkan device. See the [recording guide](docs/recording.md) for setup,
lifecycle, timing, and output options, or the
[implementation notes](docs/implementation.md) for Vulkan internals.

## Deterministic input recording and replay

`low.replay` records window input and frame timing so deterministic application
loops can reproduce the same update and rendering path. It covers the whole
context and replays at the recorded pace by default. See the
[input replay guide](docs/input-replay.md) for usage, persistence, per-window
control, and custom timelines.

### Deployment & cross-compilation
For portable deployments or cross-compilation, specify a target such as:
- `-Dtarget=x86_64-windows-gnu`
- `-Dtarget=x86_64-linux-gnu.2.17`
For GNU/Linux targets, the version suffix specifies the minimum supported glibc
version. For example, gnu.2.17 targets glibc 2.17 or newer. Choose the version
according to the compatibility requirements of your deployment.
