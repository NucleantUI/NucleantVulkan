//
//  VulkanRenderEngine.swift
//  SulphurXcodeDemo
//
//  Vulkan presentation engine that renders node slots into the CAMetalLayer
//  of a SulphurNSView (via MoltenVK / VK_EXT_metal_surface).
//
//  Usage:
//
//      let engine = try VulkanRenderEngine.attached(to: sulphurView)
//      let node   = try engine.makeThorNode(canvas: tvgCanvasHandle,
//                                           width: 512, height: 512)
//      engine.append(node)
//      // append more nodes at any time — they join the composite next frame
//



// MARK: - Node type
import VulkanCore
import CVulkan
// wgpu-native C API: bare-dylib module on macOS, framework module on iOS.
// None on wasm, where the browser's WebGPU is the device itself.
#if os(iOS)
import wgpu_native
#elseif !os(WASI)
import CWgpu
#endif
import NucleantShader
import CVulkan
#if os(macOS) || os(iOS)
import QuartzCore
#endif


public enum VulkanEngineError: Error {
    case instance(Int32)
    case surface(Int32)
    case noPhysicalDevice
    case noPresentQueue
    case device(Int32)
    case commandPool
    case descriptorPool
    case swapchain(Int32)
    case renderPass
    case framebuffer
    case shaderCompile
    case sync
    case image
    case memory
}


// MARK: - Engine

/// One window's present stack: surface → swapchain → composite pass, on a
/// `VulkanRenderDevice` (instance, device, queue) it may share with other
/// windows — whoever builds the engines decides, by handing them the same
/// device. Each frame the device updates dirty nodes (ThorVG draw / compute
/// dispatch + layout barriers) and the engine blends every published node's
/// image onto the swapchain with the alpha-blending `CompositePipeline`.
public final class VulkanRenderEngine<RenderNode: RenderContainerNode>: VulkanContext {

    // MARK: Device

    /// The GPU this window renders with — handed in by whoever builds the
    /// engine (`init(device:…)`), or made for this window alone by the inits
    /// that take no device.
    public let renderDevice: VulkanRenderDevice<RenderNode>

    // MARK: VulkanContext

    public var device:         VkDevice         { renderDevice.device }
    public var physicalDevice: VkPhysicalDevice { renderDevice.physicalDevice }
    public var descriptorPool: VkDescriptorPool { renderDevice.descriptorPool }
    /// Frames in flight — per-image resources (uniform buffers, descriptor
    /// sets) allocated against this context should be indexed by `frameIndex`.
    public let imageCount: Int

    // MARK: Core objects

    public var instance:         VkInstance    { renderDevice.instance }
    public let surface:          VkSurfaceKHR
    public var graphicsQueue:    VkQueue       { renderDevice.graphicsQueue }
    public var queueFamilyIndex: UInt32        { renderDevice.queueFamilyIndex }
    public var commandPool:      VkCommandPool { renderDevice.commandPool }

    /// Live drawable size, in pixels — every window system has a different
    /// way to ask "how big is my surface right now" (a CAMetalLayer reports
    /// its own `drawableSize`; a raw Wayland surface has no such query at
    /// all, since resize is delivered via compositor configure events the
    /// windowing layer tracks) — so whoever creates the surface hands in the
    /// one closure that answers it. Same shared, platform-agnostic role on
    /// every platform: nothing else in the engine after init cares how the
    /// window was created.
    private let getExtent: () -> VkExtent2D

    // MARK: Nodes

    /// The slots composited each frame, in array order (later = on top).
    ///
    /// The list shows nodes; it doesn't own them. A node is the device's —
    /// the same one may sit in several windows' lists, or in none — so
    /// nothing here frees one: whoever made it calls `destroyResources`,
    /// whose frees wait for every frame still sampling it.
    public var nodes: [RenderNode] = []

    public func append(_ node: RenderNode) {
        nodes.append(node)
    }

    /// Takes a single node out of the composite list — e.g. when the widget
    /// owning it is dropped from the tree, so a stale image doesn't keep
    /// drawing every frame. Keyed by the slot's stable id (the owning
    /// canvas's `id`, the same value it was appended with). The node itself
    /// stays alive for its owner to free. Groups aren't addressed by this
    /// (nothing builds one yet).
    public func remove(id: Int) {
        // let id = ObjectIdentifier(node).hashValue
        // ^ replaced (update-render-system.md): identity is the canvas-owned
        //   Int id carried by RenderNode, never derived from the node object.
        nodes.removeAll { $0.id == id }
        releaseTracking(of: id)
    }

    /// Swap a slot's context in place — same id, same z-position, new GPU
    /// resources. `remove` + `append` would hoist a rebuilt node above
    /// every sibling; a frame resize must not change stacking order.
    /// Falls back to append when the id isn't listed. The outgoing node is
    /// its owner's to free, as with `remove`.
    public func replace(id: Int, with context: RenderNode.Context) {
        // let id = ObjectIdentifier(old).hashValue
        // ^ replaced, same as remove(id:) — see note there.
        releaseTracking(of: id)
        if let index = nodes.firstIndex(where: { $0.id == id }) {
            nodes[index] = .new(id: id, context: context)
        } else {
            nodes.append(.new(id: id, context: context))
        }
    }

    /// The live slot for `id`, or nil — lets a canvas re-attach per-slot state
    /// (its widget frame) after a `replace` installs a fresh slot.
    public func node(withId id: Int) -> RenderNode? {
        nodes.first { $0.id == id }
    }

    /// Drop everything cached against a slot id whose node image was swapped
    /// *in place* (a resize): this window's sampler descriptor set + its
    /// pool, and the device's `readable` flag — the slot must not be sampled,
    /// in any window, until the resized node's next update publishes its new
    /// image. Unlike `remove`/`replace`, the node itself stays in the
    /// composite list — this only clears cache, never the slot.
    public func invalidateComposite(id: Int) {
        releaseTracking(of: id)
        renderDevice.readable.remove(id)
    }

    /// This window's descriptor set for a slot id, and its dedicated pool.
    /// The next frame re-derives it for whatever occupies the id afterwards.
    private func releaseTracking(of id: Int) {
        guard let cached = nodeSets.removeValue(forKey: id) else { return }
        // A frame still in flight may be binding the set — the pool goes
        // once those frames are done.
        let device = device
        renderDevice.releaseAfterInFlightWork { vkDestroyDescriptorPool(device, cached.pool, nil) }
    }

    /// Called at the start of every frame with Δt — mutate nodes / set `dirty`
    /// here to drive animation.
    public var onUpdate: ((Double) -> Void)?

    /// Seconds accumulated across frames.
    public private(set) var elapsed: Double = 0

    /// Frame-in-flight cursor, cycles 0..<imageCount.
    public private(set) var frameIndex: Int = 0

    public var clearColor: (r: Float, g: Float, b: Float, a: Float) = (0.02, 0.02, 0.04, 1.0)

    // MARK: Private state

    private static var maxFrames: Int { 2 }
    /// Swapchain colour format, resolved against the surface rather than
    /// assumed.
    ///
    /// BGRA is what MoltenVK presents natively, and hardcoding it was fine
    /// while Apple was the only target. Android surfaces are free to report
    /// something else — the emulator's report R8G8B8A8 first — and a format the
    /// surface never advertised is not a legal request. Requesting BGRA there
    /// is honoured literally by the driver and then read back as RGBA by the
    /// compositor, which swaps red and blue in everything drawn.
    ///
    /// Seeded with the Apple-native choice and replaced by
    /// `chooseSurfaceFormat()` before the render pass is built. The render
    /// pass, the composite pipeline and the swapchain all take it, and must
    /// agree: WebGPU rejects every frame when they don't (Chrome on Linux
    /// prefers RGBA canvases), where native drivers let it slip.
    private var colorFormat = VK_FORMAT_B8G8R8A8_UNORM

    private var renderPass:      VkRenderPass?
    private var swapchain:       VkSwapchainKHR?
    private var swapchainImages: [VkImage?]       = []
    private var swapchainViews:  [VkImageView?]   = []
    private var framebuffers:    [VkFramebuffer?] = []
    private var extent = VkExtent2D(width: 0, height: 0)

    private var composite: CompositePipeline!

    private var commandBuffers: [VkCommandBuffer?] = []
    private var imageAvailable: [VkSemaphore?]     = []
    private var renderFinished: [VkSemaphore?]     = []
    private var inFlight:       [VkFence?]         = []

    /// This window's descriptor set per slot id, with the image view it was
    /// written for and its own pool. A node's view can change under it — a
    /// resize on the device, which knows nothing of this window — so a set
    /// whose view no longer matches the node's is rebuilt. Each set gets its
    /// own dedicated pool (see `allocateNodeDescriptorSet`) so MoltenVK never
    /// has to pack multiple same-layout sets from one pool — doing so
    /// misaligns every other set's Metal argument-buffer offset.
    private var nodeSets: [Int: (set: VkDescriptorSet, view: VkImageView, pool: VkDescriptorPool)] = [:]

    // MARK: - Init

    /// The shared, platform-agnostic designated init: everything from here
    /// down is plain Vulkan — present check, render pass, sync objects,
    /// composite pipeline, first swapchain attempt — identical on every
    /// platform. The device and `surface` arrive already made: the surface
    /// from `renderDevice.instance`, which is inherently platform-specific
    /// (Metal surface via MoltenVK on Apple; Wayland/XCB surface elsewhere),
    /// so that part is the caller's job — see `init(metalLayer:)` below for
    /// the Apple entry point. The engine owns `surface` from here on.
    /// `getExtent` is the one other unavoidable seam: there's no portable
    /// "what size is my surface right now" query (a CAMetalLayer reports
    /// `drawableSize`; a raw Wayland surface doesn't self-report at all), so
    /// whoever made the surface answers it too.
    public init(
        device renderDevice: VulkanRenderDevice<RenderNode>,
        surface: VkSurfaceKHR,
        getExtent: @escaping () -> VkExtent2D
    ) throws {
        self.renderDevice = renderDevice
        self.surface = surface
        self.getExtent = getExtent
        self.imageCount = Self.maxFrames

        // All stored lets are set — instance methods are usable from here on.
        // The device's queue family was picked without this surface (or
        // against another window's), so this window has to be presentable
        // from it.
        guard renderDevice.canPresent(to: surface) else {
            throw VulkanEngineError.noPresentQueue
        }
        // The surface's format first: the render pass and the composite
        // pipeline built against it must match the swapchain's images.
        colorFormat = chooseSurfaceFormat()
        try createRenderPass()
        try createSyncObjects()
        try createCompositePipeline()
        // Tolerate a zero-sized layer at init; drawFrame retries until it has
        // a real drawable size (SulphurNSView sets it in setFrameSize).
        try? createSwapchain()
    }

    /// A window with a device of its own, made from `instance` on a queue
    /// family that presents to `surface` — the engine as it was before the
    /// device was split out. The device owns `instance` from here on.
    public convenience init(
        instance: VkInstance,
        surface: VkSurfaceKHR,
        getExtent: @escaping () -> VkExtent2D
    ) throws {
        let renderDevice = try VulkanRenderDevice<RenderNode>(instance: instance, presentingTo: surface)
        try self.init(device: renderDevice, surface: surface, getExtent: getExtent)
    }

    #if os(macOS) || os(iOS)
    /// Apple entry point: the VkSurfaceKHR from a CAMetalLayer, made on
    /// `device` — a device made with `VulkanRenderDevice()`, which the caller
    /// holds and may hand to every window it opens. Apple only allows reaching
    /// Vulkan through MoltenVK/Metal in the first place, so there's no "hand
    /// me a native surface" option here the way there is on Linux. Delegates
    /// to the shared init above for everything past that.
    public convenience init(device renderDevice: VulkanRenderDevice<RenderNode>, metalLayer: CAMetalLayer) throws {
        let surface = try Self.makeMetalSurface(instance: renderDevice.instance, layer: metalLayer)
        try self.init(device: renderDevice, surface: surface, getExtent: Self.drawableExtent(of: metalLayer))
    }

    /// A window with a device of its own, made on a Metal instance of its
    /// own — the engine as it was before the device was split out.
    public convenience init(metalLayer: CAMetalLayer) throws {
        let instance = try VulkanRenderDevice<RenderNode>.makeMetalInstance()
        let surface = try Self.makeMetalSurface(instance: instance, layer: metalLayer)
        try self.init(instance: instance, surface: surface, getExtent: Self.drawableExtent(of: metalLayer))
    }

    /// The layer's drawable size, asked fresh each time.
    private static func drawableExtent(of metalLayer: CAMetalLayer) -> () -> VkExtent2D {
        {
            let drawable = metalLayer.drawableSize
            return VkExtent2D(
                width:  UInt32(max(drawable.width, 0)),
                height: UInt32(max(drawable.height, 0))
            )
        }
    }

    /// `vkCreateMetalSurfaceEXT` for `layer`, on `instance`.
    private static func makeMetalSurface(instance: VkInstance, layer metalLayer: CAMetalLayer) throws -> VkSurfaceKHR {
        // VkMetalSurfaceCreateInfoEXT doesn't import into Swift (its ObjC
        // pLayer field makes the struct non-trivial under ARC), so lay the
        // 32-byte struct out by hand: sType@0, pNext@8, flags@16, pLayer@24.
        var createdSurface: VkSurfaceKHR?
        let surfaceInfo = UnsafeMutableRawPointer.allocate(
            byteCount: 32,
            alignment: MemoryLayout<UInt>.alignment
        )
        defer { surfaceInfo.deallocate() }
        surfaceInfo.initializeMemory(as: UInt8.self, repeating: 0, count: 32)
        surfaceInfo.storeBytes(
            of: VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT.rawValue,
            toByteOffset: 0,
            as: UInt32.self
        )
        surfaceInfo.storeBytes(
            of: UInt(bitPattern: Unmanaged.passUnretained(metalLayer).toOpaque()),
            toByteOffset: 24,
            as: UInt.self
        )
        let surfResult = vkCreateMetalSurfaceEXT(
            instance,
            OpaquePointer(surfaceInfo),
            nil,
            &createdSurface
        )
        guard surfResult == VK_SUCCESS, let surface = createdSurface else {
            throw VulkanEngineError.surface(surfResult.rawValue)
        }
        return surface
    }
    #endif

    #if os(Linux)
    /// Linux entry point: builds the VkInstance (with the Wayland surface
    /// extensions) and the VkSurfaceKHR from raw `wl_display*`/`wl_surface*`
    /// handles — unlike Apple, Linux lets us hand the loader a native
    /// surface directly via `VK_KHR_wayland_surface`, no compositor-specific
    /// struct trickery needed (the struct's fields are plain opaque C
    /// pointers, so it imports into Swift cleanly). Delegates to the shared
    /// init above for everything past that.
    public convenience init(waylandDisplay: OpaquePointer?, waylandSurface: OpaquePointer?, getExtent: @escaping () -> VkExtent2D) throws {
        let availableInstanceExts = enumerateInstanceExtensions()
        var instanceExtensions = ["VK_KHR_surface", "VK_KHR_wayland_surface"]
        if availableInstanceExts.contains("VK_KHR_get_physical_device_properties2") {
            instanceExtensions.append("VK_KHR_get_physical_device_properties2")
        }

        var createdInstance: VkInstance?
        var appInfo = VkApplicationInfo()
        appInfo.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO
        appInfo.apiVersion = (1 << 22) | (2 << 12) // Vulkan 1.2
        let instResult: VkResult = withUnsafePointer(to: &appInfo) { appPtr in
            withCStringArray(instanceExtensions) { extPtr, extCount in
                var ci = VkInstanceCreateInfo()
                ci.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
                ci.pApplicationInfo = appPtr
                ci.enabledExtensionCount = extCount
                ci.ppEnabledExtensionNames = extPtr
                return vkCreateInstance(&ci, nil, &createdInstance)
            }
        }
        guard instResult == VK_SUCCESS, let instance = createdInstance else {
            throw VulkanEngineError.instance(instResult.rawValue)
        }

        var createdSurface: VkSurfaceKHR?
        var surfaceInfo = VkWaylandSurfaceCreateInfoKHR()
        surfaceInfo.sType = VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR
        surfaceInfo.display = waylandDisplay
        surfaceInfo.surface = waylandSurface
        let surfResult = vkCreateWaylandSurfaceKHR(instance, &surfaceInfo, nil, &createdSurface)
        guard surfResult == VK_SUCCESS, let surface = createdSurface else {
            throw VulkanEngineError.surface(surfResult.rawValue)
        }

        try self.init(instance: instance, surface: surface, getExtent: getExtent)
    }

    /// X11 entry point: same shape as the Wayland one above, `VK_KHR_xcb_surface`
    /// instead of `VK_KHR_wayland_surface` — for sessions where the compositor
    /// is a plain X11/XCB window manager (e.g. Cinnamon-on-Xorg) rather than a
    /// Wayland one, so the window is a normal WM-managed top-level rather than
    /// requiring a Wayland session to exist at all.
    public convenience init(xcbConnection: OpaquePointer?, xcbWindow: xcb_window_t, getExtent: @escaping () -> VkExtent2D) throws {
        let availableInstanceExts = enumerateInstanceExtensions()
        var instanceExtensions = ["VK_KHR_surface", "VK_KHR_xcb_surface"]
        if availableInstanceExts.contains("VK_KHR_get_physical_device_properties2") {
            instanceExtensions.append("VK_KHR_get_physical_device_properties2")
        }

        var createdInstance: VkInstance?
        var appInfo = VkApplicationInfo()
        appInfo.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO
        appInfo.apiVersion = (1 << 22) | (2 << 12) // Vulkan 1.2
        let instResult: VkResult = withUnsafePointer(to: &appInfo) { appPtr in
            withCStringArray(instanceExtensions) { extPtr, extCount in
                var ci = VkInstanceCreateInfo()
                ci.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
                ci.pApplicationInfo = appPtr
                ci.enabledExtensionCount = extCount
                ci.ppEnabledExtensionNames = extPtr
                return vkCreateInstance(&ci, nil, &createdInstance)
            }
        }
        guard instResult == VK_SUCCESS, let instance = createdInstance else {
            throw VulkanEngineError.instance(instResult.rawValue)
        }

        var createdSurface: VkSurfaceKHR?
        var surfaceInfo = VkXcbSurfaceCreateInfoKHR()
        surfaceInfo.sType = VK_STRUCTURE_TYPE_XCB_SURFACE_CREATE_INFO_KHR
        surfaceInfo.connection = xcbConnection
        surfaceInfo.window = xcbWindow
        let surfResult = vkCreateXcbSurfaceKHR(instance, &surfaceInfo, nil, &createdSurface)
        guard surfResult == VK_SUCCESS, let surface = createdSurface else {
            throw VulkanEngineError.surface(surfResult.rawValue)
        }

        try self.init(instance: instance, surface: surface, getExtent: getExtent)
    }
    #endif

    #if os(Android)
    /// Android entry point: `VK_KHR_android_surface` from an `ANativeWindow *`.
    ///
    /// Same shape as the Wayland/XCB inits above — Android likewise lets the
    /// loader take a native handle directly, so there is no layer-bridging
    /// like Apple's CAMetalLayer. Vulkan is part of the platform from API 24
    /// on, so the loader is the system one and nothing is bundled.
    ///
    /// `window` is the pointer the app's SurfaceView hands over through
    /// `ANativeWindow_fromSurface`; it stays valid until the surface is
    /// destroyed, which is why teardown has to happen before that callback
    /// returns.
    /// `getSize` returns plain pixels rather than a `VkExtent2D` so callers do
    /// not need the Vulkan headers: on Android `CVulkan` is a systemLibrary and
    /// SwiftPM cannot re-export it from this package's product, so the platform
    /// layer in NucleantApplication has no way to name that type.
    public convenience init(androidWindow window: OpaquePointer, getSize: @escaping () -> (Int, Int)) throws {
        let availableInstanceExts = enumerateInstanceExtensions()
        var instanceExtensions = ["VK_KHR_surface", "VK_KHR_android_surface"]
        if availableInstanceExts.contains("VK_KHR_get_physical_device_properties2") {
            instanceExtensions.append("VK_KHR_get_physical_device_properties2")
        }

        var createdInstance: VkInstance?
        var appInfo = VkApplicationInfo()
        appInfo.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO
        appInfo.apiVersion = (1 << 22) | (2 << 12) // Vulkan 1.2
        let instResult: VkResult = withUnsafePointer(to: &appInfo) { appPtr in
            withCStringArray(instanceExtensions) { extPtr, extCount in
                var ci = VkInstanceCreateInfo()
                ci.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
                ci.pApplicationInfo = appPtr
                ci.enabledExtensionCount = extCount
                ci.ppEnabledExtensionNames = extPtr
                return vkCreateInstance(&ci, nil, &createdInstance)
            }
        }
        guard instResult == VK_SUCCESS, let instance = createdInstance else {
            throw VulkanEngineError.instance(instResult.rawValue)
        }

        var createdSurface: VkSurfaceKHR?
        var surfaceInfo = VkAndroidSurfaceCreateInfoKHR()
        surfaceInfo.sType = VK_STRUCTURE_TYPE_ANDROID_SURFACE_CREATE_INFO_KHR
        // Imports as OpaquePointer: the NDK header only forward-declares
        // `struct ANativeWindow`, so Swift never sees a complete type — which
        // is exactly what the caller already holds.
        surfaceInfo.window = window
        let surfResult = vkCreateAndroidSurfaceKHR(instance, &surfaceInfo, nil, &createdSurface)
        guard surfResult == VK_SUCCESS, let surface = createdSurface else {
            throw VulkanEngineError.surface(surfResult.rawValue)
        }

        try self.init(instance: instance, surface: surface, getExtent: {
            let (w, h) = getSize()
            return VkExtent2D(width: UInt32(max(w, 0)), height: UInt32(max(h, 0)))
        })
    }
    #endif

    deinit {
        // This window's frames, not the device: other windows on it keep
        // rendering while this one goes.
        waitForInFlightFrames()
        // The nodes are the device's, not this window's: they stay for their
        // owners, and for any other window showing them.
        nodes.removeAll()
        for cached in nodeSets.values { vkDestroyDescriptorPool(device, cached.pool, nil) }
        composite = nil   // destroys its pipeline/layouts
        destroySwapchainObjects()
        if let swapchain { vkDestroySwapchainKHR(device, swapchain, nil) }
        for sem in imageAvailable where sem != nil { vkDestroySemaphore(device, sem, nil) }
        for sem in renderFinished where sem != nil { vkDestroySemaphore(device, sem, nil) }
        for fence in inFlight {
            guard let fence else { continue }
            renderDevice.didWait(on: fence)
            vkDestroyFence(device, fence, nil)
        }
        // Allocated from the device's pool, which stays.
        if !commandBuffers.isEmpty {
            vkFreeCommandBuffers(device, commandPool, UInt32(commandBuffers.count), commandBuffers)
        }
        if let renderPass { vkDestroyRenderPass(device, renderPass, nil) }
        vkDestroySurfaceKHR(instance, surface, nil)
        // The device itself goes with whoever holds it last.
    }

    /// Block until every frame this window submitted has finished on the
    /// GPU. Its own fences only — `vkDeviceWaitIdle` would wait for every
    /// other window on the device as well.
    private func waitForInFlightFrames() {
        guard !inFlight.isEmpty else { return }
        vkWaitForFences(device, UInt32(inFlight.count), inFlight, VK_TRUE, UInt64.max)
    }

    // MARK: - Frame

    /// Render one frame. Wire this to `SulphurNSView.onFrame`.
    ///
    /// MoltenVK translates every Vulkan call here into autoreleased
    /// Objective-C/Metal objects (command buffers, encoders, texture
    /// views…). Without an explicit pool, a full frame's worth of them
    /// piles up every call — this is the single busiest call site in the
    /// app, so it owns its own drain rather than depending on the caller.
    public func drawFrame(_ dt: Double = 0) {
        #if os(macOS) || os(iOS)
        autoreleasepool {
            drawFrameUnpooled(dt)
        }
        #else
        drawFrameUnpooled(dt)
        #endif
    }

    private func drawFrameUnpooled(_ dt: Double) {
        elapsed += dt
        onUpdate?(dt)

        ensureSwapchain()
        guard let swapchain, !framebuffers.isEmpty else { return }

        let frame = frameIndex
        var fence = inFlight[frame]
        vkWaitForFences(device, 1, &fence, VK_TRUE, UInt64.max)

        var imageIndex: UInt32 = 0
        let acquire = vkAcquireNextImageKHR(
            device,
            swapchain,
            UInt64.max,
            imageAvailable[frame],
            nil,
            &imageIndex
        )
        if acquire == VK_ERROR_OUT_OF_DATE_KHR {
            recreateSwapchain()
            return
        }
        guard acquire == VK_SUCCESS || acquire == VK_SUBOPTIMAL_KHR else { return }

        guard let cmd = commandBuffers[frame], let frameFence = fence else { return }

        // 1. Node content updates — device work, in the device's own command
        //    buffer, submitted ahead of this frame on the same queue. Queue
        //    order and the nodes' barriers make the composite below see it.
        renderDevice.render(nodes)

        vkResetCommandBuffer(cmd, 0)
        var begin = VkCommandBufferBeginInfo()
        begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
        begin.flags = VkCommandBufferUsageFlags(VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT.rawValue)
        vkBeginCommandBuffer(cmd, &begin)

        // 2. Composite every published node onto the swapchain image.
        recordCompositePass(cmd: cmd, imageIndex: Int(imageIndex))

        vkEndCommandBuffer(cmd)

        // 3. Submit + present. The fence is reset only now, right before the
        //    submit that signals it again: a frame that bailed out earlier
        //    leaves it signalled, so waiting on it never hangs.
        vkResetFences(device, 1, &fence)
        guard renderDevice.submit(
            cmd,
            waitSemaphore:   imageAvailable[frame],
            waitStage:       VkPipelineStageFlags(VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT.rawValue),
            signalSemaphore: renderFinished[frame],
            fence:           frameFence
        ) == VK_SUCCESS else { return }
        let present = presentFrame(imageIndex: imageIndex, frame: frame)
        if present == VK_ERROR_OUT_OF_DATE_KHR || present == VK_SUBOPTIMAL_KHR {
            recreateSwapchain()
        }
        frameIndex = (frameIndex + 1) % Self.maxFrames
    }

    // MARK: - Composite pass

    private func recordCompositePass(cmd: VkCommandBuffer, imageIndex: Int) {
        var clear = VkClearValue()
        clear.color = VkClearColorValue(float32: clearColor)

        withUnsafePointer(to: &clear) { clearPtr in
            var info = VkRenderPassBeginInfo()
            info.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO
            info.renderPass = renderPass
            info.framebuffer = framebuffers[imageIndex]
            info.renderArea = VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: extent)
            info.clearValueCount = 1
            info.pClearValues = clearPtr
            vkCmdBeginRenderPass(cmd, &info, VK_SUBPASS_CONTENTS_INLINE)
        }

        let fullViewport = VkViewport(
            x: 0, y: 0,
            width:  Float(extent.width),
            height: Float(extent.height),
            minDepth: 0, maxDepth: 1
        )
        let fullScissor = VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: extent)

        for node in nodes {
            // A slot with a composite rect draws into that sub-region of the
            // swapchain (its widget frame); otherwise it fills the screen.
            let viewport: VkViewport
            var scissor: VkRect2D
            if let r = node.compositeRect, r.z > 0, r.w > 0 {
                viewport = VkViewport(
                    x: Float(r.x), y: Float(r.y),
                    width:  Float(r.z), height: Float(r.w),
                    minDepth: 0, maxDepth: 1
                )
                scissor = clampedScissor(x: r.x, y: r.y, width: r.z, height: r.w)
            } else {
                viewport = fullViewport
                scissor  = fullScissor
            }
            // A slot inside a clipping container narrows the scissor only, so
            // its image stays mapped to the full viewport and is simply cut
            // off rather than squeezed.
            if let clip = node.compositeScissor {
                scissor = clampedScissor(x: clip.x, y: clip.y, width: clip.z, height: clip.w)
            }
            recordComposite(of: node, cmd: cmd, viewport: viewport, scissor: scissor)
        }

        vkCmdEndRenderPass(cmd)
    }

    /// A `VkRect2D` clipped to the swapchain. Vulkan rejects a negative
    /// scissor offset and one running past the framebuffer, both of which a
    /// scrolled-off view produces naturally; an empty intersection comes back
    /// as a zero-extent rect, which draws nothing.
    private func clampedScissor(x: Double, y: Double, width: Double, height: Double) -> VkRect2D {
        let minX = Swift.max(0.0, x)
        let minY = Swift.max(0.0, y)
        let maxX = Swift.min(Double(extent.width), x + width)
        let maxY = Swift.min(Double(extent.height), y + height)
        return VkRect2D(
            offset: VkOffset2D(x: Int32(minX), y: Int32(minY)),
            extent: VkExtent2D(
                width:  UInt32(Swift.max(0, maxX - minX)),
                height: UInt32(Swift.max(0, maxY - minY))
            )
        )
    }

    /// Composite one slot, recursing into groups. A slot only draws once an
    /// update actually published its image (the device's `readable`) — a
    /// node that never rendered has nothing safe to sample.
    private func recordComposite(
        of node:  RenderNode,
        cmd:      VkCommandBuffer,
        viewport: VkViewport,
        scissor:  VkRect2D
    ) {
        // let imageView: VkImageView
        // switch node.context {
        // case .thor(let thorShaderNode):
        //     imageView = thorShaderNode.imageView
        // case .skia(let skiaShaderNode):
        //     imageView = skiaShaderNode.imageView
        // case .shader(let oGLShaderNode):
        //     imageView = oGLShaderNode.imageView
        // case .pixel_buffer(let pixelBufferShaderNode):
        //     imageView = pixelBufferShaderNode.imageView
        // case .group(let groupNode):
        //     for child in groupNode.nodes {
        //         recordComposite(of: child, cmd: cmd, viewport: viewport, scissor: scissor)
        //     }
        //     return
        // case .texture_group:
        //     return
        // }
        guard
            let imageView = node.getImageView(),
            renderDevice.readable.contains(node.id),
            let set = descriptorSet(id: node.id, imageView: imageView)
        else { return }
        
        composite.record(
            commandBuffer: cmd,
            descriptorSet: set,
            viewport:      viewport,
            scissor:       scissor
        )
    }

    // TODO resolved: keyed by the slot's stable Int id, never ObjectIdentifier.
    public func descriptorSet(id: Int, imageView: VkImageView) -> VkDescriptorSet? {
        // let id = ObjectIdentifier(node).hashValue
        // ^ replaced — RenderNode.id is the one identity both sides share.
        if let cached = nodeSets[id] {
            if cached.view == imageView { return cached.set }
            // Swapped on the device since this window wrote the set.
            releaseTracking(of: id)
        }
        guard let allocated = try? composite.allocateNodeDescriptorSet() else { return nil }
        composite.updateDescriptorSet(allocated.set, imageViews: [imageView])
        nodeSets[id] = (set: allocated.set, view: imageView, pool: allocated.pool)
        return allocated.set
    }

    // MARK: - Submit / present

    private func presentFrame(imageIndex: UInt32, frame: Int) -> VkResult {
        var waitSem = renderFinished[frame]
        var swap    = swapchain
        var index   = imageIndex
        return withUnsafePointer(to: &waitSem) { semPtr in
            withUnsafePointer(to: &swap) { swapPtr in
                withUnsafePointer(to: &index) { indexPtr in
                    var info = VkPresentInfoKHR()
                    info.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR
                    info.waitSemaphoreCount = 1
                    info.pWaitSemaphores = semPtr
                    info.swapchainCount = 1
                    info.pSwapchains = swapPtr
                    info.pImageIndices = indexPtr
                    return vkQueuePresentKHR(graphicsQueue, &info)
                }
            }
        }
    }

    // MARK: - Render pass / composite pipeline

    private func createRenderPass() throws {
        var color = VkAttachmentDescription()
        color.format         = colorFormat
        color.samples        = VK_SAMPLE_COUNT_1_BIT
        color.loadOp         = VK_ATTACHMENT_LOAD_OP_CLEAR
        color.storeOp        = VK_ATTACHMENT_STORE_OP_STORE
        color.stencilLoadOp  = VK_ATTACHMENT_LOAD_OP_DONT_CARE
        color.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE
        color.initialLayout  = VK_IMAGE_LAYOUT_UNDEFINED
        color.finalLayout    = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR

        var colorRef = VkAttachmentReference(
            attachment: 0,
            layout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
        )

        let result: VkResult = withUnsafePointer(to: &colorRef) { refPtr in
            var subpass = VkSubpassDescription()
            subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS
            subpass.colorAttachmentCount = 1
            subpass.pColorAttachments = refPtr

            var dependency = VkSubpassDependency()
            dependency.srcSubpass = UInt32.max // VK_SUBPASS_EXTERNAL
            dependency.dstSubpass = 0
            dependency.srcStageMask = VkPipelineStageFlags(VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT.rawValue)
            dependency.srcAccessMask = 0
            dependency.dstStageMask = VkPipelineStageFlags(VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT.rawValue)
            dependency.dstAccessMask = VkAccessFlags(VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT.rawValue)

            return withUnsafePointer(to: &color) { attPtr in
                withUnsafePointer(to: &subpass) { subPtr in
                    withUnsafePointer(to: &dependency) { depPtr in
                        var info = VkRenderPassCreateInfo()
                        info.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO
                        info.attachmentCount = 1
                        info.pAttachments = attPtr
                        info.subpassCount = 1
                        info.pSubpasses = subPtr
                        info.dependencyCount = 1
                        info.pDependencies = depPtr
                        return vkCreateRenderPass(device, &info, nil, &renderPass)
                    }
                }
            }
        }
        guard result == VK_SUCCESS else { throw VulkanEngineError.renderPass }
    }

    /// One-slot composite: each node draws a fullscreen alpha-blended quad
    /// sampling its own image, so slots can be appended without rebuilding
    /// the pipeline.
    private func createCompositePipeline() throws {
        let fragmentSource = """
        #version 450
        layout(location = 0) in vec2 vTexCoord;
        layout(location = 0) out vec4 fragColor;
        layout(binding = 0) uniform sampler2D nodeImage;

        void main() {
            fragColor = texture(nodeImage, vTexCoord);
        }
        """
        guard
            let vertSPIRV = VKShaderCompiler.shared.getDefaultVertexSPIRV(),
            let fragSPIRV = VKShaderCompiler.shared.compile(
                source:   fragmentSource,
                stage:    .fragment,
                filename: "engine_composite.frag"
            ),
            let renderPass
        else {
            throw VulkanEngineError.shaderCompile
        }
        composite = try CompositePipeline(
            context:    self,
            slotCount:  1,
            renderPass: renderPass,
            vertSPIRV:  vertSPIRV,
            fragSPIRV:  fragSPIRV
        )
    }

    // MARK: - Swapchain

    private func ensureSwapchain() {
        let drawable = getExtent()
        let width  = drawable.width
        let height = drawable.height
        if swapchain == nil {
            try? createSwapchain()
        } else if width > 0, height > 0, width != extent.width || height != extent.height {
            recreateSwapchain()
        }
    }

    /// The one place every resize path (the proactive check above, and the
    /// reactive VK_ERROR_OUT_OF_DATE_KHR/VK_SUBOPTIMAL_KHR recovery around
    /// acquire/present) funnels through, so this is also the one place that
    /// needs to keep window-filling nodes matching the new extent — every
    /// window-filling node's own content otherwise has nothing else tracking
    /// the window's size (no widget-tree frame is involved for those), the
    /// same seam RenderBinder/compositeRect already uses (falls back to this
    /// extent for those same nodes) — so a rotation or any other plain resize
    /// needs nothing from the widget tree.
    private func recreateSwapchain() {
        // Only this window's frames use its swapchain — the device's other
        // windows go on rendering through a resize of this one.
        waitForInFlightFrames()
        let oldWidth = extent.width, oldHeight = extent.height
        try? createSwapchain()
        // Guards a swapchain recreate that didn't actually change size (the
        // reactive OUT_OF_DATE/SUBOPTIMAL paths call this unconditionally,
        // not only on an actual size change) and one that silently failed
        // (createSwapchain can throw, swallowed by `try?`, leaving the old
        // extent in place) — neither should touch node content.
        guard extent.width != oldWidth || extent.height != oldHeight else { return }
        for node in nodes {
            node.resizeToFitWindow(width: Int(extent.width), height: Int(extent.height), device: renderDevice)
        }
    }

    private func createSwapchain() throws {
        var caps = VkSurfaceCapabilitiesKHR()
        vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physicalDevice, surface, &caps)

        var newExtent = caps.currentExtent
        if newExtent.width == UInt32.max {
            let drawable = getExtent()
            newExtent = VkExtent2D(
                width:  max(drawable.width, 1),
                height: max(drawable.height, 1)
            )
        }
        guard newExtent.width > 0, newExtent.height > 0 else {
            throw VulkanEngineError.swapchain(0)
        }

        var count = caps.minImageCount + 1
        if caps.maxImageCount > 0 { count = min(count, caps.maxImageCount) }

        let oldSwapchain = swapchain
        var newSwapchain: VkSwapchainKHR?
        var info = VkSwapchainCreateInfoKHR()
        info.sType            = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR
        info.surface          = surface
        info.minImageCount    = count
        info.imageFormat      = colorFormat
        info.imageColorSpace  = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR
        info.imageExtent      = newExtent
        info.imageArrayLayers = 1
        info.imageUsage       = VkImageUsageFlags(VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue)
        info.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE
        #if os(Android)
        // IDENTITY, not caps.currentTransform: the latter tells the
        // presentation engine "trust me, my pixels are already rotated to
        // match the display" — a promise nothing in this renderer keeps, since
        // it always draws the scene in the surface's own width/height with no
        // compensating transform of its own. currentTransform genuinely
        // changes with device rotation on Android, so that broken promise is
        // exactly what showed up as window content staying in its original
        // orientation (even on a fresh launch already rotated) while only the
        // swapchain's width/height followed the rotation. Requesting IDENTITY
        // instead hands the rotation compositing to the system compositor, so
        // nothing up the stack — this renderer, RenderBinder, or an app's own
        // window code — needs any orientation awareness at all, only
        // width/height. Scoped to Android only: every other platform's
        // currentTransform is already effectively identity (MoltenVK reports
        // only IDENTITY for a CAMetalLayer surface; Wayland/X11 have no
        // equivalent pre-rotation concept), so there is nothing to fix there
        // and no reason to touch behavior that already works.
        info.preTransform = caps.supportedTransforms & UInt32(VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR.rawValue) != 0
            ? VkSurfaceTransformFlagBitsKHR(rawValue: VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR.rawValue)
            : caps.currentTransform
        #else
        info.preTransform     = caps.currentTransform
        #endif
        info.compositeAlpha   = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR
        info.presentMode      = VK_PRESENT_MODE_FIFO_KHR
        info.clipped          = VK_TRUE
        info.oldSwapchain     = oldSwapchain
        let result = vkCreateSwapchainKHR(device, &info, nil, &newSwapchain)
        guard result == VK_SUCCESS, let created = newSwapchain else {
            throw VulkanEngineError.swapchain(result.rawValue)
        }

        destroySwapchainObjects()
        if let oldSwapchain { vkDestroySwapchainKHR(device, oldSwapchain, nil) }
        swapchain = created
        extent = newExtent

        // Images
        var imageTotal: UInt32 = 0
        vkGetSwapchainImagesKHR(device, created, &imageTotal, nil)
        var images = [VkImage?](repeating: nil, count: Int(imageTotal))
        vkGetSwapchainImagesKHR(device, created, &imageTotal, &images)
        swapchainImages = images

        // Views + framebuffers
        swapchainViews = try images.map { image in
            var view: VkImageView?
            var viewInfo = VkImageViewCreateInfo()
            viewInfo.sType    = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
            viewInfo.image    = image
            viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D
            viewInfo.format   = colorFormat
            viewInfo.subresourceRange = VkImageSubresourceRange(
                aspectMask:     VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT.rawValue),
                baseMipLevel:   0, levelCount: 1,
                baseArrayLayer: 0, layerCount: 1
            )
            guard vkCreateImageView(device, &viewInfo, nil, &view) == VK_SUCCESS else {
                throw VulkanEngineError.swapchain(result.rawValue)
            }
            return view
        }

        framebuffers = try swapchainViews.map { view in
            var framebuffer: VkFramebuffer?
            var attachment: VkImageView? = view
            let fbResult: VkResult = withUnsafePointer(to: &attachment) { attPtr in
                var fbInfo = VkFramebufferCreateInfo()
                fbInfo.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO
                fbInfo.renderPass = renderPass
                fbInfo.attachmentCount = 1
                fbInfo.pAttachments = attPtr
                fbInfo.width  = newExtent.width
                fbInfo.height = newExtent.height
                fbInfo.layers = 1
                return vkCreateFramebuffer(device, &fbInfo, nil, &framebuffer)
            }
            guard fbResult == VK_SUCCESS else { throw VulkanEngineError.framebuffer }
            return framebuffer
        }
    }

    /// Destroys framebuffers + views. The swapchain handle itself is handled
    /// by the caller (needed as `oldSwapchain` during recreation).
    private func destroySwapchainObjects() {
        for framebuffer in framebuffers where framebuffer != nil {
            vkDestroyFramebuffer(device, framebuffer, nil)
        }
        framebuffers = []
        for view in swapchainViews where view != nil {
            vkDestroyImageView(device, view, nil)
        }
        swapchainViews = []
        swapchainImages = []
    }

    // MARK: - Sync objects + command buffers

    private func createSyncObjects() throws {
        var allocInfo = VkCommandBufferAllocateInfo()
        allocInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
        allocInfo.commandPool = commandPool
        allocInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY
        allocInfo.commandBufferCount = UInt32(Self.maxFrames)
        var buffers = [VkCommandBuffer?](repeating: nil, count: Self.maxFrames)
        guard vkAllocateCommandBuffers(device, &allocInfo, &buffers) == VK_SUCCESS else {
            throw VulkanEngineError.sync
        }
        commandBuffers = buffers

        for _ in 0..<Self.maxFrames {
            var semInfo = VkSemaphoreCreateInfo()
            semInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO
            var available: VkSemaphore?
            var finished:  VkSemaphore?
            guard
                vkCreateSemaphore(device, &semInfo, nil, &available) == VK_SUCCESS,
                vkCreateSemaphore(device, &semInfo, nil, &finished)  == VK_SUCCESS
            else {
                throw VulkanEngineError.sync
            }
            imageAvailable.append(available)
            renderFinished.append(finished)

            var fenceInfo = VkFenceCreateInfo()
            fenceInfo.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO
            fenceInfo.flags = VkFenceCreateFlags(VK_FENCE_CREATE_SIGNALED_BIT.rawValue)
            var fence: VkFence?
            guard vkCreateFence(device, &fenceInfo, nil, &fence) == VK_SUCCESS else {
                throw VulkanEngineError.sync
            }
            inFlight.append(fence)
        }
    }
}


// MARK: - SulphurNSView attachment

#if canImport(SulphurApplication) && os(macOS)
public extension VulkanRenderEngine {
    /// Build an engine on the view's CAMetalLayer and drive it from the
    /// view's display link. Keep a strong reference to the returned engine.
    static func attached(to view: SulphurNSView) throws -> VulkanRenderEngine {
        let engine = try VulkanRenderEngine(metalLayer: view.metalLayer)
        view.onFrame = { [weak engine] dt in
            engine?.drawFrame(dt)
        }
        return engine
    }
}
#endif


// MARK: - Surface format

extension VulkanRenderEngine {
    /// The surface's own colour format, preferring BGRA where it is offered.
    ///
    /// BGRA first because that is what MoltenVK presents natively and what the
    /// Metal-import paths elsewhere in this file assume; RGBA is accepted next
    /// because Android surfaces commonly offer only that. `VK_FORMAT_UNDEFINED`
    /// as the sole entry is the spec's "any format goes" answer, in which case
    /// the preference stands.
    private func chooseSurfaceFormat() -> VkFormat {
        var count: UInt32 = 0
        vkGetPhysicalDeviceSurfaceFormatsKHR(physicalDevice, surface, &count, nil)
        guard count > 0 else { return colorFormat }

        var formats = [VkSurfaceFormatKHR](repeating: VkSurfaceFormatKHR(), count: Int(count))
        vkGetPhysicalDeviceSurfaceFormatsKHR(physicalDevice, surface, &count, &formats)

        if count == 1, formats[0].format == VK_FORMAT_UNDEFINED {
            return colorFormat
        }

        let srgb = formats.filter { $0.colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR }
        let candidates = srgb.isEmpty ? formats : srgb
        for preferred in [VK_FORMAT_B8G8R8A8_UNORM, VK_FORMAT_R8G8B8A8_UNORM]
        where candidates.contains(where: { $0.format == preferred }) {
            return preferred
        }
        // Neither 8-bit UNORM order offered: take what the surface leads with
        // rather than requesting something it never advertised.
        return candidates[0].format
    }

    /// Whether MoltenVK exposes storage-image use on linear-tiled BGRA8 —
    /// the exact image shape `makeThorNode(importingMetalTexture:)` creates.
    /// Gates canvas post-shader support on the Vulkan side.
    private func supportsLinearBgraStorage() -> Bool {
        var props = VkFormatProperties()
        vkGetPhysicalDeviceFormatProperties(
            physicalDevice,
            VK_FORMAT_B8G8R8A8_UNORM,
            &props
        )
        return (props.linearTilingFeatures & VkFormatFeatureFlags(VK_FORMAT_FEATURE_STORAGE_IMAGE_BIT.rawValue)) != 0
    }

    /// Block until the last frame submitted has finished on the GPU —
    /// nothing that frame read or wrote is still in use. For a host that
    /// writes a node's image outside this queue after a frame read it (a
    /// ThorVG canvas, on wgpu's queue, that `ImageNode`s copied out of):
    /// the frame's fence is what says the reads are done, and the write
    /// must wait for it. Returns at once when that frame already has.
    public func waitForPreviousFrame() {
        guard !inFlight.isEmpty else { return }
        var fence = inFlight[(frameIndex + Self.maxFrames - 1) % Self.maxFrames]
        vkWaitForFences(device, 1, &fence, VK_TRUE, UInt64.max)
    }
}


// MARK: - Helpers

/// Layout-transition barrier (same shape as the one in VulkenRenderTest.swift,
/// duplicated here because that one is file-private).
public func engineImageBarrier(
    _ cmd:     VkCommandBuffer,
    image:     VkImage,
    srcLayout: VkImageLayout,
    srcAccess: VkAccessFlags,
    srcStage:  VkPipelineStageFlagBits,
    dstLayout: VkImageLayout,
    dstAccess: VkAccessFlags,
    dstStage:  VkPipelineStageFlagBits
) {
    var barrier = VkImageMemoryBarrier()
    barrier.sType               = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER
    barrier.srcAccessMask       = srcAccess
    barrier.dstAccessMask       = dstAccess
    barrier.oldLayout           = srcLayout
    barrier.newLayout           = dstLayout
    barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED
    barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED
    barrier.image               = image
    barrier.subresourceRange    = VkImageSubresourceRange(
        aspectMask:     VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT.rawValue),
        baseMipLevel:   0, levelCount: 1,
        baseArrayLayer: 0, layerCount: 1
    )
    vkCmdPipelineBarrier(
        cmd,
        VkPipelineStageFlags(srcStage.rawValue),
        VkPipelineStageFlags(dstStage.rawValue),
        0, 0, nil, 0, nil, 1, &barrier
    )
}

/// Call `body` with a C array of NULL-terminated C strings, valid for the call.
func withCStringArray<R>(
    _ strings: [String],
    _ body: (UnsafePointer<UnsafePointer<CChar>?>?, UInt32) -> R
) -> R {
    func recurse(_ index: Int, _ acc: [UnsafePointer<CChar>?]) -> R {
        if index == strings.count {
            return acc.withUnsafeBufferPointer { buf in
                body(buf.baseAddress, UInt32(strings.count))
            }
        }
        return strings[index].withCString { cString in
            recurse(index + 1, acc + [cString])
        }
    }
    return recurse(0, [])
}

func enumerateInstanceExtensions() -> Set<String> {
    var count: UInt32 = 0
    vkEnumerateInstanceExtensionProperties(nil, &count, nil)
    guard count > 0 else { return [] }
    var props = [VkExtensionProperties](repeating: VkExtensionProperties(), count: Int(count))
    vkEnumerateInstanceExtensionProperties(nil, &count, &props)
    return Set(props.map(extensionName))
}

func extensionName(_ prop: VkExtensionProperties) -> String {
    var name = prop.extensionName
    return withUnsafeBytes(of: &name) { raw in
        String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
    }
}
