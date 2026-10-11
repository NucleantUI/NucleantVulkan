// nucleant-wgpu.js — the WebGPU half of webgpu.h on WebAssembly.
//
// Sources/CWgpuWasm implements webgpu.h — the C API ThorVG's wg engine and
// NucleantVulkan's WgpuContext call, which wgpu-native provides everywhere
// else — and reaches the browser through the imports of the "nucleant_wgpu"
// module defined here. They are part of the bridge in nucleant-webgpu.js:
// the same GPUDevice and the same table of objects as the Vulkan
// implementation, so a texture made through webgpu.h can be imported as a
// VkImage (VK_NUCLEANT_webgpu_objects) and the two APIs' submissions reach
// one GPUQueue in call order.
//
// Objects made here are reference counted (webgpu.h's AddRef/Release); a
// buffer or texture is destroyed with its last reference. The C side hands
// descriptors over as flat word lists; each decoder below reads its list in
// the order webgpu_wasm.c documents and writes it.

// webgpu.h enum value -> WebGPU string, generated from webgpu.h (the values
// are the header's; a missing one is "undefined" — the default — or not
// available in a browser).
const TEXTURE_FORMAT = [
  undefined, 'r8unorm', 'r8snorm', 'r8uint', 'r8sint', 'r16unorm', 'r16snorm', 'r16uint', 'r16sint', 'r16float',
  'rg8unorm', 'rg8snorm', 'rg8uint', 'rg8sint', 'r32float', 'r32uint', 'r32sint', 'rg16unorm', 'rg16snorm',
  'rg16uint', 'rg16sint', 'rg16float', 'rgba8unorm', 'rgba8unorm-srgb', 'rgba8snorm', 'rgba8uint', 'rgba8sint',
  'bgra8unorm', 'bgra8unorm-srgb', 'rgb10a2uint', 'rgb10a2unorm', 'rg11b10ufloat', 'rgb9e5ufloat', 'rg32float',
  'rg32uint', 'rg32sint', 'rgba16unorm', 'rgba16snorm', 'rgba16uint', 'rgba16sint', 'rgba16float', 'rgba32float',
  'rgba32uint', 'rgba32sint', 'stencil8', 'depth16unorm', 'depth24plus', 'depth24plus-stencil8', 'depth32float',
  'depth32float-stencil8',
];
const TEXTURE_DIMENSION = [undefined, '1d', '2d', '3d'];
const VIEW_DIMENSION = [undefined, '1d', '2d', '2d-array', 'cube', 'cube-array', '3d'];
const TEXTURE_ASPECT = [undefined, 'all', 'stencil-only', 'depth-only'];
const ADDRESS_MODE = [undefined, 'clamp-to-edge', 'repeat', 'mirror-repeat'];
const FILTER_MODE = [undefined, 'nearest', 'linear'];
const COMPARE_FUNCTION = [undefined, 'never', 'less', 'equal', 'less-equal', 'greater', 'not-equal', 'greater-equal', 'always'];
const BUFFER_BINDING_TYPE = [undefined, undefined, 'uniform', 'storage', 'read-only-storage'];
const SAMPLER_BINDING_TYPE = [undefined, undefined, 'filtering', 'non-filtering', 'comparison'];
const TEXTURE_SAMPLE_TYPE = [undefined, undefined, 'float', 'unfilterable-float', 'depth', 'sint', 'uint'];
const STORAGE_TEXTURE_ACCESS = [undefined, undefined, 'write-only', 'read-only', 'read-write'];
const VERTEX_STEP_MODE = [undefined, 'vertex', 'instance'];
const VERTEX_FORMAT = [
  undefined, 'uint8', 'uint8x2', 'uint8x4', 'sint8', 'sint8x2', 'sint8x4', 'unorm8', 'unorm8x2', 'unorm8x4',
  'snorm8', 'snorm8x2', 'snorm8x4', 'uint16', 'uint16x2', 'uint16x4', 'sint16', 'sint16x2', 'sint16x4', 'unorm16',
  'unorm16x2', 'unorm16x4', 'snorm16', 'snorm16x2', 'snorm16x4', 'float16', 'float16x2', 'float16x4', 'float32',
  'float32x2', 'float32x3', 'float32x4', 'uint32', 'uint32x2', 'uint32x3', 'uint32x4', 'sint32', 'sint32x2',
  'sint32x3', 'sint32x4', 'unorm10-10-10-2', 'unorm8x4-bgra',
];
const PRIMITIVE_TOPOLOGY = [undefined, 'point-list', 'line-list', 'line-strip', 'triangle-list', 'triangle-strip'];
const INDEX_FORMAT = [undefined, 'uint16', 'uint32'];
const FRONT_FACE = [undefined, 'ccw', 'cw'];
const CULL_MODE = [undefined, 'none', 'front', 'back'];
const STENCIL_OPERATION = [
  undefined, 'keep', 'zero', 'replace', 'invert', 'increment-clamp', 'decrement-clamp', 'increment-wrap', 'decrement-wrap',
];
const BLEND_OPERATION = [undefined, 'add', 'subtract', 'reverse-subtract', 'min', 'max'];
const BLEND_FACTOR = [
  undefined, 'zero', 'one', 'src', 'one-minus-src', 'src-alpha', 'one-minus-src-alpha', 'dst', 'one-minus-dst',
  'dst-alpha', 'one-minus-dst-alpha', 'src-alpha-saturated', 'constant', 'one-minus-constant', 'src1',
  'one-minus-src1', 'src1-alpha', 'one-minus-src1-alpha',
];
const LOAD_OP = [undefined, 'load', 'clear'];
const STORE_OP = [undefined, 'store', 'discard'];
const FEATURE_NAME = [
  undefined, 'core-features-and-limits', 'depth-clip-control', 'depth32float-stencil8', 'texture-compression-bc',
  'texture-compression-bc-sliced-3d', 'texture-compression-etc2', 'texture-compression-astc',
  'texture-compression-astc-sliced-3d', 'timestamp-query', 'indirect-first-instance', 'shader-f16',
  'rg11b10ufloat-renderable', 'bgra8unorm-storage', 'float32-filterable', 'float32-blendable', 'clip-distances',
  'dual-source-blending', 'subgroups', 'texture-formats-tier1', 'texture-formats-tier2', 'primitive-index',
  'texture-component-swizzle',
];
const OPTIONAL_BOOL = [false, true, undefined];

const NO_STRING = 0xffffffff;    // webgpu_wasm.c: a NULL WGPUStringView
const UNDEFINED_U32 = 0xffffffff; // WGPU_*_UNDEFINED
const ERROR_FILTER = [undefined, 'validation', 'out-of-memory', 'internal'];
const QUERY_TYPE = [undefined, 'occlusion', 'timestamp'];
const COMPILATION_MESSAGE_TYPE = { error: 1, warning: 2, info: 3 };
const ERROR_TYPE = { GPUValidationError: 2, GPUOutOfMemoryError: 3, GPUInternalError: 4 };
const POP_ERROR_SCOPE_FAILED = 0x100;
const MAP_WRITE = 0x2;
const COPY_DST = 0x8;
// WGPULimits' members in declaration order (webgpu_wasm.c's LIMITS).
const LIMITS = [
  'maxTextureDimension1D', 'maxTextureDimension2D', 'maxTextureDimension3D', 'maxTextureArrayLayers', 'maxBindGroups',
  'maxBindGroupsPlusVertexBuffers', 'maxBindingsPerBindGroup', 'maxDynamicUniformBuffersPerPipelineLayout',
  'maxDynamicStorageBuffersPerPipelineLayout', 'maxSampledTexturesPerShaderStage', 'maxSamplersPerShaderStage',
  'maxStorageBuffersPerShaderStage', 'maxStorageTexturesPerShaderStage', 'maxUniformBuffersPerShaderStage',
  'maxUniformBufferBindingSize', 'maxStorageBufferBindingSize', 'minUniformBufferOffsetAlignment',
  'minStorageBufferOffsetAlignment', 'maxVertexBuffers', 'maxBufferSize', 'maxVertexAttributes',
  'maxVertexBufferArrayStride', 'maxInterStageShaderVariables', 'maxColorAttachments',
  'maxColorAttachmentBytesPerSample', 'maxComputeWorkgroupStorageSize', 'maxComputeInvocationsPerWorkgroup',
  'maxComputeWorkgroupSizeX', 'maxComputeWorkgroupSizeY', 'maxComputeWorkgroupSizeZ',
  'maxComputeWorkgroupsPerDimension', 'maxImmediateSize',
];
const ADAPTER_INFO = ['vendor', 'architecture', 'device', 'description'];
// The GPU object a table entry holds, for its label.
const LABELLED = ['buffer', 'texture', 'view', 'sampler', 'layout', 'group', 'module', 'pipeline', 'encoder', 'pass', 'commands', 'querySet'];

/** Reads one of webgpu_wasm.c's word lists. */
class Words {
  constructor(bridge, ptr, count) {
    this.bridge = bridge;
    this.words = new Uint32Array(bridge.memory.buffer, ptr, count);
    this.index = 0;
  }

  next() { return this.words[this.index++]; }
  int() { return this.words[this.index++] | 0; }

  f64() {
    const scratch = new DataView(new ArrayBuffer(8));
    scratch.setUint32(0, this.next(), true);
    scratch.setUint32(4, this.next(), true);
    return scratch.getFloat64(0, true);
  }

  f32() {
    const scratch = new DataView(new ArrayBuffer(4));
    scratch.setUint32(0, this.next(), true);
    return scratch.getFloat32(0, true);
  }

  string() {
    const ptr = this.next();
    const length = this.next();
    return length === NO_STRING ? undefined : this.bridge.string(ptr, length);
  }

  /** A programmable stage: module, entryPoint, constants. */
  stage() {
    const stage = { module: this.bridge.get(this.next())?.module };
    const entryPoint = this.string();
    if (entryPoint) stage.entryPoint = entryPoint;
    const count = this.next();
    if (count) {
      stage.constants = {};
      for (let i = 0; i < count; i++) {
        const key = this.string();
        stage.constants[key] = this.f64();
      }
    }
    return stage;
  }

  /** A texel copy location: texture, mipLevel, origin, aspect. */
  copyTexture() {
    const texture = this.bridge.get(this.next())?.texture;
    const location = { texture, mipLevel: this.next(), origin: { x: this.next(), y: this.next(), z: this.next() } };
    const aspect = TEXTURE_ASPECT[this.next()];
    if (aspect) location.aspect = aspect;
    return location;
  }

  /** A texel copy buffer: buffer, offset, bytesPerRow, rowsPerImage. */
  copyBuffer() {
    const buffer = this.bridge.get(this.next())?.buffer;
    const location = { buffer, offset: this.f64() };
    const bytesPerRow = this.next();
    const rowsPerImage = this.next();
    if (bytesPerRow !== UNDEFINED_U32) location.bytesPerRow = bytesPerRow;
    if (rowsPerImage !== UNDEFINED_U32) location.rowsPerImage = rowsPerImage;
    return location;
  }
}

function blendComponent(words) {
  return {
    operation: BLEND_OPERATION[words.next()] ?? 'add',
    srcFactor: BLEND_FACTOR[words.next()] ?? 'one',
    dstFactor: BLEND_FACTOR[words.next()] ?? 'zero',
  };
}

function stencilFace(words) {
  return {
    compare: COMPARE_FUNCTION[words.next()] ?? 'always',
    failOp: STENCIL_OPERATION[words.next()] ?? 'keep',
    depthFailOp: STENCIL_OPERATION[words.next()] ?? 'keep',
    passOp: STENCIL_OPERATION[words.next()] ?? 'keep',
  };
}

/** The "nucleant_wgpu" imports, on `bridge`'s device and object table. */
export function makeWgpuImports(bridge) {
  const device = () => bridge.device;
  const get = (id) => bridge.get(id);
  const words = (ptr, count) => new Words(bridge, ptr, count);
  const singletons = new Map();
  const singleton = (kind) => {
    if (!singletons.has(kind)) singletons.set(kind, bridge.add({ kind, singleton: true }));
    return singletons.get(kind);
  };
  const counted = (object) => bridge.add({ ...object, refs: 1 });
  const encode = (text) => new TextEncoder().encode(text ?? '');
  const copyString = (bytes, ptr, capacity) => {
    if (ptr && capacity) new Uint8Array(bridge.memory.buffer, ptr, Math.min(bytes.length, capacity)).set(bytes.subarray(0, capacity));
    return bytes.length;
  };

  // Futures: a promise's outcome (webgpu_wasm.c polls it), 0 until settled.
  const futures = new Map();
  let nextFuture = 1;
  const future = (promise, failed) => {
    const id = nextFuture++;
    const record = { outcome: 0 };
    record.settled = Promise.resolve(promise).then(
      (outcome) => { record.outcome = outcome; },
      (error) => { record.outcome = failed; record.error = error; });
    futures.set(id, record);
    return id;
  };
  const futureWait = async (ptr, count, timeoutMs) => {
    const pending = Array.from(new Uint32Array(bridge.memory.buffer, ptr, count), (id) => futures.get(id))
      .filter((record) => record && !record.outcome)
      .map((record) => record.settled);
    if (!pending.length) return;
    const racers = [Promise.race(pending)];
    if (timeoutMs >= 0) racers.push(new Promise((resolve) => setTimeout(resolve, timeoutMs)));
    await Promise.race(racers);
  };

  return {
    log: (ptr, length) => console.warn('[CWgpu]', bridge.string(ptr, length)),

    // The adapter and device are the page's (createNucleantWebGPU); every
    // request is answered with them.
    instanceCreate: () => singleton('instance'),
    adapterGet: () => singleton('adapter'),
    deviceGet: () => singleton('device'),
    queueGet: () => singleton('queue'),
    hasFeature: (which, feature) => {
      const name = FEATURE_NAME[feature];
      const features = which === 0 ? bridge.adapter.features : bridge.device.features;
      return name && features.has(name) ? 1 : 0;
    },

    addRef: (id) => {
      const object = get(id);
      if (object && object.refs !== undefined) object.refs++;
    },
    release: (id) => {
      const object = get(id);
      if (!object || object.singleton) return 0;
      bridge.destroy(id);
      return get(id) ? 0 : 1;
    },
    setLabel: (id, ptr, length) => {
      const object = get(id);
      const key = object && LABELLED.find((name) => object[name] && typeof object[name] === 'object');
      if (key) object[key].label = bridge.string(ptr, length);
    },
    adapterInfo: (which, ptr, capacity) => copyString(encode(bridge.adapter.info?.[ADAPTER_INFO[which]]), ptr, capacity),
    // The page's limits — except immediates, which webgpu_wasm.c does not
    // provide (wgpuDeviceCreatePipelineLayout), whatever the browser has.
    limits: (which, ptr, count) => {
      const limits = which === 0 ? bridge.adapter.limits : bridge.device.limits;
      const out = new Float64Array(bridge.memory.buffer, ptr, count);
      LIMITS.slice(0, count).forEach((name, i) => { out[i] = name === 'maxImmediateSize' ? 0 : limits[name] ?? 0; });
    },

    // A buffer webgpu_wasm.c maps for writing in wasm memory is filled
    // through writeBuffer, so it is a COPY_DST buffer in place of a MAP_WRITE
    // one, padded to writeBuffer's 4-byte words. It reports the size and
    // usage asked for.
    bufferCreate: (size, usage, writtenByQueue) => {
      const actual = writtenByQueue ? (usage & ~MAP_WRITE) | COPY_DST : usage;
      const padded = writtenByQueue ? Math.ceil(size / 4) * 4 : size;
      return counted({ kind: 'buffer', buffer: device().createBuffer({ size: padded, usage: actual }), size, usage });
    },
    bufferGetSize: (id) => get(id)?.size ?? 0,
    bufferGetUsage: (id) => get(id)?.usage ?? 0,
    bufferDestroy: (id) => get(id)?.buffer.destroy(),
    bufferMapRead: (id, offset, size) => future(get(id).buffer.mapAsync(GPUMapMode.READ, offset, size).then(() => 1), 2),
    bufferReadMapped: (id, offset, ptr, size) => {
      new Uint8Array(bridge.memory.buffer, ptr, size).set(new Uint8Array(get(id).buffer.getMappedRange(offset, size)));
    },
    bufferUnmap: (id) => get(id)?.buffer.unmap(),

    futureState: (id) => futures.get(id)?.outcome ?? 0,
    futureForget: (id) => futures.delete(id),
    futureWait: bridge.blockingWaits ? new WebAssembly.Suspending(futureWait) : () => {},
    queueWorkDone: () => future(device().queue.onSubmittedWorkDone().then(() => 1), 2),
    pushErrorScope: (filter) => device().pushErrorScope(ERROR_FILTER[filter] ?? 'validation'),
    popErrorScope: () => future(device().popErrorScope().then((error) => (error ? ERROR_TYPE[error.constructor.name] ?? 5 : 1)),
                                POP_ERROR_SCOPE_FAILED),
    compilationInfo: (module) => {
      if (!bridge.blockingWaits) return 0;
      let record;
      const id = future(get(module).module.getCompilationInfo().then((info) => {
        record.messages = info.messages.map((message) => ({ message, text: encode(message.message) }));
        return 1;
      }), 2);
      record = futures.get(id);
      return id;
    },
    compilationMessages: (id, ptr, capacity) => {
      const messages = futures.get(id)?.messages ?? [];
      if (ptr && capacity) {
        const out = new Uint32Array(bridge.memory.buffer, ptr, Math.min(messages.length, capacity) * 6);
        messages.slice(0, capacity).forEach(({ message, text }, i) => {
          out.set([COMPILATION_MESSAGE_TYPE[message.type] ?? 3, message.lineNum, message.linePos, message.offset,
                   message.length, text.length], i * 6);
        });
      }
      return messages.length;
    },
    compilationMessageText: (id, index, ptr, capacity) => {
      const text = futures.get(id)?.messages?.[index]?.text;
      if (text) copyString(text, ptr, capacity);
    },

    textureCreate: (ptr, count) => {
      const w = words(ptr, count);
      const usage = w.next();
      const dimension = w.next();
      const width = w.next();
      const height = w.next();
      const depthOrArrayLayers = w.next() || 1;
      const formatCode = w.next();
      const mipLevelCount = w.next() || 1;
      const sampleCount = w.next() || 1;
      const viewFormats = [];
      for (let i = w.next(); i > 0; i--) viewFormats.push(TEXTURE_FORMAT[w.next()]);
      const format = TEXTURE_FORMAT[formatCode];
      if (!format) {
        bridge.error(`wgpuDeviceCreateTexture: texture format ${formatCode} is not available`);
        return 0;
      }
      const texture = device().createTexture({
        size: [width, height, depthOrArrayLayers],
        mipLevelCount,
        sampleCount,
        dimension: TEXTURE_DIMENSION[dimension] ?? '2d',
        format,
        usage,
        viewFormats,
      });
      // The same shape as a Vulkan image's texture, so a VkImage imported
      // over it is handled like any other.
      return counted({ kind: 'texture', texture, format, texel: bridge.texelSize(format), width, height });
    },
    // Read off the GPUTexture, so a Vulkan image's texture handed out
    // through webgpu.h (VK_NUCLEANT_webgpu_objects) answers the same.
    textureGet: (id, which) => {
      const t = get(id)?.texture;
      if (!t) return 0;
      switch (which) {
        case 0: return t.width;
        case 1: return t.height;
        case 2: return t.depthOrArrayLayers;
        case 3: return t.mipLevelCount;
        case 4: return t.sampleCount;
        case 5: return Math.max(TEXTURE_DIMENSION.indexOf(t.dimension), 0);
        case 6: return Math.max(TEXTURE_FORMAT.indexOf(t.format), 0);
        case 7: return t.usage;
        default: return 0;
      }
    },
    textureCreateView: (id, ptr, count) => {
      const texture = get(id);
      if (!texture) return 0;
      let descriptor;
      if (count) {
        const w = words(ptr, count);
        descriptor = {};
        const format = TEXTURE_FORMAT[w.next()];
        const dimension = VIEW_DIMENSION[w.next()];
        const baseMipLevel = w.next();
        const mipLevelCount = w.next();
        const baseArrayLayer = w.next();
        const arrayLayerCount = w.next();
        const aspect = TEXTURE_ASPECT[w.next()];
        const usage = w.next();
        if (format) descriptor.format = format;
        if (dimension) descriptor.dimension = dimension;
        descriptor.baseMipLevel = baseMipLevel;
        if (mipLevelCount && mipLevelCount !== UNDEFINED_U32) descriptor.mipLevelCount = mipLevelCount;
        descriptor.baseArrayLayer = baseArrayLayer;
        if (arrayLayerCount && arrayLayerCount !== UNDEFINED_U32) descriptor.arrayLayerCount = arrayLayerCount;
        if (aspect) descriptor.aspect = aspect;
        if (usage) descriptor.usage = usage;
      }
      return counted({ kind: 'view', view: texture.texture.createView(descriptor) });
    },
    textureDestroy: (id) => get(id)?.texture.destroy(),

    samplerCreate: (ptr, count) => {
      if (!count) return counted({ kind: 'sampler', sampler: device().createSampler() });
      const w = words(ptr, count);
      const descriptor = {
        addressModeU: ADDRESS_MODE[w.next()] ?? 'clamp-to-edge',
        addressModeV: ADDRESS_MODE[w.next()] ?? 'clamp-to-edge',
        addressModeW: ADDRESS_MODE[w.next()] ?? 'clamp-to-edge',
        magFilter: FILTER_MODE[w.next()] ?? 'nearest',
        minFilter: FILTER_MODE[w.next()] ?? 'nearest',
        mipmapFilter: FILTER_MODE[w.next()] ?? 'nearest',
        lodMinClamp: w.f32(),
        lodMaxClamp: w.f32(),
      };
      const compare = COMPARE_FUNCTION[w.next()];
      if (compare) descriptor.compare = compare;
      const anisotropy = w.next();
      // WebGPU takes anisotropy only with every filter linear; wgpu-native
      // ignores it otherwise, and so does this.
      if (anisotropy > 1 && descriptor.magFilter === 'linear' && descriptor.minFilter === 'linear' && descriptor.mipmapFilter === 'linear') {
        descriptor.maxAnisotropy = anisotropy;
      }
      return counted({ kind: 'sampler', sampler: device().createSampler(descriptor) });
    },

    bindGroupLayoutCreate: (ptr, count) => {
      const w = words(ptr, count);
      const entries = [];
      for (let i = w.next(); i > 0; i--) {
        const entry = { binding: w.next(), visibility: w.next() };
        const arraySize = w.next();
        const bufferType = w.next();
        const hasDynamicOffset = w.next() !== 0;
        const minBindingSize = w.f64();
        const samplerType = w.next();
        const sampleType = w.next();
        const viewDimension = w.next();
        const multisampled = w.next() !== 0;
        const access = w.next();
        const storageFormat = w.next();
        const storageViewDimension = w.next();
        if (arraySize > 1) bridge.error('wgpuDeviceCreateBindGroupLayout: binding arrays are not available in browser WebGPU');
        // BindingNotUsed (0) marks the members that are not this binding;
        // Undefined (1) asks for the member's default.
        if (bufferType) {
          entry.buffer = { type: BUFFER_BINDING_TYPE[bufferType] ?? 'uniform', hasDynamicOffset, minBindingSize };
        } else if (samplerType) {
          entry.sampler = { type: SAMPLER_BINDING_TYPE[samplerType] ?? 'filtering' };
        } else if (sampleType) {
          entry.texture = {
            sampleType: TEXTURE_SAMPLE_TYPE[sampleType] ?? 'float',
            viewDimension: VIEW_DIMENSION[viewDimension] ?? '2d',
            multisampled,
          };
        } else if (access) {
          entry.storageTexture = {
            access: STORAGE_TEXTURE_ACCESS[access] ?? 'write-only',
            format: TEXTURE_FORMAT[storageFormat],
            viewDimension: VIEW_DIMENSION[storageViewDimension] ?? '2d',
          };
        }
        entries.push(entry);
      }
      return counted({ kind: 'bindGroupLayout', layout: device().createBindGroupLayout({ entries }) });
    },

    bindGroupCreate: (ptr, count) => {
      const w = words(ptr, count);
      const layout = get(w.next())?.layout;
      const entries = [];
      for (let i = w.next(); i > 0; i--) {
        const binding = w.next();
        const buffer = w.next();
        const offset = w.f64();
        const size = w.f64();
        const sampler = w.next();
        const view = w.next();
        let resource;
        if (buffer) {
          resource = { buffer: get(buffer)?.buffer, offset };
          if (size >= 0) resource.size = size;
        } else if (sampler) {
          resource = get(sampler)?.sampler;
        } else {
          resource = get(view)?.view;
        }
        entries.push({ binding, resource });
      }
      return counted({ kind: 'bindGroup', group: device().createBindGroup({ layout, entries }) });
    },

    pipelineLayoutCreate: (ptr, count) => {
      const w = words(ptr, count);
      const bindGroupLayouts = [];
      for (let i = w.next(); i > 0; i--) bindGroupLayouts.push(get(w.next())?.layout ?? null);
      return counted({ kind: 'pipelineLayout', layout: device().createPipelineLayout({ bindGroupLayouts }) });
    },

    shaderModuleCreate: (ptr, length) => counted({
      kind: 'shaderModule',
      module: device().createShaderModule({ code: bridge.string(ptr, length) }),
    }),

    renderPipelineCreate: (ptr, count) => {
      const w = words(ptr, count);
      const layout = w.next();
      const descriptor = { layout: layout ? get(layout)?.layout : 'auto' };

      const vertex = w.stage();
      vertex.buffers = [];
      for (let i = w.next(); i > 0; i--) {
        const stepModeCode = w.next();
        const arrayStride = w.f64();
        const attributes = [];
        for (let a = w.next(); a > 0; a--) {
          attributes.push({ format: VERTEX_FORMAT[w.next()], offset: w.f64(), shaderLocation: w.next() });
        }
        // Undefined with no attributes is a hole in the list (null), not a
        // buffer the draws must bind.
        if (!stepModeCode && !attributes.length) vertex.buffers.push(null);
        else vertex.buffers.push({ arrayStride, stepMode: VERTEX_STEP_MODE[stepModeCode] ?? 'vertex', attributes });
      }
      descriptor.vertex = vertex;

      const primitive = { topology: PRIMITIVE_TOPOLOGY[w.next()] ?? 'triangle-list' };
      const stripIndexFormat = INDEX_FORMAT[w.next()];
      if (stripIndexFormat) primitive.stripIndexFormat = stripIndexFormat;
      primitive.frontFace = FRONT_FACE[w.next()] ?? 'ccw';
      primitive.cullMode = CULL_MODE[w.next()] ?? 'none';
      if (w.next()) primitive.unclippedDepth = true;
      descriptor.primitive = primitive;

      if (w.next()) {
        const depthStencil = { format: TEXTURE_FORMAT[w.next()] };
        const depthWriteEnabled = OPTIONAL_BOOL[w.next()];
        if (depthWriteEnabled !== undefined) depthStencil.depthWriteEnabled = depthWriteEnabled;
        const depthCompare = COMPARE_FUNCTION[w.next()];
        if (depthCompare) depthStencil.depthCompare = depthCompare;
        depthStencil.stencilFront = stencilFace(w);
        depthStencil.stencilBack = stencilFace(w);
        depthStencil.stencilReadMask = w.next();
        depthStencil.stencilWriteMask = w.next();
        depthStencil.depthBias = w.int();
        depthStencil.depthBiasSlopeScale = w.f32();
        depthStencil.depthBiasClamp = w.f32();
        descriptor.depthStencil = depthStencil;
      }

      descriptor.multisample = { count: w.next() || 1, mask: w.next(), alphaToCoverageEnabled: w.next() !== 0 };

      if (w.next()) {
        const fragment = w.stage();
        fragment.targets = [];
        for (let i = w.next(); i > 0; i--) {
          const format = TEXTURE_FORMAT[w.next()];
          const target = { format };
          if (w.next()) target.blend = { color: blendComponent(w), alpha: blendComponent(w) };
          target.writeMask = w.next();
          fragment.targets.push(format ? target : null);
        }
        descriptor.fragment = fragment;
      }
      return counted({ kind: 'renderPipeline', pipeline: device().createRenderPipeline(descriptor) });
    },

    computePipelineCreate: (ptr, count) => {
      const w = words(ptr, count);
      const layout = w.next();
      const pipeline = device().createComputePipeline({ layout: layout ? get(layout)?.layout : 'auto', compute: w.stage() });
      return counted({ kind: 'computePipeline', pipeline });
    },
    pipelineBindGroupLayout: (pipeline, index) =>
      counted({ kind: 'bindGroupLayout', layout: get(pipeline).pipeline.getBindGroupLayout(index) }),
    querySetCreate: (type, count) =>
      counted({ kind: 'querySet', querySet: device().createQuerySet({ type: QUERY_TYPE[type] ?? 'occlusion', count }) }),

    commandEncoderCreate: () => counted({ kind: 'commandEncoder', encoder: device().createCommandEncoder() }),

    beginRenderPass: (encoder, ptr, count) => {
      const w = words(ptr, count);
      const colorAttachments = [];
      for (let i = w.next(); i > 0; i--) {
        const view = w.next();
        const depthSlice = w.next();
        const resolveTarget = w.next();
        const attachment = {
          view: get(view)?.view,
          loadOp: LOAD_OP[w.next()] ?? 'load',
          storeOp: STORE_OP[w.next()] ?? 'store',
          clearValue: { r: w.f64(), g: w.f64(), b: w.f64(), a: w.f64() },
        };
        if (depthSlice !== UNDEFINED_U32) attachment.depthSlice = depthSlice;
        if (resolveTarget) attachment.resolveTarget = get(resolveTarget)?.view;
        colorAttachments.push(view ? attachment : null);
      }
      const descriptor = { colorAttachments };
      if (w.next()) {
        const depthStencil = { view: get(w.next())?.view };
        const depthLoadOp = LOAD_OP[w.next()];
        const depthStoreOp = STORE_OP[w.next()];
        const depthClearValue = w.f32();
        const depthReadOnly = w.next() !== 0;
        const stencilLoadOp = LOAD_OP[w.next()];
        const stencilStoreOp = STORE_OP[w.next()];
        const stencilClearValue = w.next();
        const stencilReadOnly = w.next() !== 0;
        if (depthLoadOp) depthStencil.depthLoadOp = depthLoadOp;
        if (depthStoreOp) depthStencil.depthStoreOp = depthStoreOp;
        if (!Number.isNaN(depthClearValue)) depthStencil.depthClearValue = depthClearValue;
        if (depthReadOnly) depthStencil.depthReadOnly = true;
        if (stencilLoadOp) depthStencil.stencilLoadOp = stencilLoadOp;
        if (stencilStoreOp) depthStencil.stencilStoreOp = stencilStoreOp;
        depthStencil.stencilClearValue = stencilClearValue;
        if (stencilReadOnly) depthStencil.stencilReadOnly = true;
        descriptor.depthStencilAttachment = depthStencil;
      }
      return counted({ kind: 'renderPass', pass: get(encoder).encoder.beginRenderPass(descriptor) });
    },

    copyBufferToBuffer: (encoder, source, sourceOffset, destination, destinationOffset, size) => {
      const from = get(source);
      get(encoder).encoder.copyBufferToBuffer(
        from.buffer, sourceOffset, get(destination).buffer, destinationOffset, size >= 0 ? size : from.size - sourceOffset);
    },
    copyTextureToTexture: (encoder, ptr, count) => {
      const w = words(ptr, count);
      const source = w.copyTexture();
      const destination = w.copyTexture();
      get(encoder).encoder.copyTextureToTexture(source, destination, [w.next(), w.next(), w.next()]);
    },
    copyBufferToTexture: (encoder, ptr, count) => {
      const w = words(ptr, count);
      const source = w.copyBuffer();
      const destination = w.copyTexture();
      get(encoder).encoder.copyBufferToTexture(source, destination, [w.next(), w.next(), w.next()]);
    },
    copyTextureToBuffer: (encoder, ptr, count) => {
      const w = words(ptr, count);
      const source = w.copyTexture();
      const destination = w.copyBuffer();
      get(encoder).encoder.copyTextureToBuffer(source, destination, [w.next(), w.next(), w.next()]);
    },
    clearBuffer: (encoder, buffer, offset, size) => {
      if (size >= 0) get(encoder).encoder.clearBuffer(get(buffer).buffer, offset, size);
      else get(encoder).encoder.clearBuffer(get(buffer).buffer, offset);
    },
    resolveQuerySet: (encoder, querySet, firstQuery, queryCount, destination, destinationOffset) =>
      get(encoder).encoder.resolveQuerySet(get(querySet).querySet, firstQuery, queryCount, get(destination).buffer, destinationOffset),
    beginComputePass: (encoder, ptr, count) => {
      const w = words(ptr, count);
      const descriptor = {};
      if (w.next()) {
        const timestampWrites = { querySet: get(w.next())?.querySet };
        const beginning = w.next();
        const end = w.next();
        if (beginning !== UNDEFINED_U32) timestampWrites.beginningOfPassWriteIndex = beginning;
        if (end !== UNDEFINED_U32) timestampWrites.endOfPassWriteIndex = end;
        descriptor.timestampWrites = timestampWrites;
      }
      return counted({ kind: 'computePass', pass: get(encoder).encoder.beginComputePass(descriptor) });
    },
    encoderFinish: (encoder) => counted({ kind: 'commandBuffer', commands: get(encoder).encoder.finish() }),

    dispatch: (pass, x, y, z) => get(pass).pass.dispatchWorkgroups(x, y, z),
    dispatchIndirect: (pass, buffer, offset) => get(pass).pass.dispatchWorkgroupsIndirect(get(buffer).buffer, offset),

    passSetPipeline: (pass, pipeline) => get(pass).pass.setPipeline(get(pipeline).pipeline),
    passSetBindGroup: (pass, index, group, offsetCount, offsets) => {
      const bindGroup = group ? get(group).group : null;
      if (offsetCount) get(pass).pass.setBindGroup(index, bindGroup, new Uint32Array(bridge.memory.buffer, offsets, offsetCount));
      else get(pass).pass.setBindGroup(index, bindGroup);
    },
    passSetStencilReference: (pass, reference) => get(pass).pass.setStencilReference(reference),
    passSetScissorRect: (pass, x, y, width, height) => get(pass).pass.setScissorRect(x, y, width, height),
    passSetViewport: (pass, x, y, width, height, minDepth, maxDepth) =>
      get(pass).pass.setViewport(x, y, width, height, minDepth, maxDepth),
    passSetBlendConstant: (pass, r, g, b, a) => get(pass).pass.setBlendConstant({ r, g, b, a }),
    passSetVertexBuffer: (pass, slot, buffer, offset, size) => {
      const vertices = buffer ? get(buffer).buffer : null;
      if (size >= 0) get(pass).pass.setVertexBuffer(slot, vertices, offset, size);
      else get(pass).pass.setVertexBuffer(slot, vertices, offset);
    },
    passSetIndexBuffer: (pass, buffer, format, offset, size) => {
      if (size >= 0) get(pass).pass.setIndexBuffer(get(buffer).buffer, INDEX_FORMAT[format], offset, size);
      else get(pass).pass.setIndexBuffer(get(buffer).buffer, INDEX_FORMAT[format], offset);
    },
    passDraw: (pass, vertexCount, instanceCount, firstVertex, firstInstance) =>
      get(pass).pass.draw(vertexCount, instanceCount, firstVertex, firstInstance),
    passDrawIndexed: (pass, indexCount, instanceCount, firstIndex, baseVertex, firstInstance) =>
      get(pass).pass.drawIndexed(indexCount, instanceCount, firstIndex, baseVertex, firstInstance),
    passDrawIndirect: (pass, buffer, offset, indexed) => {
      if (indexed) get(pass).pass.drawIndexedIndirect(get(buffer).buffer, offset);
      else get(pass).pass.drawIndirect(get(buffer).buffer, offset);
    },
    passEnd: (pass) => get(pass).pass.end(),

    queueSubmit: (count, ptr) => {
      const ids = new Uint32Array(bridge.memory.buffer, ptr, count);
      device().queue.submit(Array.from(ids, (id) => get(id).commands));
    },
    queueWriteBuffer: (buffer, offset, data, size) => {
      device().queue.writeBuffer(get(buffer).buffer, offset, bridge.memory.buffer, data, size);
    },
    queueWriteTexture: (ptr, count, data, size) => {
      const w = words(ptr, count);
      const destination = w.copyTexture();
      const layout = { offset: data + w.f64() };
      const bytesPerRow = w.next();
      const rowsPerImage = w.next();
      if (bytesPerRow !== UNDEFINED_U32) layout.bytesPerRow = bytesPerRow;
      if (rowsPerImage !== UNDEFINED_U32) layout.rowsPerImage = rowsPerImage;
      device().queue.writeTexture(destination, bridge.memory.buffer, layout, [w.next(), w.next(), w.next()]);
    },
  };
}
