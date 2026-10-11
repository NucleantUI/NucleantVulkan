// webgpu.h on the browser's WebGPU.
//
// Every other platform links wgpu-native for webgpu.h; it has no wasm build.
// In a browser the WebGPU API is already there — it is what the Vulkan
// implementation in CVulkanWasm runs on — so this is webgpu.h implemented on
// it. Every object is a JS-side WebGPU object (Web/nucleant-wgpu.js),
// referenced from here by an integer id that is also the handle's pointer
// value. The device is the Vulkan implementation's own GPUDevice, so:
//
//   * a texture made here can be imported into Vulkan as a VkImage
//     (VK_NUCLEANT_webgpu_objects) with no copy, the way VK_EXT_metal_objects
//     imports wgpu-native's Metal texture on Apple; and
//   * both APIs submit to the one GPUQueue, in call order — work submitted
//     here before a vkQueueSubmit is done before that submit's work runs.
//
// The C side's job is turning webgpu.h's nested, chained descriptors into
// flat word lists the JS side reads without knowing C struct layout. Each
// list's shape is documented where it is built and decoded in
// nucleant-wgpu.js in the same order.
//
// Two things a page cannot give C directly are done on this side:
//
//   * Mapped memory. A GPUBuffer's mapped range is a JS ArrayBuffer, not
//     wasm memory. A buffer mapped for writing (MapWrite, or
//     mappedAtCreation) is mapped here, in wasm memory, and its contents
//     reach the GPU through the queue (writeBuffer) when it is unmapped —
//     so mapping it is synchronous, as on a native implementation. A buffer
//     mapped for reading is mapped by the page, and the range is copied into
//     wasm memory once that mapping lands.
//   * Waiting. Futures are polled: wgpuInstanceWaitAny and
//     wgpuInstanceProcessEvents fire the callbacks of the ones the page has
//     settled. A WaitAny with a timeout suspends the module until one
//     settles when the browser has JSPI (the bridge's blocking waits);
//     without it, it returns TimedOut.
//
// Covered: what NucleantVulkan's WgpuContext, ThorVG's wg engine and Skia's
// Graphite call. The rest of webgpu.h is declared by the header but not
// defined here, so a new caller of it fails at link time rather than
// reaching a stub.

#if defined(__wasm__)

#include "include/webgpu/webgpu.h"
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define NWGPU_IMPORT(name) __attribute__((import_module("nucleant_wgpu"), import_name(#name)))

NWGPU_IMPORT(log)                  void     nwgpu_log(const char *message, uint32_t length);
NWGPU_IMPORT(instanceCreate)       uint32_t nwgpu_instance_create(void);
NWGPU_IMPORT(adapterGet)           uint32_t nwgpu_adapter_get(void);
NWGPU_IMPORT(deviceGet)            uint32_t nwgpu_device_get(void);
NWGPU_IMPORT(queueGet)             uint32_t nwgpu_queue_get(void);
/// `which`: 0 the adapter's features, 1 the device's.
NWGPU_IMPORT(hasFeature)           uint32_t nwgpu_has_feature(uint32_t which, uint32_t feature);
NWGPU_IMPORT(addRef)               void     nwgpu_add_ref(uint32_t id);
/// 1 when that was the object's last reference.
NWGPU_IMPORT(release)              uint32_t nwgpu_release(uint32_t id);
NWGPU_IMPORT(setLabel)             void     nwgpu_set_label(uint32_t id, const char *label, uint32_t length);
/// `which`: 0 vendor, 1 architecture, 2 device, 3 description. Copies at
/// most `capacity` bytes and returns the string's full length.
NWGPU_IMPORT(adapterInfo)          uint32_t nwgpu_adapter_info(uint32_t which, char *out, uint32_t capacity);
/// `which`: 0 the adapter's, 1 the device's. WGPULimits' members, in
/// declaration order, as f64s.
NWGPU_IMPORT(limits)               void     nwgpu_limits(uint32_t which, double *out, uint32_t count);

/// `writtenByQueue`: the buffer is mapped for writing in wasm memory and
/// filled through the queue, so the page makes it a COPY_DST buffer in
/// place of MAP_WRITE.
NWGPU_IMPORT(bufferCreate)         uint32_t nwgpu_buffer_create(double size, uint32_t usage, uint32_t writtenByQueue);
NWGPU_IMPORT(bufferGetSize)        double   nwgpu_buffer_get_size(uint32_t buffer);
NWGPU_IMPORT(bufferGetUsage)       uint32_t nwgpu_buffer_get_usage(uint32_t buffer);
NWGPU_IMPORT(bufferDestroy)        void     nwgpu_buffer_destroy(uint32_t buffer);
/// GPUBuffer.mapAsync(READ) — a future settling 1 when mapped, 2 when not.
NWGPU_IMPORT(bufferMapRead)        uint32_t nwgpu_buffer_map_read(uint32_t buffer, double offset, double size);
/// Copies a mapped buffer's range into wasm memory.
NWGPU_IMPORT(bufferReadMapped)     void     nwgpu_buffer_read_mapped(uint32_t buffer, double offset, void *out, uint32_t size);
NWGPU_IMPORT(bufferUnmap)          void     nwgpu_buffer_unmap(uint32_t buffer);

/// 0 while the future is pending, else its outcome (non-zero; each maker
/// below says which).
NWGPU_IMPORT(futureState)          uint32_t nwgpu_future_state(uint32_t future);
NWGPU_IMPORT(futureForget)         void     nwgpu_future_forget(uint32_t future);
/// Suspends the module (JSPI) until one of `futures` settles or
/// `timeoutMs` passes (negative: no limit); returns at once when the page
/// cannot block.
NWGPU_IMPORT(futureWait)           void     nwgpu_future_wait(const uint32_t *futures, uint32_t count, double timeoutMs);
/// queue.onSubmittedWorkDone() — settles 1, or 2 when it fails.
NWGPU_IMPORT(queueWorkDone)        uint32_t nwgpu_queue_work_done(void);
NWGPU_IMPORT(pushErrorScope)       void     nwgpu_push_error_scope(uint32_t filter);
/// device.popErrorScope() — settles with the WGPUErrorType, or
/// POP_ERROR_SCOPE_FAILED.
NWGPU_IMPORT(popErrorScope)        uint32_t nwgpu_pop_error_scope(void);
/// module.getCompilationInfo() — settles 1, or 2; 0 (no future) when the
/// page cannot block, as waiting on it then could not return the messages.
NWGPU_IMPORT(compilationInfo)      uint32_t nwgpu_compilation_info(uint32_t module);
/// A settled compilationInfo's message count; per message, up to `capacity`:
/// type, lineNum, linePos, offset, length, message length.
NWGPU_IMPORT(compilationMessages)  uint32_t nwgpu_compilation_messages(uint32_t future, uint32_t *words, uint32_t capacity);
NWGPU_IMPORT(compilationMessageText) void   nwgpu_compilation_message_text(uint32_t future, uint32_t index, char *out, uint32_t capacity);

NWGPU_IMPORT(textureCreate)        uint32_t nwgpu_texture_create(const uint32_t *words, uint32_t count);
/// `which`: 0 width, 1 height, 2 depthOrArrayLayers, 3 mipLevelCount,
/// 4 sampleCount, 5 dimension, 6 format, 7 usage.
NWGPU_IMPORT(textureGet)           uint32_t nwgpu_texture_get(uint32_t texture, uint32_t which);
NWGPU_IMPORT(textureCreateView)    uint32_t nwgpu_texture_create_view(uint32_t texture, const uint32_t *words, uint32_t count);
NWGPU_IMPORT(textureDestroy)       void     nwgpu_texture_destroy(uint32_t texture);

NWGPU_IMPORT(samplerCreate)        uint32_t nwgpu_sampler_create(const uint32_t *words, uint32_t count);
NWGPU_IMPORT(bindGroupLayoutCreate) uint32_t nwgpu_bind_group_layout_create(const uint32_t *words, uint32_t count);
NWGPU_IMPORT(bindGroupCreate)      uint32_t nwgpu_bind_group_create(const uint32_t *words, uint32_t count);
NWGPU_IMPORT(pipelineLayoutCreate) uint32_t nwgpu_pipeline_layout_create(const uint32_t *words, uint32_t count);
NWGPU_IMPORT(shaderModuleCreate)   uint32_t nwgpu_shader_module_create(const char *code, uint32_t length);
NWGPU_IMPORT(renderPipelineCreate) uint32_t nwgpu_render_pipeline_create(const uint32_t *words, uint32_t count);
NWGPU_IMPORT(computePipelineCreate) uint32_t nwgpu_compute_pipeline_create(const uint32_t *words, uint32_t count);
NWGPU_IMPORT(pipelineBindGroupLayout) uint32_t nwgpu_pipeline_bind_group_layout(uint32_t pipeline, uint32_t index);
NWGPU_IMPORT(querySetCreate)       uint32_t nwgpu_query_set_create(uint32_t type, uint32_t count);

NWGPU_IMPORT(commandEncoderCreate) uint32_t nwgpu_command_encoder_create(void);
NWGPU_IMPORT(beginRenderPass)      uint32_t nwgpu_begin_render_pass(uint32_t encoder, const uint32_t *words, uint32_t count);
NWGPU_IMPORT(copyBufferToBuffer)   void     nwgpu_copy_buffer_to_buffer(uint32_t encoder, uint32_t source, double sourceOffset,
                                                                         uint32_t destination, double destinationOffset, double size);
NWGPU_IMPORT(copyTextureToTexture) void     nwgpu_copy_texture_to_texture(uint32_t encoder, const uint32_t *words, uint32_t count);
NWGPU_IMPORT(copyBufferToTexture)  void     nwgpu_copy_buffer_to_texture(uint32_t encoder, const uint32_t *words, uint32_t count);
NWGPU_IMPORT(copyTextureToBuffer)  void     nwgpu_copy_texture_to_buffer(uint32_t encoder, const uint32_t *words, uint32_t count);
NWGPU_IMPORT(clearBuffer)          void     nwgpu_clear_buffer(uint32_t encoder, uint32_t buffer, double offset, double size);
NWGPU_IMPORT(resolveQuerySet)      void     nwgpu_resolve_query_set(uint32_t encoder, uint32_t querySet, uint32_t firstQuery, uint32_t queryCount,
                                                                   uint32_t destination, double destinationOffset);
NWGPU_IMPORT(beginComputePass)     uint32_t nwgpu_begin_compute_pass(uint32_t encoder, const uint32_t *words, uint32_t count);
NWGPU_IMPORT(encoderFinish)        uint32_t nwgpu_encoder_finish(uint32_t encoder);

// Compute passes take the render-pass calls they share (setPipeline,
// setBindGroup, end) with the pass's id.
NWGPU_IMPORT(dispatch)             void     nwgpu_dispatch(uint32_t pass, uint32_t x, uint32_t y, uint32_t z);
NWGPU_IMPORT(dispatchIndirect)     void     nwgpu_dispatch_indirect(uint32_t pass, uint32_t buffer, double offset);

NWGPU_IMPORT(passSetPipeline)      void     nwgpu_pass_set_pipeline(uint32_t pass, uint32_t pipeline);
NWGPU_IMPORT(passSetBindGroup)     void     nwgpu_pass_set_bind_group(uint32_t pass, uint32_t index, uint32_t group,
                                                                      uint32_t offsetCount, const uint32_t *offsets);
NWGPU_IMPORT(passSetStencilReference) void  nwgpu_pass_set_stencil_reference(uint32_t pass, uint32_t reference);
NWGPU_IMPORT(passSetScissorRect)   void     nwgpu_pass_set_scissor_rect(uint32_t pass, uint32_t x, uint32_t y, uint32_t width, uint32_t height);
NWGPU_IMPORT(passSetViewport)      void     nwgpu_pass_set_viewport(uint32_t pass, float x, float y, float width, float height,
                                                                    float minDepth, float maxDepth);
NWGPU_IMPORT(passSetBlendConstant) void     nwgpu_pass_set_blend_constant(uint32_t pass, double r, double g, double b, double a);
NWGPU_IMPORT(passSetVertexBuffer)  void     nwgpu_pass_set_vertex_buffer(uint32_t pass, uint32_t slot, uint32_t buffer, double offset, double size);
NWGPU_IMPORT(passSetIndexBuffer)   void     nwgpu_pass_set_index_buffer(uint32_t pass, uint32_t buffer, uint32_t format, double offset, double size);
NWGPU_IMPORT(passDraw)             void     nwgpu_pass_draw(uint32_t pass, uint32_t vertexCount, uint32_t instanceCount,
                                                            uint32_t firstVertex, uint32_t firstInstance);
NWGPU_IMPORT(passDrawIndexed)      void     nwgpu_pass_draw_indexed(uint32_t pass, uint32_t indexCount, uint32_t instanceCount,
                                                                    uint32_t firstIndex, int32_t baseVertex, uint32_t firstInstance);
NWGPU_IMPORT(passDrawIndirect)     void     nwgpu_pass_draw_indirect(uint32_t pass, uint32_t buffer, double offset, uint32_t indexed);
NWGPU_IMPORT(passEnd)              void     nwgpu_pass_end(uint32_t pass);

NWGPU_IMPORT(queueSubmit)          void     nwgpu_queue_submit(uint32_t count, const uint32_t *commandBuffers);
NWGPU_IMPORT(queueWriteBuffer)     void     nwgpu_queue_write_buffer(uint32_t buffer, double offset, const void *data, uint32_t size);
NWGPU_IMPORT(queueWriteTexture)    void     nwgpu_queue_write_texture(const uint32_t *words, uint32_t count, const void *data, uint32_t size);

// MARK: - Handles, strings, word lists

#define ID(handle) ((uint32_t)(uintptr_t)(handle))
#define HANDLE(type, id) ((type)(uintptr_t)(id))

/// Marks an absent string in a word list (a NULL `WGPUStringView`).
#define NO_STRING UINT32_MAX

static const WGPUStringView noMessage = {NULL, 0};

static void logf_(const char *format, ...) __attribute__((format(printf, 1, 2)));
static void logf_(const char *format, ...) {
    char message[512];
    va_list args;
    va_start(args, format);
    int length = vsnprintf(message, sizeof message, format, args);
    va_end(args);
    if (length < 0) return;
    nwgpu_log(message, (uint32_t)(length < (int)sizeof message ? length : (int)sizeof message - 1));
}

static size_t string_length(WGPUStringView view) {
    if (!view.data) return 0;
    return view.length == WGPU_STRLEN ? strlen(view.data) : view.length;
}

typedef struct {
    uint32_t *words;
    uint32_t count, capacity;
    int failed;
} words_t;

static void put(words_t *w, uint32_t word) {
    if (w->count == w->capacity) {
        uint32_t capacity = w->capacity ? w->capacity * 2 : 64;
        uint32_t *grown = realloc(w->words, capacity * sizeof *grown);
        if (!grown) {
            w->failed = 1;
            return;
        }
        w->words = grown;
        w->capacity = capacity;
    }
    w->words[w->count++] = word;
}

static void put_f64(words_t *w, double value) {
    uint64_t bits;
    memcpy(&bits, &value, sizeof bits);
    put(w, (uint32_t)bits);
    put(w, (uint32_t)(bits >> 32));
}

static void put_f32(words_t *w, float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof bits);
    put(w, bits);
}

/// A 64-bit size or offset as a double: exact up to 2^53, far past any
/// buffer a browser will allocate. `WGPU_WHOLE_SIZE` stays recognisable as
/// -1.
static double size64(uint64_t value) {
    return value == WGPU_WHOLE_SIZE ? -1.0 : (double)value;
}

/// (pointer, length) of a string, or (0, NO_STRING) for a NULL one.
static void put_string(words_t *w, WGPUStringView view) {
    put(w, (uint32_t)(uintptr_t)view.data);
    put(w, view.data ? (uint32_t)string_length(view) : NO_STRING);
}

/// count, then per entry: key (string), value (f64).
static void put_constants(words_t *w, size_t count, const WGPUConstantEntry *constants) {
    put(w, (uint32_t)count);
    for (size_t i = 0; i < count; i++) {
        put_string(w, constants[i].key);
        put_f64(w, constants[i].value);
    }
}

static uint32_t finish(words_t *w, uint32_t (*send)(const uint32_t *, uint32_t)) {
    uint32_t id = w->failed ? 0 : send(w->words, w->count);
    free(w->words);
    return id;
}

// MARK: - Reference counting

#define REFCOUNTED(Type)                                                     \
    void wgpu##Type##AddRef(WGPU##Type object) { nwgpu_add_ref(ID(object)); } \
    void wgpu##Type##Release(WGPU##Type object) { if (object) nwgpu_release(ID(object)); }

REFCOUNTED(Instance)
REFCOUNTED(Adapter)
REFCOUNTED(Device)
REFCOUNTED(Queue)
REFCOUNTED(Texture)
REFCOUNTED(TextureView)
REFCOUNTED(Sampler)
REFCOUNTED(BindGroupLayout)
REFCOUNTED(BindGroup)
REFCOUNTED(PipelineLayout)
REFCOUNTED(ShaderModule)
REFCOUNTED(RenderPipeline)
REFCOUNTED(ComputePipeline)
REFCOUNTED(CommandEncoder)
REFCOUNTED(CommandBuffer)
REFCOUNTED(RenderPassEncoder)
REFCOUNTED(ComputePassEncoder)
REFCOUNTED(QuerySet)

#define LABELLED(Type)                                                                    \
    void wgpu##Type##SetLabel(WGPU##Type object, WGPUStringView label) {                  \
        nwgpu_set_label(ID(object), label.data, (uint32_t)string_length(label));          \
    }

LABELLED(Buffer)
LABELLED(Texture)
LABELLED(TextureView)

// MARK: - Futures

// A future the page settles (`js`), or one settled when it was made
// (`js` 0, `outcome` set). Kept until its callback has run.

typedef enum {
    FUTURE_MAP,
    FUTURE_WORK_DONE,
    FUTURE_POP_ERROR_SCOPE,
    FUTURE_COMPILATION_INFO,
    FUTURE_RENDER_PIPELINE,
} future_kind_t;

/// Outcomes: 1 success; 2 failure (map, work done, compilation info,
/// pipeline). An error scope settles with its WGPUErrorType (1-5), or:
#define POP_ERROR_SCOPE_FAILED 0x100

typedef struct future {
    uint64_t id;
    future_kind_t kind;
    WGPUCallbackMode mode;
    uint32_t js;
    uint32_t outcome;
    uint32_t object;  // map: the buffer; pipeline: the pipeline
    union {
        WGPUBufferMapCallbackInfo map;
        WGPUQueueWorkDoneCallbackInfo workDone;
        WGPUPopErrorScopeCallbackInfo popErrorScope;
        WGPUCompilationInfoCallbackInfo compilationInfo;
        WGPUCreateRenderPipelineAsyncCallbackInfo renderPipeline;
    } callback;
    struct future *next;
} future_t;

static uint64_t nextFuture = 1;
static future_t *futures;

static future_t *future_make(future_kind_t kind, WGPUCallbackMode mode, uint32_t js, uint32_t outcome) {
    future_t *future = calloc(1, sizeof *future);
    if (!future) return NULL;
    future->id = nextFuture++;
    future->kind = kind;
    future->mode = mode;
    future->js = js;
    future->outcome = js ? 0 : outcome;
    future->next = futures;
    futures = future;
    return future;
}

static future_t *future_find(uint64_t id) {
    for (future_t *future = futures; future; future = future->next) {
        if (future->id == id) return future;
    }
    return NULL;
}

static uint32_t future_outcome(future_t *future) {
    if (!future->outcome && future->js) future->outcome = nwgpu_future_state(future->js);
    return future->outcome;
}

static void map_settled(uint32_t buffer, int mapped);
static void compilation_info_settled(future_t *future);

/// Runs the callback of a settled future and drops it.
static void future_fire(future_t *future) {
    for (future_t **link = &futures; *link; link = &(*link)->next) {
        if (*link == future) {
            *link = future->next;
            break;
        }
    }
    uint32_t outcome = future->outcome;
    switch (future->kind) {
    case FUTURE_MAP: {
        map_settled(future->object, outcome == 1);
        WGPUBufferMapCallbackInfo *info = &future->callback.map;
        if (info->callback) {
            info->callback(outcome == 1 ? WGPUMapAsyncStatus_Success : WGPUMapAsyncStatus_Aborted, noMessage,
                           info->userdata1, info->userdata2);
        }
        break;
    }
    case FUTURE_WORK_DONE: {
        WGPUQueueWorkDoneCallbackInfo *info = &future->callback.workDone;
        if (info->callback) {
            info->callback(outcome == 1 ? WGPUQueueWorkDoneStatus_Success : WGPUQueueWorkDoneStatus_Error, noMessage,
                           info->userdata1, info->userdata2);
        }
        break;
    }
    case FUTURE_POP_ERROR_SCOPE: {
        WGPUPopErrorScopeCallbackInfo *info = &future->callback.popErrorScope;
        if (info->callback) {
            int failed = outcome == POP_ERROR_SCOPE_FAILED;
            info->callback(failed ? WGPUPopErrorScopeStatus_Error : WGPUPopErrorScopeStatus_Success,
                           failed ? WGPUErrorType_Unknown : (WGPUErrorType)outcome, noMessage, info->userdata1,
                           info->userdata2);
        }
        break;
    }
    case FUTURE_COMPILATION_INFO:
        compilation_info_settled(future);
        break;
    case FUTURE_RENDER_PIPELINE: {
        WGPUCreateRenderPipelineAsyncCallbackInfo *info = &future->callback.renderPipeline;
        if (info->callback) {
            info->callback(outcome == 1 ? WGPUCreatePipelineAsyncStatus_Success : WGPUCreatePipelineAsyncStatus_ValidationError,
                           HANDLE(WGPURenderPipeline, future->object), noMessage, info->userdata1, info->userdata2);
        } else if (future->object) {
            nwgpu_release(future->object);
        }
        break;
    }
    }
    if (future->js) nwgpu_future_forget(future->js);
    free(future);
}

/// The future as webgpu.h returns it; an AllowSpontaneous one settled at
/// creation runs its callback now.
static WGPUFuture future_started(future_t *future) {
    if (!future) return (WGPUFuture){0};
    WGPUFuture handle = {future->id};
    if (future->mode == WGPUCallbackMode_AllowSpontaneous && future_outcome(future)) future_fire(future);
    return handle;
}

void wgpuInstanceProcessEvents(WGPUInstance instance) {
    (void)instance;
    // A callback may start or settle others, so look again after each.
    for (;;) {
        future_t *ready = NULL;
        for (future_t *future = futures; future && !ready; future = future->next) {
            if (future->mode != WGPUCallbackMode_WaitAnyOnly && future_outcome(future)) ready = future;
        }
        if (!ready) return;
        future_fire(ready);
    }
}

/// Fires the settled ones among `infos`; whether any completed.
static int wait_poll(size_t count, WGPUFutureWaitInfo *infos) {
    int any = 0;
    for (size_t i = 0; i < count; i++) {
        future_t *future = future_find(infos[i].future.id);
        // Not found: its callback has already run.
        infos[i].completed = !future || future_outcome(future);
        if (future && infos[i].completed) future_fire(future);
        any |= infos[i].completed;
    }
    return any;
}

WGPUWaitStatus wgpuInstanceWaitAny(WGPUInstance instance, size_t futureCount, WGPUFutureWaitInfo *infos, uint64_t timeoutNS) {
    (void)instance;
    if (futureCount && !infos) return WGPUWaitStatus_Error;
    if (wait_poll(futureCount, infos)) return WGPUWaitStatus_Success;
    if (timeoutNS == 0) return WGPUWaitStatus_TimedOut;
    uint32_t stack[16];
    uint32_t *pending = futureCount <= 16 ? stack : malloc(futureCount * sizeof *pending);
    if (!pending) return WGPUWaitStatus_Error;
    uint32_t count = 0;
    for (size_t i = 0; i < futureCount; i++) {
        future_t *future = future_find(infos[i].future.id);
        if (future && future->js) pending[count++] = future->js;
    }
    if (count) nwgpu_future_wait(pending, count, timeoutNS == UINT64_MAX ? -1.0 : (double)timeoutNS / 1e6);
    if (pending != stack) free(pending);
    return wait_poll(futureCount, infos) ? WGPUWaitStatus_Success : WGPUWaitStatus_TimedOut;
}

// MARK: - Instance, adapter, device

// The page acquires the adapter and device before the module starts — a
// browser hands them out only asynchronously — so a request here is already
// answered: its callback runs before the call returns, which webgpu.h allows
// for every callback mode.

WGPUInstance wgpuCreateInstance(const WGPUInstanceDescriptor *descriptor) {
    (void)descriptor;
    return HANDLE(WGPUInstance, nwgpu_instance_create());
}

WGPUFuture wgpuInstanceRequestAdapter(
    WGPUInstance instance, const WGPURequestAdapterOptions *options, WGPURequestAdapterCallbackInfo callbackInfo) {
    (void)instance;
    (void)options;
    uint32_t adapter = nwgpu_adapter_get();
    if (callbackInfo.callback) {
        callbackInfo.callback(adapter ? WGPURequestAdapterStatus_Success : WGPURequestAdapterStatus_Unavailable,
                              HANDLE(WGPUAdapter, adapter), noMessage, callbackInfo.userdata1, callbackInfo.userdata2);
    }
    return (WGPUFuture){nextFuture++};
}

WGPUBool wgpuAdapterHasFeature(WGPUAdapter adapter, WGPUFeatureName feature) {
    (void)adapter;
    return nwgpu_has_feature(0, (uint32_t)feature);
}

WGPUFuture wgpuAdapterRequestDevice(
    WGPUAdapter adapter, const WGPUDeviceDescriptor *descriptor, WGPURequestDeviceCallbackInfo callbackInfo) {
    (void)adapter;
    // There is one device: the one the Vulkan implementation runs on. It was
    // created with every optional feature the bridge uses that the adapter
    // has; asking for one it lacks fails the way a real request would.
    uint32_t device = nwgpu_device_get();
    WGPURequestDeviceStatus status = device ? WGPURequestDeviceStatus_Success : WGPURequestDeviceStatus_Error;
    static const char missing[] = "requested feature is not enabled on the page's WebGPU device";
    WGPUStringView message = noMessage;
    for (size_t i = 0; descriptor && device && i < descriptor->requiredFeatureCount; i++) {
        if (!nwgpu_has_feature(1, (uint32_t)descriptor->requiredFeatures[i])) {
            logf_("wgpuAdapterRequestDevice: feature %u is not available", (unsigned)descriptor->requiredFeatures[i]);
            status = WGPURequestDeviceStatus_Error;
            message = (WGPUStringView){missing, sizeof missing - 1};
            device = 0;
        }
    }
    if (callbackInfo.callback) {
        callbackInfo.callback(status, HANDLE(WGPUDevice, device), message, callbackInfo.userdata1, callbackInfo.userdata2);
    }
    return (WGPUFuture){nextFuture++};
}

WGPUBool wgpuDeviceHasFeature(WGPUDevice device, WGPUFeatureName feature) {
    (void)device;
    return nwgpu_has_feature(1, (uint32_t)feature);
}

WGPUQueue wgpuDeviceGetQueue(WGPUDevice device) {
    (void)device;
    return HANDLE(WGPUQueue, nwgpu_queue_get());
}

/// One of the adapter's strings, in memory wgpuAdapterInfoFreeMembers frees.
static WGPUStringView adapter_string(uint32_t which) {
    uint32_t length = nwgpu_adapter_info(which, NULL, 0);
    char *text = malloc(length + 1);
    if (!text) return noMessage;
    nwgpu_adapter_info(which, text, length);
    text[length] = 0;
    return (WGPUStringView){text, length};
}

WGPUStatus wgpuAdapterGetInfo(WGPUAdapter adapter, WGPUAdapterInfo *info) {
    (void)adapter;
    WGPUChainedStruct *next = info->nextInChain;
    memset(info, 0, sizeof *info);
    info->nextInChain = next;
    info->vendor = adapter_string(0);
    info->architecture = adapter_string(1);
    info->device = adapter_string(2);
    info->description = adapter_string(3);
    // The page does not say which native API is under its WebGPU.
    info->backendType = WGPUBackendType_WebGPU;
    info->adapterType = WGPUAdapterType_Unknown;
    return WGPUStatus_Success;
}

void wgpuAdapterInfoFreeMembers(WGPUAdapterInfo adapterInfo) {
    free((void *)adapterInfo.vendor.data);
    free((void *)adapterInfo.architecture.data);
    free((void *)adapterInfo.device.data);
    free((void *)adapterInfo.description.data);
}

/// WGPULimits' members in declaration order, as nwgpu_limits writes them.
#define LIMITS(X)                                                                                   \
    X(maxTextureDimension1D) X(maxTextureDimension2D) X(maxTextureDimension3D) X(maxTextureArrayLayers) \
    X(maxBindGroups) X(maxBindGroupsPlusVertexBuffers) X(maxBindingsPerBindGroup)                    \
    X(maxDynamicUniformBuffersPerPipelineLayout) X(maxDynamicStorageBuffersPerPipelineLayout)       \
    X(maxSampledTexturesPerShaderStage) X(maxSamplersPerShaderStage) X(maxStorageBuffersPerShaderStage) \
    X(maxStorageTexturesPerShaderStage) X(maxUniformBuffersPerShaderStage) X(maxUniformBufferBindingSize) \
    X(maxStorageBufferBindingSize) X(minUniformBufferOffsetAlignment) X(minStorageBufferOffsetAlignment) \
    X(maxVertexBuffers) X(maxBufferSize) X(maxVertexAttributes) X(maxVertexBufferArrayStride)        \
    X(maxInterStageShaderVariables) X(maxColorAttachments) X(maxColorAttachmentBytesPerSample)       \
    X(maxComputeWorkgroupStorageSize) X(maxComputeInvocationsPerWorkgroup) X(maxComputeWorkgroupSizeX) \
    X(maxComputeWorkgroupSizeY) X(maxComputeWorkgroupSizeZ) X(maxComputeWorkgroupsPerDimension)     \
    X(maxImmediateSize)

/// Chained structures are left as they are: the page has no limits beyond
/// WebGPU's own.
static WGPUStatus get_limits(uint32_t which, WGPULimits *limits) {
#define COUNT(name) +1
    double values[0 LIMITS(COUNT)];
#undef COUNT
    nwgpu_limits(which, values, sizeof values / sizeof *values);
    size_t i = 0;
#define ASSIGN(name) limits->name = (__typeof__(limits->name))values[i++];
    LIMITS(ASSIGN)
#undef ASSIGN
    return WGPUStatus_Success;
}

WGPUStatus wgpuAdapterGetLimits(WGPUAdapter adapter, WGPULimits *limits) {
    (void)adapter;
    return get_limits(0, limits);
}

WGPUStatus wgpuDeviceGetLimits(WGPUDevice device, WGPULimits *limits) {
    (void)device;
    return get_limits(1, limits);
}

void wgpuDevicePushErrorScope(WGPUDevice device, WGPUErrorFilter filter) {
    (void)device;
    nwgpu_push_error_scope((uint32_t)filter);
}

WGPUFuture wgpuDevicePopErrorScope(WGPUDevice device, WGPUPopErrorScopeCallbackInfo callbackInfo) {
    (void)device;
    future_t *future = future_make(FUTURE_POP_ERROR_SCOPE, callbackInfo.mode, nwgpu_pop_error_scope(), POP_ERROR_SCOPE_FAILED);
    if (future) future->callback.popErrorScope = callbackInfo;
    return future_started(future);
}

WGPUFuture wgpuQueueOnSubmittedWorkDone(WGPUQueue queue, WGPUQueueWorkDoneCallbackInfo callbackInfo) {
    (void)queue;
    future_t *future = future_make(FUTURE_WORK_DONE, callbackInfo.mode, nwgpu_queue_work_done(), 2);
    if (future) future->callback.workDone = callbackInfo;
    return future_started(future);
}

// MARK: - Buffers

// A buffer that is mapped, or being mapped. `shadow` is the mapped range in
// wasm memory: written here and sent through the queue at unmap
// (`queueWrite`), or copied from the page's mapping once it lands.

typedef struct mapping {
    uint32_t buffer;
    WGPUBufferMapState state;
    int queueWrite;
    size_t offset, size;
    uint8_t *shadow;
    struct mapping *next;
} mapping_t;

static mapping_t *mappings;

static mapping_t *mapping_find(uint32_t buffer) {
    for (mapping_t *m = mappings; m; m = m->next) {
        if (m->buffer == buffer) return m;
    }
    return NULL;
}

/// writeBuffer moves whole 4-byte words; a shadow covers its range rounded up.
static size_t round4(size_t size) {
    return (size + 3) & ~(size_t)3;
}

static mapping_t *mapping_add(uint32_t buffer, WGPUBufferMapState state, int queueWrite, size_t offset, size_t size) {
    mapping_t *m = calloc(1, sizeof *m);
    if (!m) return NULL;
    m->buffer = buffer;
    m->state = state;
    m->queueWrite = queueWrite;
    m->offset = offset;
    m->size = size;
    if (state == WGPUBufferMapState_Mapped) {
        m->shadow = calloc(1, round4(size) ? round4(size) : 4);
        if (!m->shadow) {
            free(m);
            return NULL;
        }
    }
    m->next = mappings;
    mappings = m;
    return m;
}

static void mapping_remove(uint32_t buffer) {
    for (mapping_t **link = &mappings; *link; link = &(*link)->next) {
        mapping_t *m = *link;
        if (m->buffer == buffer) {
            *link = m->next;
            free(m->shadow);
            free(m);
            return;
        }
    }
}

/// A read mapping the page finished (or failed): its range is copied in.
static void map_settled(uint32_t buffer, int mapped) {
    mapping_t *m = mapping_find(buffer);
    if (!m || m->state != WGPUBufferMapState_Pending) return;
    if (mapped) m->shadow = malloc(m->size ? m->size : 1);
    if (!mapped || !m->shadow) {
        mapping_remove(buffer);
        return;
    }
    nwgpu_buffer_read_mapped(buffer, (double)m->offset, m->shadow, (uint32_t)m->size);
    m->state = WGPUBufferMapState_Mapped;
}

WGPUBuffer wgpuDeviceCreateBuffer(WGPUDevice device, const WGPUBufferDescriptor *descriptor) {
    (void)device;
    int queueWrite = (descriptor->usage & WGPUBufferUsage_MapWrite) || descriptor->mappedAtCreation;
    uint32_t buffer = nwgpu_buffer_create((double)descriptor->size, (uint32_t)descriptor->usage, queueWrite);
    if (buffer && descriptor->mappedAtCreation &&
        !mapping_add(buffer, WGPUBufferMapState_Mapped, 1, 0, (size_t)descriptor->size)) {
        nwgpu_release(buffer);
        return NULL;
    }
    return HANDLE(WGPUBuffer, buffer);
}

void wgpuBufferAddRef(WGPUBuffer buffer) {
    nwgpu_add_ref(ID(buffer));
}

void wgpuBufferRelease(WGPUBuffer buffer) {
    if (buffer && nwgpu_release(ID(buffer))) mapping_remove(ID(buffer));
}

uint64_t wgpuBufferGetSize(WGPUBuffer buffer) {
    return (uint64_t)nwgpu_buffer_get_size(ID(buffer));
}

WGPUBufferUsage wgpuBufferGetUsage(WGPUBuffer buffer) {
    return (WGPUBufferUsage)nwgpu_buffer_get_usage(ID(buffer));
}

void wgpuBufferDestroy(WGPUBuffer buffer) {
    // Destroying unmaps, without writing what was mapped.
    mapping_remove(ID(buffer));
    nwgpu_buffer_destroy(ID(buffer));
}

WGPUBufferMapState wgpuBufferGetMapState(WGPUBuffer buffer) {
    mapping_t *m = mapping_find(ID(buffer));
    return m ? m->state : WGPUBufferMapState_Unmapped;
}

WGPUFuture wgpuBufferMapAsync(
    WGPUBuffer buffer, WGPUMapMode mode, size_t offset, size_t size, WGPUBufferMapCallbackInfo callbackInfo) {
    uint32_t id = ID(buffer);
    if (size == WGPU_WHOLE_MAP_SIZE) {
        size_t whole = (size_t)nwgpu_buffer_get_size(id);
        size = whole > offset ? whole - offset : 0;
    }
    future_t *future;
    if (mapping_find(id)) {
        logf_("wgpuBufferMapAsync: the buffer is already mapped or being mapped");
        future = future_make(FUTURE_MAP, callbackInfo.mode, 0, 2);
    } else if (mode & WGPUMapMode_Write) {
        // Mapped here at once (see the top of the file).
        int mapped = (nwgpu_buffer_get_usage(id) & WGPUBufferUsage_MapWrite) &&
                     mapping_add(id, WGPUBufferMapState_Mapped, 1, offset, size);
        future = future_make(FUTURE_MAP, callbackInfo.mode, 0, mapped ? 1 : 2);
    } else {
        uint32_t js = nwgpu_buffer_map_read(id, (double)offset, (double)size);
        future = future_make(FUTURE_MAP, callbackInfo.mode, js, 2);
        if (js && future) mapping_add(id, WGPUBufferMapState_Pending, 0, offset, size);
    }
    if (!future) return (WGPUFuture){0};
    future->object = id;
    future->callback.map = callbackInfo;
    return future_started(future);
}

static void *mapped_range(WGPUBuffer buffer, size_t offset, size_t size) {
    mapping_t *m = mapping_find(ID(buffer));
    if (!m || m->state != WGPUBufferMapState_Mapped) return NULL;
    if (size == WGPU_WHOLE_MAP_SIZE) size = offset <= m->offset + m->size ? m->offset + m->size - offset : 0;
    if (offset < m->offset || offset + size > m->offset + m->size) return NULL;
    return m->shadow + (offset - m->offset);
}

void *wgpuBufferGetMappedRange(WGPUBuffer buffer, size_t offset, size_t size) {
    mapping_t *m = mapping_find(ID(buffer));
    return m && m->queueWrite ? mapped_range(buffer, offset, size) : NULL;
}

void const *wgpuBufferGetConstMappedRange(WGPUBuffer buffer, size_t offset, size_t size) {
    return mapped_range(buffer, offset, size);
}

void wgpuBufferUnmap(WGPUBuffer buffer) {
    uint32_t id = ID(buffer);
    mapping_t *m = mapping_find(id);
    if (!m) return;
    if (m->queueWrite) {
        // Queue-ordered: before any later submit that reads the buffer.
        nwgpu_queue_write_buffer(id, (double)m->offset, m->shadow, (uint32_t)round4(m->size));
    } else {
        // Also cancels a pending map, whose callback then reports it aborted.
        nwgpu_buffer_unmap(id);
    }
    mapping_remove(id);
}

// MARK: - Textures and views

/// usage, dimension, width, height, depthOrArrayLayers, format,
/// mipLevelCount, sampleCount, viewFormatCount, viewFormats…
WGPUTexture wgpuDeviceCreateTexture(WGPUDevice device, const WGPUTextureDescriptor *descriptor) {
    (void)device;
    words_t w = {0};
    put(&w, (uint32_t)descriptor->usage);
    put(&w, (uint32_t)descriptor->dimension);
    put(&w, descriptor->size.width);
    put(&w, descriptor->size.height);
    put(&w, descriptor->size.depthOrArrayLayers);
    put(&w, (uint32_t)descriptor->format);
    put(&w, descriptor->mipLevelCount);
    put(&w, descriptor->sampleCount);
    put(&w, (uint32_t)descriptor->viewFormatCount);
    for (size_t i = 0; i < descriptor->viewFormatCount; i++) put(&w, (uint32_t)descriptor->viewFormats[i]);
    return HANDLE(WGPUTexture, finish(&w, nwgpu_texture_create));
}

uint32_t wgpuTextureGetWidth(WGPUTexture texture) { return nwgpu_texture_get(ID(texture), 0); }
uint32_t wgpuTextureGetHeight(WGPUTexture texture) { return nwgpu_texture_get(ID(texture), 1); }
uint32_t wgpuTextureGetDepthOrArrayLayers(WGPUTexture texture) { return nwgpu_texture_get(ID(texture), 2); }
uint32_t wgpuTextureGetMipLevelCount(WGPUTexture texture) { return nwgpu_texture_get(ID(texture), 3); }
uint32_t wgpuTextureGetSampleCount(WGPUTexture texture) { return nwgpu_texture_get(ID(texture), 4); }
WGPUTextureDimension wgpuTextureGetDimension(WGPUTexture texture) { return (WGPUTextureDimension)nwgpu_texture_get(ID(texture), 5); }
WGPUTextureFormat wgpuTextureGetFormat(WGPUTexture texture) { return (WGPUTextureFormat)nwgpu_texture_get(ID(texture), 6); }
WGPUTextureUsage wgpuTextureGetUsage(WGPUTexture texture) { return (WGPUTextureUsage)nwgpu_texture_get(ID(texture), 7); }

void wgpuTextureDestroy(WGPUTexture texture) {
    nwgpu_texture_destroy(ID(texture));
}

/// Empty for a NULL descriptor (every default); otherwise format, dimension,
/// baseMipLevel, mipLevelCount, baseArrayLayer, arrayLayerCount, aspect, usage.
WGPUTextureView wgpuTextureCreateView(WGPUTexture texture, const WGPUTextureViewDescriptor *descriptor) {
    if (!descriptor) return HANDLE(WGPUTextureView, nwgpu_texture_create_view(ID(texture), NULL, 0));
    const uint32_t words[] = {
        (uint32_t)descriptor->format,
        (uint32_t)descriptor->dimension,
        descriptor->baseMipLevel,
        descriptor->mipLevelCount,
        descriptor->baseArrayLayer,
        descriptor->arrayLayerCount,
        (uint32_t)descriptor->aspect,
        (uint32_t)descriptor->usage,
    };
    return HANDLE(WGPUTextureView, nwgpu_texture_create_view(ID(texture), words, sizeof words / sizeof *words));
}

// MARK: - Samplers

/// Empty for a NULL descriptor; otherwise addressModeU/V/W, magFilter,
/// minFilter, mipmapFilter, lodMinClamp (f32), lodMaxClamp (f32), compare,
/// maxAnisotropy.
WGPUSampler wgpuDeviceCreateSampler(WGPUDevice device, const WGPUSamplerDescriptor *descriptor) {
    (void)device;
    if (!descriptor) return HANDLE(WGPUSampler, nwgpu_sampler_create(NULL, 0));
    words_t w = {0};
    put(&w, (uint32_t)descriptor->addressModeU);
    put(&w, (uint32_t)descriptor->addressModeV);
    put(&w, (uint32_t)descriptor->addressModeW);
    put(&w, (uint32_t)descriptor->magFilter);
    put(&w, (uint32_t)descriptor->minFilter);
    put(&w, (uint32_t)descriptor->mipmapFilter);
    put_f32(&w, descriptor->lodMinClamp);
    put_f32(&w, descriptor->lodMaxClamp);
    put(&w, (uint32_t)descriptor->compare);
    put(&w, descriptor->maxAnisotropy);
    return HANDLE(WGPUSampler, finish(&w, nwgpu_sampler_create));
}

// MARK: - Bind groups and layouts

/// count, then per entry: binding, visibility, bindingArraySize,
/// buffer.type, buffer.hasDynamicOffset, buffer.minBindingSize (f64),
/// sampler.type, texture.sampleType, texture.viewDimension,
/// texture.multisampled, storageTexture.access, storageTexture.format,
/// storageTexture.viewDimension.
WGPUBindGroupLayout wgpuDeviceCreateBindGroupLayout(WGPUDevice device, const WGPUBindGroupLayoutDescriptor *descriptor) {
    (void)device;
    words_t w = {0};
    put(&w, (uint32_t)descriptor->entryCount);
    for (size_t i = 0; i < descriptor->entryCount; i++) {
        const WGPUBindGroupLayoutEntry *e = &descriptor->entries[i];
        put(&w, e->binding);
        put(&w, (uint32_t)e->visibility);
        put(&w, e->bindingArraySize);
        put(&w, (uint32_t)e->buffer.type);
        put(&w, e->buffer.hasDynamicOffset);
        put_f64(&w, (double)e->buffer.minBindingSize);
        put(&w, (uint32_t)e->sampler.type);
        put(&w, (uint32_t)e->texture.sampleType);
        put(&w, (uint32_t)e->texture.viewDimension);
        put(&w, e->texture.multisampled);
        put(&w, (uint32_t)e->storageTexture.access);
        put(&w, (uint32_t)e->storageTexture.format);
        put(&w, (uint32_t)e->storageTexture.viewDimension);
    }
    return HANDLE(WGPUBindGroupLayout, finish(&w, nwgpu_bind_group_layout_create));
}

/// layout, count, then per entry: binding, buffer, offset (f64), size (f64,
/// -1 for the whole buffer), sampler, textureView.
WGPUBindGroup wgpuDeviceCreateBindGroup(WGPUDevice device, const WGPUBindGroupDescriptor *descriptor) {
    (void)device;
    words_t w = {0};
    put(&w, ID(descriptor->layout));
    put(&w, (uint32_t)descriptor->entryCount);
    for (size_t i = 0; i < descriptor->entryCount; i++) {
        const WGPUBindGroupEntry *e = &descriptor->entries[i];
        put(&w, e->binding);
        put(&w, ID(e->buffer));
        put_f64(&w, (double)e->offset);
        put_f64(&w, size64(e->size));
        put(&w, ID(e->sampler));
        put(&w, ID(e->textureView));
    }
    return HANDLE(WGPUBindGroup, finish(&w, nwgpu_bind_group_create));
}

/// count, then the bind group layouts.
WGPUPipelineLayout wgpuDeviceCreatePipelineLayout(WGPUDevice device, const WGPUPipelineLayoutDescriptor *descriptor) {
    (void)device;
    if (descriptor->immediateSize) {
        logf_("wgpuDeviceCreatePipelineLayout: immediates are not available in browser WebGPU");
        return NULL;
    }
    words_t w = {0};
    put(&w, (uint32_t)descriptor->bindGroupLayoutCount);
    for (size_t i = 0; i < descriptor->bindGroupLayoutCount; i++) put(&w, ID(descriptor->bindGroupLayouts[i]));
    return HANDLE(WGPUPipelineLayout, finish(&w, nwgpu_pipeline_layout_create));
}

// MARK: - Shaders and pipelines

WGPUShaderModule wgpuDeviceCreateShaderModule(WGPUDevice device, const WGPUShaderModuleDescriptor *descriptor) {
    (void)device;
    for (const WGPUChainedStruct *chain = descriptor->nextInChain; chain; chain = chain->next) {
        if (chain->sType == WGPUSType_ShaderSourceWGSL) {
            const WGPUShaderSourceWGSL *source = (const WGPUShaderSourceWGSL *)chain;
            return HANDLE(WGPUShaderModule,
                          nwgpu_shader_module_create(source->code.data, (uint32_t)string_length(source->code)));
        }
    }
    // Browsers take WGSL only.
    logf_("wgpuDeviceCreateShaderModule: only WGSL sources are available in browser WebGPU");
    return NULL;
}

/// module, entryPoint (string), constants.
static void put_stage(words_t *w, WGPUShaderModule module, WGPUStringView entryPoint, size_t constantCount,
                      const WGPUConstantEntry *constants) {
    put(w, ID(module));
    put_string(w, entryPoint);
    put_constants(w, constantCount, constants);
}

static void put_blend_component(words_t *w, WGPUBlendComponent component) {
    put(w, (uint32_t)component.operation);
    put(w, (uint32_t)component.srcFactor);
    put(w, (uint32_t)component.dstFactor);
}

static void put_stencil_face(words_t *w, WGPUStencilFaceState face) {
    put(w, (uint32_t)face.compare);
    put(w, (uint32_t)face.failOp);
    put(w, (uint32_t)face.depthFailOp);
    put(w, (uint32_t)face.passOp);
}

/// layout,
/// vertex stage, bufferCount, per buffer: stepMode, arrayStride (f64),
///   attributeCount, per attribute: format, offset (f64), shaderLocation,
/// primitive: topology, stripIndexFormat, frontFace, cullMode, unclippedDepth,
/// hasDepthStencil [format, depthWriteEnabled, depthCompare, stencilFront (4),
///   stencilBack (4), stencilReadMask, stencilWriteMask, depthBias,
///   depthBiasSlopeScale (f32), depthBiasClamp (f32)],
/// multisample: count, mask, alphaToCoverageEnabled,
/// hasFragment [fragment stage, targetCount, per target: format, hasBlend
///   [color (3), alpha (3)], writeMask].
WGPURenderPipeline wgpuDeviceCreateRenderPipeline(WGPUDevice device, const WGPURenderPipelineDescriptor *descriptor) {
    (void)device;
    words_t w = {0};
    put(&w, ID(descriptor->layout));

    const WGPUVertexState *vertex = &descriptor->vertex;
    put_stage(&w, vertex->module, vertex->entryPoint, vertex->constantCount, vertex->constants);
    put(&w, (uint32_t)vertex->bufferCount);
    for (size_t i = 0; i < vertex->bufferCount; i++) {
        const WGPUVertexBufferLayout *buffer = &vertex->buffers[i];
        put(&w, (uint32_t)buffer->stepMode);
        put_f64(&w, (double)buffer->arrayStride);
        put(&w, (uint32_t)buffer->attributeCount);
        for (size_t a = 0; a < buffer->attributeCount; a++) {
            put(&w, (uint32_t)buffer->attributes[a].format);
            put_f64(&w, (double)buffer->attributes[a].offset);
            put(&w, buffer->attributes[a].shaderLocation);
        }
    }

    const WGPUPrimitiveState *primitive = &descriptor->primitive;
    put(&w, (uint32_t)primitive->topology);
    put(&w, (uint32_t)primitive->stripIndexFormat);
    put(&w, (uint32_t)primitive->frontFace);
    put(&w, (uint32_t)primitive->cullMode);
    put(&w, primitive->unclippedDepth);

    const WGPUDepthStencilState *depthStencil = descriptor->depthStencil;
    put(&w, depthStencil != NULL);
    if (depthStencil) {
        put(&w, (uint32_t)depthStencil->format);
        put(&w, (uint32_t)depthStencil->depthWriteEnabled);
        put(&w, (uint32_t)depthStencil->depthCompare);
        put_stencil_face(&w, depthStencil->stencilFront);
        put_stencil_face(&w, depthStencil->stencilBack);
        put(&w, depthStencil->stencilReadMask);
        put(&w, depthStencil->stencilWriteMask);
        put(&w, (uint32_t)depthStencil->depthBias);
        put_f32(&w, depthStencil->depthBiasSlopeScale);
        put_f32(&w, depthStencil->depthBiasClamp);
    }

    put(&w, descriptor->multisample.count);
    put(&w, descriptor->multisample.mask);
    put(&w, descriptor->multisample.alphaToCoverageEnabled);

    const WGPUFragmentState *fragment = descriptor->fragment;
    put(&w, fragment != NULL);
    if (fragment) {
        put_stage(&w, fragment->module, fragment->entryPoint, fragment->constantCount, fragment->constants);
        put(&w, (uint32_t)fragment->targetCount);
        for (size_t i = 0; i < fragment->targetCount; i++) {
            const WGPUColorTargetState *target = &fragment->targets[i];
            put(&w, (uint32_t)target->format);
            put(&w, target->blend != NULL);
            if (target->blend) {
                put_blend_component(&w, target->blend->color);
                put_blend_component(&w, target->blend->alpha);
            }
            put(&w, (uint32_t)target->writeMask);
        }
    }
    return HANDLE(WGPURenderPipeline, finish(&w, nwgpu_render_pipeline_create));
}

/// layout, compute stage.
WGPUComputePipeline wgpuDeviceCreateComputePipeline(WGPUDevice device, const WGPUComputePipelineDescriptor *descriptor) {
    (void)device;
    words_t w = {0};
    put(&w, ID(descriptor->layout));
    put_stage(&w, descriptor->compute.module, descriptor->compute.entryPoint, descriptor->compute.constantCount,
              descriptor->compute.constants);
    return HANDLE(WGPUComputePipeline, finish(&w, nwgpu_compute_pipeline_create));
}

/// Created at once: a browser creates pipelines asynchronously behind the
/// synchronous call and waits for them itself at submit.
WGPUFuture wgpuDeviceCreateRenderPipelineAsync(
    WGPUDevice device, const WGPURenderPipelineDescriptor *descriptor, WGPUCreateRenderPipelineAsyncCallbackInfo callbackInfo) {
    WGPURenderPipeline pipeline = wgpuDeviceCreateRenderPipeline(device, descriptor);
    future_t *future = future_make(FUTURE_RENDER_PIPELINE, callbackInfo.mode, 0, pipeline ? 1 : 2);
    if (!future) {
        wgpuRenderPipelineRelease(pipeline);
        return (WGPUFuture){0};
    }
    future->object = ID(pipeline);
    future->callback.renderPipeline = callbackInfo;
    return future_started(future);
}

WGPUBindGroupLayout wgpuRenderPipelineGetBindGroupLayout(WGPURenderPipeline renderPipeline, uint32_t groupIndex) {
    return HANDLE(WGPUBindGroupLayout, nwgpu_pipeline_bind_group_layout(ID(renderPipeline), groupIndex));
}

WGPUFuture wgpuShaderModuleGetCompilationInfo(WGPUShaderModule shaderModule, WGPUCompilationInfoCallbackInfo callbackInfo) {
    // Without a future (the page cannot block) it settles at once with no
    // messages; an error in the shader still reaches the console as the
    // device's uncaptured error.
    future_t *future = future_make(FUTURE_COMPILATION_INFO, callbackInfo.mode, nwgpu_compilation_info(ID(shaderModule)), 1);
    if (future) future->callback.compilationInfo = callbackInfo;
    return future_started(future);
}

/// Words per message from nwgpu_compilation_messages.
#define MESSAGE_WORDS 6

static void compilation_info_settled(future_t *future) {
    WGPUCompilationInfoCallbackInfo *callbackInfo = &future->callback.compilationInfo;
    if (!callbackInfo->callback) return;
    if (future->outcome != 1) {
        callbackInfo->callback(WGPUCompilationInfoRequestStatus_CallbackCancelled, NULL, callbackInfo->userdata1,
                               callbackInfo->userdata2);
        return;
    }
    uint32_t count = future->js ? nwgpu_compilation_messages(future->js, NULL, 0) : 0;
    uint32_t *words = count ? malloc(count * MESSAGE_WORDS * sizeof *words) : NULL;
    WGPUCompilationMessage *messages = count ? calloc(count, sizeof *messages) : NULL;
    if (count && (!words || !messages)) count = 0;
    if (count) nwgpu_compilation_messages(future->js, words, count);
    for (uint32_t i = 0; i < count; i++) {
        const uint32_t *w = &words[i * MESSAGE_WORDS];
        char *text = malloc(w[5] + 1);
        if (text) {
            nwgpu_compilation_message_text(future->js, i, text, w[5]);
            text[w[5]] = 0;
        }
        messages[i].type = (WGPUCompilationMessageType)w[0];
        messages[i].lineNum = w[1];
        messages[i].linePos = w[2];
        messages[i].offset = w[3];
        messages[i].length = w[4];
        messages[i].message = (WGPUStringView){text, text ? w[5] : 0};
    }
    WGPUCompilationInfo info = {NULL, count, messages};
    callbackInfo->callback(WGPUCompilationInfoRequestStatus_Success, &info, callbackInfo->userdata1, callbackInfo->userdata2);
    for (uint32_t i = 0; i < count; i++) free((void *)messages[i].message.data);
    free(messages);
    free(words);
}

// MARK: - Queries

WGPUQuerySet wgpuDeviceCreateQuerySet(WGPUDevice device, const WGPUQuerySetDescriptor *descriptor) {
    (void)device;
    return HANDLE(WGPUQuerySet, nwgpu_query_set_create((uint32_t)descriptor->type, descriptor->count));
}

void wgpuCommandEncoderResolveQuerySet(
    WGPUCommandEncoder commandEncoder, WGPUQuerySet querySet, uint32_t firstQuery, uint32_t queryCount,
    WGPUBuffer destination, uint64_t destinationOffset) {
    nwgpu_resolve_query_set(ID(commandEncoder), ID(querySet), firstQuery, queryCount, ID(destination),
                            (double)destinationOffset);
}

void wgpuCommandEncoderWriteTimestamp(WGPUCommandEncoder commandEncoder, WGPUQuerySet querySet, uint32_t queryIndex) {
    (void)commandEncoder;
    (void)querySet;
    (void)queryIndex;
    // Browsers time passes only (a pass descriptor's timestampWrites).
    logf_("wgpuCommandEncoderWriteTimestamp: not available in browser WebGPU");
}

// MARK: - Command encoding

WGPUCommandEncoder wgpuDeviceCreateCommandEncoder(WGPUDevice device, const WGPUCommandEncoderDescriptor *descriptor) {
    (void)device;
    (void)descriptor;
    return HANDLE(WGPUCommandEncoder, nwgpu_command_encoder_create());
}

/// colorCount, per attachment: view, depthSlice, resolveTarget, loadOp,
///   storeOp, clearValue (4 × f64),
/// hasDepthStencil [view, depthLoadOp, depthStoreOp, depthClearValue (f32),
///   depthReadOnly, stencilLoadOp, stencilStoreOp, stencilClearValue,
///   stencilReadOnly].
WGPURenderPassEncoder wgpuCommandEncoderBeginRenderPass(
    WGPUCommandEncoder commandEncoder, const WGPURenderPassDescriptor *descriptor) {
    if (descriptor->occlusionQuerySet || descriptor->timestampWrites) {
        logf_("wgpuCommandEncoderBeginRenderPass: query sets are not supported on WebAssembly");
        return NULL;
    }
    words_t w = {0};
    put(&w, (uint32_t)descriptor->colorAttachmentCount);
    for (size_t i = 0; i < descriptor->colorAttachmentCount; i++) {
        const WGPURenderPassColorAttachment *a = &descriptor->colorAttachments[i];
        put(&w, ID(a->view));
        put(&w, a->depthSlice);
        put(&w, ID(a->resolveTarget));
        put(&w, (uint32_t)a->loadOp);
        put(&w, (uint32_t)a->storeOp);
        put_f64(&w, a->clearValue.r);
        put_f64(&w, a->clearValue.g);
        put_f64(&w, a->clearValue.b);
        put_f64(&w, a->clearValue.a);
    }
    const WGPURenderPassDepthStencilAttachment *ds = descriptor->depthStencilAttachment;
    put(&w, ds != NULL);
    if (ds) {
        put(&w, ID(ds->view));
        put(&w, (uint32_t)ds->depthLoadOp);
        put(&w, (uint32_t)ds->depthStoreOp);
        put_f32(&w, ds->depthClearValue);
        put(&w, ds->depthReadOnly);
        put(&w, (uint32_t)ds->stencilLoadOp);
        put(&w, (uint32_t)ds->stencilStoreOp);
        put(&w, ds->stencilClearValue);
        put(&w, ds->stencilReadOnly);
    }
    uint32_t pass = w.failed ? 0 : nwgpu_begin_render_pass(ID(commandEncoder), w.words, w.count);
    free(w.words);
    return HANDLE(WGPURenderPassEncoder, pass);
}

void wgpuCommandEncoderCopyBufferToBuffer(
    WGPUCommandEncoder commandEncoder, WGPUBuffer source, uint64_t sourceOffset, WGPUBuffer destination,
    uint64_t destinationOffset, uint64_t size) {
    nwgpu_copy_buffer_to_buffer(ID(commandEncoder), ID(source), (double)sourceOffset, ID(destination),
                                (double)destinationOffset, size64(size));
}

static void put_copy_texture(words_t *w, const WGPUTexelCopyTextureInfo *info) {
    put(w, ID(info->texture));
    put(w, info->mipLevel);
    put(w, info->origin.x);
    put(w, info->origin.y);
    put(w, info->origin.z);
    put(w, (uint32_t)info->aspect);
}

/// source (texture, mipLevel, x, y, z, aspect), destination (same),
/// width, height, depthOrArrayLayers.
void wgpuCommandEncoderCopyTextureToTexture(
    WGPUCommandEncoder commandEncoder, const WGPUTexelCopyTextureInfo *source,
    const WGPUTexelCopyTextureInfo *destination, const WGPUExtent3D *copySize) {
    uint32_t words[15];
    words_t w = {words, 0, 15, 0};
    put_copy_texture(&w, source);
    put_copy_texture(&w, destination);
    put(&w, copySize->width);
    put(&w, copySize->height);
    put(&w, copySize->depthOrArrayLayers);
    nwgpu_copy_texture_to_texture(ID(commandEncoder), words, w.count);
}

static void put_copy_buffer(words_t *w, const WGPUTexelCopyBufferInfo *info) {
    put(w, ID(info->buffer));
    put_f64(w, (double)info->layout.offset);
    put(w, info->layout.bytesPerRow);
    put(w, info->layout.rowsPerImage);
}

/// source (buffer, offset (f64), bytesPerRow, rowsPerImage), destination
/// (texture, mipLevel, x, y, z, aspect), width, height, depthOrArrayLayers.
void wgpuCommandEncoderCopyBufferToTexture(
    WGPUCommandEncoder commandEncoder, const WGPUTexelCopyBufferInfo *source,
    const WGPUTexelCopyTextureInfo *destination, const WGPUExtent3D *copySize) {
    uint32_t words[14];
    words_t w = {words, 0, 14, 0};
    put_copy_buffer(&w, source);
    put_copy_texture(&w, destination);
    put(&w, copySize->width);
    put(&w, copySize->height);
    put(&w, copySize->depthOrArrayLayers);
    nwgpu_copy_buffer_to_texture(ID(commandEncoder), words, w.count);
}

/// source (texture, mipLevel, x, y, z, aspect), destination (buffer, offset
/// (f64), bytesPerRow, rowsPerImage), width, height, depthOrArrayLayers.
void wgpuCommandEncoderCopyTextureToBuffer(
    WGPUCommandEncoder commandEncoder, const WGPUTexelCopyTextureInfo *source,
    const WGPUTexelCopyBufferInfo *destination, const WGPUExtent3D *copySize) {
    uint32_t words[14];
    words_t w = {words, 0, 14, 0};
    put_copy_texture(&w, source);
    put_copy_buffer(&w, destination);
    put(&w, copySize->width);
    put(&w, copySize->height);
    put(&w, copySize->depthOrArrayLayers);
    nwgpu_copy_texture_to_buffer(ID(commandEncoder), words, w.count);
}

void wgpuCommandEncoderClearBuffer(WGPUCommandEncoder commandEncoder, WGPUBuffer buffer, uint64_t offset, uint64_t size) {
    nwgpu_clear_buffer(ID(commandEncoder), ID(buffer), (double)offset, size64(size));
}

/// hasTimestampWrites [querySet, beginningOfPassWriteIndex, endOfPassWriteIndex].
WGPUComputePassEncoder wgpuCommandEncoderBeginComputePass(
    WGPUCommandEncoder commandEncoder, const WGPUComputePassDescriptor *descriptor) {
    uint32_t words[4];
    words_t w = {words, 0, 4, 0};
    const WGPUPassTimestampWrites *timestamps = descriptor ? descriptor->timestampWrites : NULL;
    put(&w, timestamps != NULL);
    if (timestamps) {
        put(&w, ID(timestamps->querySet));
        put(&w, timestamps->beginningOfPassWriteIndex);
        put(&w, timestamps->endOfPassWriteIndex);
    }
    return HANDLE(WGPUComputePassEncoder, nwgpu_begin_compute_pass(ID(commandEncoder), words, w.count));
}

// MARK: - Compute passes

void wgpuComputePassEncoderSetPipeline(WGPUComputePassEncoder pass, WGPUComputePipeline pipeline) {
    nwgpu_pass_set_pipeline(ID(pass), ID(pipeline));
}

void wgpuComputePassEncoderSetBindGroup(
    WGPUComputePassEncoder pass, uint32_t groupIndex, WGPUBindGroup group, size_t dynamicOffsetCount,
    const uint32_t *dynamicOffsets) {
    nwgpu_pass_set_bind_group(ID(pass), groupIndex, ID(group), (uint32_t)dynamicOffsetCount, dynamicOffsets);
}

void wgpuComputePassEncoderDispatchWorkgroups(WGPUComputePassEncoder pass, uint32_t x, uint32_t y, uint32_t z) {
    nwgpu_dispatch(ID(pass), x, y, z);
}

void wgpuComputePassEncoderDispatchWorkgroupsIndirect(WGPUComputePassEncoder pass, WGPUBuffer indirectBuffer, uint64_t indirectOffset) {
    nwgpu_dispatch_indirect(ID(pass), ID(indirectBuffer), (double)indirectOffset);
}

void wgpuComputePassEncoderEnd(WGPUComputePassEncoder pass) {
    nwgpu_pass_end(ID(pass));
}

WGPUCommandBuffer wgpuCommandEncoderFinish(WGPUCommandEncoder commandEncoder, const WGPUCommandBufferDescriptor *descriptor) {
    (void)descriptor;
    return HANDLE(WGPUCommandBuffer, nwgpu_encoder_finish(ID(commandEncoder)));
}

// MARK: - Render passes

void wgpuRenderPassEncoderSetPipeline(WGPURenderPassEncoder pass, WGPURenderPipeline pipeline) {
    nwgpu_pass_set_pipeline(ID(pass), ID(pipeline));
}

void wgpuRenderPassEncoderSetBindGroup(
    WGPURenderPassEncoder pass, uint32_t groupIndex, WGPUBindGroup group, size_t dynamicOffsetCount,
    const uint32_t *dynamicOffsets) {
    nwgpu_pass_set_bind_group(ID(pass), groupIndex, ID(group), (uint32_t)dynamicOffsetCount, dynamicOffsets);
}

void wgpuRenderPassEncoderSetStencilReference(WGPURenderPassEncoder pass, uint32_t reference) {
    nwgpu_pass_set_stencil_reference(ID(pass), reference);
}

void wgpuRenderPassEncoderSetScissorRect(WGPURenderPassEncoder pass, uint32_t x, uint32_t y, uint32_t width, uint32_t height) {
    nwgpu_pass_set_scissor_rect(ID(pass), x, y, width, height);
}

void wgpuRenderPassEncoderSetViewport(
    WGPURenderPassEncoder pass, float x, float y, float width, float height, float minDepth, float maxDepth) {
    nwgpu_pass_set_viewport(ID(pass), x, y, width, height, minDepth, maxDepth);
}

void wgpuRenderPassEncoderSetBlendConstant(WGPURenderPassEncoder pass, const WGPUColor *color) {
    nwgpu_pass_set_blend_constant(ID(pass), color->r, color->g, color->b, color->a);
}

void wgpuRenderPassEncoderSetVertexBuffer(
    WGPURenderPassEncoder pass, uint32_t slot, WGPUBuffer buffer, uint64_t offset, uint64_t size) {
    nwgpu_pass_set_vertex_buffer(ID(pass), slot, ID(buffer), (double)offset, size64(size));
}

void wgpuRenderPassEncoderSetIndexBuffer(
    WGPURenderPassEncoder pass, WGPUBuffer buffer, WGPUIndexFormat format, uint64_t offset, uint64_t size) {
    nwgpu_pass_set_index_buffer(ID(pass), ID(buffer), (uint32_t)format, (double)offset, size64(size));
}

void wgpuRenderPassEncoderDraw(
    WGPURenderPassEncoder pass, uint32_t vertexCount, uint32_t instanceCount, uint32_t firstVertex, uint32_t firstInstance) {
    nwgpu_pass_draw(ID(pass), vertexCount, instanceCount, firstVertex, firstInstance);
}

void wgpuRenderPassEncoderDrawIndexed(
    WGPURenderPassEncoder pass, uint32_t indexCount, uint32_t instanceCount, uint32_t firstIndex, int32_t baseVertex,
    uint32_t firstInstance) {
    nwgpu_pass_draw_indexed(ID(pass), indexCount, instanceCount, firstIndex, baseVertex, firstInstance);
}

void wgpuRenderPassEncoderDrawIndirect(WGPURenderPassEncoder pass, WGPUBuffer indirectBuffer, uint64_t indirectOffset) {
    nwgpu_pass_draw_indirect(ID(pass), ID(indirectBuffer), (double)indirectOffset, 0);
}

void wgpuRenderPassEncoderDrawIndexedIndirect(WGPURenderPassEncoder pass, WGPUBuffer indirectBuffer, uint64_t indirectOffset) {
    nwgpu_pass_draw_indirect(ID(pass), ID(indirectBuffer), (double)indirectOffset, 1);
}

void wgpuRenderPassEncoderSetImmediates(WGPURenderPassEncoder pass, uint32_t offset, const void *data, size_t size) {
    (void)pass;
    (void)offset;
    (void)data;
    (void)size;
    // As wgpuDeviceCreatePipelineLayout says, no pipeline here has any.
    logf_("wgpuRenderPassEncoderSetImmediates: immediates are not available in browser WebGPU");
}

void wgpuRenderPassEncoderEnd(WGPURenderPassEncoder pass) {
    nwgpu_pass_end(ID(pass));
}

// MARK: - Queue

void wgpuQueueSubmit(WGPUQueue queue, size_t commandCount, const WGPUCommandBuffer *commands) {
    (void)queue;
    uint32_t stack[16];
    uint32_t *ids = commandCount <= 16 ? stack : malloc(commandCount * sizeof *ids);
    if (!ids) return;
    for (size_t i = 0; i < commandCount; i++) ids[i] = ID(commands[i]);
    nwgpu_queue_submit((uint32_t)commandCount, ids);
    if (ids != stack) free(ids);
}

void wgpuQueueWriteBuffer(WGPUQueue queue, WGPUBuffer buffer, uint64_t bufferOffset, const void *data, size_t size) {
    (void)queue;
    nwgpu_queue_write_buffer(ID(buffer), (double)bufferOffset, data, (uint32_t)size);
}

/// destination (texture, mipLevel, x, y, z, aspect), layout: offset (f64),
/// bytesPerRow, rowsPerImage, then width, height, depthOrArrayLayers.
void wgpuQueueWriteTexture(
    WGPUQueue queue, const WGPUTexelCopyTextureInfo *destination, const void *data, size_t dataSize,
    const WGPUTexelCopyBufferLayout *dataLayout, const WGPUExtent3D *writeSize) {
    (void)queue;
    uint32_t words[14];
    words_t w = {words, 0, 14, 0};
    put_copy_texture(&w, destination);
    put_f64(&w, (double)dataLayout->offset);
    put(&w, dataLayout->bytesPerRow);
    put(&w, dataLayout->rowsPerImage);
    put(&w, writeSize->width);
    put(&w, writeSize->height);
    put(&w, writeSize->depthOrArrayLayers);
    nwgpu_queue_write_texture(words, w.count, data, (uint32_t)dataSize);
}

// MARK: - Surfaces

// A WGPUSurface would present into a <canvas>; on this platform windows
// present through Vulkan (VK_NUCLEANT_webgpu_surface), and webgpu.h targets
// are textures. No surface can be created, so the calls that take one only
// say so.

WGPUSurface wgpuInstanceCreateSurface(WGPUInstance instance, const WGPUSurfaceDescriptor *descriptor) {
    (void)instance;
    (void)descriptor;
    logf_("wgpuInstanceCreateSurface: not available on WebAssembly; render into a texture instead");
    return NULL;
}

void wgpuSurfaceConfigure(WGPUSurface surface, const WGPUSurfaceConfiguration *config) {
    (void)surface;
    (void)config;
    logf_("wgpuSurfaceConfigure: not available on WebAssembly");
}

void wgpuSurfaceGetCurrentTexture(WGPUSurface surface, WGPUSurfaceTexture *surfaceTexture) {
    (void)surface;
    surfaceTexture->texture = NULL;
    surfaceTexture->status = WGPUSurfaceGetCurrentTextureStatus_Error;
}

void wgpuSurfaceUnconfigure(WGPUSurface surface) {
    (void)surface;
}

#endif /* __wasm__ */
