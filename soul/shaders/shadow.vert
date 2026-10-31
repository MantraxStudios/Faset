#version 450

// Depth-only pass: project world-space voxel vertices into the sun's light space
// to fill the shadow map. Only the position attribute is used.
// Compile:  glslc shadow.vert -o shadow.vert.spv

layout(location = 0) in vec3 inPos;

layout(push_constant) uniform Push {
    mat4 mvp;
    mat4 lightVP;
} pc;

void main()
{
    gl_Position = pc.lightVP * vec4(inPos, 1.0);
}
