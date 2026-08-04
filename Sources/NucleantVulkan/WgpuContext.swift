//
//  WgpuContext.swift
//  NucleantVulkan
//
//  Bootstraps wgpu-native (instance → adapter → device) and mints the render
//  target ThorVG's wg backend draws into. ThorVG requires real wgpu handles:
//  passing nil device/instance to tvg_wgcanvas_set_target makes
//  WgRenderer::target release the context and report success, leaving every
//  draw() failing with TVG_RESULT_INSUFFICIENT_CONDITION.
//
//  WebGPU is used on every platform (it is ThorVG's GPU backend everywhere
//  bar software/OpenGL) — so the wgpu bootstrap here is cross-platform. Only
//  the Metal-specific interop (exporting a target's `id<MTLTexture>` for a
//  zero-copy VK_EXT_metal_objects import, and the Metal fence) is `#if os`
//  guarded; other platforms select the Vulkan backend and will import the
//  target through their own external-memory path.
//
//  Raw wgpu (and CWgpu) is confined to this file — one of the two sanctioned
//  webgpu homes (the engine; the other is NucleantThorVG). Everything it
//  hands out crosses the module boundary as opaque `UnsafeMutableRawPointer`s
//  or the `Target` wrapper, so NucleantThorVG drives ThorVG's wg backend
//  without importing CWgpu itself.
//
import Foundation
// wgpu-native C API: bare-dylib module on macOS, framework module on iOS.
#if os(iOS)
import wgpu_native
#else
import CWgpu
#endif
#if canImport(Metal)
import Metal
#endif

// @unchecked Sendable: every stored property is an immutable `let` — opaque
// wgpu handles set once at init and never mutated — so the process-wide
// `shared` singleton is safe to share (wgpu's own thread-affinity aside;
// everything runs on main today).
public final class WgpuContext: @unchecked Sendable {

    /// One wgpu context for the whole process. Unlike the render engine —
    /// bound to one window's surface, hence per-window — this only bootstraps
    /// a device and mints target textures, so every window's nodes can share
    /// it. nil when wgpu bootstrap failed (logged by init).
    public static let shared: WgpuContext? = WgpuContext()

    private let instance: WGPUInstance
    private let adapter:  WGPUAdapter
    private let device:   WGPUDevice
    private let queue:    WGPUQueue

    /// Opaque handles for `tvg_wgcanvas_set_target`, which takes them as
    /// `void*` — so the thor side never needs the CWgpu types.
    public var devicePointer:   UnsafeMutableRawPointer { UnsafeMutableRawPointer(device) }
    public var instancePointer: UnsafeMutableRawPointer { UnsafeMutableRawPointer(instance) }

    /// True when the adapter granted BGRA8UnormStorage, i.e. target textures
    /// carry StorageBinding usage and canvas post shaders can imageStore into
    /// them. Compute post-processing is unavailable when this is false.
    public let canvasStorageCapable: Bool

    /// A wgpu render target. Holds the raw `WGPUTexture` pointer to hand to
    /// `tvg_wgcanvas_set_target`; on Apple it can additionally export the
    /// underlying `id<MTLTexture>` to import as a VkImage. `release()` drops
    /// this context's reference once the canvas is retargeted away from it.
    public final class Target: @unchecked Sendable {
        private let context: WgpuContext
        private let texture: WGPUTexture
        public let texturePointer: UnsafeMutableRawPointer
        public let width:  Int
        public let height: Int
        public let storageCapable: Bool
        #if os(Android)
        /// `AHardwareBuffer*` for this target's backing memory. Android's own
        /// external-memory handle type and the only one it guarantees — the
        /// emulator has VK_ANDROID_external_memory_android_hardware_buffer but
        /// no VK_KHR_external_memory_fd — so the fd path below is Linux's.
        /// Ownership of the reference passes to the importer.
        fileprivate let hardwareBuffer: UnsafeMutableRawPointer?
        #elseif !(os(macOS) || os(iOS))
        /// POSIX fd for this target's backing memory
        /// (`VK_KHR_external_memory_fd`), minted alongside the texture itself
        /// — Vulkan has no way to export memory from an already-created
        /// texture, so the fd is captured at creation time in `makeTarget`.
        /// Ownership passes to whichever `VkImportMemoryFdInfoKHR` import
        /// consumes it (the spec-mandated contract); nil if export failed.
        fileprivate let exportedFd: Int32?
        #endif

        fileprivate init(
            context: WgpuContext,
            texture: WGPUTexture,
            width: Int,
            height: Int,
            storageCapable: Bool,
            exportedFd: Int32? = nil,
            hardwareBuffer: UnsafeMutableRawPointer? = nil
        ) {
            self.context        = context
            self.texture        = texture
            self.texturePointer = UnsafeMutableRawPointer(texture)
            self.width          = width
            self.height         = height
            self.storageCapable = storageCapable
            #if os(Android)
            self.hardwareBuffer = hardwareBuffer
            #elseif !(os(macOS) || os(iOS))
            self.exportedFd     = exportedFd
            #endif
        }

        #if os(macOS) || os(iOS)
        /// The raw `id<MTLTexture>` backing this target — the exact GPU memory
        /// ThorVG renders into, for importing as a VkImage via
        /// VK_EXT_metal_objects. Metal-only.
        public func nativeMetalTexture() -> UnsafeMutableRawPointer? {
            wgpuTextureGetNativeMetalTexture(texture)
        }
        #elseif os(Android)
        /// The `AHardwareBuffer*` backing this target, for importing as a
        /// VkImage via `VkImportAndroidHardwareBufferInfoANDROID`. `nil` if the
        /// device lacks the extension or the export failed at creation time.
        public func nativeAndroidHardwareBuffer() -> UnsafeMutableRawPointer? {
            hardwareBuffer
        }
        #else
        /// The POSIX fd for this target's backing memory, for importing as a
        /// VkImage via `VkImportMemoryFdInfoKHR` (`VK_KHR_external_memory_fd`)
        /// — real GPU-to-GPU sharing between wgpu-native's own VkDevice and
        /// the caller's, on the same physical GPU. `nil` if the driver lacks
        /// the extension or export failed at creation time.
        public func nativeVulkanExportedFd() -> Int32? {
            exportedFd
        }
        #endif

        /// Drop our reference to the target texture. wgpu refcounts it and
        /// keeps it alive through any in-flight submission, but ThorVG holds
        /// its own reference while the texture is still a canvas's render
        /// target — retarget the canvas first or the memory stays.
        public func release() {
            wgpuTextureRelease(texture)
        }
    }

    init?() {
        // WebGPU backend per platform — Metal on Apple, Vulkan elsewhere.
        #if os(macOS) || os(iOS)
        let instanceBackend = WGPUInstanceBackend_Metal
        let backendType     = WGPUBackendType_Metal
        #else
        let instanceBackend = WGPUInstanceBackend_Vulkan
        let backendType     = WGPUBackendType_Vulkan
        #endif

        var extras = WGPUInstanceExtras()
        extras.chain.sType = WGPUSType(rawValue: WGPUSType_InstanceExtras.rawValue)
        extras.backends = instanceBackend

        var descriptor = WGPUInstanceDescriptor()
        let createdInstance: WGPUInstance? = withUnsafeMutablePointer(to: &extras.chain) { chainPtr in
            descriptor.nextInChain = chainPtr
            return wgpuCreateInstance(&descriptor)
        }
        guard let instance = createdInstance else {
            print("WgpuContext: wgpuCreateInstance failed")
            return nil
        }

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
            options.backendType = backendType

            // wgpu-native invokes request callbacks synchronously; its
            // wgpuInstanceWaitAny is unimplemented (panics), so don't wait.
            _ = wgpuInstanceRequestAdapter(instance, &options, callbackInfo)
        }
        guard let adapter = adapterResult else {
            print("WgpuContext: wgpuInstanceRequestAdapter failed")
            return nil
        }

        // BGRA8Unorm textures only accept STORAGE_BINDING (shaderWrite, what
        // canvas post shaders imageStore through) when the device is created
        // with the BGRA8UnormStorage feature — never on by default, so it must
        // be requested here.
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

    /// BGRA8Unorm render target for the wg canvas. ThorVG's wg backend
    /// hardcodes its final "blit" pipeline to WGPUTextureFormat_BGRA8Unorm and
    /// never reassigns it — so the target must be BGRA8Unorm or the blit
    /// render pass is format-incompatible and wgpu-native aborts.
    public func makeTarget(width: Int, height: Int) -> Target? {
        var descriptor = WGPUTextureDescriptor()
        descriptor.usage = WGPUTextureUsage_RenderAttachment
            | WGPUTextureUsage_TextureBinding
            | WGPUTextureUsage_CopySrc
            | WGPUTextureUsage_CopyDst
        #if os(macOS) || os(iOS)
        if canvasStorageCapable {
            descriptor.usage |= WGPUTextureUsage_StorageBinding
        }
        #endif
        descriptor.dimension = WGPUTextureDimension_2D
        descriptor.size = WGPUExtent3D(
            width: UInt32(width),
            height: UInt32(height),
            depthOrArrayLayers: 1
        )
        #if os(Android)
        // RGBA, not BGRA: AHardwareBuffer has no BGRA format at all, so a
        // zero-copy target has to be RGBA8Unorm. ThorVG adopts the target's
        // format (tvgWg_target_format.patch), and the importing image view
        // swaps the channels back when sampling.
        descriptor.format = WGPUTextureFormat_RGBA8Unorm
        #else
        descriptor.format = WGPUTextureFormat_BGRA8Unorm
        #endif
        descriptor.mipLevelCount = 1
        descriptor.sampleCount = 1

        #if os(macOS) || os(iOS)
        guard let texture = wgpuDeviceCreateTexture(device, &descriptor) else {
            print("WgpuContext: wgpuDeviceCreateTexture failed")
            return nil
        }
        return Target(
            context:        self,
            texture:        texture,
            width:          width,
            height:         height,
            storageCapable: canvasStorageCapable
        )
        #elseif os(Android)
        // No StorageBinding here, same as the Linux branch below.
        var hardwareBuffer: UnsafeMutableRawPointer? = nil
        guard let texture = wgpuDeviceCreateTextureWithExportedAHardwareBuffer(
            device, &descriptor, &hardwareBuffer
        ) else {
            print("WgpuContext: wgpuDeviceCreateTextureWithExportedAHardwareBuffer failed "
                  + "— device may lack VK_ANDROID_external_memory_android_hardware_buffer")
            return nil
        }
        return Target(
            context:        self,
            texture:        texture,
            width:          width,
            height:         height,
            storageCapable: false,
            hardwareBuffer: hardwareBuffer
        )
        #else
        // No StorageBinding here (see the field above the Apple-only branch):
        // the export path's hal-level usage mapping only covers the plain
        // color-attachment/sampled/copy case a ThorVG render target needs, not
        // storage — canvas post-shaders on ThorVG canvases aren't supported
        // through this path yet.
        var exportedFd: Int32 = -1
        guard let texture = wgpuDeviceCreateTextureWithExportedFd(device, &descriptor, &exportedFd) else {
            print("WgpuContext: wgpuDeviceCreateTextureWithExportedFd failed — driver may lack VK_KHR_external_memory_fd")
            return nil
        }
        return Target(
            context:        self,
            texture:        texture,
            width:          width,
            height:         height,
            storageCapable: false,
            exportedFd:     exportedFd
        )
        #endif
    }

    /// Blocks until every command previously submitted to this queue has
    /// actually finished on the GPU — not just queued. `wgpuQueueSubmit` (used
    /// by ThorVG's wg backend to flush its blit) is fire-and-forget;
    /// `tvg_canvas_sync()` success only proves the work was queued.
    public func waitForGPUCompletion() {
        #if os(macOS) || os(iOS)
        // Metal command queues execute in submission order, so committing a
        // trivial buffer here and waiting on it is a standard fence. The
        // trailing non-blocking poll lets wgpu_core reclaim per-submission
        // tracking data (otherwise leaked ~3.4 KB per canvas draw).
        defer { _ = wgpuDevicePoll(device, 0 /* don't block */, nil) }
        guard let rawQueue = wgpuQueueGetNativeMetalCommandQueue(queue) else { return }
        let mtlQueue = Unmanaged<AnyObject>.fromOpaque(rawQueue).takeUnretainedValue() as! MTLCommandQueue
        guard let fence = mtlQueue.makeCommandBuffer() else { return }
        fence.commit()
        fence.waitUntilCompleted()
        #else
        // No native-queue fence path off Apple — a blocking device poll is the
        // portable completion wait.
        _ = wgpuDevicePoll(device, 1 /* wait */, nil)
        #endif
    }
}
