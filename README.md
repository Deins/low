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
