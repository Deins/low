# low — let me open window

Small cross-platform windowing and desktop-input library for standalone Zig applications.

## Platforms

- Linux Wayland
- Linux X11
- Other platforms: stub implementation returning `UnsupportedPlatform`

Windows is planned in future.

## Features

- Runtime backend selection from `WAYLAND_DISPLAY`, `DISPLAY`, and `XDG_SESSION_TYPE`
- Multi-window support
- Window state queries and callbacks for resize, focus, pointer, keyboard, text, and close events
- Wayland titlebar/decorations preference via `xdg-decoration` when available
- Startup maximize/fullscreen state
- Vulkan surface integration via `VK_KHR_surface` plus the selected backend's Wayland or Xlib extension
- Compositor-provided Wayland cursor shapes through `wp_cursor_shape_manager_v1`

## Backend selection

Pass `.auto`, `.wayland`, or `.x11` through `InitOptions.backend`. Automatic selection uses the session type and display environment, with `XDG_SESSION_TYPE` taking precedence when set.

## Limitations

- Wayland `show()` and `hide()` record requested visibility only. The renderer owns the surface buffer and controls actual surface mapping.
- Wayland minimized state cannot be queried reliably because the protocol has no minimized-state event.
- Cursor shape changes require compositor support for `wp_cursor_shape_manager_v1`; otherwise the compositor's default cursor is retained.

`Context` is a thin handle over heap-backed backend state so Wayland listener userdata remains valid after initialization. Input and cursor enums are intentionally small and GLFW-like.

The Linux backend uses Wayland client APIs, xkbcommon, X11/Xlib, and generated Wayland protocols.
The protocol sources are vendored under `src/wayland/protocols`; they retain the upstream copyright and MIT license notices.
Linux dispatch lives in `src/linux/backend.zig`; X11 definitions are isolated in `src/x11/backend.zig`, while Wayland protocol assets remain under `src/wayland`.

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

Both Linux backends are enabled by default. They can be restricted at build time:

```sh
zig build -Dlow -Dlow_wayland=false  # X11-only runtime
zig build -Dlow -Dlow_x11=false      # Wayland-only runtime
```

The current Linux implementation is still a combined dispatch module, so both native
libraries remain link dependencies. The options prevent selection of the disabled
backend; separating the implementation files is needed to remove the unused native
library from the final link.
