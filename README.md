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

The video recorder keeps rendered pixels on the GPU, converts BGRA to BT.709 NV12, encodes and pulls stream to cpu,
then writes streaming Matroska by default (or the selected codec's raw
elementary stream when requested) through a caller-owned `std.Io.Writer`.
Vulkan Video dependencies are not
resolved by normal builds.

Request recording support with `video.selectVideoFormat(..., .on)` during
device selection; Low tries AV1, H.265, then H.264. Once the selected
`VideoDevice` is attached, a target starts with only
`beginRecording(.{ .io = io, .writer = writer })`. Explicit codec preferences,
timing, quality, resize behavior, and container settings remain optional.

See the [Vulkan Video recording guide](docs/recording.md) for device setup,
recording lifecycle, timing, output formats, and quality tradeoffs. For
platform and Vulkan-layer internals, including the Vulkan Video implementation
invariants and validation guidance, see the [implementation notes](docs/implementation.md).

## Deterministic input recording and replay

`low.replay` records window events together with the frame deltas used by the
application loop. Replaying the returned deltas instead of sampling wall time
makes input-driven rendering reproducible, including screenshot and video
capture when the application supplies `Frame.elapsed_ns` as its recording
timestamp.

The default scope includes every window in a context and maps windows by
creation order. A window slice selects per-window recording or replay, so a
tool can keep an editor window live while replaying its preview window.
Recordings can also be written to and read from a versioned binary stream.

See the [deterministic input replay guide](docs/input-replay.md) for the default
loop, per-window use, persistence, custom timing, and event injection.

### Deployment & cross-compilation
For portable deployments or cross-compilation, specify a target such as:
- `-Dtarget=x86_64-windows-gnu`
- `-Dtarget=x86_64-linux-gnu.2.17`
For GNU/Linux targets, the version suffix specifies the minimum supported glibc
version. For example, gnu.2.17 targets glibc 2.17 or newer. Choose the version
according to the compatibility requirements of your deployment.
