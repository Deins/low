# basic_low_level

This is the deliberately explicit Vulkan example. Without use of `low.vulkan.targets` helpers for swapchain management.  
It uses `low` for the window and event loop, then creates the Vulkan instance, surface, device, swapchain, and image views directly in app. 


Build it with:

```sh
zig build run
```
