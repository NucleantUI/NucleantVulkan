//
//  VulkanRenderEngine+ImageNode.swift
//  NucleantVulkan
//
//  The copy-target node factory: an engine-owned image with nothing in it
//  yet, for `ImageNode`. Generic (no backend library), so it lives in the
//  engine core alongside the node itself.
//
import VulkanCore
import CVulkan


extension VulkanRenderEngine {

    /// Build a copy-target node: an engine-owned image (TRANSFER_DST +
    /// SAMPLED, device-local, OPTIMAL tiling) at `width × height`. The image
    /// starts UNDEFINED — the node's first copy takes it from there, and
    /// until that copy is recorded the engine keeps it out of the composite.
    /// The engine does not own the resources — `destroyResources(_:)` frees
    /// them when the node is dropped. Callers append the returned node
    /// themselves.
    ///
    /// `format` is the image's — `nil` for the wgpu render targets' pixel
    /// order (`WgpuContext.targetPixelOrder`), so a copy out of a canvas
    /// node is bytes, no conversion — and `viewFormat` how the composite
    /// reads it: BGRA, as every node's view is (the two-format rule the
    /// imported canvas images follow, for the same reason).
    public func makeImageNode(
        width:      Int,
        height:     Int,
        format:     VkFormat? = nil,
        viewFormat: VkFormat = VK_FORMAT_B8G8R8A8_UNORM
    ) throws -> ImageNode<RenderNode> {
        let format = format ?? {
            switch WgpuContext.targetPixelOrder {
            case .rgba8Unorm: VK_FORMAT_R8G8B8A8_UNORM
            case .bgra8Unorm: VK_FORMAT_B8G8R8A8_UNORM
            }
        }()
        var image: VkImage?
        var imageInfo = VkImageCreateInfo()
        imageInfo.sType         = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
        imageInfo.imageType     = VK_IMAGE_TYPE_2D
        imageInfo.format        = format
        imageInfo.extent        = VkExtent3D(width: UInt32(width), height: UInt32(height), depth: 1)
        imageInfo.mipLevels     = 1
        imageInfo.arrayLayers   = 1
        imageInfo.samples       = VK_SAMPLE_COUNT_1_BIT
        imageInfo.tiling        = VK_IMAGE_TILING_OPTIMAL
        imageInfo.usage         = VkImageUsageFlags(
            VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue |
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
        viewInfo.format   = viewFormat
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

        return ImageNode(
            width:     UInt32(width),
            height:    UInt32(height),
            image:     image,
            imageView: view,
            memory:    memory
        )
    }
}
