#[compute]
#version 450

// Invocations in the (x, y, z) dimension.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Our textures.
layout(r32f, set = 0, binding = 0) uniform image2D u_src_image;
layout(r32f, set = 0, binding = 1) uniform image2D u_dest_image;

// Our push PushConstant.
layout(push_constant, std430) uniform Params {
    uint stride;
} params;

// perform a single pass of jump flood from image_0 to image_1
//
// Arguments:
//  stride: distance around UV to sample
void main() {
    uint stride = params.stride;
    ivec2 image_size = imageSize(u_src_image);
    ivec2 coord = ivec2(gl_GlobalInvocationID.xy);

    // pull the value for this point
    vec4 current_value = imageLoad(u_src_image, coord);

    // calculate the offsets around this point
    ivec2 offsets[] = ivec2[](
        ivec2(-stride, stride),  ivec2(0, stride),  ivec2(stride, stride), 
        ivec2(-stride, 0     ),                     ivec2(stride, 0     ), 
        ivec2(-stride, -stride), ivec2(0, -stride), ivec2(stride, -stride)
    );

    for (int i = 0; i < 8; i++) {
        ivec2 neighbor_coord = clamp(coord + offsets[i], ivec2(0,0), image_size-1);
        vec4 neighbor_value = imageLoad(u_src_image, neighbor_coord);
        if (neighbor_value.a < 0.5) {
            continue;
        }

        vec2 coord_delta = coord - neighbor_value.rg;
        float dist = dot(coord_delta, coord_delta);
        if (current_value.a < 1.0 || dist < current_value.b) {
            current_value.rg = neighbor_coord;
            current_value.b = dist;
            current_value.a = 1.0;
        }
    }

    imageStore(u_dest_image, coord, current_value.a > 0.5 ? current_value : vec4(0,0,0,0));
}
