//
//  VulkanRenderEngine+PixelBuffer.swift
//  NucleantVulkan
//
//  The CPU-fed node factory: an engine-owned RGBA8 image plus a
//  persistently-mapped staging buffer. Generic (no backend library), so it
//  lives in the engine core alongside `PixelBufferShaderNode` itself.
//
import VulkanCore
import CVulkan


extension VulkanRenderEngine {

    /// Build a CPU-fed upload node: an engine-owned RGBA8 image (TRANSFER_DST
    /// + SAMPLED + STORAGE) and a persistently-mapped host-visible staging
    /// buffer with one slice per frame-in-flight. The image starts UNDEFINED —
    /// the node's first `write` overwrites every texel, and until that first
    /// write the engine keeps it out of the composite entirely. The engine
    /// does not own the resources — `destroyResources(_:)` frees them when the
    /// node is dropped. Callers append the returned node themselves.
    ///
    /// `scale` > 1 sizes the node's image at width/height × scale while the
    /// producer keeps writing source-sized frames: the upload lands in an
    /// intermediate source-sized image first and a nearest `vkCmdBlitImage`
    /// stretches it up — so a post shader (e.g. a pixel-art AA upscaler) gets
    /// real subpixels without the producer replicating a single pixel. At
    /// scale 1 no intermediate image exists and the path is a direct copy.
    public func makePixelBufferNode(width: Int, height: Int, scale: Int = 1) throws -> PixelBufferShaderNode<RenderNode> {
        let scale = max(scale, 1)

        var image: VkImage?
        var imageInfo = VkImageCreateInfo()
        imageInfo.sType         = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
        imageInfo.imageType     = VK_IMAGE_TYPE_2D
        imageInfo.format        = VK_FORMAT_R8G8B8A8_UNORM
        imageInfo.extent        = VkExtent3D(width: UInt32(width * scale), height: UInt32(height * scale), depth: 1)
        imageInfo.mipLevels     = 1
        imageInfo.arrayLayers   = 1
        imageInfo.samples       = VK_SAMPLE_COUNT_1_BIT
        imageInfo.tiling        = VK_IMAGE_TILING_OPTIMAL
        imageInfo.usage         = VkImageUsageFlags(
            VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue |
            VK_IMAGE_USAGE_SAMPLED_BIT.rawValue |
            VK_IMAGE_USAGE_STORAGE_BIT.rawValue
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
        guard vkAllocateMemory(device, &allocInfo, nil, &memory) == VK_SUCCESS else {
            vkDestroyImage(device, image, nil)
            throw VulkanEngineError.memory
        }
        vkBindImageMemory(device, image, memory, 0)

        // The blit source at source resolution — only needed when scaling.
        // TRANSFER_DST (staging copy in) + TRANSFER_SRC (blit out); no view,
        // nothing ever samples it directly.
        var uploadImage:  VkImage?
        var uploadMemory: VkDeviceMemory?
        if scale > 1 {
            var upInfo = imageInfo
            upInfo.extent = VkExtent3D(width: UInt32(width), height: UInt32(height), depth: 1)
            upInfo.usage  = VkImageUsageFlags(
                VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue |
                VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue
            )
            guard vkCreateImage(device, &upInfo, nil, &uploadImage) == VK_SUCCESS,
                  let created = uploadImage else {
                throw VulkanEngineError.image
            }
            var upRequirements = VkMemoryRequirements()
            vkGetImageMemoryRequirements(device, created, &upRequirements)
            var upAlloc = VkMemoryAllocateInfo()
            upAlloc.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
            upAlloc.allocationSize = upRequirements.size
            upAlloc.memoryTypeIndex = findMemoryType(
                typeFilter: upRequirements.memoryTypeBits,
                properties: VkMemoryPropertyFlags(VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT.rawValue)
            )
            guard vkAllocateMemory(device, &upAlloc, nil, &uploadMemory) == VK_SUCCESS else {
                throw VulkanEngineError.memory
            }
            vkBindImageMemory(device, created, uploadMemory, 0)
        }

        var view: VkImageView?
        var viewInfo = VkImageViewCreateInfo()
        viewInfo.sType    = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
        viewInfo.image    = image
        viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D
        viewInfo.format   = VK_FORMAT_R8G8B8A8_UNORM
        viewInfo.subresourceRange = VkImageSubresourceRange(
            aspectMask:     VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT.rawValue),
            baseMipLevel:   0, levelCount: 1,
            baseArrayLayer: 0, layerCount: 1
        )
        guard vkCreateImageView(device, &viewInfo, nil, &view) == VK_SUCCESS, let view else {
            throw VulkanEngineError.image
        }

        // Staging: one buffer holding `imageCount` frame slices, HOST_VISIBLE
        // + HOST_COHERENT (no flush bookkeeping), mapped for the node's whole
        // lifetime.
        let bytesPerFrame = width * height * 4
        let stagingSize   = VkDeviceSize(bytesPerFrame * imageCount)
        var stagingBuffer: VkBuffer?
        var bufferInfo = VkBufferCreateInfo()
        bufferInfo.sType       = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
        bufferInfo.size        = stagingSize
        bufferInfo.usage       = VkBufferUsageFlags(VK_BUFFER_USAGE_TRANSFER_SRC_BIT.rawValue)
        bufferInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE
        guard vkCreateBuffer(device, &bufferInfo, nil, &stagingBuffer) == VK_SUCCESS,
              let stagingBuffer else {
            throw VulkanEngineError.image
        }

        var stagingRequirements = VkMemoryRequirements()
        vkGetBufferMemoryRequirements(device, stagingBuffer, &stagingRequirements)
        var stagingMemory: VkDeviceMemory?
        var stagingAlloc = VkMemoryAllocateInfo()
        stagingAlloc.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
        stagingAlloc.allocationSize = stagingRequirements.size
        stagingAlloc.memoryTypeIndex = findMemoryType(
            typeFilter: stagingRequirements.memoryTypeBits,
            properties: VkMemoryPropertyFlags(
                VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT.rawValue |
                VK_MEMORY_PROPERTY_HOST_COHERENT_BIT.rawValue
            )
        )
        guard vkAllocateMemory(device, &stagingAlloc, nil, &stagingMemory) == VK_SUCCESS,
              let stagingMemory else {
            throw VulkanEngineError.memory
        }
        vkBindBufferMemory(device, stagingBuffer, stagingMemory, 0)

        var mapped: UnsafeMutableRawPointer?
        guard vkMapMemory(device, stagingMemory, 0, stagingSize, 0, &mapped) == VK_SUCCESS,
              let mapped else {
            throw VulkanEngineError.memory
        }

        return PixelBufferShaderNode(
            sourceWidth:    UInt32(width),
            sourceHeight:   UInt32(height),
            scale:          UInt32(scale),
            image:          image,
            imageView:      view,
            memory:         memory,
            uploadImage:    uploadImage,
            uploadMemory:   uploadMemory,
            stagingBuffer:  stagingBuffer,
            stagingMemory:  stagingMemory,
            stagingPointer: mapped,
            sliceCount:     imageCount
        )
    }
}
