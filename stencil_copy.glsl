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
    // adjust position so it matches GlobalInvocationID in compute shaders
    vec2 pos = gl_FragCoord.xy - 0.5;
    frag_color = vec4(pos, 1, 1);
}
