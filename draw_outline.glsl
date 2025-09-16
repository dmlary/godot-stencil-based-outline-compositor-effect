#[compute]
#version 450

// Invocations in the (x, y, z) dimension.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Our textures.
layout(rgba16f, set = 0, binding = 0) uniform image2D u_src_image;
layout(rgba16f, set = 0, binding = 1) uniform image2D u_dest_image;

// Our push PushConstant.
layout(push_constant, std430) uniform Params {
    vec4 color;
} params;

// perform a single pass of jump flood from image_0 to image_1
//
// Arguments:
//  stride: distance around UV to sample
void main() {
    ivec2 image_size = imageSize(u_src_image);
    ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
    vec4 output_color = imageLoad(u_dest_image, coord);

    // pull the jump-flood value for this point
    vec4 value = imageLoad(u_src_image, coord);
    // output_color.rg = value.rg;
    // output_color.b = 0;
    if (value.b > 0 && value.b < (1<<15)){
        output_color.r = 0;
        output_color.g = 0;
        // output_color.rg = value.rg/vec2(image_size);
        output_color.b = (value.b-1.1)/10.0;
        output_color.a = 1;
        output_color = params.color;
    }

    imageStore(u_dest_image, coord, output_color);
}
