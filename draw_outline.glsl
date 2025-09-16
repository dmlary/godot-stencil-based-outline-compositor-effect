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
layout(set = 1, binding = 0) uniform sampler2D u_jf_result;

void main()
{
    vec2 UV = gl_FragCoord.xy / resolution;
    vec4 value = texture(u_jf_result, UV);
    frag_color = value;

    // if (value.a > 0.5) {
    //     frag_color.rgba = vec4(1, 1, 0, 1);
    // } else {
    //     frag_color.b = 1;
    // }
}
