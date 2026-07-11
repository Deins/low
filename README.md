# low — let me open window

Basic cross-platform desktop windowing library for standalone Zig vulkan applications.
With goal to be as **portable** and **cross-compilable** as possible.

## Platforms

- Linux Wayland
- Linux X11
- Windows (Win32)
- Other platforms: stub implementation returning `UnsupportedPlatform`


## Features

- Runtime backend selection from `WAYLAND_DISPLAY`, `DISPLAY`, and `XDG_SESSION_TYPE`
- Multi-window support
- Window state queries and callbacks for resize, focus, pointer, keyboard, text, and close events
- Wayland titlebar/decorations preference via `xdg-decoration` when available
- Startup maximize/fullscreen state
- Vulkan surface integration via `VK_KHR_surface` plus the selected backend's Wayland or Xlib extension
- Compositor-provided Wayland cursor shapes through `wp_cursor_shape_manager_v1`

## Backend selection and runtime dependencies

Pass `.auto`, `.wayland`, or `.x11` through `InitOptions.backend`. Automatic selection uses the session type and display environment, with `XDG_SESSION_TYPE` taking precedence when set.

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

This is not a fully static desktop executable model. Static Linux executables
cannot reliably load ordinary shared X11/Wayland client libraries and their
dependency graphs. `low` returns `error.StaticExecutableUnsupported` before
attempting that path. Distribute a dynamically linked core instead; for a
widely compatible glibc build, choose a suitable old GNU target such as
`x86_64-linux-gnu.2.17`.

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

## Standalone Vulkan example

[`examples/multiwindow_triangles`](examples/multiwindow_triangles) is a complete,
independent Zig package that uses `low`, `vulkan-zig`, and no rendering or UI
framework. It opens two windows with separate surfaces and swapchains, while
sharing a Vulkan 1.3 device and pipeline. Its README includes the from-scratch
build command and SDK setup.
