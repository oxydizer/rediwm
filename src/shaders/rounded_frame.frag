#version 300 es
precision mediump float;

// Signed-distance rounded box used by the CPU chrome rasterizer in main.zig.
// Radius is the prototype's --r-lg (10px). No blur, no shadow.
uniform vec2 u_frame_size;
uniform vec4 u_color;
uniform float u_radius;
out vec4 fragColor;

float sdRoundedBox(vec2 point, vec2 size, float radius) {
    vec2 q = abs(point - size * 0.5) - (size * 0.5 - radius);
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
}

void main() {
    float distance = sdRoundedBox(gl_FragCoord.xy, u_frame_size, u_radius);
    float coverage = clamp(0.5 - distance, 0.0, 1.0);
    fragColor = vec4(u_color.rgb, u_color.a * coverage);
}
