#version 450

// Translucent water: sampled atlas colour, sun-lit, fixed alpha so the terrain
// below shows through (alpha blending, no depth write). No shadows on water.
// Compile:  glslc water.frag -o water.frag.spv

layout(set = 0, binding = 0) uniform sampler2D uAtlas;

layout(location = 0) in vec3 vColor;
layout(location = 1) in vec3 vNormal;
layout(location = 2) in vec2 vUV;
layout(location = 3) in vec4 vLightPos;   // unused, matches vertex outputs

layout(location = 0) out vec4 outColor;

const vec3 SUN = normalize(vec3(-0.5, -0.55, -0.4));

void main()
{
    vec4 tex = texture(uAtlas, vUV);
    vec3 n = normalize(vNormal);
    float ndl = max(dot(n, -SUN), 0.0);
    float light = 0.55 + 0.45 * ndl;
    outColor = vec4(tex.rgb * light, 0.62);
}
