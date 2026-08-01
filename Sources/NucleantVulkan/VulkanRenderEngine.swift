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
#if os(iOS)
import wgpu_native
#else
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

/// Owns the whole present stack: instance → Metal surface → device → swapchain
/// → composite pass. Each frame it updates dirty nodes (ThorVG draw / compute
/// dispatch + layout barriers) and blends every published node's image onto
/// the swapchain with the alpha-blending `CompositePipeline`.
public final class VulkanRenderEngine<RenderNode: RenderContainerNode>: VulkanContext {

    // MARK: VulkanContext

    public let device:         VkDevice
    public let physicalDevice: VkPhysicalDevice
    public let descriptorPool: VkDescriptorPool
    /// Frames in flight — per-image resources (uniform buffers, descriptor
    /// sets) allocated against this context should be indexed by `frameIndex`.
    public let imageCount: Int

    // MARK: Core objects

    public let instance:         VkInstance
    public let surface:          VkSurfaceKHR
    public let graphicsQueue:    VkQueue
    public let queueFamilyIndex: UInt32
    public let commandPool:      VkCommandPool

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
    public var nodes: [RenderNode] = []

    public func append(_ node: RenderNode) {
        nodes.append(node)
    }

    /// Removes a single node from the composite list — e.g. when the widget
    /// owning it is dropped from the tree, so a stale image doesn't keep
    /// drawing every frame. Keyed by the slot's stable id (the owning
    /// canvas's `id`, the same value it was appended with). Groups aren't
    /// addressed by this (nothing builds one yet).
    public func remove(id: Int) {
        // let id = ObjectIdentifier(node).hashValue
        // ^ replaced (update-render-system.md): identity is the canvas-owned
        //   Int id carried by RenderNode, never derived from the node object.
        // Free the outgoing slot's GPU resources before it leaves the list —
        // the slot routes to its node's destroyResources. Without this every
        // removal (widget detach, resize) strands the node's VkImage on the
        // device, the exact leak that used to need a separate engine call.
        if let node = nodes.first(where: { $0.id == id }) {
            node.destroyResources(engine: self)
        }
        nodes.removeAll { $0.id == id }
        releaseTracking(of: id)
    }

    /// Swap a slot's context in place — same id, same z-position, new GPU
    /// resources. `remove` + `append` would hoist a rebuilt node above
    /// every sibling; a frame resize must not change stacking order.
    /// Falls back to append when the id isn't listed.
    public func replace(id: Int, with context: RenderNode.Context) {
        // let id = ObjectIdentifier(old).hashValue
        // ^ replaced, same as remove(id:) — see note there.
        releaseTracking(of: id)
        if let index = nodes.firstIndex(where: { $0.id == id }) {
            // Same-id swap (resize): the caller has already built the
            // replacement (it's in `context`), so the outgoing node's image
            // is now orphaned — free it before installing the new slot.
            nodes[index].destroyResources(engine: self)
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

    /// Drop everything the engine caches against a slot id whose node image was
    /// swapped *in place* (a resize) — the sampler descriptor set + its pool,
    /// and the `readable` flag. The per-slot descriptor cache assumes a node's
    /// imageView is stable for life; an in-place image swap breaks that, so the
    /// next frame must rebuild the set from the new view, and the slot must not
    /// be sampled until the resized node's next draw makes its new image
    /// readable again. Unlike `remove`/`replace`, the node itself stays in the
    /// composite list — this only clears cache, never the slot.
    public func invalidateComposite(id: Int) {
        releaseTracking(of: id)
    }

    /// Everything the engine tracked against a slot id — descriptor set +
    /// its dedicated pool, readable state, warn-once marker. Shared by
    /// `remove(id:)` / `replace(id:with:)`; the next frame re-derives it
    /// all for whatever occupies the id afterwards.
    private func releaseTracking(of id: Int) {
        nodeSets.removeValue(forKey: id)
        if let pool = nodeDescriptorPools.removeValue(forKey: id) {
            vkDestroyDescriptorPool(device, pool, nil)
        }
        readable.remove(id)
        warnedFailedNodes.remove(id)
    }

    // GPU-side teardown of a node's VkImage/view/memory lives on the node
    // now, not here: `VulkanRenderNode.destroyResources(_:)`, called through
    // the slot's `destroyResources(engine:)`. That keeps node-kind-specific
    // teardown (a CPU-fed node's staging buffer, a Skia node's surface) out
    // of the generic engine — the engine only takes the slot out of the
    // composite list via `remove(id:)`.

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
    private let colorFormat = VK_FORMAT_B8G8R8A8_UNORM

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

    /// Descriptor set per node (keyed by identity) — image views are stable
    /// for a node's lifetime, so one set-update at creation is enough. Each
    /// set gets its own dedicated pool (see `allocateNodeDescriptorSet`) so
    /// MoltenVK never has to pack multiple same-layout sets from one pool —
    /// doing so misaligns every other set's Metal argument-buffer offset.
    private var nodeSets: [Int: VkDescriptorSet] = [:]
    private var nodeDescriptorPools: [Int: VkDescriptorPool] = [:]
    /// Nodes whose image currently sits in SHADER_READ_ONLY_OPTIMAL.
    /// Internal (not private): the Skia update lives in its own file
    /// (VulkanRenderEngine+Skia.swift) and publishes through this too.
    public var readable: Set<Int> = []
    /// Nodes we've already logged a draw failure for — ThorVG's Canvas
    /// legitimately (and permanently) returns InsufficientCondition from a
    /// canvas nothing was ever painted into (e.g. a container widget whose
    /// on_canvas only holds children), so this is expected steady-state for
    /// some nodes, not a transient error worth repeating every frame.
    /// Internal for the same reason as `readable`.
    public var warnedFailedNodes: Set<Int> = []

    // MARK: - Init

    /// The shared, platform-agnostic designated init: everything from here
    /// down is plain Vulkan — device pick, queue, command pool, descriptor
    /// pool, render pass, sync objects, composite pipeline, first swapchain
    /// attempt — identical on every platform. `instance`/`surface` arrive
    /// already made: creating them is inherently platform-specific (Metal
    /// surface via MoltenVK on Apple; Wayland/XCB surface elsewhere), so
    /// that part is the caller's job — see `init(metalLayer:)` below for the
    /// Apple entry point. `getExtent` is the one other unavoidable seam:
    /// there's no portable "what size is my surface right now" query (a
    /// CAMetalLayer reports `drawableSize`; a raw Wayland surface doesn't
    /// self-report at all), so whoever made the surface answers it too.
    public init(
        instance: VkInstance,
        surface: VkSurfaceKHR,
        getExtent: @escaping () -> VkExtent2D
    ) throws {
        self.instance = instance
        self.surface = surface
        self.getExtent = getExtent
        self.imageCount = Self.maxFrames

        // --- Physical device --------------------------------------------------
        var gpuCount: UInt32 = 0
        vkEnumeratePhysicalDevices(instance, &gpuCount, nil)
        guard gpuCount > 0 else { throw VulkanEngineError.noPhysicalDevice }
        var gpus = [VkPhysicalDevice?](repeating: nil, count: Int(gpuCount))
        vkEnumeratePhysicalDevices(instance, &gpuCount, &gpus)
        guard let gpu = gpus.compactMap({ $0 }).first else {
            throw VulkanEngineError.noPhysicalDevice
        }
        self.physicalDevice = gpu

        // --- Queue family: graphics + compute + present ----------------------
        var familyCount: UInt32 = 0
        vkGetPhysicalDeviceQueueFamilyProperties(gpu, &familyCount, nil)
        var families = [VkQueueFamilyProperties](
            repeating: VkQueueFamilyProperties(),
            count: Int(familyCount)
        )
        vkGetPhysicalDeviceQueueFamilyProperties(gpu, &familyCount, &families)
        let needed = VkQueueFlags(VK_QUEUE_GRAPHICS_BIT.rawValue | VK_QUEUE_COMPUTE_BIT.rawValue)
        var pickedFamily: UInt32?
        for (i, family) in families.enumerated() where (family.queueFlags & needed) == needed {
            var presentable: VkBool32 = VK_FALSE
            vkGetPhysicalDeviceSurfaceSupportKHR(gpu, UInt32(i), surface, &presentable)
            if presentable == VK_TRUE {
                pickedFamily = UInt32(i)
                break
            }
        }
        guard let familyIndex = pickedFamily else { throw VulkanEngineError.noPresentQueue }
        self.queueFamilyIndex = familyIndex

        // --- Device + queue ----------------------------------------------------
        let availableDeviceExts = enumerateDeviceExtensions(gpu)
        var deviceExtensions = ["VK_KHR_swapchain"]
        if availableDeviceExts.contains("VK_KHR_portability_subset") {
            deviceExtensions.append("VK_KHR_portability_subset")
        }
        if availableDeviceExts.contains("VK_EXT_metal_objects") {
            deviceExtensions.append("VK_EXT_metal_objects")
        }
        // Linux ThorVG zero-copy: import wgpu-native's exported memory fd
        // (VK_KHR_external_memory_fd) as a VkImage on *this* device — the
        // Linux/Vulkan mirror of VK_EXT_metal_objects above. Both device
        // extensions are the cross-platform half of VK_KHR_external_memory,
        // already core since Vulkan 1.1.
        if availableDeviceExts.contains("VK_KHR_external_memory_fd") {
            deviceExtensions.append("VK_KHR_external_memory_fd")
        }
        var createdDevice: VkDevice?
        var priority: Float = 1.0
        let devResult: VkResult = withUnsafePointer(to: &priority) { priorityPtr in
            var qci = VkDeviceQueueCreateInfo()
            qci.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
            qci.queueFamilyIndex = familyIndex
            qci.queueCount = 1
            qci.pQueuePriorities = priorityPtr
            return withUnsafePointer(to: &qci) { qciPtr in
                withCStringArray(deviceExtensions) { extPtr, extCount in
                    var dci = VkDeviceCreateInfo()
                    dci.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
                    dci.queueCreateInfoCount = 1
                    dci.pQueueCreateInfos = qciPtr
                    dci.enabledExtensionCount = extCount
                    dci.ppEnabledExtensionNames = extPtr
                    return vkCreateDevice(gpu, &dci, nil, &createdDevice)
                }
            }
        }
        guard devResult == VK_SUCCESS, let device = createdDevice else {
            throw VulkanEngineError.device(devResult.rawValue)
        }
        self.device = device

        var queue: VkQueue?
        vkGetDeviceQueue(device, familyIndex, 0, &queue)
        guard let queue else { throw VulkanEngineError.noPresentQueue }
        self.graphicsQueue = queue

        // --- Command pool -------------------------------------------------------
        var createdPool: VkCommandPool?
        var poolInfo = VkCommandPoolCreateInfo()
        poolInfo.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
        poolInfo.flags = VkCommandPoolCreateFlags(VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT.rawValue)
        poolInfo.queueFamilyIndex = familyIndex
        guard vkCreateCommandPool(device, &poolInfo, nil, &createdPool) == VK_SUCCESS,
              let pool = createdPool else {
            throw VulkanEngineError.commandPool
        }
        self.commandPool = pool

        // --- Descriptor pool ------------------------------------------------------
        self.descriptorPool = try makeEngineDescriptorPool(device: device, maxSets: 256)

        // All stored lets are set — instance methods are usable from here on.
        try createRenderPass()
        try createSyncObjects()
        try createCompositePipeline()
        // Tolerate a zero-sized layer at init; drawFrame retries until it has
        // a real drawable size (SulphurNSView sets it in setFrameSize).
        try? createSwapchain()
    }

    #if os(macOS) || os(iOS)
    /// Apple entry point: builds the VkInstance (with the Metal surface
    /// extensions) and the VkSurfaceKHR from a CAMetalLayer itself, since
    /// Apple only allows reaching Vulkan through MoltenVK/Metal in the first
    /// place — there's no "hand me a native surface" option here the way
    /// there is on Linux. Delegates to the shared init above for everything
    /// past that.
    public convenience init(metalLayer: CAMetalLayer) throws {
        let availableInstanceExts = enumerateInstanceExtensions()
        var instanceExtensions = ["VK_KHR_surface", "VK_EXT_metal_surface"]
        if availableInstanceExts.contains("VK_KHR_get_physical_device_properties2") {
            instanceExtensions.append("VK_KHR_get_physical_device_properties2")
        }
        var instanceFlags: VkInstanceCreateFlags = 0
        if availableInstanceExts.contains("VK_KHR_portability_enumeration") {
            instanceExtensions.append("VK_KHR_portability_enumeration")
            instanceFlags = VkInstanceCreateFlags(0x00000001) // ENUMERATE_PORTABILITY_BIT_KHR
        }

        var createdInstance: VkInstance?
        var appInfo = VkApplicationInfo()
        appInfo.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO
        appInfo.apiVersion = (1 << 22) | (2 << 12) // Vulkan 1.2
        let instResult: VkResult = withUnsafePointer(to: &appInfo) { appPtr in
            withCStringArray(instanceExtensions) { extPtr, extCount in
                var ci = VkInstanceCreateInfo()
                ci.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
                ci.flags = instanceFlags
                ci.pApplicationInfo = appPtr
                ci.enabledExtensionCount = extCount
                ci.ppEnabledExtensionNames = extPtr
                return vkCreateInstance(&ci, nil, &createdInstance)
            }
        }
        guard instResult == VK_SUCCESS, let instance = createdInstance else {
            throw VulkanEngineError.instance(instResult.rawValue)
        }

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

        try self.init(instance: instance, surface: surface, getExtent: {
            let drawable = metalLayer.drawableSize
            return VkExtent2D(
                width:  UInt32(max(drawable.width, 0)),
                height: UInt32(max(drawable.height, 0))
            )
        })
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
        vkDeviceWaitIdle(device)
        // Free every live slot's node resources before the device is torn
        // down — each routes to its node's destroyResources. vkDestroyDevice
        // would reclaim the memory regardless, but explicit teardown keeps
        // the validation layers quiet about images outliving their device.
        for node in nodes { node.destroyResources(engine: self) }
        nodes.removeAll()
        for pool in nodeDescriptorPools.values { vkDestroyDescriptorPool(device, pool, nil) }
        composite = nil   // destroys its pipeline/layouts before the device goes away
        destroySwapchainObjects()
        if let swapchain { vkDestroySwapchainKHR(device, swapchain, nil) }
        for sem in imageAvailable where sem != nil { vkDestroySemaphore(device, sem, nil) }
        for sem in renderFinished where sem != nil { vkDestroySemaphore(device, sem, nil) }
        for fence in inFlight where fence != nil { vkDestroyFence(device, fence, nil) }
        if let renderPass { vkDestroyRenderPass(device, renderPass, nil) }
        vkDestroyDescriptorPool(device, descriptorPool, nil)
        vkDestroyCommandPool(device, commandPool, nil)
        vkDestroyDevice(device, nil)
        vkDestroySurfaceKHR(instance, surface, nil)
        vkDestroyInstance(instance, nil)
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

        vkResetFences(device, 1, &fence)

        guard let cmd = commandBuffers[frame] else { return }
        vkResetCommandBuffer(cmd, 0)
        var begin = VkCommandBufferBeginInfo()
        begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
        begin.flags = VkCommandBufferUsageFlags(VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT.rawValue)
        vkBeginCommandBuffer(cmd, &begin)

        // 1. Node content updates (outside the render pass).
        for node in nodes {
            //update(node, cmd: cmd)
            node.update(engine: self, cmd: cmd)
        }

        // 2. Composite every published node onto the swapchain image.
        recordCompositePass(cmd: cmd, imageIndex: Int(imageIndex))

        vkEndCommandBuffer(cmd)

        // 3. Submit + present.
        guard submit(cmd, frame: frame) == VK_SUCCESS else { return }
        let present = presentFrame(imageIndex: imageIndex, frame: frame)
        if present == VK_ERROR_OUT_OF_DATE_KHR || present == VK_SUBOPTIMAL_KHR {
            recreateSwapchain()
        }
        frameIndex = (frameIndex + 1) % Self.maxFrames
    }

    // MARK: - Node updates

    /// Per-slot dispatch: routes a `RenderNode` to the update matching its
    /// context. Groups recurse — each child is a full slot with its own id
    /// and dirty tracking.
    // private func update(_ node: RenderNode, cmd: VkCommandBuffer) {
    //     switch node.context {
    //     case .thor(let thorShaderNode):
    //         update(thorShaderNode, slot: node, cmd: cmd)
    //     case .skia(let skiaShaderNode):
    //         update(skiaShaderNode, slot: node, cmd: cmd)
    //     case .shader(let oGLShaderNode):
    //         update(oGLShaderNode, slot: node, cmd: cmd)
    //     case .pixel_buffer(let pixelBufferShaderNode):
    //         update(pixelBufferShaderNode, slot: node, cmd: cmd)
    //     case .group(let groupNode):
    //         update(groupNode, cmd: cmd)
    //     case .texture_group(_):
    //         fatalError("TextureGroup not implemented yet")
    //     }
    // }

    // private func update(_ group: GroupNode, cmd: VkCommandBuffer) {
    //     for node in group.nodes {
    //         update(node, cmd: cmd)
    //     }
    // }
    /// Draw + sync the node's ThorVG canvas, then barrier the image
    /// (optionally through the node's compute post-process) into
    /// SHADER_READ_ONLY for the composite pass.
    // private func update(_ node: ThorShaderNode, slot: RenderNode, cmd: VkCommandBuffer) {
    //     // let id = ObjectIdentifier(node).hashValue
    //     // ^ replaced: the slot carries the canvas-owned id.
    //     let id = slot.id
    //     // guard node.dirty else { return }
    //     // ^ the dirty marker moved up to the slot — Observation on the
    //     //   shader node feeds it (see RenderNode.observe).
    //     guard slot.needsRender else { return }
    //     let drawResult = node.canvas.draw()
    //     let syncResult = drawResult == TVG_RESULT_SUCCESS ? node.canvas.sync() : drawResult
    //     guard drawResult == TVG_RESULT_SUCCESS, syncResult == TVG_RESULT_SUCCESS else {
    //         if warnedFailedNodes.insert(id).inserted {
    //             print("VulkanRenderEngine: thor node \(id) failed rendering (draw: \(drawResult), sync: \(syncResult)) — logged once; this repeats every frame if nothing is ever painted into the node's canvas")
    //         }
    //         return
    //     }
    //     warnedFailedNodes.remove(id)
    //     // node.dirty = false
    //     // ^ must NOT write back to the shader node: the slot observes it,
    //     //   so an engine-side write would fire onChange and re-mark the
    //     //   slot dirty — a permanent redraw loop. The engine consumes the
    //     //   slot's flag only.
    //     // slot.needsRender = false
    //     // ^ deliberately NOT cleared for now: nothing drives per-frame
    //     //   updates yet (tetris side isn't wired up), so slots stay
    //     //   permanently dirty and every node redraws every frame — which
    //     //   is also the intended leak-amplifier mode while leaks are
    //     //   hunted. Re-enable clearing once the canvas side really drives
    //     //   updates through the Observation chain.
    //     node.waitForExternalCompletion?()

    //     // Barriers must declare the layout the image is *really* in right
    //     // now — node.currentLayout, not an assumption. An externally-backed
    //     // image's writer (Metal, via wgpu-native) never goes through our
    //     // Vulkan command stream, so on its very first draw the only
    //     // trustworthy claim is GENERAL (set at import time): valid as a
    //     // source for any prior access, and — unlike UNDEFINED — never
    //     // permits the driver to discard content. On every frame after
    //     // that, currentLayout correctly reflects where the previous
    //     // barrier below actually left it.
    //     let priorLayout  = node.currentLayout
    //     let priorAccess: VkAccessFlags = node.isExternallyBacked
    //         ? VkAccessFlags(VK_ACCESS_MEMORY_WRITE_BIT.rawValue) | VkAccessFlags(VK_ACCESS_MEMORY_READ_BIT.rawValue)
    //         : VkAccessFlags(VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT.rawValue)

    //     if let pipeline = node.computePipeline,
    //        let layout   = node.computeLayout,
    //        let ds       = node.computeDescriptorSet {

    //         engineImageBarrier(
    //             cmd,
    //             image:     node.image,
    //             srcLayout: priorLayout,
    //             srcAccess: priorAccess,
    //             srcStage:  VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
    //             dstLayout: VK_IMAGE_LAYOUT_GENERAL,
    //             dstAccess: VkAccessFlags(VK_ACCESS_SHADER_READ_BIT.rawValue) | VkAccessFlags(VK_ACCESS_SHADER_WRITE_BIT.rawValue),
    //             dstStage:  VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT
    //         )
    //         vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline)
    //         var descSet: VkDescriptorSet? = ds
    //         vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, layout, 0, 1, &descSet, 0, nil)
    //         vkCmdDispatch(cmd, (node.width + 7) / 8, (node.height + 7) / 8, 1)
    //         engineImageBarrier(
    //             cmd,
    //             image:     node.image,
    //             srcLayout: VK_IMAGE_LAYOUT_GENERAL,
    //             srcAccess: VkAccessFlags(VK_ACCESS_SHADER_WRITE_BIT.rawValue),
    //             srcStage:  VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
    //             dstLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    //             dstAccess: VkAccessFlags(VK_ACCESS_SHADER_READ_BIT.rawValue),
    //             dstStage:  VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT
    //         )
    //     } else {
    //         engineImageBarrier(
    //             cmd,
    //             image:     node.image,
    //             srcLayout: priorLayout,
    //             srcAccess: priorAccess,
    //             srcStage:  VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
    //             dstLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    //             dstAccess: VkAccessFlags(VK_ACCESS_SHADER_READ_BIT.rawValue),
    //             dstStage:  VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT
    //         )
    //     }
    //     node.currentLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
    //     readable.insert(id)
    // }

    /// The shader-only counterpart of the thor update: no canvas draw —
    /// the compute dispatch writes the whole image. Without an installed
    /// pipeline the node has no content, so it stays unpublished (never
    /// enters `readable`) instead of compositing garbage.
    // private func update(_ node: OGLShaderNode, slot: RenderNode, cmd: VkCommandBuffer) {
    //     guard slot.needsRender else { return }
    //     guard let pipeline = node.computePipeline,
    //           let layout   = node.computeLayout,
    //           let ds       = node.computeDescriptorSet
    //     else { return }

    //     engineImageBarrier(
    //         cmd,
    //         image:     node.image,
    //         srcLayout: node.currentLayout,
    //         srcAccess: VkAccessFlags(VK_ACCESS_SHADER_READ_BIT.rawValue) | VkAccessFlags(VK_ACCESS_SHADER_WRITE_BIT.rawValue),
    //         srcStage:  VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
    //         dstLayout: VK_IMAGE_LAYOUT_GENERAL,
    //         dstAccess: VkAccessFlags(VK_ACCESS_SHADER_READ_BIT.rawValue) | VkAccessFlags(VK_ACCESS_SHADER_WRITE_BIT.rawValue),
    //         dstStage:  VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT
    //     )
    //     vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline)
    //     var descSet: VkDescriptorSet? = ds
    //     vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, layout, 0, 1, &descSet, 0, nil)
    //     vkCmdDispatch(cmd, (node.width + 7) / 8, (node.height + 7) / 8, 1)
    //     engineImageBarrier(
    //         cmd,
    //         image:     node.image,
    //         srcLayout: VK_IMAGE_LAYOUT_GENERAL,
    //         srcAccess: VkAccessFlags(VK_ACCESS_SHADER_WRITE_BIT.rawValue),
    //         srcStage:  VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
    //         dstLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    //         dstAccess: VkAccessFlags(VK_ACCESS_SHADER_READ_BIT.rawValue),
    //         dstStage:  VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT
    //     )
    //     node.currentLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
    //     readable.insert(slot.id)
    //     // slot.needsRender = false
    //     // ^ same as the thor update above: kept permanently dirty until
    //     //   something actually drives updates.
    // }

    /// The CPU-fed counterpart of the thor update: instead of a ThorVG
    /// draw, the node's staged pixels are copied into its image, then
    /// (optionally) run through the compute post shader — same barrier
    /// choreography, TRANSFER standing in for the canvas draw. Without a
    /// first `write` the node has no content and stays unpublished.
    // private func update(_ node: PixelBufferShaderNode, slot: RenderNode, cmd: VkCommandBuffer) {
    //     guard slot.needsRender, node.hasContent else { return }

    //     // This frame slot's fence was waited at the top of drawFrame — the
    //     // staging slice indexed by it is provably idle, so the CPU copy
    //     // here can't race the previous frame's GPU read.
    //     node.stage(into: frameIndex)

    //     // First upload ever: the image is still UNDEFINED and fully
    //     // overwritten by the copy, so discarding is correct. Afterwards
    //     // the real prior state is "composite sampled it last frame".
    //     let firstUpload = node.currentLayout == VK_IMAGE_LAYOUT_UNDEFINED
    //     engineImageBarrier(
    //         cmd,
    //         image:     node.image,
    //         srcLayout: node.currentLayout,
    //         srcAccess: firstUpload ? 0 : VkAccessFlags(VK_ACCESS_SHADER_READ_BIT.rawValue),
    //         srcStage:  firstUpload ? VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT : VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
    //         dstLayout: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
    //         dstAccess: VkAccessFlags(VK_ACCESS_TRANSFER_WRITE_BIT.rawValue),
    //         dstStage:  VK_PIPELINE_STAGE_TRANSFER_BIT
    //     )

    //     let colorLayers = VkImageSubresourceLayers(
    //         aspectMask:     VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT.rawValue),
    //         mipLevel:       0,
    //         baseArrayLayer: 0,
    //         layerCount:     1
    //     )
    //     var region = VkBufferImageCopy()
    //     region.bufferOffset = VkDeviceSize(node.stagingOffset(of: frameIndex))
    //     // bufferRowLength/bufferImageHeight 0 = tightly packed.
    //     region.imageSubresource = colorLayers
    //     region.imageExtent = VkExtent3D(width: node.sourceWidth, height: node.sourceHeight, depth: 1)

    //     if let uploadImage = node.uploadImage {
    //         // Scaled path: staging lands in the source-sized upload image,
    //         // then a nearest blit stretches it into the scale×-larger node
    //         // image — the GPU does the pixel replication the producer no
    //         // longer pays for. After the first frame the upload image's
    //         // prior state is "blit read it", hence TRANSFER_SRC.
    //         let firstSmall = node.uploadLayout == VK_IMAGE_LAYOUT_UNDEFINED
    //         engineImageBarrier(
    //             cmd,
    //             image:     uploadImage,
    //             srcLayout: node.uploadLayout,
    //             srcAccess: firstSmall ? 0 : VkAccessFlags(VK_ACCESS_TRANSFER_READ_BIT.rawValue),
    //             srcStage:  VK_PIPELINE_STAGE_TRANSFER_BIT,
    //             dstLayout: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
    //             dstAccess: VkAccessFlags(VK_ACCESS_TRANSFER_WRITE_BIT.rawValue),
    //             dstStage:  VK_PIPELINE_STAGE_TRANSFER_BIT
    //         )
    //         vkCmdCopyBufferToImage(
    //             cmd,
    //             node.stagingBuffer,
    //             uploadImage,
    //             VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
    //             1,
    //             &region
    //         )
    //         engineImageBarrier(
    //             cmd,
    //             image:     uploadImage,
    //             srcLayout: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
    //             srcAccess: VkAccessFlags(VK_ACCESS_TRANSFER_WRITE_BIT.rawValue),
    //             srcStage:  VK_PIPELINE_STAGE_TRANSFER_BIT,
    //             dstLayout: VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
    //             dstAccess: VkAccessFlags(VK_ACCESS_TRANSFER_READ_BIT.rawValue),
    //             dstStage:  VK_PIPELINE_STAGE_TRANSFER_BIT
    //         )
    //         node.uploadLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL

    //         var blit = VkImageBlit()
    //         blit.srcSubresource = colorLayers
    //         blit.srcOffsets.1   = VkOffset3D(x: Int32(node.sourceWidth), y: Int32(node.sourceHeight), z: 1)
    //         blit.dstSubresource = colorLayers
    //         blit.dstOffsets.1   = VkOffset3D(x: Int32(node.width), y: Int32(node.height), z: 1)
    //         vkCmdBlitImage(
    //             cmd,
    //             uploadImage,
    //             VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
    //             node.image,
    //             VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
    //             1,
    //             &blit,
    //             VK_FILTER_NEAREST
    //         )
    //     } else {
    //         vkCmdCopyBufferToImage(
    //             cmd,
    //             node.stagingBuffer,
    //             node.image,
    //             VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
    //             1,
    //             &region
    //         )
    //     }

    //     if let pipeline = node.computePipeline,
    //        let layout   = node.computeLayout,
    //        let ds       = node.computeDescriptorSet {

    //         engineImageBarrier(
    //             cmd,
    //             image:     node.image,
    //             srcLayout: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
    //             srcAccess: VkAccessFlags(VK_ACCESS_TRANSFER_WRITE_BIT.rawValue),
    //             srcStage:  VK_PIPELINE_STAGE_TRANSFER_BIT,
    //             dstLayout: VK_IMAGE_LAYOUT_GENERAL,
    //             dstAccess: VkAccessFlags(VK_ACCESS_SHADER_READ_BIT.rawValue) | VkAccessFlags(VK_ACCESS_SHADER_WRITE_BIT.rawValue),
    //             dstStage:  VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT
    //         )
    //         vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline)
    //         var descSet: VkDescriptorSet? = ds
    //         vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, layout, 0, 1, &descSet, 0, nil)
    //         vkCmdDispatch(cmd, (node.width + 7) / 8, (node.height + 7) / 8, 1)
    //         engineImageBarrier(
    //             cmd,
    //             image:     node.image,
    //             srcLayout: VK_IMAGE_LAYOUT_GENERAL,
    //             srcAccess: VkAccessFlags(VK_ACCESS_SHADER_WRITE_BIT.rawValue),
    //             srcStage:  VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
    //             dstLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    //             dstAccess: VkAccessFlags(VK_ACCESS_SHADER_READ_BIT.rawValue),
    //             dstStage:  VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT
    //         )
    //     } else {
    //         engineImageBarrier(
    //             cmd,
    //             image:     node.image,
    //             srcLayout: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
    //             srcAccess: VkAccessFlags(VK_ACCESS_TRANSFER_WRITE_BIT.rawValue),
    //             srcStage:  VK_PIPELINE_STAGE_TRANSFER_BIT,
    //             dstLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    //             dstAccess: VkAccessFlags(VK_ACCESS_SHADER_READ_BIT.rawValue),
    //             dstStage:  VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT
    //         )
    //     }
    //     node.currentLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
    //     readable.insert(slot.id)
    //     // slot.needsRender = false
    //     // ^ same as the other updates: kept permanently dirty until the
    //     //   producer side drives updates through the Observation chain.
    // }

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
            let scissor: VkRect2D
            if let r = node.compositeRect, r.z > 0, r.w > 0 {
                viewport = VkViewport(
                    x: Float(r.x), y: Float(r.y),
                    width:  Float(r.z), height: Float(r.w),
                    minDepth: 0, maxDepth: 1
                )
                scissor = VkRect2D(
                    offset: VkOffset2D(x: Int32(r.x), y: Int32(r.y)),
                    extent: VkExtent2D(width: UInt32(r.z), height: UInt32(r.w))
                )
            } else {
                viewport = fullViewport
                scissor  = fullScissor
            }
            recordComposite(of: node, cmd: cmd, viewport: viewport, scissor: scissor)
        }

        vkCmdEndRenderPass(cmd)
    }

    /// Composite one slot, recursing into groups. A slot only draws once a
    /// frame update actually published its image (`readable`) — a node that
    /// never rendered has nothing safe to sample.
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
            readable.contains(node.id),
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
        if let set = nodeSets[id] { return set }
        guard let allocated = try? composite.allocateNodeDescriptorSet() else { return nil }
        composite.updateDescriptorSet(allocated.set, imageViews: [imageView])
        nodeSets[id] = allocated.set
        nodeDescriptorPools[id] = allocated.pool
        return allocated.set
    }

    // MARK: - Submit / present

    private func submit(_ cmd: VkCommandBuffer, frame: Int) -> VkResult {
        var waitStage = VkPipelineStageFlags(VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT.rawValue)
        var waitSem   = imageAvailable[frame]
        var signalSem = renderFinished[frame]
        var cmdOpt: VkCommandBuffer? = cmd
        return withUnsafePointer(to: &waitStage) { stagePtr in
            withUnsafePointer(to: &waitSem) { waitPtr in
                withUnsafePointer(to: &signalSem) { signalPtr in
                    withUnsafePointer(to: &cmdOpt) { cmdPtr in
                        var info = VkSubmitInfo()
                        info.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO
                        info.waitSemaphoreCount = 1
                        info.pWaitSemaphores = waitPtr
                        info.pWaitDstStageMask = stagePtr
                        info.commandBufferCount = 1
                        info.pCommandBuffers = cmdPtr
                        info.signalSemaphoreCount = 1
                        info.pSignalSemaphores = signalPtr
                        return vkQueueSubmit(graphicsQueue, 1, &info, inFlight[frame])
                    }
                }
            }
        }
    }

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

    private func recreateSwapchain() {
        vkDeviceWaitIdle(device)
        try? createSwapchain()
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
        info.preTransform     = caps.currentTransform
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


// MARK: - Node factory

extension VulkanRenderEngine {
    /// Build a whole self-contained ThorVG render target: its own WGPUTexture,
    /// a `Tvg_Canvas` targeting that texture, and its own `ThorShaderNode`
    /// importing that texture's Metal memory as a VkImage — the same zero-copy
    /// pattern the app's root render target uses. Callers append the returned
    /// node into `nodes` themselves; this only builds it. Used to give every
    /// widget in a tree its own composited slot instead of sharing one canvas.
    /// Pass `adopting` to target a caller-owned canvas at the new texture
    /// instead of creating one — the canvas instance the caller already
    /// handed out (e.g. to Python) stays the one the node renders.
    // func makeWidgetNode(
    //     wgpu:     WgpuContext,
    //     width:    Int,
    //     height:   Int,
    //     adopting: Tvg_Canvas? = nil
    // ) -> (node: ThorShaderNode, texture: WGPUTexture)? {
    //     guard let texture = wgpu.makeTargetTexture(width: width, height: height) else {
    //         print("VulkanRenderEngine: wgpu target texture creation failed")
    //         return nil
    //     }
    //     guard let mtlTexture = wgpu.nativeMetalTexture(of: texture) else {
    //         print("VulkanRenderEngine: wgpuTextureGetNativeMetalTexture returned null")
    //         return nil
    //     }
    //     guard let canvas = adopting ?? tvg_wgcanvas_create(TVG_ENGINE_OPTION_DEFAULT) else {
    //         print("VulkanRenderEngine: tvg_wgcanvas_create failed")
    //         return nil
    //     }
    //     // Storage (compute post shader) support needs both sides of the
    //     // shared texture to agree: wgpu must have created the MTLTexture
    //     // with shaderWrite, and MoltenVK must expose storage on linear
    //     // BGRA8 images so the import below may carry STORAGE usage.
    //     let storageCapable = wgpu.canvasStorageCapable && supportsLinearBgraStorage()
    //     guard
    //         let node = try? makeThorNode(
    //             canvas: canvas,
    //             importingMetalTexture: mtlTexture,
    //             width: width,
    //             height: height,
    //             storageCapable: storageCapable
    //         )
    //     else {
    //         print("VulkanRenderEngine: makeThorNode(importingMetalTexture:) failed")
    //         return nil
    //     }

    //     let target = tvg_wgcanvas_set_target(
    //         canvas,
    //         UnsafeMutableRawPointer(wgpu.device),
    //         UnsafeMutableRawPointer(wgpu.instance),
    //         UnsafeMutableRawPointer(texture),
    //         UInt32(width),
    //         UInt32(height),
    //         TVG_COLORSPACE_ABGR8888S,
    //         1
    //     )
    //     guard target == TVG_RESULT_SUCCESS else {
    //         print("VulkanRenderEngine: tvg_wgcanvas_set_target failed (\(target))")
    //         return nil
    //     }

    //     // Same fire-and-forget caveat as the root target: wgpuQueueSubmit
    //     // only proves ThorVG's blit was queued, not finished.
    //     node.waitForExternalCompletion = { [wgpu] in
    //         wgpu.waitForGPUCompletion()
    //     }

    //     return (node, texture)
    // }

    /// Create the VkImage a ThorVG canvas renders into and wrap everything
    /// into a `ThorShaderNode`. The image starts in COLOR_ATTACHMENT_OPTIMAL,
    /// matching the layout the engine expects after a canvas draw. The engine
    /// does not own the image — destroy it yourself if you drop the node.
    // func makeThorNode(
    //     canvas:               Tvg_Canvas,
    //     width:                Int,
    //     height:               Int,
    //     computePipeline:      VkPipeline?       = nil,
    //     computeLayout:        VkPipelineLayout? = nil,
    //     computeDescriptorSet: VkDescriptorSet?  = nil
    // ) throws -> ThorShaderNode {
    //     var image: VkImage?
    //     var imageInfo = VkImageCreateInfo()
    //     imageInfo.sType         = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
    //     imageInfo.imageType     = VK_IMAGE_TYPE_2D
    //     imageInfo.format        = VK_FORMAT_R8G8B8A8_UNORM
    //     imageInfo.extent        = VkExtent3D(width: UInt32(width), height: UInt32(height), depth: 1)
    //     imageInfo.mipLevels     = 1
    //     imageInfo.arrayLayers   = 1
    //     imageInfo.samples       = VK_SAMPLE_COUNT_1_BIT
    //     imageInfo.tiling        = VK_IMAGE_TILING_OPTIMAL
    //     imageInfo.usage         = VkImageUsageFlags(
    //         VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue |
    //         VK_IMAGE_USAGE_SAMPLED_BIT.rawValue |
    //         VK_IMAGE_USAGE_STORAGE_BIT.rawValue |
    //         VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue
    //     )
    //     imageInfo.sharingMode   = VK_SHARING_MODE_EXCLUSIVE
    //     imageInfo.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED
    //     guard vkCreateImage(device, &imageInfo, nil, &image) == VK_SUCCESS, let image else {
    //         throw VulkanEngineError.image
    //     }

    //     var requirements = VkMemoryRequirements()
    //     vkGetImageMemoryRequirements(device, image, &requirements)
    //     var memory: VkDeviceMemory?
    //     var allocInfo = VkMemoryAllocateInfo()
    //     allocInfo.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
    //     allocInfo.allocationSize = requirements.size
    //     allocInfo.memoryTypeIndex = findMemoryType(
    //         typeFilter: requirements.memoryTypeBits,
    //         properties: VkMemoryPropertyFlags(VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT.rawValue)
    //     )
    //     guard vkAllocateMemory(device, &allocInfo, nil, &memory) == VK_SUCCESS else {
    //         throw VulkanEngineError.memory
    //     }
    //     vkBindImageMemory(device, image, memory, 0)

    //     var view: VkImageView?
    //     var viewInfo = VkImageViewCreateInfo()
    //     viewInfo.sType    = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
    //     viewInfo.image    = image
    //     viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D
    //     viewInfo.format   = VK_FORMAT_R8G8B8A8_UNORM
    //     viewInfo.subresourceRange = VkImageSubresourceRange(
    //         aspectMask:     VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT.rawValue),
    //         baseMipLevel:   0, levelCount: 1,
    //         baseArrayLayer: 0, layerCount: 1
    //     )
    //     guard vkCreateImageView(device, &viewInfo, nil, &view) == VK_SUCCESS, let view else {
    //         throw VulkanEngineError.image
    //     }

    //     oneTimeSubmit { cmd in
    //         engineImageBarrier(
    //             cmd,
    //             image:     image,
    //             srcLayout: VK_IMAGE_LAYOUT_UNDEFINED,
    //             srcAccess: 0,
    //             srcStage:  VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
    //             dstLayout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    //             dstAccess: VkAccessFlags(VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT.rawValue),
    //             dstStage:  VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
    //         )
    //     }

    //     return ThorShaderNode(
    //         canvas:               ThorVulkanCanvas(base: canvas),
    //         width:                UInt32(width),
    //         height:               UInt32(height),
    //         image:                image,
    //         imageView:            view,
    //         memory:               memory,
    //         storageCapable:       true,
    //         computePipeline:      computePipeline,
    //         computeLayout:        computeLayout,
    //         computeDescriptorSet: computeDescriptorSet
    //     )
    // }

    /// Create a `ThorShaderNode` whose VkImage is *imported* from an
    /// existing `id<MTLTexture>` (via VK_EXT_metal_objects) instead of
    /// freshly allocated. Use this when another API already renders into a
    /// Metal texture and the composite pass should read that exact GPU
    /// memory — no copy, no second allocation.
    ///
    /// `mtlTexture` must be the raw `id<MTLTexture>` pointer (e.g. from
    /// `wgpuTextureGetNativeMetalTexture`), format BGRA8Unorm, matching
    /// `width`/`height` exactly. `VkImportMetalTextureInfoEXT` has an
    /// Objective-C field (`mtlTexture`) that doesn't import into this
    /// plain-C Swift target, so its 32-byte layout — identical in shape to
    /// `VkMetalSurfaceCreateInfoEXT` above — is laid out by hand:
    /// sType@0, pNext@8, plane@16, mtlTexture@24.
    // func makeThorNode(
    //     canvas:               Tvg_Canvas,
    //     importingMetalTexture mtlTexture: UnsafeMutableRawPointer,
    //     width:                Int,
    //     height:               Int,
    //     storageCapable:       Bool              = false,
    //     computePipeline:      VkPipeline?       = nil,
    //     computeLayout:        VkPipelineLayout? = nil,
    //     computeDescriptorSet: VkDescriptorSet?  = nil
    // ) throws -> ThorShaderNode {
    //     // VkImportMetalTextureInfoEXT, hand-laid: sType@0 pNext@8 plane@16 mtlTexture@24 (32 bytes).
    //     // Built first and chained onto BOTH the image creation and the
    //     // memory allocation — the struct name suggests it's the image
    //     // itself that should directly wrap the Metal texture, not just the
    //     // backing memory, and chaining it in both places costs nothing.
    //     let importInfo = UnsafeMutableRawPointer.allocate(byteCount: 32, alignment: MemoryLayout<UInt>.alignment)
    //     defer { importInfo.deallocate() }
    //     importInfo.initializeMemory(as: UInt8.self, repeating: 0, count: 32)
    //     importInfo.storeBytes(
    //         of: VK_STRUCTURE_TYPE_IMPORT_METAL_TEXTURE_INFO_EXT.rawValue,
    //         toByteOffset: 0,
    //         as: UInt32.self
    //     )
    //     importInfo.storeBytes(
    //         of: VK_IMAGE_ASPECT_COLOR_BIT.rawValue,
    //         toByteOffset: 16,
    //         as: UInt32.self
    //     )
    //     importInfo.storeBytes(
    //         of: UInt(bitPattern: mtlTexture),
    //         toByteOffset: 24,
    //         as: UInt.self
    //     )

    //     var externalMemoryInfo = VkExternalMemoryImageCreateInfo()
    //     externalMemoryInfo.sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO
    //     externalMemoryInfo.pNext = UnsafeRawPointer(importInfo)
    //     externalMemoryInfo.handleTypes = VkExternalMemoryHandleTypeFlags(
    //         VK_EXTERNAL_MEMORY_HANDLE_TYPE_MTLTEXTURE_BIT_EXT.rawValue
    //     )

    //     var image: VkImage?
    //     let imageResult: VkResult = withUnsafePointer(to: &externalMemoryInfo) { extPtr in
    //         var imageInfo = VkImageCreateInfo()
    //         imageInfo.sType         = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
    //         imageInfo.pNext         = UnsafeRawPointer(extPtr)
    //         imageInfo.imageType     = VK_IMAGE_TYPE_2D
    //         imageInfo.format        = VK_FORMAT_B8G8R8A8_UNORM
    //         imageInfo.extent        = VkExtent3D(width: UInt32(width), height: UInt32(height), depth: 1)
    //         imageInfo.mipLevels     = 1
    //         imageInfo.arrayLayers   = 1
    //         imageInfo.samples       = VK_SAMPLE_COUNT_1_BIT
    //         // LINEAR: an explicit, unambiguous byte layout both APIs agree
    //         // on. OPTIMAL is an implementation-defined tiled layout that
    //         // MoltenVK normally owns and knows how to detile — for an
    //         // *imported* Metal texture it doesn't own that layout, and
    //         // detiling it wrong would explain reading back only scattered,
    //         // low-alpha antialiasing-fringe pixels instead of the shape's
    //         // actual opaque interior.
    //         imageInfo.tiling        = VK_IMAGE_TILING_LINEAR
    //         var usage = VkImageUsageFlags(
    //             VK_IMAGE_USAGE_SAMPLED_BIT.rawValue |
    //             VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue |
    //             VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue
    //         )
    //         if storageCapable {
    //             // Lets a canvas post shader bind this image as its compute
    //             // storage output. Only requested when the underlying
    //             // MTLTexture actually has shaderWrite (see makeWidgetNode).
    //             usage |= VkImageUsageFlags(VK_IMAGE_USAGE_STORAGE_BIT.rawValue)
    //         }
    //         imageInfo.usage         = usage
    //         imageInfo.sharingMode   = VK_SHARING_MODE_EXCLUSIVE
    //         imageInfo.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED
    //         return vkCreateImage(device, &imageInfo, nil, &image)
    //     }
    //     guard imageResult == VK_SUCCESS, let image else {
    //         throw VulkanEngineError.image
    //     }

    //     var requirements = VkMemoryRequirements()
    //     vkGetImageMemoryRequirements(device, image, &requirements)

    //     var memory: VkDeviceMemory?
    //     var allocInfo = VkMemoryAllocateInfo()
    //     allocInfo.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
    //     allocInfo.pNext = UnsafeRawPointer(importInfo)
    //     allocInfo.allocationSize = requirements.size
    //     allocInfo.memoryTypeIndex = findMemoryType(
    //         typeFilter: requirements.memoryTypeBits,
    //         properties: VkMemoryPropertyFlags(VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT.rawValue)
    //     )
    //     guard vkAllocateMemory(device, &allocInfo, nil, &memory) == VK_SUCCESS else {
    //         throw VulkanEngineError.memory
    //     }
    //     vkBindImageMemory(device, image, memory, 0)

    //     var view: VkImageView?
    //     var viewInfo = VkImageViewCreateInfo()
    //     viewInfo.sType    = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
    //     viewInfo.image    = image
    //     viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D
    //     viewInfo.format   = VK_FORMAT_B8G8R8A8_UNORM
    //     viewInfo.subresourceRange = VkImageSubresourceRange(
    //         aspectMask:     VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT.rawValue),
    //         baseMipLevel:   0, levelCount: 1,
    //         baseArrayLayer: 0, layerCount: 1
    //     )
    //     guard vkCreateImageView(device, &viewInfo, nil, &view) == VK_SUCCESS, let view else {
    //         throw VulkanEngineError.image
    //     }

    //     // Content already lives in the imported texture (or will, once
    //     // ThorVG draws) — transition to GENERAL, never UNDEFINED, so the
    //     // driver isn't told it may discard it.
    //     oneTimeSubmit { cmd in
    //         engineImageBarrier(
    //             cmd,
    //             image:     image,
    //             srcLayout: VK_IMAGE_LAYOUT_UNDEFINED,
    //             srcAccess: 0,
    //             srcStage:  VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
    //             dstLayout: VK_IMAGE_LAYOUT_GENERAL,
    //             dstAccess: VkAccessFlags(VK_ACCESS_MEMORY_WRITE_BIT.rawValue) | VkAccessFlags(VK_ACCESS_MEMORY_READ_BIT.rawValue),
    //             dstStage:  VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT
    //         )
    //     }

    //     return ThorShaderNode(
    //         canvas:               ThorVulkanCanvas(base: canvas),
    //         width:                UInt32(width),
    //         height:               UInt32(height),
    //         image:                image,
    //         imageView:            view,
    //         memory:               memory,
    //         isExternallyBacked:   true,
    //         storageCapable:       storageCapable,
    //         computePipeline:      computePipeline,
    //         computeLayout:        computeLayout,
    //         computeDescriptorSet: computeDescriptorSet
    //     )
    // }

    /// Create a CPU-fed upload node: an engine-owned RGBA8 image (TRANSFER_DST
    /// + SAMPLED + STORAGE) and a persistently-mapped host-visible staging
    /// buffer with one slice per frame-in-flight. The image starts UNDEFINED —
    /// the node's first upload overwrites every texel, and until that first
    /// `write` the engine keeps it out of the composite entirely. The engine
    /// does not own the resources — `destroyResources(of:)` when dropping it.
    ///
    /// `scale` > 1 sizes the node's image at width/height × scale while the
    /// producer keeps writing source-sized frames: the upload lands in an
    /// intermediate source-sized image first and a nearest `vkCmdBlitImage`
    /// stretches it up — so a post shader (e.g. a pixel-art AA upscaler)
    /// gets real subpixels without the producer replicating a single pixel.
    /// At scale 1 no intermediate image exists and the path is exactly the
    /// old direct copy.
    // public func makePixelBufferNode(width: Int, height: Int, scale: Int = 1) throws -> PixelBufferShaderNode {
    //     let scale = max(scale, 1)
    //     var image: VkImage?
    //     var imageInfo = VkImageCreateInfo()
    //     imageInfo.sType         = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
    //     imageInfo.imageType     = VK_IMAGE_TYPE_2D
    //     imageInfo.format        = VK_FORMAT_R8G8B8A8_UNORM
    //     imageInfo.extent        = VkExtent3D(width: UInt32(width * scale), height: UInt32(height * scale), depth: 1)
    //     imageInfo.mipLevels     = 1
    //     imageInfo.arrayLayers   = 1
    //     imageInfo.samples       = VK_SAMPLE_COUNT_1_BIT
    //     imageInfo.tiling        = VK_IMAGE_TILING_OPTIMAL
    //     imageInfo.usage         = VkImageUsageFlags(
    //         VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue |
    //         VK_IMAGE_USAGE_SAMPLED_BIT.rawValue |
    //         VK_IMAGE_USAGE_STORAGE_BIT.rawValue
    //     )
    //     imageInfo.sharingMode   = VK_SHARING_MODE_EXCLUSIVE
    //     imageInfo.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED
    //     guard vkCreateImage(device, &imageInfo, nil, &image) == VK_SUCCESS, let image else {
    //         throw VulkanEngineError.image
    //     }

    //     var requirements = VkMemoryRequirements()
    //     vkGetImageMemoryRequirements(device, image, &requirements)
    //     var memory: VkDeviceMemory?
    //     var allocInfo = VkMemoryAllocateInfo()
    //     allocInfo.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
    //     allocInfo.allocationSize = requirements.size
    //     allocInfo.memoryTypeIndex = findMemoryType(
    //         typeFilter: requirements.memoryTypeBits,
    //         properties: VkMemoryPropertyFlags(VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT.rawValue)
    //     )
    //     guard vkAllocateMemory(device, &allocInfo, nil, &memory) == VK_SUCCESS else {
    //         throw VulkanEngineError.memory
    //     }
    //     vkBindImageMemory(device, image, memory, 0)

    //     // The blit source at source resolution — only needed when scaling.
    //     // TRANSFER_DST (staging copy in) + TRANSFER_SRC (blit out); no view,
    //     // nothing ever samples it directly.
    //     var uploadImage:  VkImage?
    //     var uploadMemory: VkDeviceMemory?
    //     if scale > 1 {
    //         var upInfo = imageInfo
    //         upInfo.extent = VkExtent3D(width: UInt32(width), height: UInt32(height), depth: 1)
    //         upInfo.usage  = VkImageUsageFlags(
    //             VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue |
    //             VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue
    //         )
    //         guard vkCreateImage(device, &upInfo, nil, &uploadImage) == VK_SUCCESS,
    //               let created = uploadImage else {
    //             throw VulkanEngineError.image
    //         }
    //         var upRequirements = VkMemoryRequirements()
    //         vkGetImageMemoryRequirements(device, created, &upRequirements)
    //         var upAlloc = VkMemoryAllocateInfo()
    //         upAlloc.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
    //         upAlloc.allocationSize = upRequirements.size
    //         upAlloc.memoryTypeIndex = findMemoryType(
    //             typeFilter: upRequirements.memoryTypeBits,
    //             properties: VkMemoryPropertyFlags(VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT.rawValue)
    //         )
    //         guard vkAllocateMemory(device, &upAlloc, nil, &uploadMemory) == VK_SUCCESS else {
    //             throw VulkanEngineError.memory
    //         }
    //         vkBindImageMemory(device, created, uploadMemory, 0)
    //     }

    //     var view: VkImageView?
    //     var viewInfo = VkImageViewCreateInfo()
    //     viewInfo.sType    = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
    //     viewInfo.image    = image
    //     viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D
    //     viewInfo.format   = VK_FORMAT_R8G8B8A8_UNORM
    //     viewInfo.subresourceRange = VkImageSubresourceRange(
    //         aspectMask:     VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT.rawValue),
    //         baseMipLevel:   0, levelCount: 1,
    //         baseArrayLayer: 0, layerCount: 1
    //     )
    //     guard vkCreateImageView(device, &viewInfo, nil, &view) == VK_SUCCESS, let view else {
    //         throw VulkanEngineError.image
    //     }

    //     // Staging: one buffer holding `imageCount` frame slices, HOST_VISIBLE
    //     // + HOST_COHERENT (no flush bookkeeping), mapped for the node's whole
    //     // lifetime.
    //     let bytesPerFrame = width * height * 4
    //     let stagingSize   = VkDeviceSize(bytesPerFrame * imageCount)
    //     var stagingBuffer: VkBuffer?
    //     var bufferInfo = VkBufferCreateInfo()
    //     bufferInfo.sType       = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
    //     bufferInfo.size        = stagingSize
    //     bufferInfo.usage       = VkBufferUsageFlags(VK_BUFFER_USAGE_TRANSFER_SRC_BIT.rawValue)
    //     bufferInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE
    //     guard vkCreateBuffer(device, &bufferInfo, nil, &stagingBuffer) == VK_SUCCESS,
    //           let stagingBuffer else {
    //         throw VulkanEngineError.image
    //     }

    //     var stagingRequirements = VkMemoryRequirements()
    //     vkGetBufferMemoryRequirements(device, stagingBuffer, &stagingRequirements)
    //     var stagingMemory: VkDeviceMemory?
    //     var stagingAlloc = VkMemoryAllocateInfo()
    //     stagingAlloc.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
    //     stagingAlloc.allocationSize = stagingRequirements.size
    //     stagingAlloc.memoryTypeIndex = findMemoryType(
    //         typeFilter: stagingRequirements.memoryTypeBits,
    //         properties: VkMemoryPropertyFlags(
    //             VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT.rawValue |
    //             VK_MEMORY_PROPERTY_HOST_COHERENT_BIT.rawValue
    //         )
    //     )
    //     guard vkAllocateMemory(device, &stagingAlloc, nil, &stagingMemory) == VK_SUCCESS,
    //           let stagingMemory else {
    //         throw VulkanEngineError.memory
    //     }
    //     vkBindBufferMemory(device, stagingBuffer, stagingMemory, 0)

    //     var mapped: UnsafeMutableRawPointer?
    //     guard vkMapMemory(device, stagingMemory, 0, stagingSize, 0, &mapped) == VK_SUCCESS,
    //           let mapped else {
    //         throw VulkanEngineError.memory
    //     }

    //     return PixelBufferShaderNode(
    //         sourceWidth:    UInt32(width),
    //         sourceHeight:   UInt32(height),
    //         scale:          UInt32(scale),
    //         image:          image,
    //         imageView:      view,
    //         memory:         memory,
    //         uploadImage:    uploadImage,
    //         uploadMemory:   uploadMemory,
    //         stagingBuffer:  stagingBuffer,
    //         stagingMemory:  stagingMemory,
    //         stagingPointer: mapped,
    //         sliceCount:     imageCount
    //     )
    // }

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

    /// Record + submit a transient command buffer and block until done.
    public func oneTimeSubmit(_ body: (VkCommandBuffer) -> Void) {
        var cmd: VkCommandBuffer?
        var allocInfo = VkCommandBufferAllocateInfo()
        allocInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
        allocInfo.commandPool = commandPool
        allocInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY
        allocInfo.commandBufferCount = 1
        vkAllocateCommandBuffers(device, &allocInfo, &cmd)
        guard let cmd else { return }

        var begin = VkCommandBufferBeginInfo()
        begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
        begin.flags = VkCommandBufferUsageFlags(VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT.rawValue)
        vkBeginCommandBuffer(cmd, &begin)
        body(cmd)
        vkEndCommandBuffer(cmd)

        var cmdOpt: VkCommandBuffer? = cmd
        withUnsafePointer(to: &cmdOpt) { cmdPtr in
            var submitInfo = VkSubmitInfo()
            submitInfo.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO
            submitInfo.commandBufferCount = 1
            submitInfo.pCommandBuffers = cmdPtr
            vkQueueSubmit(graphicsQueue, 1, &submitInfo, nil)
        }
        vkQueueWaitIdle(graphicsQueue)
        vkFreeCommandBuffers(device, commandPool, 1, &cmdOpt)
    }
}


// MARK: - File-private helpers

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
private func withCStringArray<R>(
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

private func enumerateInstanceExtensions() -> Set<String> {
    var count: UInt32 = 0
    vkEnumerateInstanceExtensionProperties(nil, &count, nil)
    guard count > 0 else { return [] }
    var props = [VkExtensionProperties](repeating: VkExtensionProperties(), count: Int(count))
    vkEnumerateInstanceExtensionProperties(nil, &count, &props)
    return Set(props.map(extensionName))
}

private func enumerateDeviceExtensions(_ gpu: VkPhysicalDevice) -> Set<String> {
    var count: UInt32 = 0
    vkEnumerateDeviceExtensionProperties(gpu, nil, &count, nil)
    guard count > 0 else { return [] }
    var props = [VkExtensionProperties](repeating: VkExtensionProperties(), count: Int(count))
    vkEnumerateDeviceExtensionProperties(gpu, nil, &count, &props)
    return Set(props.map(extensionName))
}

private func extensionName(_ prop: VkExtensionProperties) -> String {
    var name = prop.extensionName
    return withUnsafeBytes(of: &name) { raw in
        String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
    }
}

private func makeEngineDescriptorPool(device: VkDevice, maxSets: Int) throws -> VkDescriptorPool {
    let n = UInt32(maxSets)
    let sizes = [
        VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, descriptorCount: n),
        VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,          descriptorCount: n),
        VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,         descriptorCount: n),
        VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,         descriptorCount: n),
    ]
    var pool: VkDescriptorPool?
    let result = sizes.withUnsafeBufferPointer { buf -> VkResult in
        var info = VkDescriptorPoolCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
        info.flags = VkDescriptorPoolCreateFlags(VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT.rawValue)
        info.maxSets = UInt32(maxSets)
        info.poolSizeCount = UInt32(buf.count)
        info.pPoolSizes = buf.baseAddress
        return vkCreateDescriptorPool(device, &info, nil, &pool)
    }
    guard result == VK_SUCCESS, let pool else { throw VulkanEngineError.descriptorPool }
    return pool
}
