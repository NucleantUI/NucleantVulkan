//
//  VulkanRenderEngine+ExternalTexture.swift
//  NucleantVulkan
//
//  Factory, resize and write paths for `ExternalTextureNode` — see that file
//  for why every write is a synchronous copy into an image the node owns.
//
//  Two ways in:
//
//    * `writeExternalTexture(_:ioSurface:)` (Apple): the producer's IOSurface
//      is imported as a VkImage through VK_EXT_metal_objects
//      (`VkImportMetalIOSurfaceInfoEXT`) and copied GPU-to-GPU. No pixel
//      touches the CPU.
//    * `writeExternalTexture(_:bgra:…)`: CPU pixels, staged through a
//      host-visible buffer — the fallback for a producer that only has a
//      buffer to give (CEF with shared textures off, or unavailable).
//
//  Both record their copy into the node's own command buffer and submit it
//  on the graphics queue — the queue every frame's composite is submitted
//  on — then wait for it. Queue order does the rest: the barrier in front of
//  the copy waits out any composite still sampling the previous frame, the
//  one after it makes the next composite see this one.
//
import VulkanCore
@preconcurrency import CVulkan
#if os(macOS) || os(iOS)
import IOSurface
#endif

extension VulkanRenderEngine {

    /// The format both ends agree on: every external producer handled here
    /// (CEF's IOSurfaces, its software `OnPaint` buffer) delivers BGRA8, and
    /// BGRA is what the composite samples — so image and view are the same
    /// format and no byte is reinterpreted anywhere.
    public static var externalTextureFormat: VkFormat { VK_FORMAT_B8G8R8A8_UNORM }

    /// Build an `ExternalTextureNode` at `width × height` pixels, holding
    /// nothing yet: it stays out of the composite until its first write.
    /// Callers append the returned node themselves.
    public func makeExternalTextureNode(width: Int, height: Int) throws -> ExternalTextureNode<RenderNode> {
        let created = try makeExternalTextureImage(width: width, height: height)
        return ExternalTextureNode(
            width:     UInt32(width),
            height:    UInt32(height),
            image:     created.image,
            imageView: created.view,
            memory:    created.memory
        )
    }

    /// The node's own image: device-local, OPTIMAL tiling, BGRA8, starting
    /// UNDEFINED (the first write clears it). TRANSFER_DST for the writes,
    /// SAMPLED for the composite, and TRANSFER_SRC so `readExternalTexture`
    /// can copy back out of it — how a test sees what actually landed.
    private func makeExternalTextureImage(
        width:  Int,
        height: Int
    ) throws -> (image: VkImage, view: VkImageView, memory: VkDeviceMemory) {
        var image: VkImage?
        var imageInfo = VkImageCreateInfo()
        imageInfo.sType         = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
        imageInfo.imageType     = VK_IMAGE_TYPE_2D
        imageInfo.format        = Self.externalTextureFormat
        imageInfo.extent        = VkExtent3D(width: UInt32(width), height: UInt32(height), depth: 1)
        imageInfo.mipLevels     = 1
        imageInfo.arrayLayers   = 1
        imageInfo.samples       = VK_SAMPLE_COUNT_1_BIT
        imageInfo.tiling        = VK_IMAGE_TILING_OPTIMAL
        imageInfo.usage         = VkImageUsageFlags(
            VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue |
            VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue |
            VK_IMAGE_USAGE_SAMPLED_BIT.rawValue
        )
        imageInfo.sharingMode   = VK_SHARING_MODE_EXCLUSIVE
        imageInfo.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED
        guard vkCreateImage(device, &imageInfo, nil, &image) == VK_SUCCESS, let image else {
            throw VulkanEngineError.image
        }

        var requirements = VkMemoryRequirements()
        vkGetImageMemoryRequirements(device, image, &requirements)
        var memory: VkDeviceMemory?
        var allocInfo = VkMemoryAllocateInfo()
        allocInfo.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
        allocInfo.allocationSize = requirements.size
        allocInfo.memoryTypeIndex = findMemoryType(
            typeFilter: requirements.memoryTypeBits,
            properties: VkMemoryPropertyFlags(VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT.rawValue)
        )
        guard vkAllocateMemory(device, &allocInfo, nil, &memory) == VK_SUCCESS, let memory else {
            vkDestroyImage(device, image, nil)
            throw VulkanEngineError.memory
        }
        vkBindImageMemory(device, image, memory, 0)

        var view: VkImageView?
        var viewInfo = VkImageViewCreateInfo()
        viewInfo.sType    = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
        viewInfo.image    = image
        viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D
        viewInfo.format   = Self.externalTextureFormat
        viewInfo.subresourceRange = VkImageSubresourceRange(
            aspectMask:     VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT.rawValue),
            baseMipLevel:   0, levelCount: 1,
            baseArrayLayer: 0, layerCount: 1
        )
        guard vkCreateImageView(device, &viewInfo, nil, &view) == VK_SUCCESS, let view else {
            vkFreeMemory(device, memory, nil)
            vkDestroyImage(device, image, nil)
            throw VulkanEngineError.image
        }
        return (image, view, memory)
    }

    /// Resize a node **in place**, the way `resizeThorNode` does: a new image
    /// at the new size is swapped into the same node, so its slot, id and
    /// z-order stay. The new image starts empty — cleared on its first write —
    /// until the producer delivers a frame at the new size. `id` is the node's
    /// composite slot, whose cached descriptor still names the old view.
    /// Returns false, node untouched, when the new image can't be made.
    @discardableResult
    public func resizeExternalTextureNode(
        _ node: ExternalTextureNode<RenderNode>,
        id:     Int,
        width:  Int,
        height: Int
    ) -> Bool {
        guard width > 0, height > 0,
              node.width != UInt32(width) || node.height != UInt32(height)
        else { return true }
        let created: (image: VkImage, view: VkImageView, memory: VkDeviceMemory)
        do {
            created = try makeExternalTextureImage(width: width, height: height)
        } catch {
            print("VulkanRenderEngine: external texture resize to \(width)x\(height) failed: \(error)")
            return false
        }

        vkDeviceWaitIdle(device)
        vkDestroyImageView(device, node.imageView, nil)
        vkDestroyImage(device, node.image, nil)
        if let memory = node.memory {
            vkFreeMemory(device, memory, nil)
        }
        node.image         = created.image
        node.imageView     = created.view
        node.memory        = created.memory
        node.width         = UInt32(width)
        node.height        = UInt32(height)
        node.currentLayout = VK_IMAGE_LAYOUT_UNDEFINED
        node.hasContent    = false
        #if os(macOS) || os(iOS)
        // Sized for the old frames; the producer presents new surfaces now.
        node.releaseImportedSurfaces(self)
        #endif
        invalidateComposite(id: id)
        return true
    }

    // MARK: - Writes

    #if os(macOS) || os(iOS)
    /// Copy `ioSurface` (an `IOSurfaceRef`, BGRA8) into `node`'s image at
    /// pixel (`x`, `y`), GPU to GPU, and return once the copy has finished —
    /// the surface is free for its producer to reuse as soon as this returns.
    /// A surface bigger than the space left in the image is cut to fit; one
    /// smaller leaves the rest of the image as it was. False when the surface
    /// could not be imported (logged).
    @discardableResult
    public func writeExternalTexture(
        _ node:    ExternalTextureNode<RenderNode>,
        ioSurface: UnsafeMutableRawPointer,
        x:         Int = 0,
        y:         Int = 0
    ) -> Bool {
        guard let index = node.importedSurfaceIndex(ioSurface, engine: self) else { return false }
        let imported = node.importedSurfaces[index]
        let width  = min(imported.width,  Int(node.width)  - x)
        let height = min(imported.height, Int(node.height) - y)
        guard width > 0, height > 0 else { return true }

        return submitWrite(to: node) { cmd in
            // The producer wrote the surface on its own GPU timeline, all of
            // it finished before the surface was handed over; nothing on this
            // queue has touched it since the last write, which left it in
            // GENERAL (or PREINITIALIZED, on its first use — see
            // `importSurface`).
            engineImageBarrier(
                cmd,
                image:     imported.image,
                srcLayout: imported.layout,
                srcAccess: VkAccessFlags(VK_ACCESS_MEMORY_WRITE_BIT.rawValue),
                srcStage:  VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
                dstLayout: VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                dstAccess: VkAccessFlags(VK_ACCESS_TRANSFER_READ_BIT.rawValue),
                dstStage:  VK_PIPELINE_STAGE_TRANSFER_BIT
            )
            let layer = VkImageSubresourceLayers(
                aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT.rawValue),
                mipLevel: 0, baseArrayLayer: 0, layerCount: 1
            )
            var region = VkImageCopy(
                srcSubresource: layer,
                srcOffset:      VkOffset3D(x: 0, y: 0, z: 0),
                dstSubresource: layer,
                dstOffset:      VkOffset3D(x: Int32(x), y: Int32(y), z: 0),
                extent:         VkExtent3D(width: UInt32(width), height: UInt32(height), depth: 1)
            )
            vkCmdCopyImage(
                cmd,
                imported.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                node.image,     VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                1, &region
            )
            engineImageBarrier(
                cmd,
                image:     imported.image,
                srcLayout: VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                srcAccess: VkAccessFlags(VK_ACCESS_TRANSFER_READ_BIT.rawValue),
                srcStage:  VK_PIPELINE_STAGE_TRANSFER_BIT,
                dstLayout: VK_IMAGE_LAYOUT_GENERAL,
                dstAccess: 0,
                dstStage:  VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT
            )
            node.importedSurfaces[index].layout = VK_IMAGE_LAYOUT_GENERAL
        }
    }
    #endif

    /// Copy `height` rows of BGRA8 pixels, `bytesPerRow` apart, into `node`'s
    /// image at pixel (`x`, `y`) — the CPU fallback. Staged through a
    /// host-visible buffer the node keeps; returns once the copy has
    /// finished, so `pixels` may be reused as soon as this returns. Cut to
    /// fit, as the IOSurface write is.
    @discardableResult
    public func writeExternalTexture(
        _ node:      ExternalTextureNode<RenderNode>,
        bgra pixels: UnsafeRawPointer,
        width:       Int,
        height:      Int,
        bytesPerRow: Int,
        x:           Int = 0,
        y:           Int = 0
    ) -> Bool {
        let copyWidth  = min(width,  Int(node.width)  - x)
        let copyHeight = min(height, Int(node.height) - y)
        guard copyWidth > 0, copyHeight > 0 else { return true }
        let byteCount = bytesPerRow * height
        guard let staging = node.stagingBuffer(byteCount: byteCount, engine: self) else { return false }
        staging.mapped.copyMemory(from: pixels, byteCount: byteCount)

        return submitWrite(to: node) { cmd in
            var region = VkBufferImageCopy()
            region.bufferOffset      = 0
            region.bufferRowLength   = UInt32(bytesPerRow / 4)
            region.bufferImageHeight = UInt32(height)
            region.imageSubresource  = VkImageSubresourceLayers(
                aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT.rawValue),
                mipLevel: 0, baseArrayLayer: 0, layerCount: 1
            )
            region.imageOffset = VkOffset3D(x: Int32(x), y: Int32(y), z: 0)
            region.imageExtent = VkExtent3D(width: UInt32(copyWidth), height: UInt32(copyHeight), depth: 1)
            vkCmdCopyBufferToImage(cmd, staging.buffer, node.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region)
        }
    }

    /// Record `copy` between the barriers every write needs, submit it on the
    /// graphics queue and wait for it.
    ///
    /// In front of the copy, the node's image goes to TRANSFER_DST — waiting,
    /// by queue order, for any composite already submitted that still samples
    /// it. A fresh image (UNDEFINED) is cleared to transparent there too: a
    /// producer whose first frame is smaller than the image — one still
    /// catching up with a resize — would otherwise leave uninitialized memory
    /// showing at the edges. After it, the image goes back to what the
    /// composite samples, visible to every later submission.
    private func submitWrite(
        to node: ExternalTextureNode<RenderNode>,
        _ copy: (VkCommandBuffer) -> Void
    ) -> Bool {
        guard let cmd = node.writeCommandBuffer(engine: self), let fence = node.writeFence else { return false }
        vkResetCommandBuffer(cmd, 0)
        var begin = VkCommandBufferBeginInfo()
        begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
        begin.flags = VkCommandBufferUsageFlags(VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT.rawValue)
        vkBeginCommandBuffer(cmd, &begin)

        let fresh = node.currentLayout == VK_IMAGE_LAYOUT_UNDEFINED
        engineImageBarrier(
            cmd,
            image:     node.image,
            srcLayout: node.currentLayout,
            srcAccess: 0,
            srcStage:  fresh ? VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT : VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            dstLayout: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            dstAccess: VkAccessFlags(VK_ACCESS_TRANSFER_WRITE_BIT.rawValue),
            dstStage:  VK_PIPELINE_STAGE_TRANSFER_BIT
        )
        if fresh {
            var clear = VkClearColorValue(float32: (0, 0, 0, 0))
            var range = VkImageSubresourceRange(
                aspectMask:     VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT.rawValue),
                baseMipLevel:   0, levelCount: 1,
                baseArrayLayer: 0, layerCount: 1
            )
            vkCmdClearColorImage(cmd, node.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &clear, 1, &range)
            engineImageBarrier(
                cmd,
                image:     node.image,
                srcLayout: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                srcAccess: VkAccessFlags(VK_ACCESS_TRANSFER_WRITE_BIT.rawValue),
                srcStage:  VK_PIPELINE_STAGE_TRANSFER_BIT,
                dstLayout: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                dstAccess: VkAccessFlags(VK_ACCESS_TRANSFER_WRITE_BIT.rawValue),
                dstStage:  VK_PIPELINE_STAGE_TRANSFER_BIT
            )
        }

        copy(cmd)

        engineImageBarrier(
            cmd,
            image:     node.image,
            srcLayout: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            srcAccess: VkAccessFlags(VK_ACCESS_TRANSFER_WRITE_BIT.rawValue),
            srcStage:  VK_PIPELINE_STAGE_TRANSFER_BIT,
            dstLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            dstAccess: VkAccessFlags(VK_ACCESS_SHADER_READ_BIT.rawValue),
            dstStage:  VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT
        )
        vkEndCommandBuffer(cmd)

        var cmdOpt: VkCommandBuffer? = cmd
        let result: VkResult = withUnsafePointer(to: &cmdOpt) { cmdPtr in
            var submit = VkSubmitInfo()
            submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO
            submit.commandBufferCount = 1
            submit.pCommandBuffers = cmdPtr
            return vkQueueSubmit(graphicsQueue, 1, &submit, fence)
        }
        guard result == VK_SUCCESS else {
            print("VulkanRenderEngine: external texture write submit failed (\(result.rawValue))")
            return false
        }
        var fenceOpt: VkFence? = fence
        vkWaitForFences(device, 1, &fenceOpt, VK_TRUE, UInt64.max)
        vkResetFences(device, 1, &fenceOpt)

        node.currentLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
        node.hasContent = true
        return true
    }

    // MARK: - Readback

    /// The node's image as tightly packed BGRA8 rows, top row first — `nil`
    /// before its first write. Blocks on the GPU; for tests and debugging,
    /// never for a frame path.
    public func readExternalTexture(_ node: ExternalTextureNode<RenderNode>) -> [UInt8]? {
        guard node.hasContent else { return nil }
        let width = Int(node.width), height = Int(node.height)
        let byteCount = width * height * 4
        guard let readback = makeHostBuffer(byteCount: byteCount, usage: VK_BUFFER_USAGE_TRANSFER_DST_BIT) else {
            return nil
        }
        defer {
            vkUnmapMemory(device, readback.memory)
            vkDestroyBuffer(device, readback.buffer, nil)
            vkFreeMemory(device, readback.memory, nil)
        }
        oneTimeSubmit { cmd in
            engineImageBarrier(
                cmd,
                image:     node.image,
                srcLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                srcAccess: VkAccessFlags(VK_ACCESS_SHADER_READ_BIT.rawValue),
                srcStage:  VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
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
            vkCmdCopyImageToBuffer(cmd, node.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, readback.buffer, 1, &region)
            engineImageBarrier(
                cmd,
                image:     node.image,
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
}

// MARK: - Node-side write resources

extension ExternalTextureNode {

    /// The write path's command buffer, and its fence beside it — made on
    /// first use.
    func writeCommandBuffer(engine: Engine) -> VkCommandBuffer? {
        if let writeCommandBuffer { return writeCommandBuffer }
        var cmd: VkCommandBuffer?
        var allocInfo = VkCommandBufferAllocateInfo()
        allocInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
        allocInfo.commandPool = engine.commandPool
        allocInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY
        allocInfo.commandBufferCount = 1
        guard vkAllocateCommandBuffers(engine.device, &allocInfo, &cmd) == VK_SUCCESS, let cmd else { return nil }

        var fenceInfo = VkFenceCreateInfo()
        fenceInfo.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO
        var fence: VkFence?
        guard vkCreateFence(engine.device, &fenceInfo, nil, &fence) == VK_SUCCESS, let fence else {
            var cmdOpt: VkCommandBuffer? = cmd
            vkFreeCommandBuffers(engine.device, engine.commandPool, 1, &cmdOpt)
            return nil
        }
        writeCommandBuffer = cmd
        writeFence = fence
        return cmd
    }

    /// The staging buffer, grown to hold at least `byteCount` bytes.
    func stagingBuffer(byteCount: Int, engine: Engine) -> (buffer: VkBuffer, mapped: UnsafeMutableRawPointer)? {
        if let stagingBuffer, let stagingMapped, stagingSize >= byteCount {
            return (stagingBuffer, stagingMapped)
        }
        if let stagingMemory {
            vkUnmapMemory(engine.device, stagingMemory)
            vkFreeMemory(engine.device, stagingMemory, nil)
        }
        if let stagingBuffer {
            vkDestroyBuffer(engine.device, stagingBuffer, nil)
        }
        stagingBuffer = nil
        stagingMemory = nil
        stagingMapped = nil
        stagingSize = 0
        guard let made = engine.makeHostBuffer(byteCount: byteCount, usage: VK_BUFFER_USAGE_TRANSFER_SRC_BIT) else {
            print("VulkanRenderEngine: external texture staging buffer (\(byteCount) bytes) failed")
            return nil
        }
        stagingBuffer = made.buffer
        stagingMemory = made.memory
        stagingMapped = made.mapped
        stagingSize = byteCount
        return (made.buffer, made.mapped)
    }
}

#if os(macOS) || os(iOS)
extension ExternalTextureNode {

    /// Index into `importedSurfaces` of `surface`'s import, importing it
    /// first if it has not been seen. Moves it to the back: the list is kept
    /// in order of last use, and the front is what gets dropped.
    func importedSurfaceIndex(_ surface: UnsafeMutableRawPointer, engine: Engine) -> Int? {
        let ref = Unmanaged<IOSurfaceRef>.fromOpaque(surface).takeUnretainedValue()
        let width  = IOSurfaceGetWidth(ref)
        let height = IOSurfaceGetHeight(ref)
        if let index = importedSurfaces.firstIndex(where: { $0.surface == surface }) {
            let entry = importedSurfaces.remove(at: index)
            if entry.width == width, entry.height == height {
                importedSurfaces.append(entry)
                return importedSurfaces.count - 1
            }
            // The same address, a different size: not the surface imported.
            release(entry, engine: engine)
        }
        guard let imported = importSurface(surface, width: width, height: height, engine: engine) else {
            return nil
        }
        if importedSurfaces.count >= Self.importedSurfaceLimit {
            release(importedSurfaces.removeFirst(), engine: engine)
        }
        importedSurfaces.append(imported)
        return importedSurfaces.count - 1
    }

    /// A VkImage over `surface`'s memory via `VkImportMetalIOSurfaceInfoEXT`.
    ///
    /// The struct is laid out by hand (sType@0, pNext@8, ioSurface@16), as
    /// `VkImportMetalTextureInfoEXT` is in NucleantThorVG: its surface field
    /// is typed differently depending on whether the header was parsed as
    /// Objective-C, and a raw layout sidesteps what Swift made of it.
    ///
    /// LINEAR tiling, because an IOSurface's layout is linear and is the
    /// surface's, not the driver's to choose. That is also what makes
    /// PREINITIALIZED a legal initial layout — the one that promises the
    /// contents are kept — so the first copy out of it declares a layout the
    /// image is really in, and every later one the GENERAL the last left.
    private func importSurface(
        _ surface: UnsafeMutableRawPointer,
        width:     Int,
        height:    Int,
        engine:    Engine
    ) -> ImportedSurface? {
        let importInfo = UnsafeMutableRawPointer.allocate(byteCount: 24, alignment: MemoryLayout<UInt>.alignment)
        defer { importInfo.deallocate() }
        importInfo.initializeMemory(as: UInt8.self, repeating: 0, count: 24)
        importInfo.storeBytes(of: VK_STRUCTURE_TYPE_IMPORT_METAL_IO_SURFACE_INFO_EXT.rawValue, toByteOffset: 0, as: UInt32.self)
        importInfo.storeBytes(of: UInt(bitPattern: surface), toByteOffset: 16, as: UInt.self)

        var imageInfo = VkImageCreateInfo()
        imageInfo.sType         = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
        imageInfo.pNext         = UnsafeRawPointer(importInfo)
        imageInfo.imageType     = VK_IMAGE_TYPE_2D
        imageInfo.format        = Engine.externalTextureFormat
        imageInfo.extent        = VkExtent3D(width: UInt32(width), height: UInt32(height), depth: 1)
        imageInfo.mipLevels     = 1
        imageInfo.arrayLayers   = 1
        imageInfo.samples       = VK_SAMPLE_COUNT_1_BIT
        imageInfo.tiling        = VK_IMAGE_TILING_LINEAR
        imageInfo.usage         = VkImageUsageFlags(VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue)
        imageInfo.sharingMode   = VK_SHARING_MODE_EXCLUSIVE
        imageInfo.initialLayout = VK_IMAGE_LAYOUT_PREINITIALIZED
        var image: VkImage?
        guard vkCreateImage(engine.device, &imageInfo, nil, &image) == VK_SUCCESS, let image else {
            print("VulkanRenderEngine: importing IOSurface \(width)x\(height) as a VkImage failed")
            return nil
        }

        // MoltenVK backs the image with the surface itself; the allocation
        // only satisfies Vulkan's bind-before-use rule.
        var requirements = VkMemoryRequirements()
        vkGetImageMemoryRequirements(engine.device, image, &requirements)
        var allocInfo = VkMemoryAllocateInfo()
        allocInfo.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
        allocInfo.allocationSize = requirements.size
        allocInfo.memoryTypeIndex = engine.findMemoryType(
            typeFilter: requirements.memoryTypeBits,
            properties: VkMemoryPropertyFlags(VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT.rawValue)
        )
        var memory: VkDeviceMemory?
        guard vkAllocateMemory(engine.device, &allocInfo, nil, &memory) == VK_SUCCESS, let memory else {
            vkDestroyImage(engine.device, image, nil)
            print("VulkanRenderEngine: memory for imported IOSurface failed")
            return nil
        }
        vkBindImageMemory(engine.device, image, memory, 0)

        _ = Unmanaged<IOSurfaceRef>.fromOpaque(surface).retain()
        return ImportedSurface(
            surface: surface,
            width:   width,
            height:  height,
            image:   image,
            memory:  memory,
            layout:  VK_IMAGE_LAYOUT_PREINITIALIZED
        )
    }

    /// Drop one import: its image and allocation, and its retain on the
    /// surface. Only ever called between writes, whose fence waits leave
    /// nothing on the GPU reading it.
    private func release(_ entry: ImportedSurface, engine: Engine) {
        vkDestroyImage(engine.device, entry.image, nil)
        if let memory = entry.memory {
            vkFreeMemory(engine.device, memory, nil)
        }
        Unmanaged<IOSurfaceRef>.fromOpaque(entry.surface).release()
    }

    func releaseImportedSurfaces(_ engine: Engine) {
        for entry in importedSurfaces {
            release(entry, engine: engine)
        }
        importedSurfaces.removeAll()
    }
}
#endif
