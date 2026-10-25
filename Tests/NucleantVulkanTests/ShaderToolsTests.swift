//
//  ShaderToolsTests.swift
//  NucleantVulkanTests
//
//  The libraries every native platform links — shaderc, spirv-cross and the
//  Vulkan loader — called the way the engine calls them. None of it needs a
//  GPU, so it runs on any CI machine; on Linux and Windows it is also the
//  check that the release's artifact bundles put each shared library where
//  the test executable finds it.
//
#if !os(WASI)
import Testing
import CSPIRVCross
import CVulkan
import NucleantShader

/// The engine's composite shader (VulkanRenderEngine.createCompositePipeline).
private let compositeFragment = """
#version 450
layout(location = 0) in vec2 vTexCoord;
layout(location = 0) out vec4 fragColor;
layout(binding = 0) uniform sampler2D nodeImage;

void main() {
    fragColor = texture(nodeImage, vTexCoord);
}
"""

/// On the main actor, as the engine compiles: `VKShaderCompiler.shared` keeps
/// its cache unlocked, so tests compiling in parallel would race on it.
@MainActor
@Suite struct ShaderToolsTests {

    @Test func shadercCompilesGLSLToSPIRV() throws {
        let spirv = try #require(VKShaderCompiler.shared.compile(
            source: compositeFragment, stage: .fragment, filename: "composite.frag"))
        #expect(spirv.first == 0x0723_0203, "not a SPIR-V module: \(spirv.prefix(5))")
        #expect(spirv.count > 5)
    }

    @Test func shadercRejectsBrokenGLSL() {
        let spirv = VKShaderCompiler.shared.compile(
            source: "#version 450\nvoid main() { undeclared = 1.0; }", stage: .fragment, filename: "broken.frag")
        #expect(spirv == nil)
    }

    /// spirv-cross reads back what shaderc wrote: the one sampled image, at
    /// its set and binding, and GLSL again from the module. Not by name: the
    /// engine compiles with shaderc's performance optimisation, which strips
    /// names.
    @Test func spirvCrossReflectsAndCrossCompiles() throws {
        let spirv = try #require(VKShaderCompiler.shared.compile(
            source: compositeFragment, stage: .fragment, filename: "composite.frag"))

        var context: spvc_context?
        #expect(spvc_context_create(&context) == SPVC_SUCCESS)
        let ctx = try #require(context)
        defer { spvc_context_destroy(ctx) }

        var parsed: spvc_parsed_ir?
        let parse = spirv.withUnsafeBufferPointer { words in
            spvc_context_parse_spirv(ctx, words.baseAddress, words.count, &parsed)
        }
        #expect(parse == SPVC_SUCCESS)

        var compiler: spvc_compiler?
        #expect(spvc_context_create_compiler(ctx, SPVC_BACKEND_GLSL, parsed, SPVC_CAPTURE_MODE_TAKE_OWNERSHIP, &compiler) == SPVC_SUCCESS)
        let glsl = try #require(compiler)

        var resources: spvc_resources?
        #expect(spvc_compiler_create_shader_resources(glsl, &resources) == SPVC_SUCCESS)
        var list: UnsafePointer<spvc_reflected_resource>?
        var count = 0
        #expect(spvc_resources_get_resource_list_for_type(resources, SPVC_RESOURCE_TYPE_SAMPLED_IMAGE, &list, &count) == SPVC_SUCCESS)
        try #require(count == 1)
        let image = try #require(list).pointee
        #expect(spvc_compiler_get_decoration(glsl, image.id, SpvDecorationDescriptorSet) == 0)
        #expect(spvc_compiler_get_decoration(glsl, image.id, SpvDecorationBinding) == 0)

        var source: UnsafePointer<CChar>?
        #expect(spvc_compiler_compile(glsl, &source) == SPVC_SUCCESS)
        let output = String(cString: try #require(source))
        #expect(output.contains("layout(binding = 0) uniform sampler2D"), "\(output)")
        #expect(output.contains("texture("), "\(output)")
        #expect(output.contains("void main()"), "\(output)")
    }

    /// The loader (or, on Apple, MoltenVK itself) answers before any instance
    /// exists, with at least the Vulkan 1.2 the engine asks for.
    @Test func vulkanAnswersWithItsVersion() {
        var version: UInt32 = 0
        #expect(vkEnumerateInstanceVersion(&version) == VK_SUCCESS)
        let major = version >> 22, minor = (version >> 12) & 0x3FF
        #expect(major > 1 || (major == 1 && minor >= 2), "Vulkan \(major).\(minor)")
    }
}
#endif
