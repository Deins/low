# Vulkan helper implementation plan

## Goal

Add an optional, binding-agnostic Vulkan convenience layer to low for quick
windowed and offscreen rendering experiments. The base module remains
windowing/event-only. Enable helpers with -Dvulkan_helpers=true.

The helper must not import or pin a Vulkan binding. Callers supply their
generated binding module through low.vulkan.targets(vk). Binding-specific
proxy types, casts, and Vulkan calls stay in src/vulkan/.

## Public API

The primary helper is RenderTarget. It owns the Vulkan render target associated
with one low.Window.

Required initialization inputs:

- context and window
- instance, physical device, device, graphics queue, and queue-family index
- command pool and color format
- frames-in-flight count
- offscreen memory allocator callback

The intended frame workflow is:

1. Create RenderTarget and defer deinit.
2. Poll or step the low context.
3. Call RenderTarget.acquire().
4. Record application commands using frame.image, frame.view, frame.extent,
   and frame.command_buffer.
5. Call frame.submitAndPresent(), with frame.abort() as an error defer.

On desktop, submitAndPresent submits and calls QueuePresentKHR. On offscreen,
it submits and releases an image-ring slot without presentation.

## Responsibilities

RenderTarget owns:

- surface creation/destruction;
- desktop swapchain creation, views, acquire/present, and recreation;
- offscreen render-image ring creation, views, and recreation;
- framebuffer-resize tracking;
- command-buffer allocation/reset;
- semaphores, fences, and frame lifecycle;
- out-of-date/suboptimal handling and appropriate layout transitions.

Applications own:

- Vulkan loader, instance, physical-device, and device selection;
- shaders, pipelines, descriptors, and application state;
- command recording between acquire and submit;
- offscreen memory-type policy through the allocator callback;
- frame readback/export policy.

## Milestones

1. Keep src/vulkan/targets.zig as the only binding-facing helper area and keep
   helpers disabled by default.
2. Implement RenderTarget desktop state: surface, swapchain, views, resize,
   acquire/present, and recreation.
3. Put the existing OffscreenImageRing behind the same RenderTarget and Frame
   operations.
4. Add synchronization and status/error handling for skipped, out-of-date,
   and suboptimal frames.
5. Create examples/basic_low_level by copying and simplifying the current
   explicit triangle demo. It must not use vulkan_helpers.
6. Refactor examples/multiwindow_triangles to require vulkan_helpers and use
   RenderTarget. Remove its local AppWindow lifecycle boilerplate.
7. Add documentation and test/build coverage for default and helper-enabled
   configurations.

## Acceptance criteria

- zig build test succeeds with helpers disabled.
- zig build test -Dvulkan_helpers=true succeeds.
- basic_low_level demonstrates raw low plus Vulkan surface/swapchain setup.
- multiwindow_triangles contains no local surface/swapchain/image-view/frame
  synchronization lifecycle equivalent to the current AppWindow.
- Desktop and offscreen paths share RenderTarget.acquire and
  Frame.submitAndPresent.
- Offscreen never creates a Vulkan surface or swapchain.
