# Vulkan ABI validation and modification instructions

`src/vulkan/api.zig` is a hand-written Vulkan ABI. It must match the
authoritative C declarations for every record and function it exposes.

## Reference sources

When changing values or verifying structs, handles, or function pointers, verify against
the current Khronos sources before editing:

- Core C declarations: `https://raw.githubusercontent.com/KhronosGroup/Vulkan-Headers/main/include/vulkan/vulkan_core.h`
- Platform declarations:
  - `https://raw.githubusercontent.com/KhronosGroup/Vulkan-Headers/main/include/vulkan/vulkan_win32.h`
  - `https://raw.githubusercontent.com/KhronosGroup/Vulkan-Headers/main/include/vulkan/vulkan_wayland.h`
  - `https://raw.githubusercontent.com/KhronosGroup/Vulkan-Headers/main/include/vulkan/vulkan_xlib.h`
- Specification and registry: `https://registry.khronos.org/vulkan/specs/latest/html/vkspec.html`

## Validation

- Every Vulkan C-facing record must be an `extern struct`.
- Do not use `packed struct` unless the authoritative C declaration is
  explicitly packed. Vulkan's ordinary structs use normal C padding and
  alignment; `extern struct` supplies that layout.
- Constant namespaces such as `format` and `image_usage` are not ABI records
  and do not need `extern` layout.
- Structs must contain every C field in the same order, with matching widths,
  pointers, arrays, and constness. Do not add manual padding fields unless the
  reference declaration requires them.
- C enums should be typed `enum(i32)`; Vulkan flag typedefs should retain their
  32-bit underlying representation.
