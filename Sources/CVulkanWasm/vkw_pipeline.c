// Shader modules, render passes, framebuffers and pipelines.
//
// A shader module keeps its SPIR-V; the WGSL a browser needs is made when a
// pipeline is created, because only then is the entry point, the stage and
// the pipeline layout known — and the bridge's translation (naga) needs the
// layout to place the emulated push constants and viewport remap in the bind
// group after the descriptor sets.

#if defined(__wasm__)

#include "vkw_internal.h"

// MARK: - Shader modules

VKAPI_ATTR VkResult VKAPI_CALL vkCreateShaderModule(
    VkDevice device, const VkShaderModuleCreateInfo *pCreateInfo, const VkAllocationCallbacks *pAllocator,
    VkShaderModule *pShaderModule) {
    (void)device;
    (void)pAllocator;
    if (pCreateInfo->codeSize < 20 || pCreateInfo->codeSize % 4 != 0 || pCreateInfo->pCode[0] != 0x07230203) {
        return VK_ERROR_INVALID_SHADER_NV;
    }
    VkShaderModule module = calloc(1, sizeof *module);
    uint32_t *words = malloc(pCreateInfo->codeSize);
    if (!module || !words) {
        free(module);
        free(words);
        return VK_ERROR_OUT_OF_HOST_MEMORY;
    }
    memcpy(words, pCreateInfo->pCode, pCreateInfo->codeSize);
    module->words = words;
    module->wordCount = (uint32_t)(pCreateInfo->codeSize / 4);
    *pShaderModule = module;
    return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL vkDestroyShaderModule(VkDevice device, VkShaderModule shaderModule, const VkAllocationCallbacks *pAllocator) {
    (void)device;
    (void)pAllocator;
    if (!shaderModule) return;
    free(shaderModule->words);
    free(shaderModule);
}

// MARK: - Render passes

VKAPI_ATTR VkResult VKAPI_CALL vkCreateRenderPass(
    VkDevice device, const VkRenderPassCreateInfo *pCreateInfo, const VkAllocationCallbacks *pAllocator,
    VkRenderPass *pRenderPass) {
    (void)device;
    (void)pAllocator;
    if (pCreateInfo->attachmentCount > VKW_MAX_COLOR_ATTACHMENTS + 1 || pCreateInfo->subpassCount == 0) {
        return VK_ERROR_INITIALIZATION_FAILED;
    }
    if (pCreateInfo->subpassCount > 1) {
        // A WebGPU render pass has no subpasses; each one would be its own pass.
        vkw_logf("vkCreateRenderPass: %u subpasses; only the first is rendered on WebGPU", pCreateInfo->subpassCount);
    }
    const VkSubpassDescription *subpass = &pCreateInfo->pSubpasses[0];
    if (subpass->inputAttachmentCount || subpass->pResolveAttachments) {
        vkw_logf("vkCreateRenderPass: input/resolve attachments are not implemented on WebGPU yet");
        return VK_ERROR_FEATURE_NOT_PRESENT;
    }
    VkRenderPass pass = calloc(1, sizeof *pass);
    if (!pass) return VK_ERROR_OUT_OF_HOST_MEMORY;
    pass->attachmentCount = pCreateInfo->attachmentCount;
    for (uint32_t i = 0; i < pCreateInfo->attachmentCount; i++) {
        pass->attachments[i].format = pCreateInfo->pAttachments[i].format;
        pass->attachments[i].loadOp = pCreateInfo->pAttachments[i].loadOp;
        pass->attachments[i].storeOp = pCreateInfo->pAttachments[i].storeOp;
        pass->attachments[i].stencilLoadOp = pCreateInfo->pAttachments[i].stencilLoadOp;
        pass->attachments[i].stencilStoreOp = pCreateInfo->pAttachments[i].stencilStoreOp;
    }
    pass->depthRef = subpass->pDepthStencilAttachment ? subpass->pDepthStencilAttachment->attachment : VK_ATTACHMENT_UNUSED;
    pass->colorCount = subpass->colorAttachmentCount;
    for (uint32_t i = 0; i < subpass->colorAttachmentCount && i < VKW_MAX_COLOR_ATTACHMENTS; i++) {
        pass->colorRefs[i] = subpass->pColorAttachments[i].attachment;
    }
    *pRenderPass = pass;
    return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL vkDestroyRenderPass(VkDevice device, VkRenderPass renderPass, const VkAllocationCallbacks *pAllocator) {
    (void)device;
    (void)pAllocator;
    free(renderPass);
}

VKAPI_ATTR VkResult VKAPI_CALL vkCreateFramebuffer(
    VkDevice device, const VkFramebufferCreateInfo *pCreateInfo, const VkAllocationCallbacks *pAllocator,
    VkFramebuffer *pFramebuffer) {
    (void)device;
    (void)pAllocator;
    if (pCreateInfo->attachmentCount > VKW_MAX_COLOR_ATTACHMENTS + 1) return VK_ERROR_INITIALIZATION_FAILED;
    VkFramebuffer framebuffer = calloc(1, sizeof *framebuffer);
    if (!framebuffer) return VK_ERROR_OUT_OF_HOST_MEMORY;
    framebuffer->attachmentCount = pCreateInfo->attachmentCount;
    for (uint32_t i = 0; i < pCreateInfo->attachmentCount; i++) framebuffer->attachments[i] = pCreateInfo->pAttachments[i];
    framebuffer->width = pCreateInfo->width;
    framebuffer->height = pCreateInfo->height;
    framebuffer->layers = pCreateInfo->layers;
    *pFramebuffer = framebuffer;
    return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL vkDestroyFramebuffer(VkDevice device, VkFramebuffer framebuffer, const VkAllocationCallbacks *pAllocator) {
    (void)device;
    (void)pAllocator;
    free(framebuffer);
}

// MARK: - Pipelines

static int fill_stage(nwg_stage_t *out, const VkPipelineShaderStageCreateInfo *stage) {
    if (stage->pSpecializationInfo && stage->pSpecializationInfo->mapEntryCount > 0) {
        vkw_logf("vk*Pipelines: specialization constants are not implemented on WebGPU yet");
        return 0;
    }
    out->code = stage->module->words;
    out->wordCount = stage->module->wordCount;
    out->entry = stage->pName;
    out->entryLen = (uint32_t)strlen(stage->pName);
    return 1;
}

static int has_dynamic_state(const VkPipelineDynamicStateCreateInfo *dynamic, VkDynamicState state) {
    if (!dynamic) return 0;
    for (uint32_t i = 0; i < dynamic->dynamicStateCount; i++) {
        if (dynamic->pDynamicStates[i] == state) return 1;
    }
    return 0;
}

static VkResult create_graphics_pipeline(const VkGraphicsPipelineCreateInfo *info, VkPipeline *pPipeline) {
    nwg_render_pipeline_desc_t desc;
    memset(&desc, 0, sizeof desc);
    int hasVertex = 0;
    for (uint32_t s = 0; s < info->stageCount; s++) {
        const VkPipelineShaderStageCreateInfo *stage = &info->pStages[s];
        if (stage->stage == VK_SHADER_STAGE_VERTEX_BIT) {
            if (!fill_stage(&desc.vertex, stage)) return VK_ERROR_FEATURE_NOT_PRESENT;
            hasVertex = 1;
        } else if (stage->stage == VK_SHADER_STAGE_FRAGMENT_BIT) {
            if (!fill_stage(&desc.fragment, stage)) return VK_ERROR_FEATURE_NOT_PRESENT;
            desc.hasFragment = 1;
        } else {
            vkw_logf("vkCreateGraphicsPipelines: shader stage 0x%x has no WebGPU equivalent", (unsigned)stage->stage);
            return VK_ERROR_FEATURE_NOT_PRESENT;
        }
    }
    if (!hasVertex) return VK_ERROR_INITIALIZATION_FAILED;
    const VkPipelineVertexInputStateCreateInfo *input = info->pVertexInputState;
    if (input) {
        if (input->vertexBindingDescriptionCount > NWG_MAX_VERTEX_BINDINGS ||
            input->vertexAttributeDescriptionCount > NWG_MAX_VERTEX_ATTRIBUTES) {
            vkw_logf("vkCreateGraphicsPipelines: more than %u vertex bindings or attributes", NWG_MAX_VERTEX_BINDINGS);
            return VK_ERROR_FEATURE_NOT_PRESENT;
        }
        desc.bindingCount = input->vertexBindingDescriptionCount;
        for (uint32_t i = 0; i < desc.bindingCount; i++) {
            const VkVertexInputBindingDescription *b = &input->pVertexBindingDescriptions[i];
            desc.bindings[i] = (nwg_vertex_binding_t){ b->binding, b->stride, b->inputRate == VK_VERTEX_INPUT_RATE_INSTANCE };
        }
        desc.attributeCount = input->vertexAttributeDescriptionCount;
        for (uint32_t i = 0; i < desc.attributeCount; i++) {
            const VkVertexInputAttributeDescription *a = &input->pVertexAttributeDescriptions[i];
            desc.attributes[i] = (nwg_vertex_attribute_t){ a->location, a->binding, (uint32_t)a->format, a->offset };
        }
    }

    desc.setCount = info->layout->setCount;
    desc.topology = info->pInputAssemblyState ? (uint32_t)info->pInputAssemblyState->topology
                                              : (uint32_t)VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    if (info->pRasterizationState) {
        desc.cullMode = info->pRasterizationState->cullMode;
        desc.frontFace = (uint32_t)info->pRasterizationState->frontFace;
    }
    desc.sampleCount = info->pMultisampleState ? (uint32_t)info->pMultisampleState->rasterizationSamples : 1;

    VkRenderPass pass = info->renderPass;
    desc.colorCount = pass->colorCount;
    for (uint32_t i = 0; i < pass->colorCount; i++) {
        nwg_color_target_t *color = &desc.colors[i];
        uint32_t ref = pass->colorRefs[i];
        color->format = ref == VK_ATTACHMENT_UNUSED ? 0 : (uint32_t)pass->attachments[ref].format;
        color->writeMask = 0xF;
        const VkPipelineColorBlendStateCreateInfo *blend = info->pColorBlendState;
        if (blend && i < blend->attachmentCount) {
            const VkPipelineColorBlendAttachmentState *att = &blend->pAttachments[i];
            color->blendEnable = att->blendEnable;
            color->srcColor = (uint32_t)att->srcColorBlendFactor;
            color->dstColor = (uint32_t)att->dstColorBlendFactor;
            color->colorOp = (uint32_t)att->colorBlendOp;
            color->srcAlpha = (uint32_t)att->srcAlphaBlendFactor;
            color->dstAlpha = (uint32_t)att->dstAlphaBlendFactor;
            color->alphaOp = (uint32_t)att->alphaBlendOp;
            color->writeMask = att->colorWriteMask;
        }
    }

    // Depth/stencil: WebGPU wants the state exactly when the pass has the
    // attachment, with its format.
    const VkPipelineDepthStencilStateCreateInfo *ds = info->pDepthStencilState;
    if (pass->depthRef != VK_ATTACHMENT_UNUSED) {
        desc.depthFormat = (uint32_t)pass->attachments[pass->depthRef].format;
        desc.depthCompare = (uint32_t)VK_COMPARE_OP_ALWAYS;
        desc.front = desc.back = (nwg_stencil_face_t){ VK_COMPARE_OP_ALWAYS, VK_STENCIL_OP_KEEP, VK_STENCIL_OP_KEEP, VK_STENCIL_OP_KEEP };
        desc.stencilReadMask = desc.stencilWriteMask = 0xFF;
        if (ds) {
            desc.depthTest = ds->depthTestEnable;
            desc.depthWrite = ds->depthTestEnable && ds->depthWriteEnable;
            if (ds->depthTestEnable) desc.depthCompare = (uint32_t)ds->depthCompareOp;
            desc.stencilTest = ds->stencilTestEnable;
            if (ds->stencilTestEnable) {
                desc.front = (nwg_stencil_face_t){ ds->front.compareOp, ds->front.failOp, ds->front.depthFailOp, ds->front.passOp };
                desc.back = (nwg_stencil_face_t){ ds->back.compareOp, ds->back.failOp, ds->back.depthFailOp, ds->back.passOp };
                desc.stencilReadMask = ds->front.compareMask;
                desc.stencilWriteMask = ds->front.writeMask;
            }
        }
    }

    uint32_t gpu = nwg_render_pipeline_create(&desc);
    if (!gpu) return VK_ERROR_INITIALIZATION_FAILED;
    VkPipeline pipeline = calloc(1, sizeof *pipeline);
    if (!pipeline) {
        nwg_pipeline_destroy(gpu);
        return VK_ERROR_OUT_OF_HOST_MEMORY;
    }
    pipeline->gpu = gpu;
    pipeline->setCount = desc.setCount;
    pipeline->dynamicViewport = has_dynamic_state(info->pDynamicState, VK_DYNAMIC_STATE_VIEWPORT);
    pipeline->dynamicScissor = has_dynamic_state(info->pDynamicState, VK_DYNAMIC_STATE_SCISSOR);
    const VkPipelineViewportStateCreateInfo *viewport = info->pViewportState;
    if (viewport && !pipeline->dynamicViewport && viewport->pViewports) pipeline->viewport = viewport->pViewports[0];
    if (viewport && !pipeline->dynamicScissor && viewport->pScissors) pipeline->scissor = viewport->pScissors[0];
    pipeline->dynamicStencilReference = has_dynamic_state(info->pDynamicState, VK_DYNAMIC_STATE_STENCIL_REFERENCE);
    pipeline->dynamicStencilMasks = has_dynamic_state(info->pDynamicState, VK_DYNAMIC_STATE_STENCIL_COMPARE_MASK) ||
                                    has_dynamic_state(info->pDynamicState, VK_DYNAMIC_STATE_STENCIL_WRITE_MASK);
    pipeline->dynamicBlendConstants = has_dynamic_state(info->pDynamicState, VK_DYNAMIC_STATE_BLEND_CONSTANTS);
    pipeline->stencilReference = ds && ds->stencilTestEnable ? ds->front.reference : 0;
    pipeline->stencilCompareMask = desc.stencilReadMask;
    pipeline->stencilWriteMask = desc.stencilWriteMask;
    if (info->pColorBlendState) memcpy(pipeline->blendConstants, info->pColorBlendState->blendConstants, sizeof pipeline->blendConstants);
    *pPipeline = pipeline;
    return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL vkCreateGraphicsPipelines(
    VkDevice device, VkPipelineCache pipelineCache, uint32_t createInfoCount,
    const VkGraphicsPipelineCreateInfo *pCreateInfos, const VkAllocationCallbacks *pAllocator, VkPipeline *pPipelines) {
    (void)device;
    (void)pipelineCache;
    (void)pAllocator;
    VkResult result = VK_SUCCESS;
    for (uint32_t i = 0; i < createInfoCount; i++) {
        pPipelines[i] = NULL;
        VkResult one = create_graphics_pipeline(&pCreateInfos[i], &pPipelines[i]);
        if (one != VK_SUCCESS) result = one;
    }
    return result;
}

VKAPI_ATTR VkResult VKAPI_CALL vkCreateComputePipelines(
    VkDevice device, VkPipelineCache pipelineCache, uint32_t createInfoCount,
    const VkComputePipelineCreateInfo *pCreateInfos, const VkAllocationCallbacks *pAllocator, VkPipeline *pPipelines) {
    (void)device;
    (void)pipelineCache;
    (void)pAllocator;
    VkResult result = VK_SUCCESS;
    for (uint32_t i = 0; i < createInfoCount; i++) {
        pPipelines[i] = NULL;
        const VkComputePipelineCreateInfo *info = &pCreateInfos[i];
        nwg_compute_pipeline_desc_t desc;
        memset(&desc, 0, sizeof desc);
        if (!fill_stage(&desc.compute, &info->stage)) {
            result = VK_ERROR_FEATURE_NOT_PRESENT;
            continue;
        }
        desc.setCount = info->layout->setCount;
        uint32_t gpu = nwg_compute_pipeline_create(&desc);
        if (!gpu) {
            result = VK_ERROR_INITIALIZATION_FAILED;
            continue;
        }
        VkPipeline pipeline = calloc(1, sizeof *pipeline);
        if (!pipeline) {
            nwg_pipeline_destroy(gpu);
            result = VK_ERROR_OUT_OF_HOST_MEMORY;
            continue;
        }
        pipeline->gpu = gpu;
        pipeline->compute = 1;
        pipeline->setCount = desc.setCount;
        pPipelines[i] = pipeline;
    }
    return result;
}

VKAPI_ATTR void VKAPI_CALL vkDestroyPipeline(VkDevice device, VkPipeline pipeline, const VkAllocationCallbacks *pAllocator) {
    (void)device;
    (void)pAllocator;
    if (!pipeline) return;
    nwg_pipeline_destroy(pipeline->gpu);
    free(pipeline);
}

#endif /* __wasm__ */
