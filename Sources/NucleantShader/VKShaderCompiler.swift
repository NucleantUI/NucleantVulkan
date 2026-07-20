//
//  VKShaderCompiler.swift
//  NucleantVulkan
//


// MARK: - Shader Compiler

import CShaderc

//@MainActor
public final class VKShaderCompiler {
    nonisolated(unsafe)
    public static let shared = VKShaderCompiler()
    
    private var cache: [String: [UInt32]] = [:]
    private nonisolated(unsafe) let compiler: OpaquePointer
    
    private init() {
        compiler = shaderc_compiler_initialize()
    }
    
    deinit {
        shaderc_compiler_release(compiler)
    }
    
    public func tryCompileFragment(_ source: String) -> [UInt32]? {
        return compile(source: source, stage: .fragment, filename: "fragment.glsl")
    }

    public func getDefaultVertexSPIRV() -> [UInt32]? {
        return compile(source: VKPresetShaders.defaultVertex, stage: .vertex, filename: "vertex.glsl")
    }

    /// Compile a compute shader to SPIR-V words for injection into
    /// `VulkanCore.TexGenComputePipeline` (and other compute pipelines).
    public func tryCompileCompute(_ source: String) -> [UInt32]? {
        return compile(source: source, stage: .compute, filename: "compute.glsl")
    }

    public enum ShaderStage {
        case vertex
        case fragment
        case compute

        var shadercKind: shaderc_shader_kind {
            switch self {
            case .vertex: return shaderc_vertex_shader
            case .fragment: return shaderc_fragment_shader
            case .compute: return shaderc_compute_shader
            }
        }
    }
    
    public func compile(source: String, stage: ShaderStage, filename: String) -> [UInt32]? {
        let key = "\(stage)_\(source.hashValue)"
        if let cached = cache[key] {
            return cached
        }
        
        // Create compile options
        let options = shaderc_compile_options_initialize()
        defer { shaderc_compile_options_release(options) }
        
        // Target Vulkan 1.2 / SPIR-V 1.5
        shaderc_compile_options_set_target_env(options, shaderc_target_env_vulkan, UInt32(shaderc_env_version_vulkan_1_2.rawValue))
        shaderc_compile_options_set_target_spirv(options, shaderc_spirv_version_1_5)
        
        // Optimization level
        shaderc_compile_options_set_optimization_level(options, shaderc_optimization_level_performance)
        
        // Compile
        let result = source.withCString { sourcePtr in
            filename.withCString { filenamePtr in
                "main".withCString { entryPointPtr in
                    shaderc_compile_into_spv(
                        compiler,
                        sourcePtr,
                        source.utf8.count,
                        stage.shadercKind,
                        filenamePtr,
                        entryPointPtr,
                        options
                    )
                }
            }
        }
        
        defer { shaderc_result_release(result) }
        
        // Check for errors
        let status = shaderc_result_get_compilation_status(result)
        if status != shaderc_compilation_status_success {
            let errorMsg = shaderc_result_get_error_message(result)
            _ = errorMsg != nil ? String(cString: errorMsg!) : "Unknown error"
            return nil
        }
        
        // Get SPIR-V binary
        let length = shaderc_result_get_length(result)
        let bytes = shaderc_result_get_bytes(result)
        
        guard length > 0, let bytesPtr = bytes else {
            return nil
        }
        
        // Convert to [UInt32]
        let wordCount = length / MemoryLayout<UInt32>.size
        let spirv = bytesPtr.withMemoryRebound(to: UInt32.self, capacity: wordCount) { ptr in
            Array(UnsafeBufferPointer(start: ptr, count: wordCount))
        }
        
        cache[key] = spirv
        return spirv
    }
}
