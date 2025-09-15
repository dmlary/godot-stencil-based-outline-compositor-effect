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

void main() {
    frag_color.rgba = vec4(1, 1, 0, 1);
}
