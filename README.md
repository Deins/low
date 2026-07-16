# low — let me open window

A cross-platform desktop windowing library for Vulkan applications written in Zig.  
With goal of being **portable** and **cross-compilable**.  
Supports multiple windows, keyboard and mouse input, clipboard access etc.


Optionally provides vulkan swapchain management and useful window content features:
* screenshot grabbing (raw image bytes on cpu and utils to write bmp image files)
* recording encoded video streams of window contents (using vulkan video if supported by the gpu/driver), with av1, h265, or h264 codecs, either raw or packaged in mkv format.

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
- On windows: win32, dwmapi
#### Build-time
See [build.zig.zon](./build.zig.zon). Depends on configuration.
For full additional functionality:
- With `-Dvk_video=true`:
  - [vulkan-zig](https://github.com/Snektron/vulkan-zig)
  - Vulkan-Headers if vulkan registries can't be found and are not provided

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
  -- --frames 300 --screencap
```

The recorder keeps rendered pixels on the GPU, converts BGRA to BT.709 NV12,
and writes streaming Matroska by default (or raw Annex-B H.264 when selected)
through a caller-owned `std.Io.Writer`. Vulkan Video dependencies are not
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

### Deployment & cross-compilation
For portable deployments or cross-compilation, specify a target such as :
- `-Dtarget=x86_64-windows-gnu`
- `-Dtarget=x86_64-linux-gnu.2.17`   
    For GNU/Linux targets, the version suffix specifies the minimum supported glibc version. For example, gnu.2.17 targets glibc 2.17 or newer. Choose the version according to the compatibility requirements of your deployment.
