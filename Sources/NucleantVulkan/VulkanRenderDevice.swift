//
//  VulkanRenderDevice.swift
//  NucleantVulkan
//
//  The GPU half of the engine: instance → physical device → device → queue
//  → pools, and the node work rendered on them. Nothing here needs a window
//  — a `VulkanRenderEngine` is one window's surface, swapchain and composite
//  pass, presenting through one of these, and any number of engines can
//  present through the same one. Whoever builds the engines holds the device
//  and hands it to each of them; nothing here keeps one of its own.
//

import VulkanCore
import CVulkan

// @unchecked Sendable: every handle is an immutable `let` set once at init,
// and everything that drives the device — its renders, every window's
// frames — runs on main.
public final class VulkanRenderDevice<RenderNode: RenderContainerNode>: VulkanContext, @unchecked Sendable {

    public let instance:         VkInstance
    public let physicalDevice:   VkPhysicalDevice
    public let device:           VkDevice
    public let queueFamilyIndex: UInt32
    public let graphicsQueue:    VkQueue
    public let commandPool:      VkCommandPool
    public let descriptorPool:   VkDescriptorPool

    /// Frames in flight for the device's own renders — per-frame resources
    /// allocated against it (a staging slice) are indexed by `frameIndex`.
    /// Each window keeps its own count for its own frames.
    public let imageCount: Int = 2

    // MARK: Node state

    /// Slot ids whose node image holds content and sits in
    /// SHADER_READ_ONLY_OPTIMAL — what any window's composite may sample. A
    /// node's update publishes into it; whatever swaps a node's image in
    /// place takes the id out until the next update publishes the new one.
    public var readable: Set<Int> = []

    /// Nodes already logged for a draw failure — ThorVG's Canvas
    /// legitimately (and permanently) returns InsufficientCondition from a
    /// canvas nothing was ever painted into, so it is expected steady-state
    /// for some nodes, not a transient error worth repeating every frame.
    public var warnedFailedNodes: Set<Int> = []

    // MARK: Renders

    /// The device's frame-in-flight cursor, 0..<imageCount: during
    /// `render`, the slot whose previous render has finished on the GPU.
    public private(set) var frameIndex: Int = 0

    private var renderCommandBuffers: [VkCommandBuffer?] = []
    private var renderFences:         [VkFence?]         = []

    // MARK: Submissions

    /// Every submission on the queue is counted — the device's renders and
    /// writes, and every window's frames — so a release can wait for all of
    /// them, whichever window or render last used what it frees.
    private var submitted: UInt64 = 0
    /// Submissions not yet seen finished, and the fence each signals.
    private var inFlight: [(serial: UInt64, fence: VkFence)] = []
    private var pendingReleases: [(after: UInt64, release: () -> Void)] = []

    /// Makes the device on the first GPU with a queue family that does
    /// graphics and compute — and, when `surface` is given, presents to it.
    /// Without one, presenting is checked per window instead
    /// (`canPresent(to:)`), when its engine is made.
    ///
    /// Owns `instance` from here on: it is destroyed with the device.
    public init(instance: VkInstance, presentingTo surface: VkSurfaceKHR? = nil) throws {
        self.instance = instance

        // --- Physical device --------------------------------------------------
        var gpuCount: UInt32 = 0
        vkEnumeratePhysicalDevices(instance, &gpuCount, nil)
        guard gpuCount > 0 else { throw VulkanEngineError.noPhysicalDevice }
        var gpus = [VkPhysicalDevice?](repeating: nil, count: Int(gpuCount))
        vkEnumeratePhysicalDevices(instance, &gpuCount, &gpus)
        guard let gpu = gpus.compactMap({ $0 }).first else {
            throw VulkanEngineError.noPhysicalDevice
        }
        self.physicalDevice = gpu

        // --- Queue family: graphics + compute (+ present) --------------------
        var familyCount: UInt32 = 0
        vkGetPhysicalDeviceQueueFamilyProperties(gpu, &familyCount, nil)
        var families = [VkQueueFamilyProperties](
            repeating: VkQueueFamilyProperties(),
            count: Int(familyCount)
        )
        vkGetPhysicalDeviceQueueFamilyProperties(gpu, &familyCount, &families)
        let needed = VkQueueFlags(VK_QUEUE_GRAPHICS_BIT.rawValue | VK_QUEUE_COMPUTE_BIT.rawValue)
        var pickedFamily: UInt32?
        for (i, family) in families.enumerated() where (family.queueFlags & needed) == needed {
            if let surface {
                var presentable: VkBool32 = VK_FALSE
                vkGetPhysicalDeviceSurfaceSupportKHR(gpu, UInt32(i), surface, &presentable)
                guard presentable == VK_TRUE else { continue }
            }
            pickedFamily = UInt32(i)
            break
        }
        guard let familyIndex = pickedFamily else { throw VulkanEngineError.noPresentQueue }
        self.queueFamilyIndex = familyIndex

        // --- Device + queue ----------------------------------------------------
        let availableDeviceExts = enumerateDeviceExtensions(gpu)
        var deviceExtensions = ["VK_KHR_swapchain"]
        if availableDeviceExts.contains("VK_KHR_portability_subset") {
            deviceExtensions.append("VK_KHR_portability_subset")
        }
        if availableDeviceExts.contains("VK_EXT_metal_objects") {
            deviceExtensions.append("VK_EXT_metal_objects")
        }
        // Linux/Android ThorVG zero-copy: import wgpu-native's exported memory
        // fd (VK_KHR_external_memory_fd) as a VkImage on *this* device — the
        // Linux/Vulkan mirror of VK_EXT_metal_objects above. Both device
        // extensions are the cross-platform half of VK_KHR_external_memory,
        // already core since Vulkan 1.1.
        if availableDeviceExts.contains("VK_KHR_external_memory_fd") {
            deviceExtensions.append("VK_KHR_external_memory_fd")
        }
        // Windows' half of the same handoff: there wgpu-native exports the
        // memory as an NT handle (VK_KHR_external_memory_win32) instead.
        if availableDeviceExts.contains("VK_KHR_external_memory_win32") {
            deviceExtensions.append("VK_KHR_external_memory_win32")
        }
        #if os(Android) && NUCLEANT_ANDROID_USE_AHARDWAREBUFFER
        // Android ThorVG zero-copy, opt-in build only (see
        // ANDROID_USE_AHARDWAREBUFFER in Package.swift): the same idea one
        // handle type over, for devices/emulators that support this instead
        // of (or in addition to) VK_KHR_external_memory_fd.
        // VK_KHR_sampler_ycbcr_conversion and VK_EXT_queue_family_foreign are
        // its documented dependencies.
        for ext in [
            "VK_ANDROID_external_memory_android_hardware_buffer",
            "VK_KHR_sampler_ycbcr_conversion",
            "VK_EXT_queue_family_foreign",
        ] where availableDeviceExts.contains(ext) {
            deviceExtensions.append(ext)
        }
        #endif
        var createdDevice: VkDevice?
        var priority: Float = 1.0
        let devResult: VkResult = withUnsafePointer(to: &priority) { priorityPtr in
            var qci = VkDeviceQueueCreateInfo()
            qci.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
            qci.queueFamilyIndex = familyIndex
            qci.queueCount = 1
            qci.pQueuePriorities = priorityPtr
            return withUnsafePointer(to: &qci) { qciPtr in
                withCStringArray(deviceExtensions) { extPtr, extCount in
                    var dci = VkDeviceCreateInfo()
                    dci.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
                    dci.queueCreateInfoCount = 1
                    dci.pQueueCreateInfos = qciPtr
                    dci.enabledExtensionCount = extCount
                    dci.ppEnabledExtensionNames = extPtr
                    return vkCreateDevice(gpu, &dci, nil, &createdDevice)
                }
            }
        }
        guard devResult == VK_SUCCESS, let device = createdDevice else {
            throw VulkanEngineError.device(devResult.rawValue)
        }
        self.device = device

        var queue: VkQueue?
        vkGetDeviceQueue(device, familyIndex, 0, &queue)
        guard let queue else { throw VulkanEngineError.noPresentQueue }
        self.graphicsQueue = queue

        // --- Command pool -------------------------------------------------------
        var createdPool: VkCommandPool?
        var poolInfo = VkCommandPoolCreateInfo()
        poolInfo.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
        poolInfo.flags = VkCommandPoolCreateFlags(VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT.rawValue)
        poolInfo.queueFamilyIndex = familyIndex
        guard vkCreateCommandPool(device, &poolInfo, nil, &createdPool) == VK_SUCCESS,
              let pool = createdPool else {
            throw VulkanEngineError.commandPool
        }
        self.commandPool = pool

        // --- Descriptor pool ------------------------------------------------------
        self.descriptorPool = try makeDeviceDescriptorPool(device: device, maxSets: 256)

        // --- The device's own frames in flight ---------------------------------------
        try createRenderRing()
    }

    deinit {
        // The last engine on the device is gone by now — nothing of any
        // window's is left to wait for but what the device ran itself.
        vkDeviceWaitIdle(device)
        for pending in pendingReleases { pending.release() }
        pendingReleases.removeAll()
        for fence in renderFences where fence != nil { vkDestroyFence(device, fence, nil) }
        vkDestroyDescriptorPool(device, descriptorPool, nil)
        vkDestroyCommandPool(device, commandPool, nil)
        vkDestroyDevice(device, nil)
        vkDestroyInstance(instance, nil)
    }

    private func createRenderRing() throws {
        var allocInfo = VkCommandBufferAllocateInfo()
        allocInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
        allocInfo.commandPool = commandPool
        allocInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY
        allocInfo.commandBufferCount = UInt32(imageCount)
        var buffers = [VkCommandBuffer?](repeating: nil, count: imageCount)
        guard vkAllocateCommandBuffers(device, &allocInfo, &buffers) == VK_SUCCESS else {
            throw VulkanEngineError.sync
        }
        renderCommandBuffers = buffers
        for _ in 0..<imageCount {
            var fenceInfo = VkFenceCreateInfo()
            fenceInfo.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO
            fenceInfo.flags = VkFenceCreateFlags(VK_FENCE_CREATE_SIGNALED_BIT.rawValue)
            var fence: VkFence?
            guard vkCreateFence(device, &fenceInfo, nil, &fence) == VK_SUCCESS else {
                throw VulkanEngineError.sync
            }
            renderFences.append(fence)
        }
    }

    // MARK: - Render

    /// Record every slot's node update into one of the device's own command
    /// buffers and submit it — a window's node work ahead of its composite,
    /// or nodes no window shows at all. Slots are updated in order, so a
    /// node that copies out of another is listed after it.
    ///
    /// Doesn't wait for the work: only for the render `imageCount` renders
    /// ago, whose command buffer — and staging slices, `frameIndex` — this
    /// one reuses. What a later submission reads of it, a composite or a
    /// readback, is ordered by queue order and the nodes' own barriers.
    public func render(_ slots: [RenderNode]) {
        let frame = frameIndex
        guard let cmd = renderCommandBuffers[frame], let fence = renderFences[frame] else { return }
        var fenceOpt: VkFence? = fence
        vkWaitForFences(device, 1, &fenceOpt, VK_TRUE, UInt64.max)
        runFinishedReleases()

        vkResetCommandBuffer(cmd, 0)
        var begin = VkCommandBufferBeginInfo()
        begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
        begin.flags = VkCommandBufferUsageFlags(VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT.rawValue)
        vkBeginCommandBuffer(cmd, &begin)
        for slot in slots {
            slot.update(device: self, cmd: cmd)
        }
        vkEndCommandBuffer(cmd)

        vkResetFences(device, 1, &fenceOpt)
        let result = submit(cmd, fence: fence)
        if result != VK_SUCCESS {
            print("VulkanRenderDevice: render submit failed (\(result.rawValue))")
        }
        frameIndex = (frameIndex + 1) % imageCount
    }

    /// Record `body` into a transient command buffer, submit it and wait for
    /// it — that work only, not the queue: other windows' frames go on.
    public func oneTimeSubmit(_ body: (VkCommandBuffer) -> Void) {
        var cmd: VkCommandBuffer?
        var allocInfo = VkCommandBufferAllocateInfo()
        allocInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
        allocInfo.commandPool = commandPool
        allocInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY
        allocInfo.commandBufferCount = 1
        vkAllocateCommandBuffers(device, &allocInfo, &cmd)
        guard let cmd else { return }
        var cmdOpt: VkCommandBuffer? = cmd
        defer { vkFreeCommandBuffers(device, commandPool, 1, &cmdOpt) }

        var fenceInfo = VkFenceCreateInfo()
        fenceInfo.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO
        var fence: VkFence?
        guard vkCreateFence(device, &fenceInfo, nil, &fence) == VK_SUCCESS, let fence else { return }
        defer { vkDestroyFence(device, fence, nil) }

        var begin = VkCommandBufferBeginInfo()
        begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
        begin.flags = VkCommandBufferUsageFlags(VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT.rawValue)
        vkBeginCommandBuffer(cmd, &begin)
        body(cmd)
        vkEndCommandBuffer(cmd)

        submitAndWait(cmd, fence: fence)
    }

    // MARK: - Submit

    /// Submit `cmd` on the queue, signalling `fence` — the one way work
    /// reaches the queue, the device's and every window's, so each
    /// submission counts toward `releaseAfterInFlightWork`.
    ///
    /// `fence` must have been waited since it was last submitted (every
    /// caller waits before resetting): a fence handed in again means the
    /// submission it last signalled is done.
    public func submit(
        _ cmd: VkCommandBuffer,
        waitSemaphore:   VkSemaphore? = nil,
        waitStage:       VkPipelineStageFlags = 0,
        signalSemaphore: VkSemaphore? = nil,
        fence:           VkFence
    ) -> VkResult {
        var waitStage = waitStage
        var waitSem   = waitSemaphore
        var signalSem = signalSemaphore
        var cmdOpt: VkCommandBuffer? = cmd
        let result: VkResult = withUnsafePointer(to: &waitStage) { stagePtr in
            withUnsafePointer(to: &waitSem) { waitPtr in
                withUnsafePointer(to: &signalSem) { signalPtr in
                    withUnsafePointer(to: &cmdOpt) { cmdPtr in
                        var info = VkSubmitInfo()
                        info.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO
                        info.waitSemaphoreCount = waitSemaphore == nil ? 0 : 1
                        info.pWaitSemaphores = waitSemaphore == nil ? nil : waitPtr
                        info.pWaitDstStageMask = waitSemaphore == nil ? nil : stagePtr
                        info.commandBufferCount = 1
                        info.pCommandBuffers = cmdPtr
                        info.signalSemaphoreCount = signalSemaphore == nil ? 0 : 1
                        info.pSignalSemaphores = signalSemaphore == nil ? nil : signalPtr
                        return vkQueueSubmit(graphicsQueue, 1, &info, fence)
                    }
                }
            }
        }
        guard result == VK_SUCCESS else { return result }
        inFlight.removeAll { $0.fence == fence }
        submitted += 1
        inFlight.append((serial: submitted, fence: fence))
        return result
    }

    /// `submit`, then wait for that submission alone — not the queue, so
    /// other windows' frames go on — and reset `fence` for its next use.
    @discardableResult
    public func submitAndWait(_ cmd: VkCommandBuffer, fence: VkFence) -> VkResult {
        let result = submit(cmd, fence: fence)
        guard result == VK_SUCCESS else { return result }
        var fenceOpt: VkFence? = fence
        vkWaitForFences(device, 1, &fenceOpt, VK_TRUE, UInt64.max)
        vkResetFences(device, 1, &fenceOpt)
        didWait(on: fence)
        return result
    }

    /// The submission `fence` last signalled is done — the caller waited for
    /// it. Required before a fence handed to `submit` is destroyed, so the
    /// device never asks a fence that no longer exists.
    public func didWait(on fence: VkFence) {
        inFlight.removeAll { $0.fence == fence }
    }

    // MARK: - Deferred release

    /// Run `release` once every submission made so far — any window's
    /// frame, any render or write — has finished on the GPU: for what is
    /// being freed while something in flight may still read it (a node's
    /// image, a descriptor pool a composite binds). Never blocks: it runs at
    /// the first render, frame or release that finds that work done — right
    /// here, when nothing is in flight.
    public func releaseAfterInFlightWork(_ release: @escaping () -> Void) {
        pendingReleases.append((after: submitted, release: release))
        runFinishedReleases()
    }

    /// Run the releases whose submissions the GPU has finished.
    public func runFinishedReleases() {
        guard !pendingReleases.isEmpty else { return }
        inFlight.removeAll { vkGetFenceStatus(device, $0.fence) == VK_SUCCESS }
        // Everything before the oldest submission still out is done.
        let completed = (inFlight.map(\.serial).min() ?? submitted + 1) - 1
        let due = pendingReleases.filter { $0.after <= completed }
        guard !due.isEmpty else { return }
        pendingReleases.removeAll { $0.after <= completed }
        for pending in due { pending.release() }
    }

    // MARK: - Readback

    /// `image` as tightly packed 4-byte texels, top row first, in its own
    /// format — read from SHADER_READ_ONLY_OPTIMAL, where a node's update
    /// leaves it, and put back there. Needs TRANSFER_SRC usage, which every
    /// node image made by the device has. Blocks on the GPU; for tests,
    /// export and debugging, never for a frame path.
    public func readPixels(of image: VkImage, width: Int, height: Int) -> [UInt8]? {
        let byteCount = width * height * 4
        guard byteCount > 0,
              let readback = makeHostBuffer(byteCount: byteCount, usage: VK_BUFFER_USAGE_TRANSFER_DST_BIT)
        else { return nil }
        defer {
            vkUnmapMemory(device, readback.memory)
            vkDestroyBuffer(device, readback.buffer, nil)
            vkFreeMemory(device, readback.memory, nil)
        }
        oneTimeSubmit { cmd in
            engineImageBarrier(
                cmd,
                image:     image,
                srcLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                srcAccess: VkAccessFlags(VK_ACCESS_MEMORY_WRITE_BIT.rawValue),
                srcStage:  VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
                dstLayout: VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                dstAccess: VkAccessFlags(VK_ACCESS_TRANSFER_READ_BIT.rawValue),
                dstStage:  VK_PIPELINE_STAGE_TRANSFER_BIT
            )
            var region = VkBufferImageCopy()
            region.imageSubresource = VkImageSubresourceLayers(
                aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT.rawValue),
                mipLevel: 0, baseArrayLayer: 0, layerCount: 1
            )
            region.imageExtent = VkExtent3D(width: UInt32(width), height: UInt32(height), depth: 1)
            vkCmdCopyImageToBuffer(cmd, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, readback.buffer, 1, &region)
            engineImageBarrier(
                cmd,
                image:     image,
                srcLayout: VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                srcAccess: VkAccessFlags(VK_ACCESS_TRANSFER_READ_BIT.rawValue),
                srcStage:  VK_PIPELINE_STAGE_TRANSFER_BIT,
                dstLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                dstAccess: VkAccessFlags(VK_ACCESS_SHADER_READ_BIT.rawValue),
                dstStage:  VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT
            )
        }
        return Array(UnsafeRawBufferPointer(start: readback.mapped, count: byteCount))
    }

    /// A node's image, read back as `readPixels(of:width:height:)` does —
    /// `nil` until an update has published it (`readable`).
    public func readPixels<Node: VulkanRenderNode>(of node: Node, id: Int) -> [UInt8]? where Node.ContainerNode == RenderNode {
        guard readable.contains(id) else { return nil }
        return readPixels(of: node.image, width: Int(node.width), height: Int(node.height))
    }

    /// A host-visible, coherent buffer of `byteCount` bytes, mapped. The
    /// caller unmaps and frees it.
    func makeHostBuffer(
        byteCount: Int,
        usage:     VkBufferUsageFlagBits
    ) -> (buffer: VkBuffer, memory: VkDeviceMemory, mapped: UnsafeMutableRawPointer)? {
        var info = VkBufferCreateInfo()
        info.sType       = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
        info.size        = VkDeviceSize(byteCount)
        info.usage       = VkBufferUsageFlags(usage.rawValue)
        info.sharingMode = VK_SHARING_MODE_EXCLUSIVE
        var buffer: VkBuffer?
        guard vkCreateBuffer(device, &info, nil, &buffer) == VK_SUCCESS, let buffer else { return nil }

        var requirements = VkMemoryRequirements()
        vkGetBufferMemoryRequirements(device, buffer, &requirements)
        var alloc = VkMemoryAllocateInfo()
        alloc.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
        alloc.allocationSize = requirements.size
        alloc.memoryTypeIndex = findMemoryType(
            typeFilter: requirements.memoryTypeBits,
            properties: VkMemoryPropertyFlags(
                VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT.rawValue | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT.rawValue
            )
        )
        var memory: VkDeviceMemory?
        guard vkAllocateMemory(device, &alloc, nil, &memory) == VK_SUCCESS, let memory else {
            vkDestroyBuffer(device, buffer, nil)
            return nil
        }
        vkBindBufferMemory(device, buffer, memory, 0)
        var mapped: UnsafeMutableRawPointer?
        guard vkMapMemory(device, memory, 0, VkDeviceSize(byteCount), 0, &mapped) == VK_SUCCESS, let mapped else {
            vkFreeMemory(device, memory, nil)
            vkDestroyBuffer(device, buffer, nil)
            return nil
        }
        return (buffer, memory, mapped)
    }

    /// Whether the device's queue can present to `surface` — asked of every
    /// window's surface, since the queue family was picked without it.
    public func canPresent(to surface: VkSurfaceKHR) -> Bool {
        var presentable: VkBool32 = VK_FALSE
        vkGetPhysicalDeviceSurfaceSupportKHR(physicalDevice, queueFamilyIndex, surface, &presentable)
        return presentable == VK_TRUE
    }
}


// MARK: - Helpers

private func enumerateDeviceExtensions(_ gpu: VkPhysicalDevice) -> Set<String> {
    var count: UInt32 = 0
    vkEnumerateDeviceExtensionProperties(gpu, nil, &count, nil)
    guard count > 0 else { return [] }
    var props = [VkExtensionProperties](repeating: VkExtensionProperties(), count: Int(count))
    vkEnumerateDeviceExtensionProperties(gpu, nil, &count, &props)
    return Set(props.map(extensionName))
}

private func makeDeviceDescriptorPool(device: VkDevice, maxSets: Int) throws -> VkDescriptorPool {
    let n = UInt32(maxSets)
    let sizes = [
        VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, descriptorCount: n),
        VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,          descriptorCount: n),
        VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,         descriptorCount: n),
        VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,         descriptorCount: n),
    ]
    var pool: VkDescriptorPool?
    let result = sizes.withUnsafeBufferPointer { buf -> VkResult in
        var info = VkDescriptorPoolCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
        info.flags = VkDescriptorPoolCreateFlags(VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT.rawValue)
        info.maxSets = UInt32(maxSets)
        info.poolSizeCount = UInt32(buf.count)
        info.pPoolSizes = buf.baseAddress
        return vkCreateDescriptorPool(device, &info, nil, &pool)
    }
    guard result == VK_SUCCESS, let pool else { throw VulkanEngineError.descriptorPool }
    return pool
}
