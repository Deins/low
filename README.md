# low — let me open window

Basic cross-platform desktop windowing library for standalone Zig vulkan applications.
With goal to be as **portable** and **cross-compilable** as possible.

## Platforms

- Linux Wayland
- Linux X11
- Windows (Win32)
- Offscreen / headless with injectable events for testing etc.
- Other platforms: stub implementation returning `UnsupportedPlatform`


## Features

`low` is the complete supported public API: applications should import only
the root module (with `low.vulkan` as its intentional submodule). Platform
backends and shared runtime modules under `src/internal` are implementation
details.

- Runtime backend selection from `WAYLAND_DISPLAY`, `DISPLAY`, and `XDG_SESSION_TYPE`
- A cross-platform offscreen backend for deterministic, display-server-free testing and rendering
- Multi-window support
- Window state queries and callbacks for resize, focus, pointer, keyboard, text, and close events
- Wayland titlebar/decorations preference via `xdg-decoration` when available
- Startup maximize/fullscreen state
- Vulkan surface integration via `VK_KHR_surface` plus the selected backend's Wayland or Xlib extension
- Compositor-provided Wayland cursor shapes through `wp_cursor_shape_manager_v1`

## Backend selection and runtime dependencies

On Linux, pass `.auto`, `.wayland`, `.x11`, or `.offscreen` through `InitOptions.backend`.
Automatic selection uses the session type and display environment, with
`XDG_SESSION_TYPE` taking precedence when set. `.offscreen` has no desktop environment and doesn't load/connect to a desktop library, instead creates vulkan render target and allows inject events as needed.

### Offscreen frames and input

The offscreen backend creates logical windows only: it has no native surface,
requires no Vulkan instance extensions, and `vulkan.createSurface` returns
`error.OffscreenSurfaceUnavailable`. Applications still own rendering.

Use the default `.manual` mode when a test or renderer should advance exactly
when it chooses:

```zig
var context = try low.Context.init(allocator, .{ .backend = .offscreen });
defer context.deinit();
const window = try context.createWindow(.{ .title = "test" });

try window.injectEvent(.{ .key = .{ .key = .a, .action = .press } });
try context.step(); // delivers the queued key callback
// render one frame here
```

For a conventional rendering loop, set `.offscreen.frame_mode` to
`.continuous`. `interval_ns = null` runs as fast as the caller renders;
`1_000_000_000 / 60` rate-limits to 60 Hz. Each `nextFrame()` waits as needed
and then delivers queued events. `Window.injectEvent` supports close, resize,
scale, focus, pointer enter/motion, mouse buttons, scrolling, keys, and UTF-8
text. The text bytes are copied when injected.

```zig
var context = try low.Context.init(allocator, .{
    .backend = .offscreen,
    .offscreen = .{ .frame_mode = .{ .continuous = .{
        .interval_ns = 1_000_000_000 / 60,
    } } },
});
while (!window.shouldClose()) {
    try context.nextFrame();
    // render one frame here
}
```

### Optional Vulkan render-target helpers

The base module remains windowing and event only. Enable the optional
binding-agnostic render-target layer with `-Dvk_extras=true`.
`low.vulkan` owns a small Vulkan 1.2 ABI and resolves its required instance and
device commands at runtime; applications may use any Vulkan binding for the
rest of their renderer. `RenderTarget` owns the desktop surface/swapchain or
an offscreen image ring, frame command buffers, synchronization, resize
recreation, and layout transitions:

```zig
const RenderTarget = low.vulkan.targets().RenderTarget;
var loader = try low.vulkan.Loader.init();
defer loader.deinit();
const low_instance = try loader.loadInstanceApi(instance_handle);
const low_device = try low.vulkan.Device.init(&low_instance, device_handle);
var target = try RenderTarget.init(allocator, .{
    .context = &context,
    .window = window,
    .instance = &low_instance,
    .physical_device = physical_device,
    .device = &low_device,
    .graphics_queue = graphics_queue,
    .graphics_queue_family = graphics_queue_family,
    .command_pool = command_pool,
    .color_format = color_format,
    .frames_in_flight = 2,
    // Required only for `.offscreen` contexts:
    // .memory_allocator = .{ .allocate_and_bind = allocate, .free = free },
});
defer target.deinit();

var frame = try target.acquire();
defer frame.abort();
// Record application commands using frame.command_buffer, frame.image,
// frame.view, and frame.extent.
try frame.submitAndPresent();
```

The helper uses Vulkan 1.2 core submission and barrier commands. On desktop,
`submitAndPresent` presents the acquired swapchain image; offscreen targets
never create a surface or swapchain and leave the rendered image in
`transfer_src_optimal`.

The selected backend loads only its own system libraries at runtime:

- Wayland: `libwayland-client.so.0` and `libxkbcommon.so.0`
- X11: `libX11.so.6`

They are loaded with `dlopen` through Zig's dynamic-library API after backend
selection. Thus one executable can run on a Wayland-only or X11-only system,
and missing libraries are reported as `error.BackendLibraryUnavailable` instead
of preventing process startup. In `.auto` mode, if both display sockets are
present, `low` also tries the other enabled backend after a library/connection
failure. Explicit `.wayland` and `.x11` requests remain strict.

The loaded handles intentionally remain alive for the process lifetime, so
generated Wayland protocol calls and live windows cannot retain invalid
function pointers.

## Limitations

- Wayland `show()` and `hide()` record requested visibility only. The renderer owns the surface buffer and controls actual surface mapping.
- Wayland minimized state cannot be queried reliably because the protocol has no minimized-state event.
- Cursor shape changes require compositor support for `wp_cursor_shape_manager_v1`; otherwise the compositor's default cursor is retained.

`Context` is a thin handle over heap-backed backend state so Wayland listener userdata remains valid after initialization. Input and cursor enums are intentionally small and GLFW-like.

The Linux backend uses runtime bindings for Wayland client APIs, xkbcommon, and
X11/Xlib, plus generated Wayland protocols.
The protocol sources are vendored under `src/wayland/protocols`; they retain the upstream copyright and MIT license notices.
Linux dispatch lives in `src/linux/backend.zig`; header-free X11 and xkbcommon
ABI bindings live in `src/linux`, while Wayland protocol assets remain under
`src/wayland`.

## Build and test

From this directory:

```sh
zig build
zig build test
```

The parent project enables this backend with `-Dlow`:

```sh
zig build run-app -Dlow
```

Both Linux backends are enabled by default. They can be disabled for smaller binaries or otherwise:

```sh
zig build -Dlow -Dlow_wayland=false  # X11-only runtime
zig build -Dlow -Dlow_x11=false      # Wayland-only runtime
```

For the parent project, a portable glibc baseline can be selected without
installing GUI development packages:

```sh
zig build -Dlow -Dtarget=x86_64-linux-gnu.2.17
```

The resulting ELF has no `DT_NEEDED` entries for `libX11`,
`libwayland-client`, or `libxkbcommon`; only the selected desktop stack needs
to be installed on the destination machine at runtime.

The Windows backend is implemented with Win32 and exposes the same `Context` and
`Window` API, including native HWND access for Vulkan (`VK_KHR_win32_surface`).

## Standalone Vulkan examples

[`examples/basic_low_level`](examples/basic_low_level) shows the explicit,
raw setup path: low window, Vulkan surface, device, swapchain, and image
views. It does not enable the helper layer.

[`examples/multiwindow_triangles`](examples/multiwindow_triangles) is a complete,
independent Zig package that uses `low`, `vulkan-zig`, and the optional
`RenderTarget` layer. It opens two windows with separate targets while sharing
a Vulkan 1.3 device and pipeline. Its README includes the from-scratch build
command and SDK setup.
