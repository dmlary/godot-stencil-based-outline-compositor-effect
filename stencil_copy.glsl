#[vertex]
#version 450 core
layout(location = 0) in vec3 vertex_attrib;

void main()
{
    gl_Position = vec4(vertex_attrib, 1.0);
}

#[fragment]
#version 450 core
layout (location = 0) out vec4 frag_color;
layout (set = 0, binding = 0) uniform FrameData {
    vec2 resolution;
};

void main() {
    // Initialize all pixels with their UV, and their distance (0) from nearest
    // set value.  Alpha channel denotes there is a value here.
    vec2 UV = gl_FragCoord.xy / resolution;
    frag_color.rgba = vec4(UV.x, UV.y, 0, 1);
    // frag_color.rgba = vec4(1.0, 1.0, 1.0, 1.0);
    // frag_color.a = 1;
}
