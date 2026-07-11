# basic_low_level

This is the deliberately explicit Vulkan example. It uses `low` for the
window and event loop, then creates the Vulkan instance, surface, device,
swapchain, and image views directly. It does not enable or import
`low.vulkan.targets`.

Build it with:

```sh
zig build run
```

As with the other example, set `VULKAN_SDK` or pass `-Dvk_registry=/path/to/vk.xml`
when a Vulkan-Headers registry is not available through the package cache.
