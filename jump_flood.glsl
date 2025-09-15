#[compute]
#version 450

// Invocations in the (x, y, z) dimension.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Our textures.
layout(r32f, set = 0, binding = 0) uniform image2D input_image;
layout(r32f, set = 1, binding = 0) uniform image2D output_image;

// Our push PushConstant.
// layout(push_constant, std430) uniform Params {
//     int stride;
// } params;

void main() {
    ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
    vec4 value = imageLoad(input_image, uv);
    imageStore(output_image, uv, value);
    barrier();
}
