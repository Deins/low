# low implementation notes

This document is for contributors and for applications that need to understand
the platform boundary. The supported application API is documented in the
[main README](README.md).

## Backend selection and loading

On Linux, `InitOptions.backend` accepts `.auto`, `.wayland`, `.x11`, or
`.offscreen`. Automatic selection gives `XDG_SESSION_TYPE` precedence. When it
is unset, `WAYLAND_DISPLAY` and `DISPLAY` are used. If both desktop sockets are
available, automatic selection may try the other enabled backend after a
library or connection failure; explicit backend requests remain strict.

The Linux desktop backends load their system libraries at runtime:

- Wayland loads `libwayland-client.so.0` and `libxkbcommon.so.0`.
- X11 loads `libX11.so.6`.

This keeps the unused desktop stack out of startup and allows one executable to
run on Wayland-only or X11-only systems. Missing libraries and failed display
connections are reported through `low.Error`. Loaded libraries remain alive for
the process lifetime because generated protocol calls and live windows retain
function pointers into them.

The offscreen backend is entirely in-process: it creates logical windows,
queues synthetic events, and never loads or connects to a desktop library.

## Vulkan layer

`low.vulkan` always exposes the small loader and surface helpers. The optional
render-target layer is compiled only with `-Dvk_extras=true`:

```zig
const RenderTarget = low.vulkan.targets().RenderTarget;
```

`RenderTarget` owns desktop surface/swapchain setup, frame command buffers,
synchronization, resize recreation, and layout transitions. The application
still owns the Vulkan instance, physical-device selection, queues, command
pool, and rendering commands. It can use any Vulkan binding alongside low's
binding-agnostic ABI.

For an offscreen target, provide `memory_allocator` callbacks to allocate and
bind the target's images. Offscreen targets never create a surface or swapchain
and leave the rendered image in `transfer_src_optimal` after submission.

## Platform behavior

- Wayland `show()` and `hide()` record requested visibility. The renderer owns
  the surface buffer and therefore controls when the surface is actually mapped.
- Wayland minimized state cannot be queried reliably because the protocol does
  not provide a minimized-state event.
- Cursor shape requests use `wp_cursor_shape_manager_v1` when the compositor
  advertises it; otherwise the compositor's default cursor remains active.
- Unsupported operating systems build the stub backend and return
  `error.UnsupportedPlatform` when initialized.

## Build options and portability

Linux builds enable both desktop backends by default. Disable either one when a
smaller binary or a single runtime path is desired:

```sh
zig build -Dx11=false       # Wayland-only
zig build -Dwayland=false   # X11-only
zig build -Dvk_extras=true  # optional Vulkan targets
```

The Linux runtime bindings are header-free and are loaded through `dlopen`.
The resulting executable does not have `DT_NEEDED` entries for X11, Wayland,
or xkbcommon; those libraries are required only when the corresponding backend
is selected at runtime. A glibc baseline can be selected when cross-compiling,
for example:

```sh
zig build -Dtarget=x86_64-linux-gnu.2.17
```

Wayland protocol sources are vendored under `src/wayland/protocols` and are
used to generate the client bindings during the build. Platform implementations
live under `src/linux` and `src/windows`; shared runtime types live under
`src/internal`. These modules are implementation details and should not be
imported by applications.

