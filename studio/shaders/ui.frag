#version 450
// Texto: el atlas guarda la cobertura del glifo en el canal R. Imágenes: radio -2.
// Formas: rectángulo redondeado por función de distancia (bordes suaves, contornos y sombras).
layout(set = 0, binding = 0) uniform sampler2D atlas;
// Imagen RGBA (p. ej. la pantalla del dispositivo Android), con filtrado lineal.
layout(set = 0, binding = 1) uniform sampler2D image;

layout(location = 0) in vec2 inUV;
layout(location = 1) in vec4 inColor;
layout(location = 2) in vec4 inRect;
layout(location = 3) in vec4 inParams;
layout(location = 0) out vec4 outColor;

float roundBox(vec2 p, vec2 halfSize, float r) {
    vec2 q = abs(p) - halfSize + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

void main() {
    if (inParams.x < -1.5) {
        vec4 t = texture(image, inUV);
        outColor = vec4(t.rgb * inColor.rgb, t.a * inColor.a);
        return;
    }
    float alpha;
    if (inParams.x < 0.0) {
        alpha = texture(atlas, inUV).r;
    } else {
        float d = roundBox(inRect.xy, inRect.zw, inParams.x);
        float soft = max(inParams.z, 1.0);
        alpha = clamp(0.5 - d / soft, 0.0, 1.0);
        if (inParams.y > 0.0) alpha -= clamp(0.5 - (d + inParams.y), 0.0, 1.0);
    }
    outColor = vec4(inColor.rgb, inColor.a * alpha);
}
