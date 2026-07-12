const std = @import("std");
const vk = @import("_vk_video");
const Vulkan = @import("../../vulkan.zig");
const low_vk = @import("../api.zig");

pub const VideoDevice = struct {
    allocator: std.mem.Allocator,
    low_instance: *const Vulkan.Instance,
    low_device: *const Vulkan.Device,
    instance_handle: vk.Instance,
    physical_device: vk.PhysicalDevice,
    device_handle: vk.Device,
    instance_wrapper: vk.InstanceWrapper,
    device_wrapper: vk.DeviceWrapper,
    encode_queue: vk.Queue,
    encode_queue_family: u32,
    compute_queue: vk.Queue,
    compute_queue_family: u32,
    memory_properties: vk.PhysicalDeviceMemoryProperties,
    attached_targets: usize = 0,

    pub fn init(options: anytype) !VideoDevice {
        const low_instance: *const Vulkan.Instance = options.instance;
        const low_device: *const Vulkan.Device = options.device;
        const instance_handle = toInstance(low_instance.handle);
        const physical_device = toPhysicalDevice(options.physical_device);
        const device_handle = toDevice(low_device.handle);
        const get_instance_proc_addr: vk.PfnGetInstanceProcAddr = @ptrCast(low_instance.get_instance_proc_addr);
        const get_device_proc_addr: vk.PfnGetDeviceProcAddr = @ptrCast(low_instance.dispatch.get_device_proc_addr);
        const instance_wrapper = vk.InstanceWrapper.load(instance_handle, get_instance_proc_addr);
        const device_wrapper = vk.DeviceWrapper.load(device_handle, get_device_proc_addr);
        try requireCommands(device_wrapper.dispatch);
        return .{
            .allocator = options.allocator,
            .low_instance = low_instance,
            .low_device = low_device,
            .instance_handle = instance_handle,
            .physical_device = physical_device,
            .device_handle = device_handle,
            .instance_wrapper = instance_wrapper,
            .device_wrapper = device_wrapper,
            .encode_queue = toQueue(options.encode_queue),
            .encode_queue_family = options.encode_queue_family,
            .compute_queue = toQueue(options.compute_queue),
            .compute_queue_family = options.compute_queue_family,
            .memory_properties = instance_wrapper.getPhysicalDeviceMemoryProperties(physical_device),
        };
    }

    pub fn deinit(self: *VideoDevice) void {
        if (std.debug.runtime_safety) std.debug.assert(self.attached_targets == 0);
        self.* = undefined;
    }

    pub fn device(self: *VideoDevice) vk.DeviceProxy {
        return vk.DeviceProxy.init(self.device_handle, &self.device_wrapper);
    }

    pub fn instance(self: *VideoDevice) vk.InstanceProxy {
        return vk.InstanceProxy.init(self.instance_handle, &self.instance_wrapper);
    }

    pub fn attachTarget(self: *VideoDevice) void {
        self.attached_targets += 1;
    }

    pub fn detachTarget(self: *VideoDevice) void {
        std.debug.assert(self.attached_targets != 0);
        self.attached_targets -= 1;
    }

    pub fn findMemoryType(self: *const VideoDevice, bits: u32, required: vk.MemoryPropertyFlags, preferred: vk.MemoryPropertyFlags) !u32 {
        var required_match: ?u32 = null;
        for (0..self.memory_properties.memory_type_count) |index| {
            if (bits & (@as(u32, 1) << @intCast(index)) == 0) continue;
            const flags = self.memory_properties.memory_types[index].property_flags;
            if (!flags.contains(required)) continue;
            if (flags.contains(preferred)) return @intCast(index);
            if (required_match == null) required_match = @intCast(index);
        }
        return required_match orelse error.NoCompatibleMemoryType;
    }
};

fn requireCommands(dispatch: vk.DeviceWrapper.Dispatch) !void {
    if (dispatch.vkCreateVideoSessionKHR == null or
        dispatch.vkDestroyVideoSessionKHR == null or
        dispatch.vkGetVideoSessionMemoryRequirementsKHR == null or
        dispatch.vkBindVideoSessionMemoryKHR == null or
        dispatch.vkCreateVideoSessionParametersKHR == null or
        dispatch.vkDestroyVideoSessionParametersKHR == null or
        dispatch.vkGetEncodedVideoSessionParametersKHR == null or
        dispatch.vkCmdBeginVideoCodingKHR == null or
        dispatch.vkCmdControlVideoCodingKHR == null or
        dispatch.vkCmdEncodeVideoKHR == null or
        dispatch.vkCmdEndVideoCodingKHR == null or
        dispatch.vkCmdPipelineBarrier2 == null)
    {
        return error.VulkanVideoFunctionUnavailable;
    }
}

fn toInstance(handle: low_vk.InstanceHandle) vk.Instance {
    return @enumFromInt(@intFromPtr(handle orelse return .null_handle));
}

fn toPhysicalDevice(handle: low_vk.PhysicalDevice) vk.PhysicalDevice {
    return @enumFromInt(@intFromPtr(handle orelse return .null_handle));
}

fn toDevice(handle: low_vk.DeviceHandle) vk.Device {
    return @enumFromInt(@intFromPtr(handle orelse return .null_handle));
}

fn toQueue(handle: low_vk.Queue) vk.Queue {
    return @enumFromInt(@intFromPtr(handle orelse return .null_handle));
}
