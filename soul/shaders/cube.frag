#version 450

// Main pass: atlas texture, baked ambient occlusion (in vColor), sun lighting
// with soft shadow-map shadows (3x3 PCF), and distance fog to the sky colour.
// Compile:  glslc cube.frag -o cube.frag.spv

layout(set = 0, binding = 0) uniform sampler2D uAtlas;
layout(set = 0, binding = 1) uniform sampler2D uShadow;

layout(location = 0) in vec3 vColor;
layout(location = 1) in vec3 vNormal;
layout(location = 2) in vec2 vUV;
layout(location = 3) in vec4 vLightPos;

layout(location = 0) out vec4 outColor;

const vec3 SUN = normalize(vec3(-0.5, -0.55, -0.4));
const vec3 SKY = vec3(0.55, 0.72, 0.97);

float shadowFactor()
{
    vec3 p = vLightPos.xyz / vLightPos.w;
    vec2 uv = p.xy * 0.5 + 0.5;
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0 || p.z > 1.0 || p.z < 0.0)
        return 1.0;

    float cur = p.z;
    float bias = 0.0025;
    float texel = 1.0 / 2048.0;
    float sum = 0.0;
    for (int x = -1; x <= 1; x++)
        for (int y = -1; y <= 1; y++)
        {
            float d = texture(uShadow, uv + vec2(float(x), float(y)) * texel).r;
            sum += (cur - bias > d) ? 0.0 : 1.0;
        }
    return sum / 9.0;
}

void main()
{
    vec4 tex = texture(uAtlas, vUV);
    if (tex.a < 0.5) discard;

    vec3 n = normalize(vNormal);
    float ndl = max(dot(n, -SUN), 0.0);
    float shadowTerm = mix(0.6, 1.0, shadowFactor());   // soft shadows, never black
    float light = (0.58 + 0.42 * ndl) * shadowTerm;

    vec3 col = tex.rgb * vColor * light;                // vColor carries ambient occlusion

    // distance fog (hides the streamed chunk boundary)
    float near = 0.1;
    float far = 1000.0;
    float lin = (near * far) / (far - gl_FragCoord.z * (far - near));
    float fog = clamp((lin - 70.0) / 40.0, 0.0, 1.0);

    outColor = vec4(mix(col, SKY, fog), 1.0);
}
