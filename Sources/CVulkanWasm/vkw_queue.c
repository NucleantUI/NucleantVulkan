// vkQueueSubmit, fences, semaphores and the wait calls.
//
// A submit walks its command buffers' recorded commands and writes them out
// as the bridge's command stream, keeping Vulkan's command-buffer state
// (bound pipeline, sets, viewport, scissor, push constants) the way Vulkan
// does — across render passes, reset at each command buffer. Where WebGPU
// needs something Vulkan lets the app leave out, it is made here:
//
// * Viewports. Vulkan allows a viewport larger than, or off the edge of,
//   the framebuffer; WebGPU requires it inside. The viewport is clamped to
//   the framebuffer and the vertex stage remaps clip space by a per-draw
//   (scale, offset) so every vertex lands where the unclamped viewport put
//   it — draws partly off-screen render the visible part, exactly as on
//   Vulkan.
// * Push constants. Each draw/dispatch that sees new push constants (or a
//   new viewport) gets a slot in the submit's arena; the bridge binds it with
//   a dynamic offset.
// * Copy row pitch. WebGPU wants bytesPerRow in multiples of 256 for
//   buffer<->texture copies. Uploads from host-visible memory are repacked
//   here into the arena; anything else the bridge repacks on the GPU.
// * Readback. A copy into host-visible memory brings the bytes back into the
//   memory's shadow once the submit has finished, which is when Vulkan says
//   the host may read them.

#if defined(__wasm__)

#include "vkw_internal.h"

// MARK: - Stream building

typedef struct {
    uint32_t *words;
    uint32_t  count, capacity;
    uint8_t  *arena;
    uint32_t  arenaSize, arenaCapacity;
    int       failed;
} stream_t;

static void emit(stream_t *s, uint32_t word) {
    if (s->count == s->capacity) {
        uint32_t capacity = s->capacity ? s->capacity * 2 : 1024;
        uint32_t *grown = realloc(s->words, capacity * sizeof *grown);
        if (!grown) {
            s->failed = 1;
            return;
        }
        s->words = grown;
        s->capacity = capacity;
    }
    s->words[s->count++] = word;
}

static void emit_f(stream_t *s, float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof bits);
    emit(s, bits);
}

/// Offset of `size` fresh, zeroed bytes in the arena, 256-aligned.
static uint32_t arena_alloc(stream_t *s, uint32_t size) {
    uint32_t offset = (s->arenaSize + 255u) & ~255u;
    uint32_t end = offset + size;
    if (end > s->arenaCapacity) {
        uint32_t capacity = s->arenaCapacity ? s->arenaCapacity : 64 * 1024;
        while (capacity < end) capacity *= 2;
        uint8_t *grown = realloc(s->arena, capacity);
        if (!grown) {
            s->failed = 1;
            return 0;
        }
        s->arena = grown;
        s->arenaCapacity = capacity;
    }
    memset(s->arena + s->arenaSize, 0, end - s->arenaSize);
    s->arenaSize = end;
    return offset;
}

// MARK: - Command buffer state

typedef struct {
    int           inRender, inCompute;
    uint32_t      targetWidth, targetHeight;
    VkPipeline    pipeline[2];
    VkViewport    viewport;
    int           hasViewport;
    VkRect2D      scissor;
    int           hasScissor;
    int           viewportDirty, scissorDirty;
    uint8_t       push[NWG_MAX_PUSH_CONSTANTS];
    int           drawDataDirty[2];
    // The clamped viewport and the remap that undoes the clamp.
    float         clamped[4];
    float         remap[4];
    int           viewportEmpty;
} cb_state_t;

typedef struct {
    uint32_t buffer, offset, size, memory;
    uint8_t *host;
} readback_t;

typedef struct {
    readback_t *items;
    uint32_t    count, capacity;
} readbacks_t;

static void add_readback(readbacks_t *list, readback_t item) {
    if (list->count == list->capacity) {
        uint32_t capacity = list->capacity ? list->capacity * 2 : 8;
        readback_t *grown = realloc(list->items, capacity * sizeof *grown);
        if (!grown) return;
        list->items = grown;
        list->capacity = capacity;
    }
    list->items[list->count++] = item;
}

static void end_compute(stream_t *s, cb_state_t *st) {
    if (!st->inCompute) return;
    emit(s, NWG_OP_END_COMPUTE_PASS);
    st->inCompute = 0;
}

/// Recomputes the clamped viewport and the clip-space remap that keeps
/// vertices where the unclamped Vulkan viewport would map them. With the
/// clamped rect (cx, cy, cw, ch) and the Vulkan one (x, y, w, h):
///   x' = x * w/cw + ((2(x - cx) + w)/cw - 1)
///   y' = y * h/ch + (1 - (2(y - cy) + h)/ch)
/// in WebGPU clip space (y up — the translation already flipped y). Signed
/// h, so a negative-height (flipped) Vulkan viewport works the same way.
static void resolve_viewport(cb_state_t *st) {
    float x = 0, y = 0, w = (float)st->targetWidth, h = (float)st->targetHeight;
    float minDepth = 0, maxDepth = 1;
    if (st->hasViewport) {
        x = st->viewport.x;
        y = st->viewport.y;
        w = st->viewport.width;
        h = st->viewport.height;
        minDepth = st->viewport.minDepth;
        maxDepth = st->viewport.maxDepth;
    }
    float top = h >= 0 ? y : y + h;
    float bottom = h >= 0 ? y + h : y;
    float cx0 = x > 0 ? x : 0;
    float cy0 = top > 0 ? top : 0;
    float cx1 = x + w < (float)st->targetWidth ? x + w : (float)st->targetWidth;
    float cy1 = bottom < (float)st->targetHeight ? bottom : (float)st->targetHeight;
    float cw = cx1 - cx0, ch = cy1 - cy0;
    st->viewportEmpty = !(cw > 0 && ch > 0 && w != 0);
    if (st->viewportEmpty) return;
    st->clamped[0] = cx0;
    st->clamped[1] = cy0;
    st->clamped[2] = cw;
    st->clamped[3] = ch;
    st->remap[0] = w / cw;
    st->remap[1] = h / ch;
    st->remap[2] = (2.0f * (x - cx0) + w) / cw - 1.0f;
    st->remap[3] = 1.0f - (2.0f * (y - cy0) + h) / ch;
    if (minDepth < 0) minDepth = 0;
    if (maxDepth > 1) maxDepth = 1;
    st->viewport.minDepth = minDepth;
    st->viewport.maxDepth = maxDepth;
}

static void flush_viewport(stream_t *s, cb_state_t *st) {
    if (!st->viewportDirty) return;
    resolve_viewport(st);
    if (!st->viewportEmpty) {
        emit(s, NWG_OP_SET_VIEWPORT);
        emit_f(s, st->clamped[0]);
        emit_f(s, st->clamped[1]);
        emit_f(s, st->clamped[2]);
        emit_f(s, st->clamped[3]);
        emit_f(s, st->hasViewport ? st->viewport.minDepth : 0.0f);
        emit_f(s, st->hasViewport ? st->viewport.maxDepth : 1.0f);
    }
    st->viewportDirty = 0;
    st->drawDataDirty[NWG_BIND_GRAPHICS] = 1;
}

/// The scissor clamped into the render target; returns 0 when empty.
static int flush_scissor(stream_t *s, cb_state_t *st) {
    int64_t x0 = 0, y0 = 0, x1 = st->targetWidth, y1 = st->targetHeight;
    if (st->hasScissor) {
        x0 = st->scissor.offset.x;
        y0 = st->scissor.offset.y;
        x1 = x0 + st->scissor.extent.width;
        y1 = y0 + st->scissor.extent.height;
    }
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > st->targetWidth) x1 = st->targetWidth;
    if (y1 > st->targetHeight) y1 = st->targetHeight;
    if (x1 <= x0 || y1 <= y0) return 0;
    if (st->scissorDirty) {
        emit(s, NWG_OP_SET_SCISSOR);
        emit(s, (uint32_t)x0);
        emit(s, (uint32_t)y0);
        emit(s, (uint32_t)(x1 - x0));
        emit(s, (uint32_t)(y1 - y0));
        st->scissorDirty = 0;
    }
    return 1;
}

static void flush_draw_data(stream_t *s, cb_state_t *st, uint32_t bindPoint) {
    if (!st->drawDataDirty[bindPoint]) return;
    uint32_t slot = arena_alloc(s, NWG_DRAW_DATA_SLOT);
    if (s->failed) return;
    float remap[4] = { 1, 1, 0, 0 };
    if (bindPoint == NWG_BIND_GRAPHICS && !st->viewportEmpty) memcpy(remap, st->remap, sizeof remap);
    memcpy(s->arena + slot, remap, sizeof remap);
    memcpy(s->arena + slot + NWG_PUSH_CONSTANT_OFFSET, st->push, NWG_MAX_PUSH_CONSTANTS);
    emit(s, NWG_OP_DRAW_DATA);
    emit(s, bindPoint);
    emit(s, slot);
    st->drawDataDirty[bindPoint] = 0;
}

static void emit_set(stream_t *s, uint32_t bindPoint, uint32_t index, VkDescriptorSet set) {
    emit(s, NWG_OP_BIND_SET);
    emit(s, bindPoint);
    emit(s, index);
    emit(s, set ? set->id : 0);
    emit(s, set ? set->version : 0);
    uint32_t count = 0;
    if (set) {
        for (uint32_t i = 0; i < set->count; i++) count += set->descriptors[i].type != 0;
    }
    emit(s, count);
    if (!set) return;
    for (uint32_t i = 0; i < set->count; i++) {
        const vkw_descriptor_t *d = &set->descriptors[i];
        if (!d->type) continue;
        emit(s, d->binding);
        emit(s, d->type);
        emit(s, d->a);
        emit(s, d->b);
        emit(s, d->c);
    }
}

static void begin_render_pass(stream_t *s, cb_state_t *st, const vkw_cmd_t *cmd) {
    end_compute(s, st);
    VkRenderPass pass = cmd->beginRenderPass.renderPass;
    VkFramebuffer framebuffer = cmd->beginRenderPass.framebuffer;
    emit(s, NWG_OP_BEGIN_RENDER_PASS);
    emit(s, pass->colorCount);
    for (uint32_t i = 0; i < pass->colorCount; i++) {
        uint32_t ref = pass->colorRefs[i];
        if (ref == VK_ATTACHMENT_UNUSED || ref >= framebuffer->attachmentCount) {
            for (int k = 0; k < 7; k++) emit(s, 0);
            continue;
        }
        const vkw_attachment_t *att = &pass->attachments[ref];
        VkClearColorValue clear = { .float32 = { 0, 0, 0, 0 } };
        if (ref < cmd->beginRenderPass.clearCount) clear = cmd->beginRenderPass.clears[ref].color;
        emit(s, framebuffer->attachments[ref]->gpu);
        // LOAD keeps the contents; CLEAR and DONT_CARE both clear (WebGPU
        // has no "undefined" load, and clearing is the cheap choice).
        emit(s, att->loadOp == VK_ATTACHMENT_LOAD_OP_LOAD ? 0u : 1u);
        emit(s, att->storeOp == VK_ATTACHMENT_STORE_OP_STORE ? 0u : 1u);
        emit_f(s, clear.float32[0]);
        emit_f(s, clear.float32[1]);
        emit_f(s, clear.float32[2]);
        emit_f(s, clear.float32[3]);
    }
    st->inRender = 1;
    st->targetWidth = framebuffer->width;
    st->targetHeight = framebuffer->height;
    // A new WebGPU pass starts from default state; Vulkan's carries on.
    st->viewportDirty = 1;
    st->scissorDirty = 1;
    st->drawDataDirty[NWG_BIND_GRAPHICS] = 1;
}

static int begin_draw(stream_t *s, cb_state_t *st) {
    if (!st->inRender) return 0;
    flush_viewport(s, st);
    if (st->viewportEmpty) return 0;  // the viewport lies wholly off the target
    if (!flush_scissor(s, st)) return 0;
    flush_draw_data(s, st, NWG_BIND_GRAPHICS);
    return 1;
}

static void begin_dispatch(stream_t *s, cb_state_t *st) {
    if (!st->inCompute) {
        emit(s, NWG_OP_BEGIN_COMPUTE_PASS);
        st->inCompute = 1;
        st->drawDataDirty[NWG_BIND_COMPUTE] = 1;
    }
    flush_draw_data(s, st, NWG_BIND_COMPUTE);
}

// MARK: - Transfers

static void copy_buffer_to_image(stream_t *s, const vkw_cmd_t *cmd) {
    VkBuffer buffer = cmd->bufferImage.buffer;
    VkImage image = cmd->bufferImage.image;
    const VkBufferImageCopy *r = &cmd->bufferImage.region;
    if (!image->gpu) {
        vkw_logf("vkCmdCopyBufferToImage: copying into a swapchain image is not implemented on WebGPU");
        return;
    }
    uint32_t texel = vkw_format_bytes(image->format);
    uint32_t rowLength = r->bufferRowLength ? r->bufferRowLength : r->imageExtent.width;
    uint32_t imageHeight = r->bufferImageHeight ? r->bufferImageHeight : r->imageExtent.height;
    uint32_t layers = image->type == VK_IMAGE_TYPE_3D ? r->imageExtent.depth : r->imageSubresource.layerCount;
    uint32_t z = image->type == VK_IMAGE_TYPE_3D ? (uint32_t)r->imageOffset.z : r->imageSubresource.baseArrayLayer;
    uint32_t bytesPerRow = rowLength * texel;
    uint32_t rowBytes = r->imageExtent.width * texel;

    uint32_t source = buffer->gpu;
    uint32_t offset = (uint32_t)r->bufferOffset;
    uint32_t pitch = bytesPerRow;
    uint32_t rowsPerImage = imageHeight;
    VkDeviceMemory memory = buffer->memory;
    if (bytesPerRow % NWG_COPY_ROW_ALIGNMENT != 0 && memory && memory->shadow && !memory->gpuWritten) {
        // The bytes the copy reads are the host's own, in the shadow: lay
        // them out at a 256-byte pitch in the arena and copy from there.
        pitch = (rowBytes + NWG_COPY_ROW_ALIGNMENT - 1) & ~(NWG_COPY_ROW_ALIGNMENT - 1);
        rowsPerImage = r->imageExtent.height;
        uint32_t slot = arena_alloc(s, pitch * rowsPerImage * layers);
        if (s->failed) return;
        const uint8_t *from = memory->shadow + buffer->memoryOffset + r->bufferOffset;
        for (uint32_t layer = 0; layer < layers; layer++) {
            for (uint32_t row = 0; row < r->imageExtent.height; row++) {
                memcpy(s->arena + slot + (layer * rowsPerImage + row) * pitch,
                       from + ((uint64_t)layer * imageHeight + row) * bytesPerRow, rowBytes);
            }
        }
        source = 0;
        offset = slot;
    }
    emit(s, NWG_OP_COPY_BUFFER_TO_TEXTURE);
    emit(s, source);
    emit(s, offset);
    emit(s, pitch);
    emit(s, rowsPerImage);
    emit(s, image->gpu);
    emit(s, r->imageSubresource.mipLevel);
    emit(s, (uint32_t)r->imageOffset.x);
    emit(s, (uint32_t)r->imageOffset.y);
    emit(s, z);
    emit(s, r->imageExtent.width);
    emit(s, r->imageExtent.height);
    emit(s, layers);
}

static void copy_image_to_buffer(stream_t *s, const vkw_cmd_t *cmd, readbacks_t *readbacks) {
    VkBuffer buffer = cmd->bufferImage.buffer;
    VkImage image = cmd->bufferImage.image;
    const VkBufferImageCopy *r = &cmd->bufferImage.region;
    if (!image->gpu) {
        vkw_logf("vkCmdCopyImageToBuffer: reading a swapchain image is not implemented on WebGPU");
        return;
    }
    uint32_t texel = vkw_format_bytes(image->format);
    uint32_t rowLength = r->bufferRowLength ? r->bufferRowLength : r->imageExtent.width;
    uint32_t imageHeight = r->bufferImageHeight ? r->bufferImageHeight : r->imageExtent.height;
    uint32_t layers = image->type == VK_IMAGE_TYPE_3D ? r->imageExtent.depth : r->imageSubresource.layerCount;
    uint32_t z = image->type == VK_IMAGE_TYPE_3D ? (uint32_t)r->imageOffset.z : r->imageSubresource.baseArrayLayer;
    uint32_t bytesPerRow = rowLength * texel;
    emit(s, NWG_OP_COPY_TEXTURE_TO_BUFFER);
    emit(s, image->gpu);
    emit(s, r->imageSubresource.mipLevel);
    emit(s, (uint32_t)r->imageOffset.x);
    emit(s, (uint32_t)r->imageOffset.y);
    emit(s, z);
    emit(s, r->imageExtent.width);
    emit(s, r->imageExtent.height);
    emit(s, layers);
    emit(s, buffer->gpu);
    emit(s, (uint32_t)r->bufferOffset);
    emit(s, bytesPerRow);
    emit(s, imageHeight);

    VkDeviceMemory memory = buffer->memory;
    if (memory && memory->shadow) {
        uint64_t size = (uint64_t)bytesPerRow * imageHeight * (layers - 1) +
                        (uint64_t)bytesPerRow * (r->imageExtent.height - 1) + (uint64_t)r->imageExtent.width * texel;
        add_readback(readbacks, (readback_t){
            .buffer = buffer->gpu,
            .offset = (uint32_t)r->bufferOffset,
            .size = (uint32_t)size,
            .memory = memory->id,
            .host = memory->shadow + buffer->memoryOffset + r->bufferOffset,
        });
    }
}

static void copy_image(stream_t *s, const vkw_cmd_t *cmd) {
    VkImage src = cmd->copyImage.src, dst = cmd->copyImage.dst;
    const VkImageCopy *r = &cmd->copyImage.region;
    if (!src->gpu || !dst->gpu) {
        vkw_logf("vkCmdCopyImage: swapchain images are not copyable on WebGPU yet");
        return;
    }
    int src3D = src->type == VK_IMAGE_TYPE_3D, dst3D = dst->type == VK_IMAGE_TYPE_3D;
    emit(s, NWG_OP_COPY_TEXTURE_TO_TEXTURE);
    emit(s, src->gpu);
    emit(s, r->srcSubresource.mipLevel);
    emit(s, (uint32_t)r->srcOffset.x);
    emit(s, (uint32_t)r->srcOffset.y);
    emit(s, src3D ? (uint32_t)r->srcOffset.z : r->srcSubresource.baseArrayLayer);
    emit(s, dst->gpu);
    emit(s, r->dstSubresource.mipLevel);
    emit(s, (uint32_t)r->dstOffset.x);
    emit(s, (uint32_t)r->dstOffset.y);
    emit(s, dst3D ? (uint32_t)r->dstOffset.z : r->dstSubresource.baseArrayLayer);
    emit(s, r->extent.width);
    emit(s, r->extent.height);
    emit(s, src3D ? r->extent.depth : r->srcSubresource.layerCount);
}

static void blit_image(stream_t *s, const vkw_cmd_t *cmd) {
    VkImage src = cmd->blit.src, dst = cmd->blit.dst;
    const VkImageBlit *r = &cmd->blit.region;
    if (!src->gpu || !dst->gpu) {
        vkw_logf("vkCmdBlitImage: swapchain images are not blittable on WebGPU yet");
        return;
    }
    uint32_t layers = r->srcSubresource.layerCount;
    for (uint32_t layer = 0; layer < layers; layer++) {
        emit(s, NWG_OP_BLIT_TEXTURE);
        emit(s, src->gpu);
        emit(s, r->srcSubresource.mipLevel);
        emit(s, r->srcSubresource.baseArrayLayer + layer);
        emit(s, (uint32_t)r->srcOffsets[0].x);
        emit(s, (uint32_t)r->srcOffsets[0].y);
        emit(s, (uint32_t)r->srcOffsets[1].x);
        emit(s, (uint32_t)r->srcOffsets[1].y);
        emit(s, dst->gpu);
        emit(s, r->dstSubresource.mipLevel);
        emit(s, r->dstSubresource.baseArrayLayer + layer);
        emit(s, (uint32_t)r->dstOffsets[0].x);
        emit(s, (uint32_t)r->dstOffsets[0].y);
        emit(s, (uint32_t)r->dstOffsets[1].x);
        emit(s, (uint32_t)r->dstOffsets[1].y);
        emit(s, cmd->blit.filter == VK_FILTER_LINEAR ? 1u : 0u);
    }
}

static void clear_image(stream_t *s, const vkw_cmd_t *cmd) {
    VkImage image = cmd->clear.image;
    const VkImageSubresourceRange *range = &cmd->clear.range;
    if (!image->gpu) return;
    uint32_t mips = range->levelCount == VK_REMAINING_MIP_LEVELS ? image->mipLevels - range->baseMipLevel : range->levelCount;
    uint32_t layers = range->layerCount == VK_REMAINING_ARRAY_LAYERS ? image->arrayLayers - range->baseArrayLayer : range->layerCount;
    if (image->type == VK_IMAGE_TYPE_3D) layers = 1;
    for (uint32_t mip = 0; mip < mips; mip++) {
        for (uint32_t layer = 0; layer < layers; layer++) {
            emit(s, NWG_OP_CLEAR_TEXTURE);
            emit(s, image->gpu);
            emit(s, range->baseMipLevel + mip);
            emit(s, range->baseArrayLayer + layer);
            emit_f(s, cmd->clear.color.float32[0]);
            emit_f(s, cmd->clear.color.float32[1]);
            emit_f(s, cmd->clear.color.float32[2]);
            emit_f(s, cmd->clear.color.float32[3]);
        }
    }
}

// MARK: - One command buffer

static void encode_command_buffer(stream_t *s, VkCommandBuffer cb, readbacks_t *readbacks) {
    cb_state_t st;
    memset(&st, 0, sizeof st);
    for (uint32_t i = 0; i < cb->count && !s->failed; i++) {
        const vkw_cmd_t *cmd = &cb->commands[i];
        switch (cmd->type) {
        case VKW_CMD_BEGIN_RENDER_PASS:
            begin_render_pass(s, &st, cmd);
            break;
        case VKW_CMD_END_RENDER_PASS:
            if (st.inRender) emit(s, NWG_OP_END_RENDER_PASS);
            st.inRender = 0;
            break;
        case VKW_CMD_BIND_PIPELINE: {
            uint32_t point = cmd->bindPipeline.bindPoint;
            VkPipeline pipeline = cmd->bindPipeline.pipeline;
            st.pipeline[point] = pipeline;
            emit(s, NWG_OP_SET_PIPELINE);
            emit(s, point);
            emit(s, pipeline ? pipeline->gpu : 0);
            if (point == NWG_BIND_GRAPHICS && pipeline) {
                // Baked-in (non-dynamic) viewport/scissor apply on bind.
                if (!pipeline->dynamicViewport) {
                    st.viewport = pipeline->viewport;
                    st.hasViewport = 1;
                    st.viewportDirty = 1;
                }
                if (!pipeline->dynamicScissor) {
                    st.scissor = pipeline->scissor;
                    st.hasScissor = 1;
                    st.scissorDirty = 1;
                }
            }
            break;
        }
        case VKW_CMD_BIND_SETS:
            for (uint32_t k = 0; k < cmd->bindSets.count; k++) {
                emit_set(s, cmd->bindSets.bindPoint, cmd->bindSets.firstSet + k, cmd->bindSets.sets[k]);
            }
            break;
        case VKW_CMD_PUSH_CONSTANTS:
            memcpy(st.push + cmd->pushConstants.offset, cmd->pushConstants.bytes, cmd->pushConstants.size);
            st.drawDataDirty[NWG_BIND_GRAPHICS] = 1;
            st.drawDataDirty[NWG_BIND_COMPUTE] = 1;
            break;
        case VKW_CMD_SET_VIEWPORT:
            st.viewport = cmd->viewport;
            st.hasViewport = 1;
            st.viewportDirty = 1;
            break;
        case VKW_CMD_SET_SCISSOR:
            st.scissor = cmd->scissor;
            st.hasScissor = 1;
            st.scissorDirty = 1;
            break;
        case VKW_CMD_DRAW:
            if (!begin_draw(s, &st)) break;
            emit(s, NWG_OP_DRAW);
            emit(s, cmd->draw.vertexCount);
            emit(s, cmd->draw.instanceCount);
            emit(s, cmd->draw.firstVertex);
            emit(s, cmd->draw.firstInstance);
            break;
        case VKW_CMD_DRAW_INDIRECT:
            if (!begin_draw(s, &st)) break;
            emit(s, NWG_OP_DRAW_INDIRECT);
            emit(s, cmd->drawIndirect.buffer->gpu);
            emit(s, (uint32_t)cmd->drawIndirect.offset);
            break;
        case VKW_CMD_DISPATCH:
            if (st.inRender) break;
            begin_dispatch(s, &st);
            emit(s, NWG_OP_DISPATCH);
            emit(s, cmd->dispatch.x);
            emit(s, cmd->dispatch.y);
            emit(s, cmd->dispatch.z);
            break;
        case VKW_CMD_COPY_BUFFER_TO_IMAGE:
            end_compute(s, &st);
            copy_buffer_to_image(s, cmd);
            break;
        case VKW_CMD_COPY_IMAGE_TO_BUFFER:
            end_compute(s, &st);
            copy_image_to_buffer(s, cmd, readbacks);
            break;
        case VKW_CMD_COPY_IMAGE:
            end_compute(s, &st);
            copy_image(s, cmd);
            break;
        case VKW_CMD_BLIT_IMAGE:
            end_compute(s, &st);
            blit_image(s, cmd);
            break;
        case VKW_CMD_CLEAR_COLOR_IMAGE:
            end_compute(s, &st);
            clear_image(s, cmd);
            break;
        }
    }
    end_compute(s, &st);
    if (st.inRender) emit(s, NWG_OP_END_RENDER_PASS);
}

// MARK: - Submit

static stream_t gStream;

VKAPI_ATTR VkResult VKAPI_CALL vkQueueSubmit(VkQueue queue, uint32_t submitCount, const VkSubmitInfo *pSubmits, VkFence fence) {
    stream_t *s = &gStream;
    s->count = 0;
    s->arenaSize = 0;
    s->failed = 0;
    readbacks_t readbacks = { 0 };

    for (uint32_t i = 0; i < submitCount; i++) {
        for (uint32_t c = 0; c < pSubmits[i].commandBufferCount; c++) {
            encode_command_buffer(s, pSubmits[i].pCommandBuffers[c], &readbacks);
        }
    }
    for (uint32_t i = 0; i < readbacks.count; i++) {
        const readback_t *r = &readbacks.items[i];
        emit(s, NWG_OP_READBACK);
        emit(s, r->buffer);
        emit(s, r->offset);
        emit(s, r->size);
        emit(s, r->memory);
        emit(s, (uint32_t)(uintptr_t)r->host);
    }
    free(readbacks.items);
    if (s->failed) return VK_ERROR_OUT_OF_HOST_MEMORY;

    // Coherent memory: whatever the host wrote into still-mapped memory is
    // visible to this submit, as on a Vulkan driver.
    vkw_flush_mapped(queue->device);
    uint32_t serial = nwg_queue_submit(s->words, s->count, s->arena, s->arenaSize);
    queue->lastSerial = serial;
    if (fence) fence->serial = serial;
    return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL vkQueueWaitIdle(VkQueue queue) {
    if (queue->lastSerial > nwg_queue_completed_serial()) nwg_queue_wait_serial(queue->lastSerial);
    return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL vkDeviceWaitIdle(VkDevice device) {
    return vkQueueWaitIdle(&device->queue);
}

// MARK: - Fences

#define FENCE_UNSIGNALLED UINT32_MAX

VKAPI_ATTR VkResult VKAPI_CALL vkCreateFence(
    VkDevice device, const VkFenceCreateInfo *pCreateInfo, const VkAllocationCallbacks *pAllocator, VkFence *pFence) {
    (void)device;
    (void)pAllocator;
    VkFence fence = calloc(1, sizeof *fence);
    if (!fence) return VK_ERROR_OUT_OF_HOST_MEMORY;
    fence->serial = (pCreateInfo->flags & VK_FENCE_CREATE_SIGNALED_BIT) ? 0 : FENCE_UNSIGNALLED;
    *pFence = fence;
    return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL vkDestroyFence(VkDevice device, VkFence fence, const VkAllocationCallbacks *pAllocator) {
    (void)device;
    (void)pAllocator;
    free(fence);
}

VKAPI_ATTR VkResult VKAPI_CALL vkResetFences(VkDevice device, uint32_t fenceCount, const VkFence *pFences) {
    (void)device;
    for (uint32_t i = 0; i < fenceCount; i++) pFences[i]->serial = FENCE_UNSIGNALLED;
    return VK_SUCCESS;
}

static int fence_signalled(VkFence fence, uint32_t completed) {
    return fence->serial != FENCE_UNSIGNALLED && fence->serial <= completed;
}

VKAPI_ATTR VkResult VKAPI_CALL vkGetFenceStatus(VkDevice device, VkFence fence) {
    (void)device;
    return fence_signalled(fence, nwg_queue_completed_serial()) ? VK_SUCCESS : VK_NOT_READY;
}

VKAPI_ATTR VkResult VKAPI_CALL vkWaitForFences(
    VkDevice device, uint32_t fenceCount, const VkFence *pFences, VkBool32 waitAll, uint64_t timeout) {
    (void)device;
    uint32_t completed = nwg_queue_completed_serial();
    uint32_t target = 0;
    int any = 0;
    for (uint32_t i = 0; i < fenceCount; i++) {
        VkFence fence = pFences[i];
        if (fence_signalled(fence, completed)) {
            any = 1;
            continue;
        }
        // Never submitted: nothing will ever signal it.
        if (fence->serial == FENCE_UNSIGNALLED) {
            if (waitAll) return VK_TIMEOUT;
            continue;
        }
        if (waitAll) {
            if (fence->serial > target) target = fence->serial;
        } else if (target == 0 || fence->serial < target) {
            target = fence->serial;
        }
    }
    if (target == 0) return (waitAll || any) ? VK_SUCCESS : VK_TIMEOUT;
    if (!waitAll && any) return VK_SUCCESS;
    if (timeout == 0) return VK_TIMEOUT;
    // Blocks under JSPI. Without it the bridge cannot block the browser's
    // thread and returns at once; WebGPU still keeps every resource the
    // pending work uses alive and ordered, so the frame loop proceeds as on
    // Vulkan — only host reads of GPU-written memory arrive later.
    nwg_queue_wait_serial(target);
    return VK_SUCCESS;
}

// MARK: - Semaphores

VKAPI_ATTR VkResult VKAPI_CALL vkCreateSemaphore(
    VkDevice device, const VkSemaphoreCreateInfo *pCreateInfo, const VkAllocationCallbacks *pAllocator,
    VkSemaphore *pSemaphore) {
    (void)device;
    (void)pCreateInfo;
    (void)pAllocator;
    // One queue, executing in submission order: every semaphore wait is
    // already satisfied by the order of the submits.
    VkSemaphore semaphore = calloc(1, sizeof *semaphore);
    if (!semaphore) return VK_ERROR_OUT_OF_HOST_MEMORY;
    *pSemaphore = semaphore;
    return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL vkDestroySemaphore(VkDevice device, VkSemaphore semaphore, const VkAllocationCallbacks *pAllocator) {
    (void)device;
    (void)pAllocator;
    free(semaphore);
}

#endif /* __wasm__ */
