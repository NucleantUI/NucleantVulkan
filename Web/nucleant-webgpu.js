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
  READBACK: 19,
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
    const view = texture.texture.createView({
      format: FORMATS[u(2)]?.[0] ?? texture.format,
      dimension: VIEW_DIMENSIONS[u(3)] ?? '2d',
      baseMipLevel: u(4),
      mipLevelCount: u(5),
      baseArrayLayer: u(6),
      arrayLayerCount: u(7),
    });
    return this.add({ kind: 'view', view });
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
    const descriptor = {
      layout: layout.layout,
      vertex: { module: vertex.module, entryPoint: vertex.entryPoint },
      primitive: {
        topology,
        cullMode: ['none', 'front', 'back', 'none'][cull] ?? 'none',
        frontFace: u(12) === 1 ? 'cw' : 'ccw',
      },
      multisample: { count: u(13) || 1 },
    };
    if (fragment) descriptor.fragment = { module: fragment.module, entryPoint: fragment.entryPoint, targets };
    const pipeline = this.device.createRenderPipeline(descriptor);
    return this.add({ kind: 'renderPipeline', pipeline, setCount, ...layout });
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
    const logical = { pipeline: [null, null], sets: [[], []], drawData: [0, 0] };
    let pass = null;
    let applied = null;
    const resetApplied = () => { applied = { pipeline: null, groups: [], draw: -1 }; };

    const apply = (bindPoint, kind) => {
      const pipeline = this.get(logical.pipeline[bindPoint]);
      if (!pipeline || pipeline.kind !== kind) return false;
      if (applied.pipeline !== pipeline) {
        pass.setPipeline(pipeline.pipeline);
        applied.pipeline = pipeline;
        applied.groups = [];
        applied.draw = -1;
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
          for (let a = 0; a < count; a++) {
            const viewId = next(), load = next(), store = next();
            const clearValue = [floats[i], floats[i + 1], floats[i + 2], floats[i + 3]];
            i += 4;
            const view = viewId ? this.resolveView(viewId) : null;
            colorAttachments.push(view ? { view, loadOp: load ? 'clear' : 'load', storeOp: store ? 'discard' : 'store', clearValue } : null);
          }
          pass = encoder.beginRenderPass({ colorAttachments });
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
