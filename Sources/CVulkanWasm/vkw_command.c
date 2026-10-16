// Command pools, command buffers and command recording.
//
// Recording only stores the commands (copying everything the caller's
// pointers held). They become WebGPU commands at vkQueueSubmit — see
// vkw_queue.c — which is also what lets a command buffer be submitted more
// than once, as Vulkan allows and a GPUCommandBuffer does not.

#if defined(__wasm__)

#include "vkw_internal.h"

// MARK: - Pools and buffers

VKAPI_ATTR VkResult VKAPI_CALL vkCreateCommandPool(
    VkDevice device, const VkCommandPoolCreateInfo *pCreateInfo, const VkAllocationCallbacks *pAllocator,
    VkCommandPool *pCommandPool) {
    (void)device;
    (void)pAllocator;
    if (pCreateInfo->queueFamilyIndex != 0) return VK_ERROR_INITIALIZATION_FAILED;
    VkCommandPool pool = calloc(1, sizeof *pool);
    if (!pool) return VK_ERROR_OUT_OF_HOST_MEMORY;
    *pCommandPool = pool;
    return VK_SUCCESS;
}

static void free_command_buffer(VkCommandBuffer buffer) {
    free(buffer->commands);
    free(buffer);
}

VKAPI_ATTR void VKAPI_CALL vkDestroyCommandPool(VkDevice device, VkCommandPool commandPool, const VkAllocationCallbacks *pAllocator) {
    (void)device;
    (void)pAllocator;
    if (!commandPool) return;
    for (VkCommandBuffer buffer = commandPool->buffers; buffer;) {
        VkCommandBuffer next = buffer->nextInPool;
        free_command_buffer(buffer);
        buffer = next;
    }
    free(commandPool);
}

VKAPI_ATTR VkResult VKAPI_CALL vkAllocateCommandBuffers(
    VkDevice device, const VkCommandBufferAllocateInfo *pAllocateInfo, VkCommandBuffer *pCommandBuffers) {
    VkCommandPool pool = pAllocateInfo->commandPool;
    for (uint32_t i = 0; i < pAllocateInfo->commandBufferCount; i++) {
        VkCommandBuffer buffer = calloc(1, sizeof *buffer);
        if (!buffer) {
            for (uint32_t j = 0; j < i; j++) {
                pool->buffers = pCommandBuffers[j]->nextInPool;
                free_command_buffer(pCommandBuffers[j]);
                pCommandBuffers[j] = NULL;
            }
            return VK_ERROR_OUT_OF_HOST_MEMORY;
        }
        buffer->device = device;
        buffer->pool = pool;
        buffer->nextInPool = pool->buffers;
        pool->buffers = buffer;
        pCommandBuffers[i] = buffer;
    }
    return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL vkFreeCommandBuffers(
    VkDevice device, VkCommandPool commandPool, uint32_t commandBufferCount, const VkCommandBuffer *pCommandBuffers) {
    (void)device;
    for (uint32_t i = 0; i < commandBufferCount; i++) {
        VkCommandBuffer buffer = pCommandBuffers[i];
        if (!buffer) continue;
        for (VkCommandBuffer *link = &commandPool->buffers; *link; link = &(*link)->nextInPool) {
            if (*link == buffer) {
                *link = buffer->nextInPool;
                break;
            }
        }
        free_command_buffer(buffer);
    }
}

VKAPI_ATTR VkResult VKAPI_CALL vkResetCommandBuffer(VkCommandBuffer commandBuffer, VkCommandBufferResetFlags flags) {
    (void)flags;
    commandBuffer->count = 0;
    commandBuffer->recording = 0;
    return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL vkBeginCommandBuffer(VkCommandBuffer commandBuffer, const VkCommandBufferBeginInfo *pBeginInfo) {
    (void)pBeginInfo;
    // Beginning implicitly resets, as with a pool created with
    // RESET_COMMAND_BUFFER_BIT.
    commandBuffer->count = 0;
    commandBuffer->recording = 1;
    return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL vkEndCommandBuffer(VkCommandBuffer commandBuffer) {
    commandBuffer->recording = 0;
    return VK_SUCCESS;
}

static vkw_cmd_t *append(VkCommandBuffer buffer, vkw_cmd_type_t type) {
    if (buffer->count == buffer->capacity) {
        uint32_t capacity = buffer->capacity ? buffer->capacity * 2 : 64;
        vkw_cmd_t *grown = realloc(buffer->commands, capacity * sizeof *grown);
        if (!grown) {
            vkw_logf("command buffer: out of memory, command dropped");
            return NULL;
        }
        buffer->commands = grown;
        buffer->capacity = capacity;
    }
    vkw_cmd_t *cmd = &buffer->commands[buffer->count++];
    memset(cmd, 0, sizeof *cmd);
    cmd->type = type;
    return cmd;
}

// MARK: - Render passes and state

VKAPI_ATTR void VKAPI_CALL vkCmdBeginRenderPass(
    VkCommandBuffer commandBuffer, const VkRenderPassBeginInfo *pRenderPassBegin, VkSubpassContents contents) {
    (void)contents;
    vkw_cmd_t *cmd = append(commandBuffer, VKW_CMD_BEGIN_RENDER_PASS);
    if (!cmd) return;
    cmd->beginRenderPass.renderPass = pRenderPassBegin->renderPass;
    cmd->beginRenderPass.framebuffer = pRenderPassBegin->framebuffer;
    uint32_t count = pRenderPassBegin->clearValueCount;
    if (count > VKW_MAX_COLOR_ATTACHMENTS) count = VKW_MAX_COLOR_ATTACHMENTS;
    cmd->beginRenderPass.clearCount = count;
    for (uint32_t i = 0; i < count; i++) cmd->beginRenderPass.clears[i] = pRenderPassBegin->pClearValues[i];
}

VKAPI_ATTR void VKAPI_CALL vkCmdEndRenderPass(VkCommandBuffer commandBuffer) {
    append(commandBuffer, VKW_CMD_END_RENDER_PASS);
}

VKAPI_ATTR void VKAPI_CALL vkCmdBindPipeline(VkCommandBuffer commandBuffer, VkPipelineBindPoint pipelineBindPoint, VkPipeline pipeline) {
    vkw_cmd_t *cmd = append(commandBuffer, VKW_CMD_BIND_PIPELINE);
    if (!cmd) return;
    cmd->bindPipeline.bindPoint = pipelineBindPoint == VK_PIPELINE_BIND_POINT_COMPUTE ? NWG_BIND_COMPUTE : NWG_BIND_GRAPHICS;
    cmd->bindPipeline.pipeline = pipeline;
}

VKAPI_ATTR void VKAPI_CALL vkCmdBindDescriptorSets(
    VkCommandBuffer commandBuffer, VkPipelineBindPoint pipelineBindPoint, VkPipelineLayout layout, uint32_t firstSet,
    uint32_t descriptorSetCount, const VkDescriptorSet *pDescriptorSets, uint32_t dynamicOffsetCount,
    const uint32_t *pDynamicOffsets) {
    (void)layout;
    (void)pDynamicOffsets;
    static int warned;
    if (dynamicOffsetCount > 0 && !warned) {
        warned = 1;
        vkw_logf("vkCmdBindDescriptorSets: dynamic offsets are not implemented on WebGPU yet; ignored");
    }
    vkw_cmd_t *cmd = append(commandBuffer, VKW_CMD_BIND_SETS);
    if (!cmd) return;
    cmd->bindSets.bindPoint = pipelineBindPoint == VK_PIPELINE_BIND_POINT_COMPUTE ? NWG_BIND_COMPUTE : NWG_BIND_GRAPHICS;
    cmd->bindSets.firstSet = firstSet;
    uint32_t count = descriptorSetCount;
    if (firstSet + count > VKW_MAX_SETS) count = firstSet < VKW_MAX_SETS ? VKW_MAX_SETS - firstSet : 0;
    cmd->bindSets.count = count;
    for (uint32_t i = 0; i < count; i++) cmd->bindSets.sets[i] = pDescriptorSets[i];
}

VKAPI_ATTR void VKAPI_CALL vkCmdPushConstants(
    VkCommandBuffer commandBuffer, VkPipelineLayout layout, VkShaderStageFlags stageFlags, uint32_t offset,
    uint32_t size, const void *pValues) {
    (void)layout;
    (void)stageFlags;
    if (offset + size > NWG_MAX_PUSH_CONSTANTS) return;
    vkw_cmd_t *cmd = append(commandBuffer, VKW_CMD_PUSH_CONSTANTS);
    if (!cmd) return;
    cmd->pushConstants.offset = offset;
    cmd->pushConstants.size = size;
    memcpy(cmd->pushConstants.bytes, pValues, size);
}

VKAPI_ATTR void VKAPI_CALL vkCmdSetViewport(
    VkCommandBuffer commandBuffer, uint32_t firstViewport, uint32_t viewportCount, const VkViewport *pViewports) {
    if (firstViewport != 0 || viewportCount == 0) return;  // WebGPU has a single viewport
    vkw_cmd_t *cmd = append(commandBuffer, VKW_CMD_SET_VIEWPORT);
    if (cmd) cmd->viewport = pViewports[0];
}

VKAPI_ATTR void VKAPI_CALL vkCmdSetScissor(
    VkCommandBuffer commandBuffer, uint32_t firstScissor, uint32_t scissorCount, const VkRect2D *pScissors) {
    if (firstScissor != 0 || scissorCount == 0) return;
    vkw_cmd_t *cmd = append(commandBuffer, VKW_CMD_SET_SCISSOR);
    if (cmd) cmd->scissor = pScissors[0];
}

VKAPI_ATTR void VKAPI_CALL vkCmdPipelineBarrier(
    VkCommandBuffer commandBuffer, VkPipelineStageFlags srcStageMask, VkPipelineStageFlags dstStageMask,
    VkDependencyFlags dependencyFlags, uint32_t memoryBarrierCount, const VkMemoryBarrier *pMemoryBarriers,
    uint32_t bufferMemoryBarrierCount, const VkBufferMemoryBarrier *pBufferMemoryBarriers,
    uint32_t imageMemoryBarrierCount, const VkImageMemoryBarrier *pImageMemoryBarriers) {
    // WebGPU tracks resource usage and synchronises between passes itself,
    // and has no image layouts: a barrier's ordering is already guaranteed,
    // and its layout transition has nothing to transition.
    (void)commandBuffer; (void)srcStageMask; (void)dstStageMask; (void)dependencyFlags;
    (void)memoryBarrierCount; (void)pMemoryBarriers; (void)bufferMemoryBarrierCount;
    (void)pBufferMemoryBarriers; (void)imageMemoryBarrierCount; (void)pImageMemoryBarriers;
}

static void set_stencil(VkCommandBuffer commandBuffer, uint32_t which, VkStencilFaceFlags faces, uint32_t value) {
    vkw_cmd_t *cmd = append(commandBuffer, VKW_CMD_SET_STENCIL);
    if (!cmd) return;
    cmd->stencil.which = which;
    cmd->stencil.faces = faces;
    cmd->stencil.value = value;
}

VKAPI_ATTR void VKAPI_CALL vkCmdSetStencilCompareMask(VkCommandBuffer commandBuffer, VkStencilFaceFlags faceMask, uint32_t compareMask) {
    set_stencil(commandBuffer, VKW_STENCIL_COMPARE_MASK, faceMask, compareMask);
}

VKAPI_ATTR void VKAPI_CALL vkCmdSetStencilWriteMask(VkCommandBuffer commandBuffer, VkStencilFaceFlags faceMask, uint32_t writeMask) {
    set_stencil(commandBuffer, VKW_STENCIL_WRITE_MASK, faceMask, writeMask);
}

VKAPI_ATTR void VKAPI_CALL vkCmdSetStencilReference(VkCommandBuffer commandBuffer, VkStencilFaceFlags faceMask, uint32_t reference) {
    set_stencil(commandBuffer, VKW_STENCIL_REFERENCE, faceMask, reference);
}

VKAPI_ATTR void VKAPI_CALL vkCmdSetBlendConstants(VkCommandBuffer commandBuffer, const float blendConstants[4]) {
    vkw_cmd_t *cmd = append(commandBuffer, VKW_CMD_SET_BLEND_CONSTANTS);
    if (cmd) memcpy(cmd->blendConstants, blendConstants, sizeof cmd->blendConstants);
}

// MARK: - Vertex input

VKAPI_ATTR void VKAPI_CALL vkCmdBindVertexBuffers(
    VkCommandBuffer commandBuffer, uint32_t firstBinding, uint32_t bindingCount, const VkBuffer *pBuffers,
    const VkDeviceSize *pOffsets) {
    if (firstBinding + bindingCount > NWG_MAX_VERTEX_BINDINGS) {
        vkw_logf("vkCmdBindVertexBuffers: bindings beyond %u are not available on WebGPU; ignored", NWG_MAX_VERTEX_BINDINGS);
        return;
    }
    vkw_cmd_t *cmd = append(commandBuffer, VKW_CMD_BIND_VERTEX_BUFFERS);
    if (!cmd) return;
    cmd->vertexBuffers.first = firstBinding;
    cmd->vertexBuffers.count = bindingCount;
    for (uint32_t i = 0; i < bindingCount; i++) {
        cmd->vertexBuffers.buffers[i] = pBuffers[i];
        cmd->vertexBuffers.offsets[i] = pOffsets[i];
    }
}

VKAPI_ATTR void VKAPI_CALL vkCmdBindIndexBuffer(VkCommandBuffer commandBuffer, VkBuffer buffer, VkDeviceSize offset, VkIndexType indexType) {
    if (indexType != VK_INDEX_TYPE_UINT16 && indexType != VK_INDEX_TYPE_UINT32) {
        vkw_logf("vkCmdBindIndexBuffer: index type %d has no WebGPU equivalent; ignored", (int)indexType);
        return;
    }
    vkw_cmd_t *cmd = append(commandBuffer, VKW_CMD_BIND_INDEX_BUFFER);
    if (!cmd) return;
    cmd->indexBuffer.buffer = buffer;
    cmd->indexBuffer.offset = offset;
    cmd->indexBuffer.type = indexType;
}

// MARK: - Draw / dispatch

VKAPI_ATTR void VKAPI_CALL vkCmdDraw(
    VkCommandBuffer commandBuffer, uint32_t vertexCount, uint32_t instanceCount, uint32_t firstVertex, uint32_t firstInstance) {
    vkw_cmd_t *cmd = append(commandBuffer, VKW_CMD_DRAW);
    if (!cmd) return;
    cmd->draw.vertexCount = vertexCount;
    cmd->draw.instanceCount = instanceCount;
    cmd->draw.firstVertex = firstVertex;
    cmd->draw.firstInstance = firstInstance;
}

VKAPI_ATTR void VKAPI_CALL vkCmdDrawIndexed(
    VkCommandBuffer commandBuffer, uint32_t indexCount, uint32_t instanceCount, uint32_t firstIndex, int32_t vertexOffset,
    uint32_t firstInstance) {
    vkw_cmd_t *cmd = append(commandBuffer, VKW_CMD_DRAW_INDEXED);
    if (!cmd) return;
    cmd->drawIndexed.indexCount = indexCount;
    cmd->drawIndexed.instanceCount = instanceCount;
    cmd->drawIndexed.firstIndex = firstIndex;
    cmd->drawIndexed.vertexOffset = vertexOffset;
    cmd->drawIndexed.firstInstance = firstInstance;
}

VKAPI_ATTR void VKAPI_CALL vkCmdDrawIndirect(
    VkCommandBuffer commandBuffer, VkBuffer buffer, VkDeviceSize offset, uint32_t drawCount, uint32_t stride) {
    // WebGPU's drawIndirect reads one command; Vulkan's reads drawCount of
    // them `stride` apart — the same draws one after another.
    for (uint32_t i = 0; i < drawCount; i++) {
        vkw_cmd_t *cmd = append(commandBuffer, VKW_CMD_DRAW_INDIRECT);
        if (!cmd) return;
        cmd->drawIndirect.buffer = buffer;
        cmd->drawIndirect.offset = offset + (uint64_t)i * stride;
    }
}

VKAPI_ATTR void VKAPI_CALL vkCmdDispatch(VkCommandBuffer commandBuffer, uint32_t groupCountX, uint32_t groupCountY, uint32_t groupCountZ) {
    vkw_cmd_t *cmd = append(commandBuffer, VKW_CMD_DISPATCH);
    if (!cmd) return;
    cmd->dispatch.x = groupCountX;
    cmd->dispatch.y = groupCountY;
    cmd->dispatch.z = groupCountZ;
}

// MARK: - Transfers

VKAPI_ATTR void VKAPI_CALL vkCmdCopyBufferToImage(
    VkCommandBuffer commandBuffer, VkBuffer srcBuffer, VkImage dstImage, VkImageLayout dstImageLayout,
    uint32_t regionCount, const VkBufferImageCopy *pRegions) {
    (void)dstImageLayout;
    for (uint32_t i = 0; i < regionCount; i++) {
        vkw_cmd_t *cmd = append(commandBuffer, VKW_CMD_COPY_BUFFER_TO_IMAGE);
        if (!cmd) return;
        cmd->bufferImage.buffer = srcBuffer;
        cmd->bufferImage.image = dstImage;
        cmd->bufferImage.region = pRegions[i];
    }
}

VKAPI_ATTR void VKAPI_CALL vkCmdCopyImageToBuffer(
    VkCommandBuffer commandBuffer, VkImage srcImage, VkImageLayout srcImageLayout, VkBuffer dstBuffer,
    uint32_t regionCount, const VkBufferImageCopy *pRegions) {
    (void)srcImageLayout;
    // Memory the GPU writes into is read back rather than flushed from the
    // host side again (see vkw_flush_mapped).
    if (dstBuffer->memory) dstBuffer->memory->gpuWritten = 1;
    for (uint32_t i = 0; i < regionCount; i++) {
        vkw_cmd_t *cmd = append(commandBuffer, VKW_CMD_COPY_IMAGE_TO_BUFFER);
        if (!cmd) return;
        cmd->bufferImage.buffer = dstBuffer;
        cmd->bufferImage.image = srcImage;
        cmd->bufferImage.region = pRegions[i];
    }
}

VKAPI_ATTR void VKAPI_CALL vkCmdCopyImage(
    VkCommandBuffer commandBuffer, VkImage srcImage, VkImageLayout srcImageLayout, VkImage dstImage,
    VkImageLayout dstImageLayout, uint32_t regionCount, const VkImageCopy *pRegions) {
    (void)srcImageLayout;
    (void)dstImageLayout;
    for (uint32_t i = 0; i < regionCount; i++) {
        vkw_cmd_t *cmd = append(commandBuffer, VKW_CMD_COPY_IMAGE);
        if (!cmd) return;
        cmd->copyImage.src = srcImage;
        cmd->copyImage.dst = dstImage;
        cmd->copyImage.region = pRegions[i];
    }
}

VKAPI_ATTR void VKAPI_CALL vkCmdBlitImage(
    VkCommandBuffer commandBuffer, VkImage srcImage, VkImageLayout srcImageLayout, VkImage dstImage,
    VkImageLayout dstImageLayout, uint32_t regionCount, const VkImageBlit *pRegions, VkFilter filter) {
    (void)srcImageLayout;
    (void)dstImageLayout;
    for (uint32_t i = 0; i < regionCount; i++) {
        vkw_cmd_t *cmd = append(commandBuffer, VKW_CMD_BLIT_IMAGE);
        if (!cmd) return;
        cmd->blit.src = srcImage;
        cmd->blit.dst = dstImage;
        cmd->blit.region = pRegions[i];
        cmd->blit.filter = filter;
    }
}

VKAPI_ATTR void VKAPI_CALL vkCmdClearColorImage(
    VkCommandBuffer commandBuffer, VkImage image, VkImageLayout imageLayout, const VkClearColorValue *pColor,
    uint32_t rangeCount, const VkImageSubresourceRange *pRanges) {
    (void)imageLayout;
    for (uint32_t i = 0; i < rangeCount; i++) {
        vkw_cmd_t *cmd = append(commandBuffer, VKW_CMD_CLEAR_COLOR_IMAGE);
        if (!cmd) return;
        cmd->clear.image = image;
        cmd->clear.color = *pColor;
        cmd->clear.range = pRanges[i];
    }
}

VKAPI_ATTR void VKAPI_CALL vkCmdClearAttachments(
    VkCommandBuffer commandBuffer, uint32_t attachmentCount, const VkClearAttachment *pAttachments, uint32_t rectCount,
    const VkClearRect *pRects) {
    if (attachmentCount > VKW_MAX_COLOR_ATTACHMENTS + 1) attachmentCount = VKW_MAX_COLOR_ATTACHMENTS + 1;
    // One command per rect: WebGPU clears them one at a time anyway.
    for (uint32_t r = 0; r < rectCount; r++) {
        vkw_cmd_t *cmd = append(commandBuffer, VKW_CMD_CLEAR_ATTACHMENTS);
        if (!cmd) return;
        cmd->clearAttachments.count = attachmentCount;
        for (uint32_t i = 0; i < attachmentCount; i++) cmd->clearAttachments.attachments[i] = pAttachments[i];
        cmd->clearAttachments.rect = pRects[r];
    }
}

#endif /* __wasm__ */
