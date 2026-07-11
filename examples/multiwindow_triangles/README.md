# `low` multi-window Vulkan triangles

This directory is a standalone Zig project: it depends on `low` through the
local `../..` path and otherwise only fetches `vulkan-zig` and lazy Vulkan
headers. It intentionally has no UI, rendering, or Vulkan helper libraries.

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
```

Without `VULKAN_SDK`, binding generation falls back to the lazy
`vulkan_headers` dependency. You can also point the build at a registry:

```sh
zig build -Dvk_registry=/path/to/registry/vk.xml
```

`glslc` must still be available on `PATH` to compile the two GLSL shaders.

## Relevant `low` glue

`low.vulkan.Loader(vk)` dynamically opens the system Vulkan loader, avoiding a
link-time dependency. `low.vulkan.requiredInstanceExtensions(&context)` uses
the backend chosen by `low`, and `low.vulkan.createSurface(vk, &context,
window, instance)` creates the matching Wayland, Xlib, or Win32 surface.
