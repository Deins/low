#version 460

layout(push_constant) uniform Push {
    vec2 offset;
    vec3 color;
} push_data;

layout(location = 0) out vec3 color;

const vec2 positions[3] = vec2[](
    vec2(0.0, -0.22),
    vec2(0.19, 0.16),
    vec2(-0.19, 0.16)
);

void main() {
    gl_Position = vec4(positions[gl_VertexIndex] + push_data.offset, 0.0, 1.0);
    color = push_data.color;
}
