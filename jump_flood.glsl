#[compute]
#version 450

const float INFINITY = 1.0e10;

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
    ivec2 image_size = imageSize(u_src_image);
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);

    float best_dist = INFINITY;
    vec2 best_pos = vec2(0,0);

    for (int x = -1; x <= 1; x++) {
        for (int y = -1; y <= 1; y++) {
            ivec2 offset = ivec2(x * params.stride, y * params.stride);
            ivec2 neighbor_pos = clamp(
                    pos + offset, ivec2(0,0), image_size-1);
            vec4 neighbor_value = imageLoad(u_src_image, neighbor_pos);
            vec2 pos_delta = pos - neighbor_pos;
            float dist = dot(pos_delta, pos_delta);
            if (neighbor_value.r != -1 && dist < best_dist) {
                best_dist = dist;
                best_pos = neighbor_pos;
            }
        }
    }

    imageStore(
        u_dest_image,
        pos,
        best_dist != INFINITY ?
            vec4(best_pos.x, best_pos.y, best_dist, 1) :
            vec4(-1,-1,INFINITY,0));
}
