#[compute]
#version 450

// Invocations in the (x, y, z) dimension.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Our textures.
layout(r32f, set = 0, binding = 0) uniform image2D u_image_0;
layout(r32f, set = 1, binding = 0) uniform image2D u_image_1;

// Our push PushConstant.
layout(push_constant, std430) uniform Params {
    uint passes;
} params;

// perform a single pass of jump flood from image_0 to image_1
//
// Arguments:
//  stride: distance around UV to sample
void do_jump_flood_pass_a(uint stride) {
    ivec2 image_size = imageSize(u_image_0);
    ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
    vec4 current_value = imageLoad(u_image_0, coord);
    ivec2 offsets[] = ivec2[](
        ivec2(-stride, stride),  ivec2(0, stride),  ivec2(stride, stride), 
        ivec2(-stride, 0     ),                     ivec2(stride, 0     ), 
        ivec2(-stride, -stride), ivec2(0, -stride), ivec2(stride, -stride)
    );

    for (int i = 0; i < 8; i++) {
        ivec2 neighbor_coord = coord + offsets[i];
        if (neighbor_coord.x < 0 || neighbor_coord.y < 0 ||
                neighbor_coord.x >= image_size.x ||
                neighbor_coord.y >= image_size.y) {
            continue;
        }

        vec4 neighbor_value = imageLoad(u_image_0, neighbor_coord);
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

    imageStore(u_image_1, coord, current_value.a > 0.5 ? current_value : vec4(0,0,0,0));
}

void do_jump_flood_pass_b(uint stride) {
    ivec2 image_size = imageSize(u_image_0);
    ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
    vec4 current_value = imageLoad(u_image_1, coord);
    ivec2 offsets[] = ivec2[](
        ivec2(-stride, stride),  ivec2(0, stride),  ivec2(stride, stride), 
        ivec2(-stride, 0     ),                     ivec2(stride, 0     ), 
        ivec2(-stride, -stride), ivec2(0, -stride), ivec2(stride, -stride)
    );

    for (int i = 0; i < 8; i++) {
        ivec2 neighbor_coord = coord + offsets[i];
        if (neighbor_coord.x < 0 || neighbor_coord.y < 0 ||
                neighbor_coord.x >= image_size.x ||
                neighbor_coord.y >= image_size.y) {
            continue;
        }

        vec4 neighbor_value = imageLoad(u_image_1, neighbor_coord);
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

    imageStore(u_image_0, coord, current_value.a > 0.5 ? current_value : vec4(0,0,0,0));
}

void main() {
    ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
    uint dir = 0;
    for (uint pass = params.passes; pass > 0; pass--) {
        uint stride = 1<<(pass-1);
        if ((dir & 1U)== 0U) {
            do_jump_flood_pass_a(stride);
        } else {
            do_jump_flood_pass_b(stride);
        }
        dir += 1;
        barrier();
    }
}
