#version 450

// Main pass vertex shader: clip-space position via MVP, plus the light-space
// position for shadow lookup. Sun direction is a constant in the fragment shader.
// Compile:  glslc cube.vert -o cube.vert.spv

layout(location = 0) in vec3 inPos;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec3 inColor;
layout(location = 3) in vec2 inUV;

layout(push_constant) uniform Push {
    mat4 mvp;
    mat4 lightVP;
} pc;

layout(location = 0) out vec3 vColor;
layout(location = 1) out vec3 vNormal;
layout(location = 2) out vec2 vUV;
layout(location = 3) out vec4 vLightPos;

void main()
{
    gl_Position = pc.mvp * vec4(inPos, 1.0);
    vColor    = inColor;
    vNormal   = inNormal;
    vUV       = inUV;
    vLightPos = pc.lightVP * vec4(inPos, 1.0);
}
