#version 450
// Vértice de la interfaz: posición en píxeles, coordenada de textura, color y,
// para las formas redondeadas, la posición local respecto al centro y sus parámetros.
layout(location = 0) in vec2 inPos;
layout(location = 1) in vec2 inUV;
layout(location = 2) in vec4 inColor;
layout(location = 3) in vec4 inRect;    // xy: posición local, zw: semitamaño
layout(location = 4) in vec4 inParams;  // x: radio (<0 = texto), y: grosor de borde, z: difuminado

layout(push_constant) uniform Push { vec2 screenSize; } pc;

layout(location = 0) out vec2 outUV;
layout(location = 1) out vec4 outColor;
layout(location = 2) out vec4 outRect;
layout(location = 3) out vec4 outParams;

void main() {
    vec2 ndc = inPos / pc.screenSize * 2.0 - 1.0;
    gl_Position = vec4(ndc, 0.0, 1.0);
    outUV = inUV;
    outColor = inColor;
    outRect = inRect;
    outParams = inParams;
}
