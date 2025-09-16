#[compute]
#version 450

// Invocations in the (x, y, z) dimension.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Our textures.
layout(rgba16f, set = 0, binding = 0) uniform image2D u_src_image;
layout(rgba16f, set = 0, binding = 1) uniform image2D u_dest_image;

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

    // current_value.rg = ((current_value.rg - coord)*100.0);

    for (int i = 0; i < 8; i++) {
        ivec2 neighbor_coord = clamp(coord + offsets[i], ivec2(0,0), image_size-1);
        vec4 neighbor_value = imageLoad(u_src_image, neighbor_coord);
        if (neighbor_value.b < 0) {
            continue;
        }

        // confirmed that neighbor's rg equals its coordinates
        vec2 coord_delta = coord - neighbor_coord;
        // vec2 coord_delta = neighbor_coord - coord;
        // 3432, 2009
        // current_value.r = coord.x / (3432.0/1.3);
        // current_value.g = coord.y / (2009/1.3);
        // current_value.rg = coord.xy/(ivec2(image_size) / 1.3);
        //
        // current_value.rg = coord_delta;
        // current_value.a = 1;
        //current_value.g = 0;

        float dist = dot(coord_delta, coord_delta);
        // current_value.b = dist/2.0;
        // current_value.b = dist/10000.0;
        if (current_value.b < 0 || dist < current_value.b) {
            current_value.rg = neighbor_coord;
            current_value.b = dist;
            current_value.a = 1;
        }
    }

    imageStore(u_dest_image, coord, current_value.b >= 0 ? current_value : vec4(-1,-1,-1,0));
}
