# Vulkan Video shaders

`bgra_to_nv12.spv` is checked in so downstream builds do not need the Vulkan
SDK shader compiler. Regenerate and validate it from the repository root with:

```sh
zig build regenerate-vk-video-shader
zig build check-vk-video-shader
spirv-val --target-env vulkan1.3 src/vulkan/video/shaders/bgra_to_nv12.spv
```

The conversion is BT.709 limited range. Render targets are first normalized to
RGBA8; this also down-converts the supported packed 10-bit UNORM source
formats. The H.264 VUI emitted by the recorder uses matching colour primaries,
transfer characteristics, matrix coefficients, and range metadata.
