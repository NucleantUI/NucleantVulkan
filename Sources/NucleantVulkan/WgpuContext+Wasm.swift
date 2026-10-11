//
//  WgpuContext+Wasm.swift
//  NucleantVulkan
//
//  `WgpuContext` on WebAssembly. Everywhere else this type bootstraps
//  wgpu-native — a second GPU device next to Vulkan — and mints the textures
//  ThorVG's wg engine draws into, which the engine then imports as VkImages
//  through the platform's external-memory path.
//
//  In the browser CWgpu is webgpu.h on the page's own WebGPU (CWgpuWasm),
//  and the device it answers with is the one the Vulkan implementation runs
//  on. So the bootstrap is the same webgpu.h calls, a target is a plain
//  texture on that device, and the import is VK_NUCLEANT_webgpu_objects — a
//  VkImage over the texture itself, the counterpart of VK_EXT_metal_objects
//  on Apple. One device also means one queue: ThorVG's submits reach the GPU
//  before the Vulkan submit that samples their result, in call order, so
//  there is nothing to wait for between the two.
//
#if os(WASI)
import CWgpu

public final class WgpuContext: @unchecked Sendable {

    /// One context for the page, shared by every window's nodes. nil when the
    /// bootstrap failed (logged by init).
    public static let shared: WgpuContext? = WgpuContext()

    private let instance: WGPUInstance
    private let adapter:  WGPUAdapter
    private let device:   WGPUDevice
    private let queue:    WGPUQueue

    /// Opaque handles for `tvg_wgcanvas_set_target`, which takes them as
    /// `void*` — so the thor side never needs the CWgpu types.
    public var devicePointer:   UnsafeMutableRawPointer { UnsafeMutableRawPointer(device) }
    public var instancePointer: UnsafeMutableRawPointer { UnsafeMutableRawPointer(instance) }

    /// True when the device has BGRA8UnormStorage, i.e. target textures carry
    /// StorageBinding usage and canvas post shaders can imageStore into them.
    public let canvasStorageCapable: Bool

    /// A render target: a texture on the page's device. `release()` drops
    /// this context's reference once the canvas is retargeted away from it.
    public final class Target: @unchecked Sendable {
        private let texture: WGPUTexture
        public let texturePointer: UnsafeMutableRawPointer
        public let width:  Int
        public let height: Int
        public let storageCapable: Bool

        fileprivate init(texture: WGPUTexture, width: Int, height: Int, storageCapable: Bool) {
            self.texture        = texture
            self.texturePointer = UnsafeMutableRawPointer(texture)
            self.width          = width
            self.height         = height
            self.storageCapable = storageCapable
        }

        /// The `WGPUTexture` itself, for importing as a VkImage through
        /// `VkImportWebGPUTextureInfoNUCLEANT` (VK_NUCLEANT_webgpu_objects)
        /// — the counterpart of `nativeMetalTexture()` on Apple.
        public func nativeWebGPUTexture() -> UnsafeMutableRawPointer {
            texturePointer
        }

        /// Drop our reference to the target texture. An image imported over
        /// it holds its own until it is destroyed, and ThorVG uses it while
        /// it is a canvas's target — retarget the canvas first.
        public func release() {
            wgpuTextureRelease(texture)
        }
    }

    init?() {
        guard let instance = wgpuCreateInstance(nil) else {
            print("WgpuContext: wgpuCreateInstance failed")
            return nil
        }

        // Answered before the call returns: the page acquired the adapter
        // and device before the module started.
        var adapterResult: WGPUAdapter? = nil
        withUnsafeMutablePointer(to: &adapterResult) { slot in
            var callbackInfo = WGPURequestAdapterCallbackInfo()
            callbackInfo.mode = WGPUCallbackMode_AllowSpontaneous
            callbackInfo.callback = { status, adapter, _, userdata1, _ in
                guard status == WGPURequestAdapterStatus_Success else { return }
                userdata1?.assumingMemoryBound(to: WGPUAdapter?.self).pointee = adapter
            }
            callbackInfo.userdata1 = UnsafeMutableRawPointer(slot)
            var options = WGPURequestAdapterOptions()
            options.powerPreference = WGPUPowerPreference_HighPerformance
            _ = wgpuInstanceRequestAdapter(instance, &options, callbackInfo)
        }
        guard let adapter = adapterResult else {
            print("WgpuContext: wgpuInstanceRequestAdapter failed")
            return nil
        }

        // Same reason as the native bootstrap: BGRA8Unorm textures take
        // StorageBinding only with the BGRA8UnormStorage feature.
        let bgraStorage = wgpuAdapterHasFeature(adapter, WGPUFeatureName_BGRA8UnormStorage) != 0

        var deviceResult: WGPUDevice? = nil
        withUnsafeMutablePointer(to: &deviceResult) { slot in
            var callbackInfo = WGPURequestDeviceCallbackInfo()
            callbackInfo.mode = WGPUCallbackMode_AllowSpontaneous
            callbackInfo.callback = { status, device, _, userdata1, _ in
                guard status == WGPURequestDeviceStatus_Success else { return }
                userdata1?.assumingMemoryBound(to: WGPUDevice?.self).pointee = device
            }
            callbackInfo.userdata1 = UnsafeMutableRawPointer(slot)
            if bgraStorage {
                var requiredFeatures: [WGPUFeatureName] = [WGPUFeatureName_BGRA8UnormStorage]
                requiredFeatures.withUnsafeBufferPointer { featPtr in
                    var descriptor = WGPUDeviceDescriptor()
                    descriptor.requiredFeatureCount = featPtr.count
                    descriptor.requiredFeatures = featPtr.baseAddress
                    _ = wgpuAdapterRequestDevice(adapter, &descriptor, callbackInfo)
                }
            } else {
                _ = wgpuAdapterRequestDevice(adapter, nil, callbackInfo)
            }
        }
        guard let device = deviceResult else {
            print("WgpuContext: wgpuAdapterRequestDevice failed")
            return nil
        }

        self.instance = instance
        self.adapter  = adapter
        self.device   = device
        self.queue    = wgpuDeviceGetQueue(device)
        self.canvasStorageCapable = bgraStorage
    }

    /// Channel order of every texture `makeTarget` mints. BGRA, the format
    /// ThorVG's wg engine renders its final blit into, and the engine's
    /// composite format, so the importing image and its view agree.
    public enum PixelOrder: Sendable {
        case bgra8Unorm
        case rgba8Unorm
    }

    public static let targetPixelOrder: PixelOrder = .bgra8Unorm

    /// A texture ThorVG can draw into and a VkImage can be made over:
    /// rendered to by ThorVG's final blit, sampled by the composite, and a
    /// copy source for image nodes filled out of a canvas.
    public func makeTarget(width: Int, height: Int) -> Target? {
        var descriptor = WGPUTextureDescriptor()
        descriptor.usage = WGPUTextureUsage_RenderAttachment
            | WGPUTextureUsage_TextureBinding
            | WGPUTextureUsage_CopySrc
            | WGPUTextureUsage_CopyDst
        if canvasStorageCapable {
            descriptor.usage |= WGPUTextureUsage_StorageBinding
        }
        descriptor.dimension = WGPUTextureDimension_2D
        descriptor.size = WGPUExtent3D(width: UInt32(width), height: UInt32(height), depthOrArrayLayers: 1)
        descriptor.format = WGPUTextureFormat_BGRA8Unorm
        descriptor.mipLevelCount = 1
        descriptor.sampleCount = 1
        guard let texture = wgpuDeviceCreateTexture(device, &descriptor) else {
            print("WgpuContext: wgpuDeviceCreateTexture failed")
            return nil
        }
        return Target(texture: texture, width: width, height: height, storageCapable: canvasStorageCapable)
    }

    /// Nothing to wait for: webgpu.h and Vulkan share the page's one queue,
    /// so ThorVG's submitted work runs before any Vulkan submit made after
    /// it. Kept so callers read the same on every platform.
    public func waitForGPUCompletion() {}
}

#endif
