//! The small Vulkan ABI used by low's render-target helpers.
//!
//! These declarations intentionally describe the Vulkan ABI directly instead
//! of importing a generated binding. The helper only needs a small Vulkan 1.2
//! subset; applications remain free to use another binding for the rest of
//! their renderer.
const builtin = @import("builtin");
const std = @import("std");

pub const call_conv: std.builtin.CallingConvention = if (builtin.target.os.tag == .windows and builtin.target.cpu.arch == .x86) .winapi else .c;

pub const Bool32 = u32;
pub const TRUE: Bool32 = 1;
pub const FALSE: Bool32 = 0;

pub const InstanceHandle = ?*anyopaque;
pub const PhysicalDevice = ?*anyopaque;
pub const DeviceHandle = ?*anyopaque;
pub const Queue = ?*anyopaque;
pub const CommandBuffer = ?*anyopaque;

pub const SurfaceKHR = u64;
pub const SwapchainKHR = u64;
pub const Image = u64;
pub const ImageView = u64;
pub const DeviceMemory = u64;
pub const Semaphore = u64;
pub const Fence = u64;
pub const CommandPool = u64;
pub const Buffer = u64;

pub const Result = enum(i32) {
    success = 0,
    not_ready = 1,
    timeout = 2,
    event_set = 3,
    event_reset = 4,
    incomplete = 5,
    error_out_of_host_memory = -1,
    error_out_of_device_memory = -2,
    error_initialization_failed = -3,
    error_device_lost = -4,
    error_memory_map_failed = -5,
    error_layer_not_present = -6,
    error_extension_not_present = -7,
    error_feature_not_present = -8,
    error_incompatible_driver = -9,
    error_too_many_objects = -10,
    error_format_not_supported = -11,
    error_fragmented_pool = -12,
    error_unknown = -13,
    error_surface_lost_khr = -1000000000,
    error_native_window_in_use_khr = -1000000001,
    suboptimal_khr = 1000001003,
    error_out_of_date_khr = -1000001004,
    _,
};

pub const StructureType = enum(i32) {
    application_info = 0,
    instance_create_info = 1,
    device_queue_create_info = 2,
    device_create_info = 3,
    submit_info = 4,
    memory_allocate_info = 5,
    fence_create_info = 8,
    semaphore_create_info = 9,
    image_create_info = 14,
    image_view_create_info = 15,
    command_pool_create_info = 39,
    command_buffer_allocate_info = 40,
    command_buffer_begin_info = 42,
    image_memory_barrier = 45,
    win32_surface_create_info_khr = 1000009000,
    xlib_surface_create_info_khr = 1000004000,
    wayland_surface_create_info_khr = 1000006000,
    swapchain_create_info_khr = 1000001000,
    present_info_khr = 1000001001,
};

pub const Format = i32;
pub const format = struct {
    pub const @"undefined": Format = 0;
    pub const b8g8r8a8_unorm: Format = 44;
};

pub const ColorSpaceKHR = i32;
pub const color_space = struct {
    pub const srgb_nonlinear_khr: ColorSpaceKHR = 0;
};

pub const ImageLayout = enum(i32) {
    undefined = 0,
    general = 1,
    color_attachment_optimal = 2,
    transfer_src_optimal = 6,
    transfer_dst_optimal = 7,
    present_src_khr = 1000001002,
};

pub const ImageType = enum(i32) {
    @"1d" = 0,
    @"2d" = 1,
    @"3d" = 2,
};

pub const ImageTiling = enum(i32) {
    optimal = 0,
    linear = 1,
};

pub const ImageViewType = enum(i32) {
    @"1d" = 0,
    @"2d" = 1,
    @"3d" = 2,
    cube = 3,
};

pub const ComponentSwizzle = enum(i32) {
    identity = 0,
};

pub const SharingMode = enum(i32) {
    exclusive = 0,
    concurrent = 1,
};

pub const CommandBufferLevel = enum(i32) {
    primary = 0,
    secondary = 1,
};

pub const PresentModeKHR = i32;
pub const present_mode = struct {
    pub const fifo_khr: PresentModeKHR = 2;
};

pub const ImageUsageFlags = u32;
pub const ImageAspectFlags = u32;
pub const PipelineStageFlags = u32;
pub const AccessFlags = u32;
pub const DependencyFlags = u32;
pub const CommandBufferUsageFlags = u32;
pub const CommandBufferResetFlags = u32;
pub const CommandPoolCreateFlags = u32;
pub const SampleCountFlags = u32;
pub const SemaphoreCreateFlags = u32;
pub const FenceCreateFlags = u32;
pub const ImageCreateFlags = u32;
pub const ImageViewCreateFlags = u32;
pub const SwapchainCreateFlagsKHR = u32;
pub const SurfaceTransformFlagsKHR = u32;
pub const CompositeAlphaFlagsKHR = u32;
pub const QueueFlags = u32;
pub const MemoryPropertyFlags = u32;
pub const MemoryHeapFlags = u32;

pub const image_usage = struct {
    pub const transfer_src_bit: ImageUsageFlags = 1 << 0;
    pub const transfer_dst_bit: ImageUsageFlags = 1 << 1;
    pub const color_attachment_bit: ImageUsageFlags = 1 << 4;
};

pub const image_aspect = struct {
    pub const color_bit: ImageAspectFlags = 1 << 0;
};

pub const pipeline_stage = struct {
    pub const top_of_pipe_bit: PipelineStageFlags = 1 << 0;
    pub const transfer_bit: PipelineStageFlags = 1 << 10;
    pub const color_attachment_output_bit: PipelineStageFlags = 1 << 13;
    pub const bottom_of_pipe_bit: PipelineStageFlags = 1 << 15;
};

pub const access = struct {
    pub const transfer_read_bit: AccessFlags = 1 << 11;
    pub const transfer_write_bit: AccessFlags = 1 << 12;
    pub const color_attachment_write_bit: AccessFlags = 1 << 7;
};

pub const command_buffer_usage = struct {
    pub const one_time_submit_bit: CommandBufferUsageFlags = 1 << 0;
};

pub const command_pool_create = struct {
    pub const reset_command_buffer_bit: CommandPoolCreateFlags = 1 << 1;
};

pub const fence_create = struct {
    pub const signaled_bit: FenceCreateFlags = 1 << 0;
};

pub const surface_transform = struct {
    pub const identity_bit_khr: SurfaceTransformFlagsKHR = 1 << 0;
};

pub const composite_alpha = struct {
    pub const opaque_bit_khr: CompositeAlphaFlagsKHR = 1 << 0;
    pub const pre_multiplied_bit_khr: CompositeAlphaFlagsKHR = 1 << 1;
    pub const post_multiplied_bit_khr: CompositeAlphaFlagsKHR = 1 << 2;
    pub const inherit_bit_khr: CompositeAlphaFlagsKHR = 1 << 3;
};

pub const queue = struct {
    pub const graphics_bit: QueueFlags = 1 << 0;
};

pub const memory_property = struct {
    pub const device_local_bit: MemoryPropertyFlags = 1 << 0;
};

pub const sample_count = struct {
    pub const @"1_bit": u32 = 1;
};

pub const QUEUE_FAMILY_IGNORED: u32 = 0xffffffff;

pub const Extent2D = extern struct {
    width: u32,
    height: u32,
};

pub const Extent3D = extern struct {
    width: u32,
    height: u32,
    depth: u32,
};

pub const Offset2D = extern struct {
    x: i32,
    y: i32,
};

pub const Rect2D = extern struct {
    offset: Offset2D,
    extent: Extent2D,
};

pub const ComponentMapping = extern struct {
    r: ComponentSwizzle,
    g: ComponentSwizzle,
    b: ComponentSwizzle,
    a: ComponentSwizzle,
};

pub const ImageSubresourceRange = extern struct {
    aspect_mask: ImageAspectFlags,
    base_mip_level: u32,
    level_count: u32,
    base_array_layer: u32,
    layer_count: u32,
};

pub const SurfaceCapabilitiesKHR = extern struct {
    min_image_count: u32,
    max_image_count: u32,
    current_extent: Extent2D,
    min_image_extent: Extent2D,
    max_image_extent: Extent2D,
    max_image_array_layers: u32,
    supported_transforms: SurfaceTransformFlagsKHR,
    current_transform: SurfaceTransformFlagsKHR,
    supported_composite_alpha: CompositeAlphaFlagsKHR,
    supported_usage_flags: ImageUsageFlags,
};

pub const SurfaceFormatKHR = extern struct {
    format: Format,
    color_space: ColorSpaceKHR,
};

pub const QueueFamilyProperties = extern struct {
    queue_flags: QueueFlags,
    queue_count: u32,
    timestamp_valid_bits: u32,
    min_image_transfer_granularity: Extent3D,
};

pub const MemoryType = extern struct {
    property_flags: MemoryPropertyFlags,
    heap_index: u32,
};

pub const MemoryHeap = extern struct {
    size: u64,
    flags: MemoryHeapFlags,
};

pub const PhysicalDeviceMemoryProperties = extern struct {
    memory_type_count: u32,
    memory_types: [32]MemoryType,
    memory_heap_count: u32,
    memory_heaps: [16]MemoryHeap,
};

pub const MemoryRequirements = extern struct {
    size: u64,
    alignment: u64,
    memory_type_bits: u32,
};

pub const MemoryAllocateInfo = extern struct {
    s_type: StructureType,
    p_next: ?*const anyopaque,
    allocation_size: u64,
    memory_type_index: u32,
};

pub const MemoryBarrier = extern struct {
    s_type: StructureType,
    p_next: ?*const anyopaque,
    src_access_mask: AccessFlags,
    dst_access_mask: AccessFlags,
};

pub const BufferMemoryBarrier = extern struct {
    s_type: StructureType,
    p_next: ?*const anyopaque,
    src_access_mask: AccessFlags,
    dst_access_mask: AccessFlags,
    src_queue_family_index: u32,
    dst_queue_family_index: u32,
    buffer: Buffer,
    offset: u64,
    size: u64,
};

pub const SwapchainCreateInfoKHR = extern struct {
    s_type: StructureType,
    p_next: ?*const anyopaque,
    flags: SwapchainCreateFlagsKHR,
    surface: SurfaceKHR,
    min_image_count: u32,
    image_format: Format,
    image_color_space: ColorSpaceKHR,
    image_extent: Extent2D,
    image_array_layers: u32,
    image_usage: ImageUsageFlags,
    image_sharing_mode: SharingMode,
    queue_family_index_count: u32,
    p_queue_family_indices: ?[*]const u32,
    pre_transform: SurfaceTransformFlagsKHR,
    composite_alpha: CompositeAlphaFlagsKHR,
    present_mode: PresentModeKHR,
    clipped: Bool32,
    old_swapchain: SwapchainKHR,
};

pub const ImageViewCreateInfo = extern struct {
    s_type: StructureType,
    p_next: ?*const anyopaque,
    flags: ImageViewCreateFlags,
    image: Image,
    view_type: ImageViewType,
    format: Format,
    components: ComponentMapping,
    subresource_range: ImageSubresourceRange,
};

pub const CommandBufferAllocateInfo = extern struct {
    s_type: StructureType,
    p_next: ?*const anyopaque,
    command_pool: CommandPool,
    level: CommandBufferLevel,
    command_buffer_count: u32,
};

pub const SemaphoreCreateInfo = extern struct {
    s_type: StructureType,
    p_next: ?*const anyopaque,
    flags: SemaphoreCreateFlags,
};

pub const FenceCreateInfo = extern struct {
    s_type: StructureType,
    p_next: ?*const anyopaque,
    flags: FenceCreateFlags,
};

pub const CommandBufferBeginInfo = extern struct {
    s_type: StructureType,
    p_next: ?*const anyopaque,
    flags: CommandBufferUsageFlags,
    p_inheritance_info: ?*const anyopaque,
};

pub const SubmitInfo = extern struct {
    s_type: StructureType,
    p_next: ?*const anyopaque,
    wait_semaphore_count: u32,
    p_wait_semaphores: ?[*]const Semaphore,
    p_wait_dst_stage_mask: ?[*]const PipelineStageFlags,
    command_buffer_count: u32,
    p_command_buffers: ?[*]const CommandBuffer,
    signal_semaphore_count: u32,
    p_signal_semaphores: ?[*]const Semaphore,
};

pub const ImageCreateInfo = extern struct {
    s_type: StructureType,
    p_next: ?*const anyopaque,
    flags: ImageCreateFlags,
    image_type: ImageType,
    format: Format,
    extent: Extent3D,
    mip_levels: u32,
    array_layers: u32,
    samples: SampleCountFlags,
    tiling: ImageTiling,
    usage: ImageUsageFlags,
    sharing_mode: SharingMode,
    queue_family_index_count: u32,
    p_queue_family_indices: ?[*]const u32,
    initial_layout: ImageLayout,
};

pub const ImageMemoryBarrier = extern struct {
    s_type: StructureType,
    p_next: ?*const anyopaque,
    src_access_mask: AccessFlags,
    dst_access_mask: AccessFlags,
    old_layout: ImageLayout,
    new_layout: ImageLayout,
    src_queue_family_index: u32,
    dst_queue_family_index: u32,
    image: Image,
    subresource_range: ImageSubresourceRange,
};

pub const Win32SurfaceCreateInfoKHR = extern struct {
    s_type: StructureType,
    p_next: ?*const anyopaque,
    flags: u32,
    hinstance: ?*anyopaque,
    hwnd: ?*anyopaque,
};

pub const WaylandSurfaceCreateInfoKHR = extern struct {
    s_type: StructureType,
    p_next: ?*const anyopaque,
    flags: u32,
    display: ?*anyopaque,
    surface: ?*anyopaque,
};

pub const XlibSurfaceCreateInfoKHR = extern struct {
    s_type: StructureType,
    p_next: ?*const anyopaque,
    flags: u32,
    dpy: ?*anyopaque,
    window: usize,
};

pub const PresentInfoKHR = extern struct {
    s_type: StructureType,
    p_next: ?*const anyopaque,
    wait_semaphore_count: u32,
    p_wait_semaphores: ?[*]const Semaphore,
    swapchain_count: u32,
    p_swapchains: ?[*]const SwapchainKHR,
    p_image_indices: ?[*]const u32,
    p_results: ?[*]Result,
};

pub const PfnVoidFunction = ?*const fn () callconv(call_conv) void;
pub const PfnGetInstanceProcAddr = *const fn (InstanceHandle, [*:0]const u8) callconv(call_conv) PfnVoidFunction;
pub const PfnGetDeviceProcAddr = *const fn (DeviceHandle, [*:0]const u8) callconv(call_conv) PfnVoidFunction;

pub const PfnDestroyInstance = *const fn (InstanceHandle, ?*const anyopaque) callconv(call_conv) void;
pub const PfnDestroySurfaceKHR = *const fn (InstanceHandle, SurfaceKHR, ?*const anyopaque) callconv(call_conv) void;
pub const PfnGetPhysicalDeviceSurfaceSupportKHR = *const fn (PhysicalDevice, u32, SurfaceKHR, *Bool32) callconv(call_conv) Result;
pub const PfnGetPhysicalDeviceSurfaceCapabilitiesKHR = *const fn (PhysicalDevice, SurfaceKHR, *SurfaceCapabilitiesKHR) callconv(call_conv) Result;
pub const PfnGetPhysicalDeviceSurfaceFormatsKHR = *const fn (PhysicalDevice, SurfaceKHR, *u32, ?[*]SurfaceFormatKHR) callconv(call_conv) Result;
pub const PfnGetPhysicalDeviceMemoryProperties = *const fn (PhysicalDevice, *PhysicalDeviceMemoryProperties) callconv(call_conv) void;
pub const PfnCreateWin32SurfaceKHR = *const fn (InstanceHandle, *const Win32SurfaceCreateInfoKHR, ?*const anyopaque, *SurfaceKHR) callconv(call_conv) Result;
pub const PfnCreateWaylandSurfaceKHR = *const fn (InstanceHandle, *const WaylandSurfaceCreateInfoKHR, ?*const anyopaque, *SurfaceKHR) callconv(call_conv) Result;
pub const PfnCreateXlibSurfaceKHR = *const fn (InstanceHandle, *const XlibSurfaceCreateInfoKHR, ?*const anyopaque, *SurfaceKHR) callconv(call_conv) Result;

pub const PfnDeviceWaitIdle = *const fn (DeviceHandle) callconv(call_conv) Result;
pub const PfnWaitForFences = *const fn (DeviceHandle, u32, [*]const Fence, Bool32, u64) callconv(call_conv) Result;
pub const PfnAcquireNextImageKHR = *const fn (DeviceHandle, SwapchainKHR, u64, Semaphore, Fence, *u32) callconv(call_conv) Result;
pub const PfnResetCommandBuffer = *const fn (CommandBuffer, CommandBufferResetFlags) callconv(call_conv) Result;
pub const PfnBeginCommandBuffer = *const fn (CommandBuffer, *const CommandBufferBeginInfo) callconv(call_conv) Result;
pub const PfnEndCommandBuffer = *const fn (CommandBuffer) callconv(call_conv) Result;
pub const PfnQueueSubmit = *const fn (Queue, u32, [*]const SubmitInfo, Fence) callconv(call_conv) Result;
pub const PfnQueuePresentKHR = *const fn (Queue, *const PresentInfoKHR) callconv(call_conv) Result;
pub const PfnCreateSwapchainKHR = *const fn (DeviceHandle, *const SwapchainCreateInfoKHR, ?*const anyopaque, *SwapchainKHR) callconv(call_conv) Result;
pub const PfnDestroySwapchainKHR = *const fn (DeviceHandle, SwapchainKHR, ?*const anyopaque) callconv(call_conv) void;
pub const PfnGetSwapchainImagesKHR = *const fn (DeviceHandle, SwapchainKHR, *u32, ?[*]Image) callconv(call_conv) Result;
pub const PfnCreateImageView = *const fn (DeviceHandle, *const ImageViewCreateInfo, ?*const anyopaque, *ImageView) callconv(call_conv) Result;
pub const PfnDestroyImageView = *const fn (DeviceHandle, ImageView, ?*const anyopaque) callconv(call_conv) void;
pub const PfnAllocateCommandBuffers = *const fn (DeviceHandle, *const CommandBufferAllocateInfo, [*]CommandBuffer) callconv(call_conv) Result;
pub const PfnFreeCommandBuffers = *const fn (DeviceHandle, CommandPool, u32, [*]const CommandBuffer) callconv(call_conv) void;
pub const PfnAllocateMemory = *const fn (DeviceHandle, *const MemoryAllocateInfo, ?*const anyopaque, *DeviceMemory) callconv(call_conv) Result;
pub const PfnFreeMemory = *const fn (DeviceHandle, DeviceMemory, ?*const anyopaque) callconv(call_conv) void;
pub const PfnCreateSemaphore = *const fn (DeviceHandle, *const SemaphoreCreateInfo, ?*const anyopaque, *Semaphore) callconv(call_conv) Result;
pub const PfnDestroySemaphore = *const fn (DeviceHandle, Semaphore, ?*const anyopaque) callconv(call_conv) void;
pub const PfnCreateFence = *const fn (DeviceHandle, *const FenceCreateInfo, ?*const anyopaque, *Fence) callconv(call_conv) Result;
pub const PfnDestroyFence = *const fn (DeviceHandle, Fence, ?*const anyopaque) callconv(call_conv) void;
pub const PfnCreateImage = *const fn (DeviceHandle, *const ImageCreateInfo, ?*const anyopaque, *Image) callconv(call_conv) Result;
pub const PfnDestroyImage = *const fn (DeviceHandle, Image, ?*const anyopaque) callconv(call_conv) void;
pub const PfnGetImageMemoryRequirements = *const fn (DeviceHandle, Image, *MemoryRequirements) callconv(call_conv) void;
pub const PfnBindImageMemory = *const fn (DeviceHandle, Image, DeviceMemory, u64) callconv(call_conv) Result;
pub const PfnCmdPipelineBarrier = *const fn (CommandBuffer, PipelineStageFlags, PipelineStageFlags, DependencyFlags, u32, ?[*]const MemoryBarrier, u32, ?[*]const BufferMemoryBarrier, u32, ?[*]const ImageMemoryBarrier) callconv(call_conv) void;
