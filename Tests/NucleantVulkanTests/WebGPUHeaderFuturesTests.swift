//
//  WebGPUHeaderFuturesTests.swift
//  NucleantVulkanTests
//
//  The rest of webgpu.h on the browser's WebGPU (CWgpu on wasm) — what a
//  renderer like Skia's Graphite leans on beyond drawing: mapped buffers
//  (written in wasm memory and sent through the queue; read once the page's
//  mapping lands), futures waited on with wgpuInstanceWaitAny, compute
//  passes, buffer/texture copies, queries, error scopes, shader compilation
//  messages, limits and adapter info. Run with scripts/run_wasm_tests.py
//  (headless Chrome, which has JSPI, so waits with a timeout block).
//
#if os(WASI)
import Testing
import CWgpu
@testable import NucleantVulkan

@Suite(.serialized)
struct WebGPUHeaderFuturesTests {

    // MARK: Mapping

    @Test func mappedAtCreationContentsReachTheGPU() throws {
        let gpu = try GPU()
        let source = try #require(gpu.buffer(size: 16, usage: WGPUBufferUsage_CopySrc, mappedAtCreation: true))
        defer { gpu.drop(source) }
        #expect(wgpuBufferGetMapState(source) == WGPUBufferMapState_Mapped)
        let range = try #require(wgpuBufferGetMappedRange(source, 0, 16))
        for i in 0..<4 { range.storeBytes(of: UInt32(i * 10 + 1), toByteOffset: i * 4, as: UInt32.self) }
        wgpuBufferUnmap(source)
        #expect(wgpuBufferGetMapState(source) == WGPUBufferMapState_Unmapped)
        // It reports what was asked for, whatever the page made it.
        #expect(wgpuBufferGetUsage(source) == WGPUBufferUsage_CopySrc)
        #expect(wgpuBufferGetSize(source) == 16)

        #expect(words(try gpu.read(source, size: 16)) == [1, 11, 21, 31])
    }

    @Test func writeMappingCompletesInTheFirstWait() throws {
        let gpu = try GPU()
        let size = 256
        let staging = try #require(gpu.buffer(size: size, usage: WGPUBufferUsage_MapWrite | WGPUBufferUsage_CopySrc))
        defer { gpu.drop(staging) }
        #expect(wgpuBufferGetMapState(staging) == WGPUBufferMapState_Unmapped)

        // Twice: a renderer maps the same upload buffer again once the GPU
        // is done with it.
        for round in 0..<2 {
            let outcome = Outcome()
            let future = wgpuBufferMapAsync(staging, WGPUMapMode_Write, 0, size, outcome.mapCallback(mode: WGPUCallbackMode_WaitAnyOnly))
            // WaitAnyOnly: nothing runs before the wait.
            #expect(outcome.count == 0)
            var wait = WGPUFutureWaitInfo(future: future, completed: 0)
            #expect(wgpuInstanceWaitAny(gpu.instance, 1, &wait, 0) == WGPUWaitStatus_Success)
            #expect(wait.completed != 0)
            #expect(outcome.count == 1)
            #expect(outcome.status == WGPUMapAsyncStatus_Success.rawValue)
            #expect(wgpuBufferGetMapState(staging) == WGPUBufferMapState_Mapped)
            let range = try #require(wgpuBufferGetMappedRange(staging, 0, size))
            for i in 0..<size / 4 { range.storeBytes(of: UInt32(i + round * 1000), toByteOffset: i * 4, as: UInt32.self) }
            wgpuBufferUnmap(staging)
            let read = words(try gpu.read(staging, size: size))
            #expect(read[0] == UInt32(round * 1000))
            #expect(read[63] == UInt32(63 + round * 1000))
        }
    }

    @Test func readMappingOfABufferNotMappableFails() throws {
        let gpu = try GPU()
        let buffer = try #require(gpu.buffer(size: 16, usage: WGPUBufferUsage_CopySrc))
        defer { gpu.drop(buffer) }
        let outcome = Outcome()
        try gpu.expectingError(WGPUErrorType_Validation) {
            let future = wgpuBufferMapAsync(buffer, WGPUMapMode_Read, 0, 16, outcome.mapCallback(mode: WGPUCallbackMode_WaitAnyOnly))
            var wait = WGPUFutureWaitInfo(future: future, completed: 0)
            #expect(wgpuInstanceWaitAny(gpu.instance, 1, &wait, UInt64.max) == WGPUWaitStatus_Success)
        }
        #expect(outcome.count == 1)
        #expect(outcome.status != WGPUMapAsyncStatus_Success.rawValue)
        #expect(wgpuBufferGetMapState(buffer) == WGPUBufferMapState_Unmapped)
        #expect(wgpuBufferGetConstMappedRange(buffer, 0, 16) == nil)
    }

    // MARK: Copies between buffers and textures

    @Test func bufferToTextureAndBack() throws {
        let gpu = try GPU()
        // 4×2 RGBA8; a copy's rows are 256-byte aligned.
        var descriptor = WGPUTextureDescriptor()
        descriptor.usage = WGPUTextureUsage_CopyDst | WGPUTextureUsage_CopySrc
        descriptor.dimension = WGPUTextureDimension_2D
        descriptor.size = WGPUExtent3D(width: 4, height: 2, depthOrArrayLayers: 1)
        descriptor.format = WGPUTextureFormat_RGBA8Unorm
        descriptor.mipLevelCount = 1
        descriptor.sampleCount = 1
        let texture = try #require(wgpuDeviceCreateTexture(gpu.device, &descriptor))
        defer { wgpuTextureRelease(texture) }

        let upload = try #require(gpu.buffer(size: 512, usage: WGPUBufferUsage_CopySrc, mappedAtCreation: true))
        defer { gpu.drop(upload) }
        let range = try #require(wgpuBufferGetMappedRange(upload, 0, 512))
        for row in 0..<2 {
            for x in 0..<4 {
                range.storeBytes(of: UInt32(0xFF00_0000) | UInt32(row * 16 + x), toByteOffset: row * 256 + x * 4, as: UInt32.self)
            }
        }
        wgpuBufferUnmap(upload)

        let readback = try #require(gpu.buffer(size: 512, usage: WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst))
        defer { gpu.drop(readback) }
        try gpu.submit { encoder in
            var buffer = WGPUTexelCopyBufferInfo()
            buffer.layout = WGPUTexelCopyBufferLayout(offset: 0, bytesPerRow: 256, rowsPerImage: 2)
            var image = WGPUTexelCopyTextureInfo()
            image.texture = texture
            image.aspect = WGPUTextureAspect_All
            var size = WGPUExtent3D(width: 4, height: 2, depthOrArrayLayers: 1)
            buffer.buffer = upload
            wgpuCommandEncoderCopyBufferToTexture(encoder, &buffer, &image, &size)
            buffer.buffer = readback
            wgpuCommandEncoderCopyTextureToBuffer(encoder, &image, &buffer, &size)
        }
        try gpu.map(readback, mode: WGPUMapMode_Read, size: 512)
        let mapped = try #require(wgpuBufferGetConstMappedRange(readback, 0, 512))
        #expect(mapped.load(fromByteOffset: 0, as: UInt32.self) == 0xFF00_0000)
        #expect(mapped.load(fromByteOffset: 256 + 3 * 4, as: UInt32.self) == 0xFF00_0013)
        // A read mapping hands out no writable range.
        #expect(wgpuBufferGetMappedRange(readback, 0, 512) == nil)
        wgpuBufferUnmap(readback)
    }

    // MARK: Compute

    @Test func computePassDirectAndIndirectDispatch() throws {
        let gpu = try GPU()
        let module = try #require(gpu.shader("""
        @group(0) @binding(0) var<storage, read_write> data: array<u32>;
        @compute @workgroup_size(8) fn main(@builtin(global_invocation_id) id: vec3u) {
            data[id.x] = data[id.x] + id.x + 1u;
        }
        """))
        defer { wgpuShaderModuleRelease(module) }

        var entry = WGPUBindGroupLayoutEntry()
        entry.binding = 0
        entry.visibility = WGPUShaderStage_Compute
        entry.buffer.type = WGPUBufferBindingType_Storage
        var layoutDescriptor = WGPUBindGroupLayoutDescriptor()
        layoutDescriptor.entryCount = 1
        let groupLayout = try #require(withUnsafePointer(to: &entry) { entryPtr in
            layoutDescriptor.entries = entryPtr
            return wgpuDeviceCreateBindGroupLayout(gpu.device, &layoutDescriptor)
        })
        defer { wgpuBindGroupLayoutRelease(groupLayout) }
        var groupLayoutRef: WGPUBindGroupLayout? = groupLayout
        let pipelineLayout = try #require(withUnsafePointer(to: &groupLayoutRef) { layouts in
            var descriptor = WGPUPipelineLayoutDescriptor()
            descriptor.bindGroupLayoutCount = 1
            descriptor.bindGroupLayouts = layouts
            return wgpuDeviceCreatePipelineLayout(gpu.device, &descriptor)
        })
        defer { wgpuPipelineLayoutRelease(pipelineLayout) }
        var pipelineDescriptor = WGPUComputePipelineDescriptor()
        pipelineDescriptor.layout = pipelineLayout
        pipelineDescriptor.compute.module = module
        pipelineDescriptor.compute.entryPoint = view("main")
        let pipeline = try #require(wgpuDeviceCreateComputePipeline(gpu.device, &pipelineDescriptor))
        defer { wgpuComputePipelineRelease(pipeline) }

        let data = try #require(gpu.buffer(size: 32, usage: WGPUBufferUsage_Storage | WGPUBufferUsage_CopySrc | WGPUBufferUsage_CopyDst))
        defer { gpu.drop(data) }
        // Junk first, so the clear is what zeroes it.
        let junk = [UInt32](repeating: 0xDEAD, count: 8)
        junk.withUnsafeBytes { wgpuQueueWriteBuffer(gpu.queue, data, 0, $0.baseAddress, 32) }
        let indirect = try #require(gpu.buffer(size: 12, usage: WGPUBufferUsage_Indirect, mappedAtCreation: true))
        defer { gpu.drop(indirect) }
        let counts = try #require(wgpuBufferGetMappedRange(indirect, 0, 12))
        for i in 0..<3 { counts.storeBytes(of: UInt32(1), toByteOffset: i * 4, as: UInt32.self) }
        wgpuBufferUnmap(indirect)

        var groupEntry = WGPUBindGroupEntry()
        groupEntry.binding = 0
        groupEntry.buffer = data
        groupEntry.size = 32
        let group = try #require(withUnsafePointer(to: &groupEntry) { entryPtr in
            var descriptor = WGPUBindGroupDescriptor()
            descriptor.layout = groupLayout
            descriptor.entryCount = 1
            descriptor.entries = entryPtr
            return wgpuDeviceCreateBindGroup(gpu.device, &descriptor)
        })
        defer { wgpuBindGroupRelease(group) }

        try gpu.submit { encoder in
            wgpuCommandEncoderClearBuffer(encoder, data, 0, UInt64.max)
            let pass = wgpuCommandEncoderBeginComputePass(encoder, nil)
            wgpuComputePassEncoderSetPipeline(pass, pipeline)
            wgpuComputePassEncoderSetBindGroup(pass, 0, group, 0, nil)
            wgpuComputePassEncoderDispatchWorkgroups(pass, 1, 1, 1)
            wgpuComputePassEncoderDispatchWorkgroupsIndirect(pass, indirect, 0)
            wgpuComputePassEncoderEnd(pass)
            wgpuComputePassEncoderRelease(pass)
        }
        #expect(words(try gpu.read(data, size: 32)) == (0..<8).map { UInt32(2 * ($0 + 1)) })
    }

    // MARK: Futures

    @Test func submittedWorkDoneSettlesInAWait() throws {
        let gpu = try GPU()
        try gpu.submit { _ in }
        let outcome = Outcome()
        var info = WGPUQueueWorkDoneCallbackInfo()
        info.mode = WGPUCallbackMode_WaitAnyOnly
        info.callback = { status, _, userdata, _ in Outcome.from(userdata).record(status.rawValue) }
        info.userdata1 = outcome.pointer
        var wait = WGPUFutureWaitInfo(future: wgpuQueueOnSubmittedWorkDone(gpu.queue, info), completed: 0)
        #expect(wgpuInstanceWaitAny(gpu.instance, 1, &wait, UInt64.max) == WGPUWaitStatus_Success)
        #expect(outcome.status == WGPUQueueWorkDoneStatus_Success.rawValue)
        // Waiting again on a future that has run is done at once.
        #expect(wgpuInstanceWaitAny(gpu.instance, 1, &wait, 0) == WGPUWaitStatus_Success)
        #expect(outcome.count == 1)
    }

    @Test func processEventsRunsAllowProcessEventsCallbacks() throws {
        let gpu = try GPU()
        let buffer = try #require(gpu.buffer(size: 16, usage: WGPUBufferUsage_MapWrite | WGPUBufferUsage_CopySrc))
        defer { gpu.drop(buffer) }
        let outcome = Outcome()
        _ = wgpuBufferMapAsync(buffer, WGPUMapMode_Write, 0, 16, outcome.mapCallback(mode: WGPUCallbackMode_AllowProcessEvents))
        #expect(outcome.count == 0)
        wgpuInstanceProcessEvents(gpu.instance)
        #expect(outcome.count == 1)
        wgpuBufferUnmap(buffer)

        // AllowSpontaneous: run as soon as it is settled — here, at once.
        let spontaneous = Outcome()
        _ = wgpuBufferMapAsync(buffer, WGPUMapMode_Write, 0, 16, spontaneous.mapCallback(mode: WGPUCallbackMode_AllowSpontaneous))
        #expect(spontaneous.count == 1)
        wgpuBufferUnmap(buffer)
    }

    // MARK: Errors and shader messages

    @Test func errorScopesReportWhatHappenedInThem() throws {
        let gpu = try GPU()
        try gpu.expectingError(WGPUErrorType_NoError) {
            let buffer = gpu.buffer(size: 16, usage: WGPUBufferUsage_CopyDst)
            gpu.drop(buffer)
        }
        try gpu.expectingError(WGPUErrorType_Validation) {
            // MapRead goes with CopyDst only.
            let buffer = gpu.buffer(size: 16, usage: WGPUBufferUsage_MapRead | WGPUBufferUsage_Storage)
            gpu.drop(buffer)
        }
    }

    @Test func compilationInfoListsTheShadersErrors() throws {
        let gpu = try GPU()
        var module: WGPUShaderModule?
        try gpu.expectingError(WGPUErrorType_Validation) {
            module = gpu.shader("@compute @workgroup_size(1) fn main() {\n    let x: u32 = undefined_name;\n}\n")
        }
        let shader = try #require(module)
        defer { wgpuShaderModuleRelease(shader) }
        let outcome = Outcome()
        var info = WGPUCompilationInfoCallbackInfo()
        info.mode = WGPUCallbackMode_WaitAnyOnly
        info.callback = { status, info, userdata, _ in
            let outcome = Outcome.from(userdata)
            outcome.record(status.rawValue)
            guard let info else { return }
            for i in 0..<info.pointee.messageCount {
                let message = info.pointee.messages[i]
                outcome.messages.append((message.type.rawValue, message.lineNum, string(message.message)))
            }
        }
        info.userdata1 = outcome.pointer
        var wait = WGPUFutureWaitInfo(future: wgpuShaderModuleGetCompilationInfo(shader, info), completed: 0)
        #expect(wgpuInstanceWaitAny(gpu.instance, 1, &wait, UInt64.max) == WGPUWaitStatus_Success)
        #expect(outcome.status == WGPUCompilationInfoRequestStatus_Success.rawValue)
        let error = try #require(outcome.messages.first { $0.type == WGPUCompilationMessageType_Error.rawValue })
        #expect(error.line == 2)
        #expect(error.text.contains("undefined_name"))
    }

    // MARK: Pipelines and queries

    @Test func renderPipelineAsyncAndItsBindGroupLayout() throws {
        let gpu = try GPU()
        let module = try #require(gpu.shader("""
        @group(0) @binding(0) var<uniform> tint: vec4f;
        @vertex fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
            return vec4f(f32(i & 1u), f32(i >> 1u), 0.0, 1.0);
        }
        @fragment fn fs() -> @location(0) vec4f { return tint; }
        """))
        defer { wgpuShaderModuleRelease(module) }
        let outcome = Outcome()
        var target = WGPUColorTargetState()
        target.format = WGPUTextureFormat_RGBA8Unorm
        target.writeMask = WGPUColorWriteMask_All
        withUnsafePointer(to: &target) { targetPtr in
            var fragment = WGPUFragmentState()
            fragment.module = module
            fragment.entryPoint = view("fs")
            fragment.targetCount = 1
            fragment.targets = targetPtr
            withUnsafePointer(to: &fragment) { fragmentPtr in
                var descriptor = WGPURenderPipelineDescriptor()
                descriptor.vertex.module = module
                descriptor.vertex.entryPoint = view("vs")
                descriptor.primitive.topology = WGPUPrimitiveTopology_TriangleList
                descriptor.primitive.frontFace = WGPUFrontFace_CCW
                descriptor.primitive.cullMode = WGPUCullMode_None
                descriptor.multisample.count = 1
                descriptor.multisample.mask = UInt32.max
                descriptor.fragment = fragmentPtr
                var info = WGPUCreateRenderPipelineAsyncCallbackInfo()
                info.mode = WGPUCallbackMode_AllowSpontaneous
                info.callback = { status, pipeline, _, userdata, _ in
                    let outcome = Outcome.from(userdata)
                    outcome.record(status.rawValue)
                    outcome.pipeline = pipeline
                }
                info.userdata1 = outcome.pointer
                _ = wgpuDeviceCreateRenderPipelineAsync(gpu.device, &descriptor, info)
            }
        }
        #expect(outcome.status == WGPUCreatePipelineAsyncStatus_Success.rawValue)
        let pipeline = try #require(outcome.pipeline)
        defer { wgpuRenderPipelineRelease(pipeline) }
        let layout = try #require(wgpuRenderPipelineGetBindGroupLayout(pipeline, 0))
        wgpuBindGroupLayoutRelease(layout)
    }

    @Test func unwrittenQueriesResolveToZero() throws {
        let gpu = try GPU()
        var descriptor = WGPUQuerySetDescriptor()
        descriptor.type = WGPUQueryType_Occlusion
        descriptor.count = 2
        let queries = try #require(wgpuDeviceCreateQuerySet(gpu.device, &descriptor))
        defer { wgpuQuerySetRelease(queries) }
        let resolved = try #require(gpu.buffer(size: 256, usage: WGPUBufferUsage_QueryResolve | WGPUBufferUsage_CopySrc | WGPUBufferUsage_CopyDst))
        defer { gpu.drop(resolved) }
        let ones = [UInt32](repeating: 1, count: 4)
        ones.withUnsafeBytes { wgpuQueueWriteBuffer(gpu.queue, resolved, 0, $0.baseAddress, 16) }
        try gpu.submit { encoder in wgpuCommandEncoderResolveQuerySet(encoder, queries, 0, 2, resolved, 0) }
        #expect(words(try gpu.read(resolved, size: 16)) == [0, 0, 0, 0])
    }

    // MARK: The page's adapter and device

    @Test func limitsAndAdapterInfoAreThePages() throws {
        let gpu = try GPU()
        var limits = WGPULimits()
        #expect(wgpuDeviceGetLimits(gpu.device, &limits) == WGPUStatus_Success)
        // WebGPU's guaranteed minimums.
        #expect(limits.maxTextureDimension2D >= 8192)
        #expect(limits.maxBindGroups >= 4)
        #expect(limits.minUniformBufferOffsetAlignment > 0 && limits.minUniformBufferOffsetAlignment <= 256)
        #expect(limits.maxUniformBufferBindingSize >= 65536)
        #expect(limits.maxBufferSize >= 268_435_456)
        // Not provided here, so not offered, whatever the browser has.
        #expect(limits.maxImmediateSize == 0)
        var adapterLimits = WGPULimits()
        #expect(wgpuAdapterGetLimits(gpu.adapter, &adapterLimits) == WGPUStatus_Success)
        #expect(adapterLimits.maxTextureDimension2D >= limits.maxTextureDimension2D)

        var info = WGPUAdapterInfo()
        #expect(wgpuAdapterGetInfo(gpu.adapter, &info) == WGPUStatus_Success)
        #expect(info.backendType == WGPUBackendType_WebGPU)
        #expect(info.vendor.data != nil)
        wgpuAdapterInfoFreeMembers(info)
    }
}

// MARK: - Helpers

/// The page's device through webgpu.h, and the plumbing a test needs.
private struct GPU {
    let instance: WGPUInstance
    let adapter: WGPUAdapter
    let device: WGPUDevice
    let queue: WGPUQueue

    init() throws {
        let context = try #require(WgpuContext.shared)
        instance = OpaquePointer(context.instancePointer)
        device = OpaquePointer(context.devicePointer)
        queue = wgpuDeviceGetQueue(device)
        // The request is answered before it returns (the page's adapter).
        let outcome = Outcome()
        var info = WGPURequestAdapterCallbackInfo()
        info.mode = WGPUCallbackMode_AllowSpontaneous
        info.callback = { _, adapter, _, userdata, _ in Outcome.from(userdata).adapter = adapter }
        info.userdata1 = outcome.pointer
        _ = wgpuInstanceRequestAdapter(instance, nil, info)
        adapter = try #require(outcome.adapter)
    }

    func buffer(size: Int, usage: WGPUBufferUsage, mappedAtCreation: Bool = false) -> WGPUBuffer? {
        var descriptor = WGPUBufferDescriptor()
        descriptor.usage = usage
        descriptor.size = UInt64(size)
        descriptor.mappedAtCreation = mappedAtCreation ? 1 : 0
        return wgpuDeviceCreateBuffer(device, &descriptor)
    }

    func drop(_ buffer: WGPUBuffer?) {
        guard let buffer else { return }
        wgpuBufferDestroy(buffer)
        wgpuBufferRelease(buffer)
    }

    func shader(_ code: String) -> WGPUShaderModule? {
        code.withCString { text in
            var source = WGPUShaderSourceWGSL()
            source.chain.sType = WGPUSType_ShaderSourceWGSL
            source.code = WGPUStringView(data: text, length: code.utf8.count)
            return withUnsafeMutablePointer(to: &source.chain) { chain in
                var descriptor = WGPUShaderModuleDescriptor()
                descriptor.nextInChain = chain
                return wgpuDeviceCreateShaderModule(device, &descriptor)
            }
        }
    }

    func submit(_ encode: (WGPUCommandEncoder) -> Void) throws {
        let encoder = try #require(wgpuDeviceCreateCommandEncoder(device, nil))
        defer { wgpuCommandEncoderRelease(encoder) }
        encode(encoder)
        var commands: WGPUCommandBuffer? = wgpuCommandEncoderFinish(encoder, nil)
        wgpuQueueSubmit(queue, 1, &commands)
        wgpuCommandBufferRelease(commands)
    }

    /// Maps `buffer` and waits for it.
    func map(_ buffer: WGPUBuffer, mode: WGPUMapMode, size: Int) throws {
        let outcome = Outcome()
        let future = wgpuBufferMapAsync(buffer, mode, 0, size, outcome.mapCallback(mode: WGPUCallbackMode_WaitAnyOnly))
        var wait = WGPUFutureWaitInfo(future: future, completed: 0)
        #expect(wgpuInstanceWaitAny(instance, 1, &wait, UInt64.max) == WGPUWaitStatus_Success)
        try #require(outcome.status == WGPUMapAsyncStatus_Success.rawValue)
    }

    /// `source`'s first `size` bytes, through a buffer mapped for reading.
    func read(_ source: WGPUBuffer, size: Int) throws -> [UInt8] {
        let staging = try #require(buffer(size: size, usage: WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst))
        defer { drop(staging) }
        try submit { encoder in wgpuCommandEncoderCopyBufferToBuffer(encoder, source, 0, staging, 0, UInt64(size)) }
        try map(staging, mode: WGPUMapMode_Read, size: size)
        let range = try #require(wgpuBufferGetConstMappedRange(staging, 0, size))
        let bytes = Array(UnsafeRawBufferPointer(start: range, count: size))
        wgpuBufferUnmap(staging)
        return bytes
    }

    /// Runs `body` in a validation, out-of-memory and internal error scope
    /// each, and expects `type` from the one that applies (none: NoError
    /// from all).
    func expectingError(_ type: WGPUErrorType, _ body: () throws -> Void) throws {
        let filters = [WGPUErrorFilter_Validation, WGPUErrorFilter_OutOfMemory, WGPUErrorFilter_Internal]
        for filter in filters { wgpuDevicePushErrorScope(device, filter) }
        try body()
        var types: [UInt32] = []
        for _ in filters {
            let outcome = Outcome()
            var info = WGPUPopErrorScopeCallbackInfo()
            info.mode = WGPUCallbackMode_WaitAnyOnly
            info.callback = { status, type, _, userdata, _ in
                let outcome = Outcome.from(userdata)
                outcome.record(status.rawValue)
                outcome.errorType = type.rawValue
            }
            info.userdata1 = outcome.pointer
            var wait = WGPUFutureWaitInfo(future: wgpuDevicePopErrorScope(device, info), completed: 0)
            #expect(wgpuInstanceWaitAny(instance, 1, &wait, UInt64.max) == WGPUWaitStatus_Success)
            #expect(outcome.status == WGPUPopErrorScopeStatus_Success.rawValue)
            types.append(outcome.errorType)
        }
        // Popped innermost first: internal, out of memory, validation.
        let expected: [UInt32] = switch type {
        case WGPUErrorType_Validation: [WGPUErrorType_NoError.rawValue, WGPUErrorType_NoError.rawValue, type.rawValue]
        case WGPUErrorType_OutOfMemory: [WGPUErrorType_NoError.rawValue, type.rawValue, WGPUErrorType_NoError.rawValue]
        case WGPUErrorType_Internal: [type.rawValue, WGPUErrorType_NoError.rawValue, WGPUErrorType_NoError.rawValue]
        default: Array(repeating: WGPUErrorType_NoError.rawValue, count: 3)
        }
        #expect(types == expected)
    }
}

/// What a callback reported; its pointer is the callback's userdata1.
private final class Outcome {
    var count = 0
    var status: UInt32 = 0
    var errorType: UInt32 = 0
    var messages: [(type: UInt32, line: UInt64, text: String)] = []
    var pipeline: WGPURenderPipeline?
    var adapter: WGPUAdapter?

    var pointer: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    static func from(_ pointer: UnsafeMutableRawPointer?) -> Outcome {
        Unmanaged<Outcome>.fromOpaque(pointer!).takeUnretainedValue()
    }

    func record(_ status: UInt32) {
        count += 1
        self.status = status
    }

    func mapCallback(mode: WGPUCallbackMode) -> WGPUBufferMapCallbackInfo {
        var info = WGPUBufferMapCallbackInfo()
        info.mode = mode
        info.callback = { status, _, userdata, _ in Outcome.from(userdata).record(status.rawValue) }
        info.userdata1 = pointer
        return info
    }
}

private func words(_ bytes: [UInt8]) -> [UInt32] {
    bytes.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
}

private func view(_ text: StaticString) -> WGPUStringView {
    WGPUStringView(data: UnsafeRawPointer(text.utf8Start).assumingMemoryBound(to: CChar.self), length: text.utf8CodeUnitCount)
}

private func string(_ view: WGPUStringView) -> String {
    guard let data = view.data else { return "" }
    return String(decoding: UnsafeRawBufferPointer(start: data, count: view.length), as: UTF8.self)
}
#endif
