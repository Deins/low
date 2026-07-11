#version 460

layout(push_constant) uniform Push {
    vec2 offset;
    vec2 screen_size;
    vec3 color;
} push_data;

layout(location = 0) out vec3 color;

const vec2 positions[3] = vec2[](
    vec2(0.0, -70.0),
    vec2(70.0, 70.0),
    vec2(-70.0, 70.0)
);

void main() {
    // Keep the motion in normalized screen coordinates, but apply the
    // triangle's local geometry in pixels. This prevents resize-dependent
    // stretching while retaining the existing motion behavior.
    vec2 center = (push_data.offset * 0.5 + 0.5) * push_data.screen_size;
    vec2 pixel_position = center + positions[gl_VertexIndex];
    vec2 ndc_position = pixel_position / push_data.screen_size * 2.0 - 1.0;
    gl_Position = vec4(ndc_position, 0.0, 1.0);
    color = push_data.color;
}
