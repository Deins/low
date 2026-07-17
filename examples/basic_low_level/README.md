# basic_low_level

This is the deliberately explicit Vulkan example without
`low.vulkan.targets` swapchain management. It uses `low` for the window, event
loop, and window-owned Vulkan surface. It selects the device first through the
backend's native presentation-support query, then creates the window, swapchain,
and image views directly in the application.


Build it with:

```sh
zig build run
```
