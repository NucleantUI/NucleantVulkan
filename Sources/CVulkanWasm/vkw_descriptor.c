// Descriptor set layouts, pipeline layouts, descriptor pools and sets.
//
// WebGPU bind groups are immutable and tied to a layout, while a Vulkan
// descriptor set is a mutable slot array that can be rewritten until the
// work that binds it is submitted. So a set lives here as plain data — what
// each descriptor currently points at, plus a version bumped on every write —
// and the bridge builds (and caches, per version) the GPUBindGroup when a
// submit binds the set for a draw.

#if defined(__wasm__)

#include "vkw_internal.h"

// MARK: - Set layouts

VKAPI_ATTR VkResult VKAPI_CALL vkCreateDescriptorSetLayout(
    VkDevice device, const VkDescriptorSetLayoutCreateInfo *pCreateInfo, const VkAllocationCallbacks *pAllocator,
    VkDescriptorSetLayout *pSetLayout) {
    (void)device;
    (void)pAllocator;
    VkDescriptorSetLayout layout = calloc(1, sizeof *layout);
    if (!layout) return VK_ERROR_OUT_OF_HOST_MEMORY;
    layout->bindingCount = pCreateInfo->bindingCount;
    layout->bindings = calloc(pCreateInfo->bindingCount ? pCreateInfo->bindingCount : 1, sizeof *layout->bindings);
    if (!layout->bindings) {
        free(layout);
        return VK_ERROR_OUT_OF_HOST_MEMORY;
    }
    for (uint32_t i = 0; i < pCreateInfo->bindingCount; i++) {
        const VkDescriptorSetLayoutBinding *src = &pCreateInfo->pBindings[i];
        vkw_layout_binding_t *dst = &layout->bindings[i];
        dst->binding = src->binding;
        dst->type = src->descriptorType;
        dst->count = src->descriptorCount;
        if (src->descriptorCount > 1) {
            // A WebGPU bind group entry holds one resource; arrays of them
            // (binding_array) are not part of core WebGPU.
            vkw_logf("vkCreateDescriptorSetLayout: binding %u has %u descriptors; WebGPU binds one per binding",
                     src->binding, src->descriptorCount);
        }
        if (src->pImmutableSamplers && src->descriptorCount > 0 &&
            (src->descriptorType == VK_DESCRIPTOR_TYPE_SAMPLER ||
             src->descriptorType == VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER)) {
            dst->immutableSamplers = calloc(src->descriptorCount, sizeof(VkSampler));
            if (dst->immutableSamplers) {
                memcpy(dst->immutableSamplers, src->pImmutableSamplers, src->descriptorCount * sizeof(VkSampler));
            }
        }
        layout->descriptorCount += src->descriptorCount;
    }
    *pSetLayout = layout;
    return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL vkDestroyDescriptorSetLayout(
    VkDevice device, VkDescriptorSetLayout descriptorSetLayout, const VkAllocationCallbacks *pAllocator) {
    (void)device;
    (void)pAllocator;
    if (!descriptorSetLayout) return;
    for (uint32_t i = 0; i < descriptorSetLayout->bindingCount; i++) free(descriptorSetLayout->bindings[i].immutableSamplers);
    free(descriptorSetLayout->bindings);
    free(descriptorSetLayout);
}

// MARK: - Pipeline layouts

VKAPI_ATTR VkResult VKAPI_CALL vkCreatePipelineLayout(
    VkDevice device, const VkPipelineLayoutCreateInfo *pCreateInfo, const VkAllocationCallbacks *pAllocator,
    VkPipelineLayout *pPipelineLayout) {
    (void)pAllocator;
    // One bind group is kept for the emulated per-draw data (push constants
    // and the viewport remap), so the sets get the rest.
    uint32_t maxSets = vkw_device_info(device)->maxBindGroups - 1;
    if (maxSets > VKW_MAX_SETS) maxSets = VKW_MAX_SETS;
    if (pCreateInfo->setLayoutCount > maxSets) {
        vkw_logf("vkCreatePipelineLayout: %u descriptor sets; WebGPU leaves room for %u",
                 pCreateInfo->setLayoutCount, maxSets);
        return VK_ERROR_INITIALIZATION_FAILED;
    }
    uint32_t pushConstantSize = 0;
    for (uint32_t i = 0; i < pCreateInfo->pushConstantRangeCount; i++) {
        const VkPushConstantRange *range = &pCreateInfo->pPushConstantRanges[i];
        if (range->offset + range->size > pushConstantSize) pushConstantSize = range->offset + range->size;
    }
    if (pushConstantSize > NWG_MAX_PUSH_CONSTANTS) {
        vkw_logf("vkCreatePipelineLayout: %u bytes of push constants; the limit is %u",
                 pushConstantSize, NWG_MAX_PUSH_CONSTANTS);
        return VK_ERROR_INITIALIZATION_FAILED;
    }
    VkPipelineLayout layout = calloc(1, sizeof *layout);
    if (!layout) return VK_ERROR_OUT_OF_HOST_MEMORY;
    layout->setCount = pCreateInfo->setLayoutCount;
    layout->pushConstantSize = pushConstantSize;
    *pPipelineLayout = layout;
    return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL vkDestroyPipelineLayout(
    VkDevice device, VkPipelineLayout pipelineLayout, const VkAllocationCallbacks *pAllocator) {
    (void)device;
    (void)pAllocator;
    free(pipelineLayout);
}

// MARK: - Pools and sets

VKAPI_ATTR VkResult VKAPI_CALL vkCreateDescriptorPool(
    VkDevice device, const VkDescriptorPoolCreateInfo *pCreateInfo, const VkAllocationCallbacks *pAllocator,
    VkDescriptorPool *pDescriptorPool) {
    (void)device;
    (void)pAllocator;
    VkDescriptorPool pool = calloc(1, sizeof *pool);
    if (!pool) return VK_ERROR_OUT_OF_HOST_MEMORY;
    pool->maxSets = pCreateInfo->maxSets;
    *pDescriptorPool = pool;
    return VK_SUCCESS;
}

static void free_set(VkDescriptorSet set) {
    nwg_descriptor_set_release(set->id);
    free(set->descriptors);
    free(set);
}

VKAPI_ATTR void VKAPI_CALL vkDestroyDescriptorPool(
    VkDevice device, VkDescriptorPool descriptorPool, const VkAllocationCallbacks *pAllocator) {
    (void)device;
    (void)pAllocator;
    if (!descriptorPool) return;
    // Destroying a pool frees every set allocated from it.
    for (VkDescriptorSet set = descriptorPool->sets; set;) {
        VkDescriptorSet next = set->nextInPool;
        free_set(set);
        set = next;
    }
    free(descriptorPool);
}

VKAPI_ATTR VkResult VKAPI_CALL vkResetDescriptorPool(
    VkDevice device, VkDescriptorPool descriptorPool, VkDescriptorPoolResetFlags flags) {
    (void)device;
    (void)flags;
    // Every set allocated from the pool goes back to it.
    for (VkDescriptorSet set = descriptorPool->sets; set;) {
        VkDescriptorSet next = set->nextInPool;
        free_set(set);
        set = next;
    }
    descriptorPool->sets = NULL;
    descriptorPool->liveSets = 0;
    return VK_SUCCESS;
}

static uint32_t descriptor_kind(VkDescriptorType type) {
    switch (type) {
    case VK_DESCRIPTOR_TYPE_SAMPLER:                return NWG_DESC_SAMPLER;
    case VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER: return NWG_DESC_COMBINED;
    case VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE:          return NWG_DESC_SAMPLED_IMAGE;
    case VK_DESCRIPTOR_TYPE_STORAGE_IMAGE:          return NWG_DESC_STORAGE_IMAGE;
    case VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER:
    case VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC: return NWG_DESC_UNIFORM_BUFFER;
    case VK_DESCRIPTOR_TYPE_STORAGE_BUFFER:
    case VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC: return NWG_DESC_STORAGE_BUFFER;
    default:                                        return 0;
    }
}

VKAPI_ATTR VkResult VKAPI_CALL vkAllocateDescriptorSets(
    VkDevice device, const VkDescriptorSetAllocateInfo *pAllocateInfo, VkDescriptorSet *pDescriptorSets) {
    VkDescriptorPool pool = pAllocateInfo->descriptorPool;
    if (pool->liveSets + pAllocateInfo->descriptorSetCount > pool->maxSets) {
        for (uint32_t i = 0; i < pAllocateInfo->descriptorSetCount; i++) pDescriptorSets[i] = NULL;
        return VK_ERROR_OUT_OF_POOL_MEMORY;
    }
    for (uint32_t i = 0; i < pAllocateInfo->descriptorSetCount; i++) {
        VkDescriptorSetLayout layout = pAllocateInfo->pSetLayouts[i];
        VkDescriptorSet set = calloc(1, sizeof *set);
        vkw_descriptor_t *descriptors = calloc(layout->descriptorCount ? layout->descriptorCount : 1, sizeof *descriptors);
        if (!set || !descriptors) {
            free(set);
            free(descriptors);
            for (uint32_t j = 0; j < i; j++) {
                // Unlink what this call already added; it was pushed at the head.
                pool->sets = pDescriptorSets[j]->nextInPool;
                pool->liveSets--;
                free_set(pDescriptorSets[j]);
                pDescriptorSets[j] = NULL;
            }
            return VK_ERROR_OUT_OF_HOST_MEMORY;
        }
        uint32_t index = 0;
        for (uint32_t b = 0; b < layout->bindingCount; b++) {
            const vkw_layout_binding_t *binding = &layout->bindings[b];
            for (uint32_t e = 0; e < binding->count; e++, index++) {
                descriptors[index].binding = binding->binding;
                if (binding->immutableSamplers) {
                    // Pre-filled, as Vulkan treats an immutable sampler as
                    // part of the layout itself.
                    uint32_t sampler = binding->immutableSamplers[e]->gpu;
                    descriptors[index].immutableSampler = sampler;
                    descriptors[index].type = descriptor_kind(binding->type);
                    if (binding->type == VK_DESCRIPTOR_TYPE_SAMPLER) descriptors[index].a = sampler;
                    else descriptors[index].b = sampler;
                }
            }
        }
        set->id = vkw_next_id();
        set->layout = layout;
        set->count = layout->descriptorCount;
        set->descriptors = descriptors;
        set->pool = pool;
        set->nextInPool = pool->sets;
        pool->sets = set;
        pool->liveSets++;
        pDescriptorSets[i] = set;
    }
    return VK_SUCCESS;
}

/// Index of (binding, element) in the set's descriptor array, following
/// Vulkan's rule that an update running past a binding's count continues
/// into the next binding. -1 when out of range.
static int descriptor_index(VkDescriptorSet set, uint32_t binding, uint32_t element) {
    const VkDescriptorSetLayout layout = set->layout;
    uint32_t index = 0;
    uint32_t b = 0;
    for (; b < layout->bindingCount; b++) {
        if (layout->bindings[b].binding == binding) break;
        index += layout->bindings[b].count;
    }
    for (; b < layout->bindingCount; b++) {
        if (element < layout->bindings[b].count) return (int)(index + element);
        element -= layout->bindings[b].count;
        index += layout->bindings[b].count;
    }
    return -1;
}

VKAPI_ATTR void VKAPI_CALL vkUpdateDescriptorSets(
    VkDevice device, uint32_t descriptorWriteCount, const VkWriteDescriptorSet *pDescriptorWrites,
    uint32_t descriptorCopyCount, const VkCopyDescriptorSet *pDescriptorCopies) {
    (void)device;
    for (uint32_t w = 0; w < descriptorWriteCount; w++) {
        const VkWriteDescriptorSet *write = &pDescriptorWrites[w];
        VkDescriptorSet set = write->dstSet;
        uint32_t kind = descriptor_kind(write->descriptorType);
        if (!kind) {
            vkw_logf("vkUpdateDescriptorSets: descriptor type %d has no WebGPU equivalent", (int)write->descriptorType);
            continue;
        }
        for (uint32_t i = 0; i < write->descriptorCount; i++) {
            int index = descriptor_index(set, write->dstBinding, write->dstArrayElement + i);
            if (index < 0) break;
            vkw_descriptor_t *d = &set->descriptors[index];
            // An immutable sampler is part of the layout and wins over the
            // update's, as in Vulkan.
            uint32_t fixed = d->immutableSampler;
            d->type = kind;
            d->a = d->b = d->c = 0;
            switch (kind) {
            case NWG_DESC_SAMPLER:
                d->a = fixed ? fixed : (write->pImageInfo[i].sampler ? write->pImageInfo[i].sampler->gpu : 0);
                break;
            case NWG_DESC_COMBINED: {
                const VkDescriptorImageInfo *info = &write->pImageInfo[i];
                d->a = info->imageView ? info->imageView->gpu : 0;
                d->b = fixed ? fixed : (info->sampler ? info->sampler->gpu : 0);
                break;
            }
            case NWG_DESC_SAMPLED_IMAGE:
            case NWG_DESC_STORAGE_IMAGE:
                d->a = write->pImageInfo[i].imageView ? write->pImageInfo[i].imageView->gpu : 0;
                break;
            case NWG_DESC_UNIFORM_BUFFER:
            case NWG_DESC_STORAGE_BUFFER: {
                const VkDescriptorBufferInfo *info = &write->pBufferInfo[i];
                d->a = info->buffer ? info->buffer->gpu : 0;
                d->b = (uint32_t)info->offset;
                d->c = info->range == VK_WHOLE_SIZE ? 0 : (uint32_t)info->range;
                break;
            }
            }
        }
        set->version++;
    }
    for (uint32_t c = 0; c < descriptorCopyCount; c++) {
        const VkCopyDescriptorSet *copy = &pDescriptorCopies[c];
        for (uint32_t i = 0; i < copy->descriptorCount; i++) {
            int from = descriptor_index(copy->srcSet, copy->srcBinding, copy->srcArrayElement + i);
            int to = descriptor_index(copy->dstSet, copy->dstBinding, copy->dstArrayElement + i);
            if (from < 0 || to < 0) break;
            vkw_descriptor_t *dst = &copy->dstSet->descriptors[to];
            const vkw_descriptor_t *src = &copy->srcSet->descriptors[from];
            dst->type = src->type;
            dst->a = src->a;
            dst->b = dst->immutableSampler && src->type == NWG_DESC_COMBINED ? dst->immutableSampler : src->b;
            dst->c = src->c;
        }
        copy->dstSet->version++;
    }
}

#endif /* __wasm__ */
