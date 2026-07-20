//
//  VKPresetShaders.swift
//  NucleantVulkan
//
//  Created by CodeBuilder on 20/07/2026.
//



// MARK: - Preset Shaders

public enum VKPresetShaders {
    
    public static let defaultVertex = """
    #version 450
    
    vec2 positions[6] = vec2[](
        vec2(-1.0, -1.0),
        vec2( 1.0, -1.0),
        vec2( 1.0,  1.0),
        vec2(-1.0, -1.0),
        vec2( 1.0,  1.0),
        vec2(-1.0,  1.0)
    );
    
    vec2 texCoords[6] = vec2[](
        vec2(0.0, 0.0),
        vec2(1.0, 0.0),
        vec2(1.0, 1.0),
        vec2(0.0, 0.0),
        vec2(1.0, 1.0),
        vec2(0.0, 1.0)
    );
    
    layout(location = 0) out vec2 vTexCoord;
    
    void main() {
        gl_Position = vec4(positions[gl_VertexIndex], 0.0, 1.0);
        vTexCoord = texCoords[gl_VertexIndex];
    }
    """
    
    public static let plasma = """
    #version 450
    
    layout(location = 0) in vec2 vTexCoord;
    layout(location = 0) out vec4 fragColor;
    
    layout(push_constant) uniform PushConstants {
        float time;
        float _pad0;
        vec2 resolution;
        vec2 mouse;
    } pc;
    
    const float PI = 3.14159265359;
    const float PI_2_3 = 2.094395102;
    const float PI_4_3 = 4.188790205;
    
    void main() {
        vec2 uv = vTexCoord;
        float t = pc.time;
        
        float v = 0.0;
        v += sin(uv.x * 10.0 + t);
        v += sin((uv.y * 10.0 + t) * 0.5);
        v += sin((uv.x * 10.0 + uv.y * 10.0 + t) * 0.5);
        
        vec2 c = uv * 10.0 - 5.0;
        v += sin(sqrt(c.x * c.x + c.y * c.y + 1.0) + t);
        v *= 0.5;
        
        vec3 col = vec3(
            sin(PI * v),
            sin(PI * v + PI_2_3),
            sin(PI * v + PI_4_3)
        );
        col = col * 0.5 + 0.5;
        
        fragColor = vec4(col, 1.0);
    }
    """
    
    public static let rainbow = """
    #version 450
    
    layout(location = 0) in vec2 vTexCoord;
    layout(location = 0) out vec4 fragColor;
    
    layout(push_constant) uniform PushConstants {
        float time;
        float _pad0;
        vec2 resolution;
        vec2 mouse;
    } pc;
    
    vec3 hsv2rgb(vec3 c) {
        vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
        vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
        return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
    }
    
    void main() {
        float hue = fract(vTexCoord.x + vTexCoord.y * 0.5 + pc.time * 0.2);
        vec3 color = hsv2rgb(vec3(hue, 0.8, 0.9));
        fragColor = vec4(color, 1.0);
    }
    """
    
    public static let fire = """
    #version 450
    
    layout(location = 0) in vec2 vTexCoord;
    layout(location = 0) out vec4 fragColor;
    
    layout(push_constant) uniform PushConstants {
        float time;
        float _pad0;
        vec2 resolution;
        vec2 mouse;
    } pc;
    
    float noise(vec2 p) {
        return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
    }
    
    float smoothNoise(vec2 p) {
        vec2 i = floor(p);
        vec2 f = fract(p);
        f = f * f * (3.0 - 2.0 * f);
        
        float a = noise(i);
        float b = noise(i + vec2(1.0, 0.0));
        float c = noise(i + vec2(0.0, 1.0));
        float d = noise(i + vec2(1.0, 1.0));
        
        return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
    }
    
    void main() {
        vec2 uv = vTexCoord;
        
        float n = 0.0;
        n += smoothNoise(uv * 8.0 + vec2(0.0, -pc.time * 3.0)) * 0.5;
        n += smoothNoise(uv * 16.0 + vec2(0.0, -pc.time * 4.0)) * 0.25;
        n += smoothNoise(uv * 32.0 + vec2(0.0, -pc.time * 5.0)) * 0.125;
        
        n *= 1.0 - uv.y;
        n = clamp(n * 2.0, 0.0, 1.0);
        
        vec3 color;
        color.r = min(1.0, n * 2.0);
        color.g = max(0.0, n - 0.3) * 1.5;
        color.b = max(0.0, n - 0.7) * 3.0;
        
        fragColor = vec4(color, n > 0.1 ? 1.0 : 0.0);
    }
    """
    
    public static let ripple = """
    #version 450
    
    layout(location = 0) in vec2 vTexCoord;
    layout(location = 0) out vec4 fragColor;
    
    layout(push_constant) uniform PushConstants {
        float time;
        float _pad0;
        vec2 resolution;
        vec2 mouse;
    } pc;
    
    void main() {
        vec2 uv = vTexCoord - 0.5;
        float dist = length(uv);
        
        float wave = sin(dist * 30.0 - pc.time * 5.0) * 0.5 + 0.5;
        float fade = max(0.0, 1.0 - dist * 2.0);
        
        float intensity = wave * fade;
        
        vec3 color = vec3(0.2, 0.5, 0.8) + vec3(0.3, 0.3, 0.2) * intensity;
        fragColor = vec4(color, 1.0);
    }
    """
}
