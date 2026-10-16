// nucleant-webgpu.js — the WebGPU half of NucleantVulkan's Vulkan
// implementation for WebAssembly.
//
// Sources/CVulkanWasm implements the Vulkan API the engine calls and keeps
// all Vulkan state; it reaches the browser's WebGPU through the imports of
// the "nucleant_webgpu" module defined here. This side holds the WebGPU
// objects (by integer id — 0 is "none", ids are never reused), turns SPIR-V
// into WGSL through naga (naga_webgpu.wasm), and executes the command stream
// a vkQueueSubmit hands over.
//
//   const gpu = await createNucleantWebGPU({ nagaURL: "naga_webgpu.wasm" });
//   const { instance } = await WebAssembly.instantiate(bytes, { ...gpu.imports, ...wasi });
//   gpu.attach(instance);
//
// Waits (vkWaitForFences, vkQueueWaitIdle, vkDeviceWaitIdle) really block
// when the browser has JSPI (WebAssembly.Suspending / promising): the wasm
// stack suspends until the GPU is done, and readbacks into host-visible
// memory have landed by then — Vulkan's own guarantee. That needs every call
// into wasm to go through WebAssembly.promising, which the loader does when
// `gpu.blockingWaits` is true. Without JSPI the waits return at once (WebGPU
// keeps in-flight resources alive and ordered regardless) and readbacks land
// asynchronously.
//
// The same bridge also serves webgpu.h (Sources/CWgpuWasm, the "nucleant_wgpu"
// imports in nucleant-wgpu.js) on this device and object table — what
// ThorVG's wg engine draws through, into textures a VkImage can be made
// over.

import { makeWgpuImports } from './nucleant-wgpu.js';

const SAMPLER_BINDING_OFFSET = 512;   // NagaWebGPU/src/split_combined.rs
const PUSH_CONSTANT_OFFSET = 256;     // vkw_internal.h NWG_PUSH_CONSTANT_OFFSET

const OP = {
  BEGIN_RENDER_PASS: 1, END_RENDER_PASS: 2, SET_PIPELINE: 3, BIND_SET: 4, SET_VIEWPORT: 5,
  SET_SCISSOR: 6, DRAW_DATA: 7, DRAW: 8, DRAW_INDIRECT: 9, BEGIN_COMPUTE_PASS: 10,
  END_COMPUTE_PASS: 11, DISPATCH: 12, COPY_BUFFER_TO_BUFFER: 13, COPY_BUFFER_TO_TEXTURE: 14,
  COPY_TEXTURE_TO_BUFFER: 15, COPY_TEXTURE_TO_TEXTURE: 16, CLEAR_TEXTURE: 17, BLIT_TEXTURE: 18,
  READBACK: 19, SET_VERTEX_BUFFER: 20, SET_INDEX_BUFFER: 21, DRAW_INDEXED: 22, SET_STENCIL_REFERENCE: 23,
  SET_STENCIL_MASKS: 24, SET_BLEND_CONSTANT: 25, CLEAR_ATTACHMENTS: 26,
};

const DESC = { SAMPLER: 1, COMBINED: 2, SAMPLED_IMAGE: 3, STORAGE_IMAGE: 4, UNIFORM_BUFFER: 5, STORAGE_BUFFER: 6 };

// VkFormat -> [GPUTextureFormat, bytes per texel]
const FORMATS = {
  9: ['r8unorm', 1], 10: ['r8snorm', 1], 13: ['r8uint', 1], 14: ['r8sint', 1],
  16: ['rg8unorm', 2], 17: ['rg8snorm', 2], 20: ['rg8uint', 2], 21: ['rg8sint', 2],
  37: ['rgba8unorm', 4], 38: ['rgba8snorm', 4], 41: ['rgba8uint', 4], 42: ['rgba8sint', 4],
  43: ['rgba8unorm-srgb', 4], 44: ['bgra8unorm', 4], 50: ['bgra8unorm-srgb', 4],
  64: ['rgb10a2unorm', 4], 74: ['r16uint', 2], 75: ['r16sint', 2], 76: ['r16float', 2],
  81: ['rg16uint', 4], 82: ['rg16sint', 4], 83: ['rg16float', 4],
  95: ['rgba16uint', 8], 96: ['rgba16sint', 8], 97: ['rgba16float', 8],
  98: ['r32uint', 4], 99: ['r32sint', 4], 100: ['r32float', 4],
  101: ['rg32uint', 8], 102: ['rg32sint', 8], 103: ['rg32float', 8],
  107: ['rgba32uint', 16], 108: ['rgba32sint', 16], 109: ['rgba32float', 16],
  124: ['depth16unorm', 2], 126: ['depth32float', 4], 129: ['depth24plus-stencil8', 4],
};
const VK_FORMAT_OF = Object.fromEntries(Object.entries(FORMATS).map(([vk, [gpu]]) => [gpu, Number(vk)]));
const TEXEL_OF = Object.fromEntries(Object.values(FORMATS));

const VIEW_DIMENSIONS = ['1d', '2d', '3d', 'cube', '1d', '2d-array', 'cube-array'];
const ADDRESS_MODES = ['repeat', 'mirror-repeat', 'clamp-to-edge', 'clamp-to-edge', 'clamp-to-edge'];
const COMPARE = ['never', 'less', 'equal', 'less-equal', 'greater', 'not-equal', 'greater-equal', 'always'];
const TOPOLOGY = ['point-list', 'line-list', 'line-strip', 'triangle-list', 'triangle-strip'];
const BLEND_FACTORS = [
  'zero', 'one', 'src', 'one-minus-src', 'dst', 'one-minus-dst', 'src-alpha', 'one-minus-src-alpha',
  'dst-alpha', 'one-minus-dst-alpha', 'constant', 'one-minus-constant', 'constant', 'one-minus-constant',
  'src-alpha-saturated',
];
const BLEND_OPS = ['add', 'subtract', 'reverse-subtract', 'min', 'max'];
const STENCIL_OPS = ['keep', 'zero', 'replace', 'increment-clamp', 'decrement-clamp', 'invert', 'increment-wrap', 'decrement-wrap'];
const STENCIL_FORMATS = new Set(['depth24plus-stencil8', 'depth32float-stencil8', 'stencil8']);

// VkFormat -> GPUVertexFormat. WebGPU has no 3-component 8/16-bit formats and
// no *SCALED ones (integers read as floats).
const VERTEX_FORMATS = {
  9: 'unorm8', 10: 'snorm8', 13: 'uint8', 14: 'sint8',
  16: 'unorm8x2', 17: 'snorm8x2', 20: 'uint8x2', 21: 'sint8x2',
  37: 'unorm8x4', 38: 'snorm8x4', 41: 'uint8x4', 42: 'sint8x4', 44: 'unorm8x4-bgra',
  64: 'unorm10-10-10-2',
  70: 'unorm16', 71: 'snorm16', 74: 'uint16', 75: 'sint16', 76: 'float16',
  77: 'unorm16x2', 78: 'snorm16x2', 81: 'uint16x2', 82: 'sint16x2', 83: 'float16x2',
  91: 'unorm16x4', 92: 'snorm16x4', 95: 'uint16x4', 96: 'sint16x4', 97: 'float16x4',
  98: 'uint32', 99: 'sint32', 100: 'float32',
  101: 'uint32x2', 102: 'sint32x2', 103: 'float32x2',
  104: 'uint32x3', 105: 'sint32x3', 106: 'float32x3',
  107: 'uint32x4', 108: 'sint32x4', 109: 'float32x4',
};

// vkCmdClearAttachments inside a pass: a triangle over the target, cut to
// the rect by the scissor. Colour comes from the blend constant
// (1 * constant + 0 * dst), depth from the viewport's depth range (z = 0
// lands on minDepth = maxDepth). With no colour attachments there is no
// fragment stage.
const CLEAR_SHADER = (colorCount) => /* wgsl */ `
@vertex fn vs(@builtin(vertex_index) index: u32) -> @builtin(position) vec4<f32> {
  let p = vec2<f32>(f32((index << 1u) & 2u), f32(index & 2u)) * 2.0 - 1.0;
  return vec4<f32>(p, 0.0, 1.0);
}
` + (colorCount ? `
struct Out { ${Array.from({ length: colorCount }, (_, i) => `@location(${i}) c${i}: vec4<f32>,`).join(' ')} }
@fragment fn fs() -> Out {
  var out: Out;
  ${Array.from({ length: colorCount }, (_, i) => `out.c${i} = vec4<f32>(1.0);`).join(' ')}
  return out;
}` : '');

// Word offsets in nwg_render_pipeline_desc_t (vkw_internal.h).
const DESC_BINDINGS = 87, DESC_ATTRIBUTES = 136, DESC_DEPTH = 201;

const STAGE_CODE = { vertex: 0, fragment: 1, compute: 2 };

const BLIT_SHADER = /* wgsl */ `
@group(0) @binding(0) var source: texture_2d<f32>;
@group(0) @binding(1) var sourceSampler: sampler;
@group(0) @binding(2) var<uniform> rect: vec4<f32>;  // source uv of the target's left/top and right/bottom edges
struct Out { @builtin(position) position: vec4<f32>, @location(0) uv: vec2<f32> }
@vertex fn vs(@builtin(vertex_index) index: u32) -> Out {
  let corner = vec2<f32>(f32(index & 1u), f32((index >> 1u) & 1u));
  var out: Out;
  out.position = vec4<f32>(corner.x * 2.0 - 1.0, 1.0 - corner.y * 2.0, 0.0, 1.0);
  out.uv = mix(rect.xy, rect.zw, corner);
  return out;
}
@fragment fn fs(in: Out) -> @location(0) vec4<f32> {
  return textureSampleLevel(source, sourceSampler, in.uv, 0.0);
}`;

function alignUp(value, alignment) {
  return Math.ceil(value / alignment) * alignment;
}

/**
 * Acquires the GPUDevice and loads the SPIR-V translator, then returns the
 * bridge: `imports` for instantiating the wasm module, `attach(instance)`
 * once it exists.
 *
 * @param {object} options
 * @param {string|URL} options.nagaURL       naga_webgpu.wasm
 * @param {boolean}    [options.jspi]        force JSPI on/off (default: when available)
 * @param {GPUPowerPreference} [options.powerPreference]
 * @param {(message: string) => void} [options.onError]  every WebGPU / translation error
 */
export async function createNucleantWebGPU(options = {}) {
  if (!navigator.gpu) throw new Error('NucleantVulkan: this browser has no WebGPU (navigator.gpu)');
  const adapter = await navigator.gpu.requestAdapter({ powerPreference: options.powerPreference ?? 'high-performance' });
  if (!adapter) throw new Error('NucleantVulkan: no WebGPU adapter');
  const requiredFeatures = ['bgra8unorm-storage', 'float32-filterable'].filter((f) => adapter.features.has(f));
  const requiredLimits = {};
  for (const name of ['maxBindGroups', 'maxBufferSize', 'maxStorageBufferBindingSize', 'maxTextureDimension2D',
                      'maxStorageBuffersPerShaderStage', 'maxComputeInvocationsPerWorkgroup',
                      'maxComputeWorkgroupSizeX', 'maxComputeWorkgroupSizeY']) {
    if (name in adapter.limits) requiredLimits[name] = adapter.limits[name];
  }
  const device = await adapter.requestDevice({ requiredFeatures, requiredLimits });
  const naga = await loadNaga(options.nagaURL ?? new URL('naga_webgpu.wasm', import.meta.url));
  const jspi = (options.jspi ?? true) && typeof WebAssembly.Suspending === 'function' && typeof WebAssembly.promising === 'function';
  const bridge = new Bridge(adapter, device, naga, requiredFeatures, jspi, options.onError);
  device.addEventListener('uncapturederror', (event) => bridge.error('WebGPU:', event.error.message));
  device.lost.then((info) => {
    if (info.reason !== 'destroyed') bridge.error('WebGPU device lost:', info.reason, info.message);
  });
  return bridge;
}

async function loadNaga(url) {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`NucleantVulkan: cannot load ${url} (${response.status})`);
  const { instance } = await WebAssembly.instantiate(await response.arrayBuffer(), {});
  return instance.exports;
}

class Bridge {
  constructor(adapter, device, naga, features, jspi, onError) {
    this.onError = onError;
    this.adapter = adapter;
    this.device = device;
    this.naga = naga;
    this.features = new Set(features);
    this.blockingWaits = jspi;
    this.memory = null;

    this.objects = new Map();
    this.nextId = 1;

    this.submitted = 0;
    this.completed = 0;
    this.completion = Promise.resolve();
    this.releasedMemories = new Set();

    this.arena = null;
    this.arenaGeneration = 0;
    this.bindGroups = new Map();      // `${layoutKey}|${setId}` -> { version, group }
    this.setKeys = new Map();         // setId -> Set of keys above
    this.layoutCache = new Map();     // layout key -> GPUBindGroupLayout
    this.emptyGroups = new Map();     // GPUBindGroupLayout -> GPUBindGroup
    this.clearPipelines = new Map();  // pass attachments + what is cleared -> GPURenderPipeline
    this.blitPipelines = new Map();
    this.warned = new Set();

    this.imports = { nucleant_webgpu: this.makeImports(), nucleant_wgpu: makeWgpuImports(this) };
  }

  /** Call once the module is instantiated: the bridge reads and writes its memory. */
  attach(instance) {
    this.memory = instance.exports.memory;
  }

  // MARK: - Handles and memory

  add(object) {
    const id = this.nextId++;
    this.objects.set(id, object);
    return id;
  }

  get(id) {
    return id ? this.objects.get(id) : undefined;
  }

  bytes() { return new Uint8Array(this.memory.buffer); }
  view() { return new DataView(this.memory.buffer); }

  /** Bytes per texel of a GPUTextureFormat, for copies; 0 if not copyable here. */
  texelSize(format) {
    return TEXEL_OF[format] ?? 0;
  }

  string(ptr, length) {
    return new TextDecoder().decode(new Uint8Array(this.memory.buffer, ptr, length));
  }

  /** Every error the bridge sees goes through here (and to `options.onError`). */
  error(...parts) {
    console.error('[NucleantVulkan]', ...parts);
    this.onError?.(parts.join(' '));
  }

  warnOnce(key, message) {
    if (this.warned.has(key)) return;
    this.warned.add(key);
    console.warn('[NucleantVulkan]', message);
  }

  // MARK: - Imports

  makeImports() {
    const waitSerial = async (serial) => {
      while (this.completed < serial) await this.completion;
      return 1;
    };
    return {
      deviceInfo: (ptr) => this.deviceInfo(ptr),
      log: (ptr, length) => console.warn('[NucleantVulkan]', this.string(ptr, length)),

      surfaceCreate: (ptr, length) => this.surfaceCreate(this.string(ptr, length)),
      surfaceDestroy: (id) => this.destroy(id),
      surfaceGetSize: (id, out) => {
        const surface = this.get(id);
        const view = this.view();
        view.setUint32(out, surface ? surface.canvas.width : 0, true);
        view.setUint32(out + 4, surface ? surface.canvas.height : 0, true);
      },
      surfaceConfigure: (id, format, usage, premultiplied) => {
        const surface = this.get(id);
        surface.context.configure({
          device: this.device,
          format: FORMATS[format][0],
          usage,
          alphaMode: premultiplied ? 'premultiplied' : 'opaque',
        });
        surface.configured = true;
        surface.format = FORMATS[format][0];
      },
      surfaceUnconfigure: (id) => {
        const surface = this.get(id);
        if (surface?.configured) surface.context.unconfigure();
        if (surface) surface.configured = false;
      },

      bufferCreate: (size, usage) => this.add({ kind: 'buffer', buffer: this.device.createBuffer({ size, usage }), size }),
      bufferDestroy: (id) => this.destroy(id),
      bufferWrite: (id, offset, ptr, size) => {
        this.device.queue.writeBuffer(this.get(id).buffer, offset, this.memory.buffer, ptr, size);
      },

      textureCreate: (ptr) => this.textureCreate(ptr),
      textureImport: (id, format, width, height) => this.textureImport(id, format, width, height),
      textureExport: (id) => this.textureExport(id),
      textureDestroy: (id) => this.destroy(id),
      viewCreate: (ptr) => this.viewCreate(ptr),
      viewDestroy: (id) => this.objects.delete(id),
      samplerCreate: (ptr) => this.samplerCreate(ptr),
      samplerDestroy: (id) => this.objects.delete(id),

      renderPipelineCreate: (ptr) => this.renderPipelineCreate(ptr),
      computePipelineCreate: (ptr) => this.computePipelineCreate(ptr),
      pipelineDestroy: (id) => this.objects.delete(id),

      descriptorSetRelease: (setId) => {
        for (const key of this.setKeys.get(setId) ?? []) this.bindGroups.delete(key);
        this.setKeys.delete(setId);
      },
      memoryRelease: (memoryId) => this.releasedMemories.add(memoryId),

      queueSubmit: (stream, wordCount, arena, arenaSize) => this.submit(stream, wordCount, arena, arenaSize),
      queueCompletedSerial: () => this.completed,
      queueWaitSerial: this.blockingWaits ? new WebAssembly.Suspending(waitSerial) : () => 0,
    };
  }

  /**
   * Drops an object. A counted one — a webgpu.h object, or a texture both
   * webgpu.h and a VkImage hold — goes with its last reference.
   */
  destroy(id) {
    const object = this.objects.get(id);
    if (!object) return;
    if (object.refs !== undefined && --object.refs > 0) return;
    this.objects.delete(id);
    if (object.kind === 'buffer') object.buffer.destroy();
    else if (object.kind === 'texture') object.texture.destroy();
    else if (object.kind === 'querySet') object.querySet.destroy();
    else if (object.kind === 'surface' && object.configured) object.context.unconfigure();
  }

  deviceInfo(ptr) {
    const view = this.view();
    const limits = this.device.limits;
    const preferred = navigator.gpu.getPreferredCanvasFormat();
    const words = [
      VK_FORMAT_OF[preferred] ?? 44,
      this.features.has('bgra8unorm-storage') ? 1 : 0,
      this.features.has('float32-filterable') ? 1 : 0,
      limits.maxTextureDimension2D,
      limits.maxTextureDimension3D,
      limits.maxTextureArrayLayers,
      limits.maxBindGroups,
      Math.min(limits.maxUniformBufferBindingSize, 0xffffffff),
      Math.min(limits.maxStorageBufferBindingSize, 0xffffffff),
      Math.min(limits.maxBufferSize, 0xffffffff),
      limits.maxComputeWorkgroupsPerDimension,
      limits.maxComputeInvocationsPerWorkgroup,
      this.blockingWaits ? 1 : 0,
    ];
    words.forEach((word, i) => view.setUint32(ptr + i * 4, word >>> 0, true));
    const info = this.adapter.info ?? {};
    const name = new TextEncoder().encode(`${info.vendor ?? ''} ${info.architecture ?? ''} ${info.device ?? ''}`.trim() || 'WebGPU');
    const target = new Uint8Array(this.memory.buffer, ptr + words.length * 4, 200);
    target.fill(0);
    target.set(name.subarray(0, 199));
  }

  // MARK: - Surfaces

  surfaceCreate(selector) {
    const canvas = document.querySelector(selector);
    if (!(canvas instanceof HTMLCanvasElement)) return 0;
    const context = canvas.getContext('webgpu');
    if (!context) return 0;
    return this.add({ kind: 'surface', canvas, context, configured: false, texture: null, view: null });
  }

  /** The texture a swapchain-image view stands for: this frame's canvas texture. */
  resolveView(id) {
    const object = this.get(id);
    if (!object) return null;
    if (object.kind === 'view') return object.view;
    const surface = this.get(object.surface);
    if (!surface) return null;
    if (!surface.view) {
      surface.texture = surface.context.getCurrentTexture();
      surface.view = surface.texture.createView();
      this.frameSurfaces.add(surface);
    }
    return surface.view;
  }

  // MARK: - Textures, views, samplers

  textureCreate(ptr) {
    const v = this.view();
    const u = (i) => v.getUint32(ptr + i * 4, true);
    const format = FORMATS[u(0)];
    if (!format) return 0;
    const dimension = ['1d', '1d', '2d', '3d'][u(6)];
    const texture = this.device.createTexture({
      size: [u(1), u(2), u(3)],
      mipLevelCount: u(4),
      sampleCount: u(5),
      dimension,
      format: format[0],
      usage: u(7),
    });
    return this.add({ kind: 'texture', texture, format: format[0], texel: format[1], width: u(1), height: u(2), refs: 1 });
  }

  /** VK_NUCLEANT_webgpu_objects: a VkImage's reference to a webgpu.h texture. */
  textureImport(id, vkFormat, width, height) {
    const object = this.get(id);
    // A mismatch is the caller's to handle: vkCreateImage fails with
    // VK_ERROR_INVALID_EXTERNAL_HANDLE, and this says why.
    if (object?.kind !== 'texture' || object.refs === undefined) {
      console.warn('[NucleantVulkan]', `vkCreateImage: ${id} is not a WebGPU texture`);
      return 0;
    }
    const format = FORMATS[vkFormat]?.[0];
    if (object.format !== format || object.width !== width || object.height !== height) {
      console.warn('[NucleantVulkan]', `vkCreateImage: the WebGPU texture is ${object.format} ${object.width}x${object.height}, ` +
                   `the image ${format ?? vkFormat} ${width}x${height}`);
      return 0;
    }
    object.refs++;
    return id;
  }

  /**
   * VK_NUCLEANT_webgpu_objects: a webgpu.h reference to a VkImage's texture.
   * The object is the image's own; webgpu.h reads what it needs off the
   * GPUTexture (nucleant-wgpu.js), and releases the reference like any of
   * its own.
   */
  textureExport(id) {
    const object = this.get(id);
    if (object?.kind !== 'texture' || object.refs === undefined) return 0;
    object.refs++;
    return id;
  }

  viewCreate(ptr) {
    const v = this.view();
    const u = (i) => v.getUint32(ptr + i * 4, true);
    if (u(0) === 0) return this.add({ kind: 'surfaceView', surface: u(1) });
    const texture = this.get(u(0));
    const viewFormat = FORMATS[u(2)]?.[0] ?? texture.format;
    const view = texture.texture.createView({
      format: viewFormat,
      dimension: VIEW_DIMENSIONS[u(3)] ?? '2d',
      baseMipLevel: u(4),
      mipLevelCount: u(5),
      baseArrayLayer: u(6),
      arrayLayerCount: u(7),
    });
    return this.add({ kind: 'view', view, format: viewFormat, samples: texture.texture.sampleCount });
  }

  samplerCreate(ptr) {
    const v = this.view();
    const u = (i) => v.getUint32(ptr + i * 4, true);
    const f = (i) => v.getFloat32(ptr + i * 4, true);
    const mag = u(0) === 1 ? 'linear' : 'nearest';
    const min = u(1) === 1 ? 'linear' : 'nearest';
    const mip = u(2) === 1 ? 'linear' : 'nearest';
    const lodMin = Math.max(0, f(6));
    const descriptor = {
      magFilter: mag,
      minFilter: min,
      mipmapFilter: mip,
      addressModeU: ADDRESS_MODES[u(3)] ?? 'clamp-to-edge',
      addressModeV: ADDRESS_MODES[u(4)] ?? 'clamp-to-edge',
      addressModeW: ADDRESS_MODES[u(5)] ?? 'clamp-to-edge',
      lodMinClamp: lodMin,
      lodMaxClamp: Math.max(lodMin, f(7)),
    };
    if (u(8)) descriptor.compare = COMPARE[u(9)];
    // WebGPU allows anisotropy only with every filter linear.
    if (u(10) > 1 && mag === 'linear' && min === 'linear' && mip === 'linear') descriptor.maxAnisotropy = Math.min(u(10), 16);
    return this.add({ kind: 'sampler', sampler: this.device.createSampler(descriptor) });
  }

  // MARK: - Pipelines

  /** SPIR-V -> WGSL plus reflection, through naga_webgpu.wasm. */
  translate(stagePtr, stage, drawGroup) {
    const v = this.view();
    const code = v.getUint32(stagePtr, true);
    const wordCount = v.getUint32(stagePtr + 4, true);
    const entry = v.getUint32(stagePtr + 8, true);
    const entryLength = v.getUint32(stagePtr + 12, true);
    const n = this.naga;
    const spirvBytes = wordCount * 4;
    const spirv = n.nv_alloc(spirvBytes);
    const name = n.nv_alloc(Math.max(entryLength, 1));
    new Uint8Array(n.memory.buffer, spirv, spirvBytes).set(new Uint8Array(this.memory.buffer, code, spirvBytes));
    new Uint8Array(n.memory.buffer, name, entryLength).set(new Uint8Array(this.memory.buffer, entry, entryLength));
    const failed = n.nv_translate(spirv, wordCount, STAGE_CODE[stage], name, entryLength, drawGroup);
    const text = new TextDecoder().decode(new Uint8Array(n.memory.buffer, n.nv_result_ptr(), n.nv_result_len()));
    n.nv_result_free();
    n.nv_dealloc(spirv, spirvBytes);
    n.nv_dealloc(name, Math.max(entryLength, 1));
    if (failed) {
      this.error(`${stage} shader: ${text}`);
      return null;
    }
    const result = JSON.parse(text);
    result.module = this.device.createShaderModule({ code: result.wgsl, label: `${stage}:${result.entryPoint}` });
    result.module.getCompilationInfo?.().then((info) => {
      for (const message of info.messages) {
        if (message.type === 'error') this.error(`WGSL (${stage}) ${message.lineNum}:${message.linePos} ${message.message}\n${result.wgsl}`);
      }
    });
    return result;
  }

  bindGroupLayout(entries) {
    const key = JSON.stringify(entries);
    let layout = this.layoutCache.get(key);
    if (!layout) {
      layout = this.device.createBindGroupLayout({ entries });
      this.layoutCache.set(key, layout);
    }
    return { layout, key, entries };
  }

  /**
   * The pipeline layout: one bind group per descriptor set, built from what
   * the shaders actually use (WebGPU layouts need the storage format, sample
   * type and view dimension a Vulkan set layout doesn't say), then the
   * draw-data group with the emulated push constants / viewport remap.
   */
  pipelineLayout(stages, setCount) {
    const groups = Array.from({ length: setCount }, () => new Map());
    let viewportFix = false;
    let pushSize = 0;
    let pushVisibility = 0;
    for (const stage of stages) {
      const visibility = { vertex: GPUShaderStage.VERTEX, fragment: GPUShaderStage.FRAGMENT, compute: GPUShaderStage.COMPUTE }[stage.stage];
      if (stage.drawData.viewportFix) viewportFix = true;
      if (stage.drawData.pushConstantSize) {
        pushSize = Math.max(pushSize, stage.drawData.pushConstantSize);
        pushVisibility |= visibility;
      }
      for (const b of stage.bindings) {
        if (b.group >= setCount) continue;  // the draw-data group, or a set the layout lacks
        const existing = groups[b.group].get(b.binding);
        if (existing) {
          existing.visibility |= visibility;
          continue;
        }
        const entry = { binding: b.binding, visibility };
        if (b.kind === 'buffer') entry.buffer = { type: b.type };
        else if (b.kind === 'sampler') entry.sampler = { type: b.type };
        else if (b.kind === 'texture') entry.texture = { sampleType: b.sampleType, viewDimension: b.viewDimension, multisampled: b.multisampled };
        else if (b.kind === 'storageTexture') entry.storageTexture = { access: b.access, format: b.format, viewDimension: b.viewDimension };
        groups[b.group].set(b.binding, entry);
      }
    }
    const groupLayouts = groups.map((map) => this.bindGroupLayout([...map.values()].sort((a, b) => a.binding - b.binding)));
    const bindGroupLayouts = groupLayouts.map((g) => g.layout);
    let draw = null;
    if (viewportFix || pushSize) {
      const entries = [];
      if (viewportFix) {
        entries.push({ binding: 0, visibility: GPUShaderStage.VERTEX, buffer: { type: 'read-only-storage', hasDynamicOffset: true, minBindingSize: 16 } });
      }
      if (pushSize) {
        entries.push({ binding: 1, visibility: pushVisibility, buffer: { type: 'read-only-storage', hasDynamicOffset: true, minBindingSize: pushSize } });
      }
      draw = { ...this.bindGroupLayout(entries), group: setCount, viewportFix, pushSize, groups: new Map() };
      bindGroupLayouts.push(draw.layout);
    }
    return { layout: this.device.createPipelineLayout({ bindGroupLayouts }), groupLayouts, draw };
  }

  renderPipelineCreate(ptr) {
    const v = this.view();
    const u = (i) => v.getUint32(ptr + i * 4, true);
    const hasFragment = u(8);
    const setCount = u(9);
    const vertex = this.translate(ptr, 'vertex', setCount);
    const fragment = hasFragment ? this.translate(ptr + 16, 'fragment', setCount) : null;
    if (!vertex || (hasFragment && !fragment)) return 0;
    const layout = this.pipelineLayout(fragment ? [vertex, fragment] : [vertex], setCount);

    const cull = u(11);
    if (cull === 3) this.warnOnce('cull-both', 'cullMode FRONT_AND_BACK has no WebGPU equivalent; culling nothing');
    const targets = [];
    for (let i = 0; i < u(14); i++) {
      const base = 15 + i * 9;
      const format = FORMATS[u(base)];
      if (!format) {
        targets.push(null);
        continue;
      }
      const target = { format: format[0], writeMask: u(base + 8) };
      if (u(base + 1)) {
        target.blend = {
          color: { srcFactor: BLEND_FACTORS[u(base + 2)], dstFactor: BLEND_FACTORS[u(base + 3)], operation: BLEND_OPS[u(base + 4)] },
          alpha: { srcFactor: BLEND_FACTORS[u(base + 5)], dstFactor: BLEND_FACTORS[u(base + 6)], operation: BLEND_OPS[u(base + 7)] },
        };
      }
      targets.push(target);
    }
    const topology = TOPOLOGY[u(10)];
    if (!topology) {
      this.error('primitive topology', u(10), 'has no WebGPU equivalent');
      return 0;
    }

    // Vertex input: WebGPU numbers its buffers by slot, Vulkan by binding —
    // the bindings in order are the slots.
    const bindings = [];
    for (let b = 0; b < u(DESC_BINDINGS); b++) {
      const base = DESC_BINDINGS + 1 + b * 3;
      bindings.push({ binding: u(base), stride: u(base + 1), perInstance: u(base + 2) });
    }
    bindings.sort((a, b) => a.binding - b.binding);
    const buffers = bindings.map((b) => ({ arrayStride: b.stride, stepMode: b.perInstance ? 'instance' : 'vertex', attributes: [] }));
    for (let a = 0; a < u(DESC_ATTRIBUTES); a++) {
      const base = DESC_ATTRIBUTES + 1 + a * 4;
      const format = VERTEX_FORMATS[u(base + 2)];
      const slot = bindings.findIndex((b) => b.binding === u(base + 1));
      if (!format || slot < 0) {
        this.error(`vertex attribute ${u(base)}: VkFormat ${u(base + 2)} has no WebGPU vertex format`);
        return 0;
      }
      buffers[slot].attributes.push({ shaderLocation: u(base), format, offset: u(base + 3) });
    }

    const descriptor = {
      layout: layout.layout,
      vertex: { module: vertex.module, entryPoint: vertex.entryPoint, buffers },
      primitive: {
        topology,
        cullMode: ['none', 'front', 'back', 'none'][cull] ?? 'none',
        frontFace: u(12) === 1 ? 'cw' : 'ccw',
      },
      multisample: { count: u(13) || 1 },
    };
    if (fragment) descriptor.fragment = { module: fragment.module, entryPoint: fragment.entryPoint, targets };

    // Depth/stencil, exactly when the pass has the attachment.
    const depthFormat = FORMATS[u(DESC_DEPTH)]?.[0];
    let stencil = false;
    if (depthFormat) {
      const depthStencil = {
        format: depthFormat,
        depthWriteEnabled: !!u(DESC_DEPTH + 2),
        depthCompare: u(DESC_DEPTH + 1) ? COMPARE[u(DESC_DEPTH + 3)] : 'always',
      };
      if (STENCIL_FORMATS.has(depthFormat) && u(DESC_DEPTH + 4)) {
        stencil = true;
        const face = (base) => ({
          compare: COMPARE[u(base)], failOp: STENCIL_OPS[u(base + 1)], depthFailOp: STENCIL_OPS[u(base + 2)], passOp: STENCIL_OPS[u(base + 3)],
        });
        depthStencil.stencilFront = face(DESC_DEPTH + 5);
        depthStencil.stencilBack = face(DESC_DEPTH + 9);
        depthStencil.stencilReadMask = u(DESC_DEPTH + 13);
        depthStencil.stencilWriteMask = u(DESC_DEPTH + 14);
      }
      descriptor.depthStencil = depthStencil;
    }
    const pipeline = this.device.createRenderPipeline(descriptor);
    return this.add({
      kind: 'renderPipeline', pipeline, setCount, ...layout, descriptor, stencil,
      strip: topology.endsWith('-strip'), vertexSlots: bindings.map((b) => b.binding), variants: new Map(),
    });
  }

  /**
   * The GPURenderPipeline for a draw. WebGPU bakes into the pipeline what
   * Vulkan sets per draw: the stencil compare/write masks (dynamic state) and,
   * for an indexed strip, the index format its restarts are read in. Each
   * combination in use gets a pipeline of its own, made once.
   */
  pipelineVariant(pipeline, masks, indexFormat) {
    const stencil = pipeline.stencil && masks
      && (masks[0] !== pipeline.descriptor.depthStencil.stencilReadMask || masks[1] !== pipeline.descriptor.depthStencil.stencilWriteMask);
    const strip = pipeline.strip && indexFormat;
    if (!stencil && !strip) return pipeline.pipeline;
    const key = `${stencil ? masks.join(',') : ''}|${strip ? indexFormat : ''}`;
    let variant = pipeline.variants.get(key);
    if (!variant) {
      const descriptor = { ...pipeline.descriptor };
      if (stencil) descriptor.depthStencil = { ...descriptor.depthStencil, stencilReadMask: masks[0], stencilWriteMask: masks[1] };
      if (strip) descriptor.primitive = { ...descriptor.primitive, stripIndexFormat: indexFormat };
      variant = this.device.createRenderPipeline(descriptor);
      pipeline.variants.set(key, variant);
    }
    return variant;
  }

  /** The pipeline vkCmdClearAttachments draws with in a pass of `info`'s attachments. */
  clearPipeline(info, colorMask, depth, stencil) {
    const key = `${info.colorFormats.join(',')}|${info.depthFormat ?? ''}|${info.samples}|${colorMask}|${depth}|${stencil}`;
    let pipeline = this.clearPipelines.get(key);
    if (pipeline) return pipeline;
    const colorCount = info.colorFormats.length;
    const module = this.device.createShaderModule({ code: CLEAR_SHADER(colorCount), label: 'vkCmdClearAttachments' });
    const constant = { srcFactor: 'constant', dstFactor: 'zero', operation: 'add' };
    const descriptor = {
      layout: this.device.createPipelineLayout({ bindGroupLayouts: [] }),
      vertex: { module, entryPoint: 'vs' },
      primitive: { topology: 'triangle-list' },
      multisample: { count: info.samples },
    };
    if (colorCount) {
      descriptor.fragment = {
        module, entryPoint: 'fs',
        targets: info.colorFormats.map((format, i) => format
          ? { format, writeMask: colorMask & (1 << i) ? GPUColorWrite.ALL : 0, blend: { color: constant, alpha: constant } }
          : null),
      };
    }
    if (info.depthFormat) {
      descriptor.depthStencil = { format: info.depthFormat, depthWriteEnabled: depth, depthCompare: 'always' };
      if (STENCIL_FORMATS.has(info.depthFormat)) {
        const face = { compare: 'always', failOp: 'keep', depthFailOp: 'keep', passOp: stencil ? 'replace' : 'keep' };
        Object.assign(descriptor.depthStencil, { stencilFront: face, stencilBack: face, stencilWriteMask: stencil ? 0xff : 0 });
      }
    }
    pipeline = this.device.createRenderPipeline(descriptor);
    this.clearPipelines.set(key, pipeline);
    return pipeline;
  }

  computePipelineCreate(ptr) {
    const setCount = this.view().getUint32(ptr + 16, true);
    const compute = this.translate(ptr, 'compute', setCount);
    if (!compute) return 0;
    const layout = this.pipelineLayout([compute], setCount);
    const pipeline = this.device.createComputePipeline({
      layout: layout.layout,
      compute: { module: compute.module, entryPoint: compute.entryPoint },
    });
    return this.add({ kind: 'computePipeline', pipeline, setCount, ...layout });
  }

  // MARK: - Bind groups

  /** The GPUBindGroup for descriptor set `set` under `groupLayout`, cached per set version. */
  bindGroupFor(groupLayout, set) {
    if (groupLayout.entries.length === 0) {
      let group = this.emptyGroups.get(groupLayout.layout);
      if (!group) {
        group = this.device.createBindGroup({ layout: groupLayout.layout, entries: [] });
        this.emptyGroups.set(groupLayout.layout, group);
      }
      return group;
    }
    if (!set) return null;
    const key = `${groupLayout.key}|${set.setId}`;
    const cached = this.bindGroups.get(key);
    if (cached && cached.version === set.version) return cached.group;

    const byBinding = new Map(set.descriptors.map((d) => [d.binding, d]));
    const entries = [];
    for (const layoutEntry of groupLayout.entries) {
      const binding = layoutEntry.binding;
      let resource = null;
      if (layoutEntry.sampler) {
        // A split combined sampler sits SAMPLER_BINDING_OFFSET above its image.
        const combined = binding >= SAMPLER_BINDING_OFFSET ? byBinding.get(binding - SAMPLER_BINDING_OFFSET) : null;
        if (combined?.type === DESC.COMBINED) resource = this.get(combined.b)?.sampler;
        else if (byBinding.get(binding)?.type === DESC.SAMPLER) resource = this.get(byBinding.get(binding).a)?.sampler;
      } else if (layoutEntry.texture || layoutEntry.storageTexture) {
        const d = byBinding.get(binding);
        if (d && (d.type === DESC.COMBINED || d.type === DESC.SAMPLED_IMAGE || d.type === DESC.STORAGE_IMAGE)) resource = this.resolveView(d.a);
      } else if (layoutEntry.buffer) {
        const d = byBinding.get(binding);
        const buffer = d && this.get(d.a);
        if (buffer) resource = d.c ? { buffer: buffer.buffer, offset: d.b, size: d.c } : { buffer: buffer.buffer, offset: d.b };
      }
      if (!resource) {
        this.warnOnce(`missing:${set.setId}:${binding}`, `descriptor set ${set.setId}: binding ${binding} is used by the pipeline but holds nothing; draw skipped`);
        return null;
      }
      entries.push({ binding, resource });
    }
    const group = this.device.createBindGroup({ layout: groupLayout.layout, entries });
    this.bindGroups.set(key, { version: set.version, group });
    if (!this.setKeys.has(set.setId)) this.setKeys.set(set.setId, new Set());
    this.setKeys.get(set.setId).add(key);
    return group;
  }

  drawBindGroup(draw) {
    let group = draw.groups.get(this.arenaGeneration);
    if (!group) {
      const entries = [];
      if (draw.viewportFix) entries.push({ binding: 0, resource: { buffer: this.arena, offset: 0, size: 16 } });
      if (draw.pushSize) entries.push({ binding: 1, resource: { buffer: this.arena, offset: 0, size: draw.pushSize } });
      group = this.device.createBindGroup({ layout: draw.layout, entries });
      draw.groups.clear();
      draw.groups.set(this.arenaGeneration, group);
    }
    return group;
  }

  // MARK: - Submit

  ensureArena(size) {
    if (this.arena && this.arena.size >= size) return;
    let capacity = this.arena ? this.arena.size : 64 * 1024;
    while (capacity < size) capacity *= 2;
    const old = this.arena;
    if (old) this.device.queue.onSubmittedWorkDone().then(() => old.destroy());
    this.arena = this.device.createBuffer({
      size: capacity,
      usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_SRC | GPUBufferUsage.COPY_DST,
      label: 'NucleantVulkan arena',
    });
    this.arenaGeneration++;
  }

  submit(streamPtr, wordCount, arenaPtr, arenaSize) {
    const device = this.device;
    if (arenaSize > 0) {
      this.ensureArena(arenaSize);
      device.queue.writeBuffer(this.arena, 0, this.memory.buffer, arenaPtr, alignUp(arenaSize, 4));
    } else {
      this.ensureArena(4);
    }
    const words = new Uint32Array(this.memory.buffer, streamPtr, wordCount);
    const floats = new Float32Array(this.memory.buffer, streamPtr, wordCount);
    const encoder = device.createCommandEncoder();
    this.frameSurfaces = new Set();
    const scratch = [];
    const readbacks = [];

    // Vulkan command-buffer state (it survives render passes) and what the
    // current WebGPU pass has actually been given (it doesn't).
    const logical = {
      pipeline: [null, null], sets: [[], []], drawData: [0, 0],
      vertexBuffers: [], index: null, stencilMasks: null, stencilReference: 0, blendConstant: [0, 0, 0, 0],
    };
    let pass = null;
    let passInfo = null;
    let applied = null;
    const resetApplied = () => {
      applied = { pipeline: null, gpuPipeline: null, groups: [], draw: -1, vertex: [], index: null, stencilReference: null, blendConstant: null };
    };
    const formatOfView = (id) => {
      const object = this.get(id);
      return object?.kind === 'view' ? object.format : this.get(object?.surface)?.format;
    };

    const apply = (bindPoint, kind, indexed = false) => {
      const pipeline = this.get(logical.pipeline[bindPoint]);
      if (!pipeline || pipeline.kind !== kind) return false;
      const indexFormat = indexed ? logical.index?.format : undefined;
      if (indexed && !indexFormat) {
        this.warnOnce('no-index-buffer', 'vkCmdDrawIndexed without an index buffer bound; draw skipped');
        return false;
      }
      const gpuPipeline = kind === 'renderPipeline' ? this.pipelineVariant(pipeline, logical.stencilMasks, indexFormat) : pipeline.pipeline;
      if (applied.gpuPipeline !== gpuPipeline) {
        pass.setPipeline(gpuPipeline);
        applied.gpuPipeline = gpuPipeline;
      }
      if (applied.pipeline !== pipeline) {
        applied.pipeline = pipeline;
        applied.groups = [];
        applied.draw = -1;
      }
      if (kind === 'renderPipeline') {
        for (let slot = 0; slot < pipeline.vertexSlots.length; slot++) {
          const bound = logical.vertexBuffers[pipeline.vertexSlots[slot]];
          const buffer = this.get(bound?.buffer);
          if (!buffer) {
            this.warnOnce(`no-vertex-buffer:${pipeline.vertexSlots[slot]}`,
                          `no vertex buffer bound at binding ${pipeline.vertexSlots[slot]}; draw skipped`);
            return false;
          }
          const current = applied.vertex[slot];
          if (!current || current.buffer !== bound.buffer || current.offset !== bound.offset) {
            pass.setVertexBuffer(slot, buffer.buffer, bound.offset);
            applied.vertex[slot] = bound;
          }
        }
        if (indexed && applied.index !== logical.index) {
          const buffer = this.get(logical.index.buffer);
          if (!buffer) return false;
          pass.setIndexBuffer(buffer.buffer, logical.index.format, logical.index.offset);
          applied.index = logical.index;
        }
        if (passInfo?.stencil && applied.stencilReference !== logical.stencilReference) {
          pass.setStencilReference(logical.stencilReference);
          applied.stencilReference = logical.stencilReference;
        }
        if (applied.blendConstant !== logical.blendConstant) {
          pass.setBlendConstant(logical.blendConstant);
          applied.blendConstant = logical.blendConstant;
        }
      }
      for (let g = 0; g < pipeline.setCount; g++) {
        const group = this.bindGroupFor(pipeline.groupLayouts[g], logical.sets[bindPoint][g]);
        if (!group) return false;
        if (applied.groups[g] !== group) {
          pass.setBindGroup(g, group);
          applied.groups[g] = group;
        }
      }
      if (pipeline.draw) {
        const offset = logical.drawData[bindPoint];
        if (applied.draw !== offset) {
          const offsets = [];
          if (pipeline.draw.viewportFix) offsets.push(offset);
          if (pipeline.draw.pushSize) offsets.push(offset + PUSH_CONSTANT_OFFSET);
          pass.setBindGroup(pipeline.draw.group, this.drawBindGroup(pipeline.draw), offsets);
          applied.draw = offset;
        }
      }
      return true;
    };

    let i = 0;
    const next = () => words[i++];
    while (i < wordCount) {
      const op = next();
      switch (op) {
        case OP.BEGIN_RENDER_PASS: {
          const count = next();
          const colorAttachments = [];
          const colorFormats = [];
          let samples = 0;
          for (let a = 0; a < count; a++) {
            const viewId = next(), load = next(), store = next();
            const clearValue = [floats[i], floats[i + 1], floats[i + 2], floats[i + 3]];
            i += 4;
            const view = viewId ? this.resolveView(viewId) : null;
            colorAttachments.push(view ? { view, loadOp: load ? 'clear' : 'load', storeOp: store ? 'discard' : 'store', clearValue } : null);
            colorFormats.push(view ? formatOfView(viewId) : null);
            if (view && samples === 0) samples = this.get(viewId)?.samples ?? 1;
          }
          const depthId = next(), depthLoad = next(), depthStore = next(), depthClear = floats[i++];
          const stencilLoad = next(), stencilStore = next(), stencilClear = next();
          const width = next(), height = next();
          const descriptor = { colorAttachments };
          const depthFormat = depthId ? formatOfView(depthId) : null;
          if (depthId) {
            const attachment = {
              view: this.resolveView(depthId),
              depthLoadOp: depthLoad ? 'clear' : 'load', depthStoreOp: depthStore ? 'discard' : 'store', depthClearValue: depthClear,
            };
            if (STENCIL_FORMATS.has(depthFormat)) {
              Object.assign(attachment, { stencilLoadOp: stencilLoad ? 'clear' : 'load', stencilStoreOp: stencilStore ? 'discard' : 'store', stencilClearValue: stencilClear });
            }
            descriptor.depthStencilAttachment = attachment;
            if (samples === 0) samples = this.get(depthId)?.samples ?? 1;
          }
          pass = encoder.beginRenderPass(descriptor);
          passInfo = { colorFormats, depthFormat, stencil: STENCIL_FORMATS.has(depthFormat), samples: samples || 1, width, height };
          resetApplied();
          break;
        }
        case OP.END_RENDER_PASS:
        case OP.END_COMPUTE_PASS:
          pass?.end();
          pass = null;
          break;
        case OP.SET_PIPELINE: {
          const bindPoint = next();
          logical.pipeline[bindPoint] = next();
          break;
        }
        case OP.BIND_SET: {
          const bindPoint = next(), index = next(), setId = next(), version = next(), count = next();
          const descriptors = [];
          for (let d = 0; d < count; d++) descriptors.push({ binding: next(), type: next(), a: next(), b: next(), c: next() });
          logical.sets[bindPoint][index] = { setId, version, descriptors };
          break;
        }
        case OP.SET_VIEWPORT:
          pass.setViewport(floats[i], floats[i + 1], floats[i + 2], floats[i + 3], floats[i + 4], floats[i + 5]);
          i += 6;
          break;
        case OP.SET_SCISSOR:
          pass.setScissorRect(words[i], words[i + 1], words[i + 2], words[i + 3]);
          i += 4;
          break;
        case OP.DRAW_DATA: {
          const bindPoint = next();
          logical.drawData[bindPoint] = next();
          break;
        }
        case OP.DRAW: {
          const vertexCount = next(), instanceCount = next(), firstVertex = next(), firstInstance = next();
          if (apply(0, 'renderPipeline')) pass.draw(vertexCount, instanceCount, firstVertex, firstInstance);
          break;
        }
        case OP.DRAW_INDEXED: {
          const indexCount = next(), instanceCount = next(), firstIndex = next(), baseVertex = next() | 0, firstInstance = next();
          if (apply(0, 'renderPipeline', true)) pass.drawIndexed(indexCount, instanceCount, firstIndex, baseVertex, firstInstance);
          break;
        }
        case OP.SET_VERTEX_BUFFER: {
          const binding = next(), buffer = next(), offset = next();
          logical.vertexBuffers[binding] = { buffer, offset };
          break;
        }
        case OP.SET_INDEX_BUFFER: {
          const buffer = next(), offset = next(), wide = next();
          logical.index = { buffer, offset, format: wide ? 'uint32' : 'uint16' };
          break;
        }
        case OP.SET_STENCIL_REFERENCE:
          logical.stencilReference = next();
          break;
        case OP.SET_STENCIL_MASKS:
          logical.stencilMasks = [next(), next()];
          break;
        case OP.SET_BLEND_CONSTANT:
          logical.blendConstant = [floats[i], floats[i + 1], floats[i + 2], floats[i + 3]];
          i += 4;
          break;
        case OP.CLEAR_ATTACHMENTS: {
          const x = next(), y = next(), width = next(), height = next(), colorCount = next();
          const colors = [];
          for (let c = 0; c < colorCount; c++) {
            colors.push({ index: next(), value: [floats[i], floats[i + 1], floats[i + 2], floats[i + 3]] });
            i += 4;
          }
          const clearDepth = next() === 1, depth = floats[i++], clearStencil = next() === 1, stencil = next();
          if (!pass || !passInfo) break;
          // One draw per colour (each its own blend constant); depth and
          // stencil go with the first.
          const draws = colors.filter((c) => passInfo.colorFormats[c.index]).map((c) => ({ mask: 1 << c.index, value: c.value, depth: false, stencil: false }));
          const ds = { depth: clearDepth && !!passInfo.depthFormat, stencil: clearStencil && passInfo.stencil };
          if (ds.depth || ds.stencil) {
            if (draws.length) Object.assign(draws[0], ds);
            else draws.push({ mask: 0, value: [0, 0, 0, 0], ...ds });
          }
          for (const draw of draws) {
            pass.setPipeline(this.clearPipeline(passInfo, draw.mask, draw.depth, draw.stencil));
            pass.setViewport(0, 0, passInfo.width, passInfo.height, draw.depth ? depth : 0, draw.depth ? depth : 1);
            pass.setScissorRect(x, y, width, height);
            pass.setBlendConstant(draw.value);
            if (draw.stencil) pass.setStencilReference(stencil);
            pass.draw(3);
          }
          // What it changed is given again before the next draw (the C side
          // re-sends the viewport and scissor).
          Object.assign(applied, { pipeline: null, gpuPipeline: null, groups: [], draw: -1, stencilReference: null, blendConstant: null });
          break;
        }
        case OP.DRAW_INDIRECT: {
          const buffer = this.get(next()), offset = next();
          if (buffer && apply(0, 'renderPipeline')) pass.drawIndirect(buffer.buffer, offset);
          break;
        }
        case OP.BEGIN_COMPUTE_PASS:
          pass = encoder.beginComputePass();
          resetApplied();
          break;
        case OP.DISPATCH: {
          const x = next(), y = next(), z = next();
          if (apply(1, 'computePipeline')) pass.dispatchWorkgroups(x, y, z);
          break;
        }
        case OP.COPY_BUFFER_TO_BUFFER: {
          const src = this.get(next()), srcOffset = next(), dst = this.get(next()), dstOffset = next(), size = next();
          encoder.copyBufferToBuffer(src.buffer, srcOffset, dst.buffer, dstOffset, size);
          break;
        }
        case OP.COPY_BUFFER_TO_TEXTURE: {
          const bufferId = next(), offset = next(), bytesPerRow = next(), rowsPerImage = next();
          const texture = this.get(next()), mipLevel = next(), x = next(), y = next(), z = next();
          const width = next(), height = next(), depth = next();
          const source = bufferId ? this.get(bufferId).buffer : this.arena;
          this.copyBufferToTexture(encoder, scratch, source, offset, bytesPerRow, rowsPerImage, texture, mipLevel, [x, y, z], [width, height, depth]);
          break;
        }
        case OP.COPY_TEXTURE_TO_BUFFER: {
          const texture = this.get(next()), mipLevel = next(), x = next(), y = next(), z = next();
          const width = next(), height = next(), depth = next();
          const buffer = this.get(next()), offset = next(), bytesPerRow = next(), rowsPerImage = next();
          this.copyTextureToBuffer(encoder, scratch, texture, mipLevel, [x, y, z], [width, height, depth], buffer.buffer, offset, bytesPerRow, rowsPerImage);
          break;
        }
        case OP.COPY_TEXTURE_TO_TEXTURE: {
          const src = this.get(next()), srcMip = next(), sx = next(), sy = next(), sz = next();
          const dst = this.get(next()), dstMip = next(), dx = next(), dy = next(), dz = next();
          const width = next(), height = next(), depth = next();
          encoder.copyTextureToTexture(
            { texture: src.texture, mipLevel: srcMip, origin: [sx, sy, sz] },
            { texture: dst.texture, mipLevel: dstMip, origin: [dx, dy, dz] },
            [width, height, depth]);
          break;
        }
        case OP.CLEAR_TEXTURE: {
          const texture = this.get(next()), mipLevel = next(), layer = next();
          const clearValue = [floats[i], floats[i + 1], floats[i + 2], floats[i + 3]];
          i += 4;
          const view = texture.texture.createView({ dimension: '2d', baseMipLevel: mipLevel, mipLevelCount: 1, baseArrayLayer: layer, arrayLayerCount: 1 });
          encoder.beginRenderPass({ colorAttachments: [{ view, loadOp: 'clear', storeOp: 'store', clearValue }] }).end();
          break;
        }
        case OP.BLIT_TEXTURE: {
          const src = this.get(next()), srcMip = next(), srcLayer = next();
          const s = [next() | 0, next() | 0, next() | 0, next() | 0];
          const dst = this.get(next()), dstMip = next(), dstLayer = next();
          const d = [next() | 0, next() | 0, next() | 0, next() | 0];
          const linear = next() === 1;
          this.blit(encoder, scratch, src, srcMip, srcLayer, s, dst, dstMip, dstLayer, d, linear);
          break;
        }
        case OP.READBACK: {
          readbacks.push({ buffer: this.get(next()), offset: next(), size: next(), memory: next(), host: next() });
          break;
        }
        default:
          this.error('unknown stream op', op, 'at word', i - 1);
          i = wordCount;
      }
    }
    if (pass) pass.end();

    // Readbacks: copy what the GPU wrote into mappable buffers, and once
    // they map, into the memory's host shadow.
    const staged = [];
    for (const r of readbacks) {
      if (!r.buffer) continue;
      const start = r.offset & ~3;
      const size = alignUp(r.offset + r.size, 4) - start;
      const staging = device.createBuffer({ size, usage: GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST });
      encoder.copyBufferToBuffer(r.buffer.buffer, start, staging, 0, size);
      staged.push({ ...r, staging, delta: r.offset - start });
    }

    device.queue.submit([encoder.finish()]);
    for (const surface of this.frameSurfaces) {
      surface.view = null;
      surface.texture = null;
    }
    const serial = ++this.submitted;
    const done = Promise.all([
      device.queue.onSubmittedWorkDone(),
      ...staged.map((r) => r.staging.mapAsync(GPUMapMode.READ).then(() => {
        if (!this.releasedMemories.has(r.memory)) {
          const data = new Uint8Array(r.staging.getMappedRange(), r.delta, r.size);
          new Uint8Array(this.memory.buffer).set(data, r.host);
        }
        r.staging.unmap();
        r.staging.destroy();
      })),
    ]).then(() => {
      for (const buffer of scratch) buffer.destroy();
    });
    // Completion is in submission order, as fences signal on a Vulkan queue.
    this.completion = this.completion.then(() => done).then(() => { this.completed = Math.max(this.completed, serial); });
    return serial;
  }

  // MARK: - Copies WebGPU constrains more than Vulkan

  copyBufferToTexture(encoder, scratch, source, offset, bytesPerRow, rowsPerImage, texture, mipLevel, origin, size) {
    const [width, height, depth] = size;
    if (bytesPerRow % 256 === 0) {
      encoder.copyBufferToTexture({ buffer: source, offset, bytesPerRow, rowsPerImage },
                                  { texture: texture.texture, mipLevel, origin }, size);
      return;
    }
    // Repack rows to a 256-byte pitch on the GPU, then copy from there.
    const rowBytes = width * texture.texel;
    const pitch = alignUp(rowBytes, 256);
    if (rowBytes % 4 !== 0 || bytesPerRow % 4 !== 0 || offset % 4 !== 0) {
      this.warnOnce('copy-align', 'buffer->image copy with rows not 4-byte aligned is not supported on WebGPU');
      return;
    }
    const temp = this.device.createBuffer({ size: pitch * height * depth, usage: GPUBufferUsage.COPY_SRC | GPUBufferUsage.COPY_DST });
    scratch.push(temp);
    for (let layer = 0; layer < depth; layer++) {
      for (let row = 0; row < height; row++) {
        encoder.copyBufferToBuffer(source, offset + (layer * rowsPerImage + row) * bytesPerRow, temp, (layer * height + row) * pitch, rowBytes);
      }
    }
    encoder.copyBufferToTexture({ buffer: temp, offset: 0, bytesPerRow: pitch, rowsPerImage: height },
                                { texture: texture.texture, mipLevel, origin }, size);
  }

  copyTextureToBuffer(encoder, scratch, texture, mipLevel, origin, size, buffer, offset, bytesPerRow, rowsPerImage) {
    const [width, height, depth] = size;
    if (bytesPerRow % 256 === 0) {
      encoder.copyTextureToBuffer({ texture: texture.texture, mipLevel, origin },
                                  { buffer, offset, bytesPerRow, rowsPerImage }, size);
      return;
    }
    const rowBytes = width * texture.texel;
    const pitch = alignUp(rowBytes, 256);
    if (rowBytes % 4 !== 0 || bytesPerRow % 4 !== 0 || offset % 4 !== 0) {
      this.warnOnce('copy-align', 'image->buffer copy with rows not 4-byte aligned is not supported on WebGPU');
      return;
    }
    const temp = this.device.createBuffer({ size: pitch * height * depth, usage: GPUBufferUsage.COPY_SRC | GPUBufferUsage.COPY_DST });
    scratch.push(temp);
    encoder.copyTextureToBuffer({ texture: texture.texture, mipLevel, origin },
                                { buffer: temp, offset: 0, bytesPerRow: pitch, rowsPerImage: height }, size);
    for (let layer = 0; layer < depth; layer++) {
      for (let row = 0; row < height; row++) {
        encoder.copyBufferToBuffer(temp, (layer * height + row) * pitch, buffer, offset + (layer * rowsPerImage + row) * bytesPerRow, rowBytes);
      }
    }
  }

  /** vkCmdBlitImage: a scaled (and possibly mirrored) copy, drawn as a textured quad. */
  blit(encoder, scratch, src, srcMip, srcLayer, s, dst, dstMip, dstLayer, d, linear) {
    const sw = s[2] - s[0], sh = s[3] - s[1], dw = d[2] - d[0], dh = d[3] - d[1];
    if (sw === dw && sh === dh && sw > 0 && sh > 0 && src.format === dst.format) {
      encoder.copyTextureToTexture(
        { texture: src.texture, mipLevel: srcMip, origin: [s[0], s[1], srcLayer] },
        { texture: dst.texture, mipLevel: dstMip, origin: [d[0], d[1], dstLayer] },
        [sw, sh, 1]);
      return;
    }
    let pipeline = this.blitPipelines.get(dst.format);
    if (!pipeline) {
      const module = this.device.createShaderModule({ code: BLIT_SHADER });
      pipeline = this.device.createRenderPipeline({
        layout: 'auto',
        vertex: { module, entryPoint: 'vs' },
        fragment: { module, entryPoint: 'fs', targets: [{ format: dst.format }] },
        primitive: { topology: 'triangle-strip' },
      });
      this.blitPipelines.set(dst.format, pipeline);
    }
    const srcWidth = Math.max(1, src.width >> srcMip), srcHeight = Math.max(1, src.height >> srcMip);
    // The target's left/top edge shows whichever source edge maps there:
    // a destination given right-to-left (or bottom-up) mirrors the image.
    const left = dw >= 0 ? s[0] : s[2], right = dw >= 0 ? s[2] : s[0];
    const top = dh >= 0 ? s[1] : s[3], bottom = dh >= 0 ? s[3] : s[1];
    const rect = new Float32Array([left / srcWidth, top / srcHeight, right / srcWidth, bottom / srcHeight]);
    const uniform = this.device.createBuffer({ size: 16, usage: GPUBufferUsage.UNIFORM, mappedAtCreation: true });
    new Float32Array(uniform.getMappedRange()).set(rect);
    uniform.unmap();
    scratch.push(uniform);
    const sampler = this.device.createSampler({ magFilter: linear ? 'linear' : 'nearest', minFilter: linear ? 'linear' : 'nearest' });
    const group = this.device.createBindGroup({
      layout: pipeline.getBindGroupLayout(0),
      entries: [
        { binding: 0, resource: src.texture.createView({ dimension: '2d', baseMipLevel: srcMip, mipLevelCount: 1, baseArrayLayer: srcLayer, arrayLayerCount: 1 }) },
        { binding: 1, resource: sampler },
        { binding: 2, resource: { buffer: uniform } },
      ],
    });
    const view = dst.texture.createView({ dimension: '2d', baseMipLevel: dstMip, mipLevelCount: 1, baseArrayLayer: dstLayer, arrayLayerCount: 1 });
    const pass = encoder.beginRenderPass({ colorAttachments: [{ view, loadOp: 'load', storeOp: 'store' }] });
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, group);
    pass.setViewport(Math.min(d[0], d[2]), Math.min(d[1], d[3]), Math.abs(dw), Math.abs(dh), 0, 1);
    pass.draw(4);
    pass.end();
  }
}
