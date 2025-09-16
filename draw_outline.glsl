#[vertex]
#version 450 core
layout(location = 0) in vec3 vertex_attrib;
layout(r32f, set = 1, binding = 0) uniform image2D u_jf_result;

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

void main()
{
    vec2 UV = gl_FragCoord.xy / resolution;
    frag_color.rgba = vec4(1, 1, 0, 1);
}
