extends CompositorEffect
class_name StencilBasedOutlineCompositorEffect

## GLSL stencil_copy_shader source file
@export_file("*.glsl") var glsl_shader_file = "res://render_shader.glsl"

var rd: RenderingDevice

# Everything needed for the render stencil_copy_pipeline that copys from the stencil buffer
## cached copy of the depth/stencil texture to detect when it changes
var depth_texture: RID

## stencil copy shader
var stencil_copy_shader: RID
# XXX create the buffer, and the uniform, and the uniform set at startup.
# Update the buffer when the resolution changes
var per_frame_uniform_buffer : RID
var per_frame_uniform: RDUniform

# framebuffer used for the stencil copy stencil_copy_pipeline
# rebuild: resolution change, depth buffer rid change
var framebuffer: RID
var framebuf_format: int # rebuild pipeline when changes

## Vertex array containing a triangle that covers the full screen quad
var vertex_format : int
var vertex_buffer : RID
var vertex_array : RID

## stencil copy pipeline
var stencil_copy_pipeline: RID


## destination texture
var texture: RID
# used to detect
var texture_format := RDTextureFormat.new()
var output_texture := Texture2DRD.new()

var mutex := Mutex.new()
@export var shader_dirty := true

# Called when this resource is constructed.
func _init():
    effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_OPAQUE

    # Grab the rendering device
    rd = RenderingServer.get_rendering_device()

    _build_stencil_copy_shader()
    ## We create the vertex & index arrays to draw a full-screen quad.

    # build the vertex format
    var vertex_attr = RDVertexAttribute.new()
    vertex_attr.location = 0
    vertex_attr.format = RenderingDevice.DATA_FORMAT_R32G32B32_SFLOAT
    vertex_attr.stride = 4 * 3
    vertex_format = rd.vertex_format_create([vertex_attr])

    # These vertex points make a triangle that cover the entire screen.  The
    # points are declared in counter-clockwise winding order so that the front
    # of the quad is facing the camera.  This is important for the stencil
    # operations set in _build_pipeline(), as we only set stencil front_ops.
    var vertex_data = PackedVector3Array([
        Vector3(-1, -1, 0),
        Vector3(3, -1, 0),
        Vector3(-1, 3, 0),
    ])
    var vertex_bytes = vertex_data.to_byte_array()
    vertex_buffer = rd.vertex_buffer_create(vertex_bytes.size(), vertex_bytes)
    vertex_array = rd.vertex_array_create(3, vertex_format, [vertex_buffer])

func _load_glsl_from_file(path) -> Variant:
    var lines = []
    if not FileAccess.file_exists(path):
        push_error("_load_glsl_from_file() file not found: ", path)
        return null
    
    var file = FileAccess.open(path, FileAccess.READ)
    if not file:
        push_error("_load_glsl_from_file() failed to open `", path, "`: ", FileAccess.get_open_error())
        return null

    while not file.eof_reached():
        lines.append(file.get_line())

    file.close()

    var source := RDShaderSource.new()
    source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
    source.source_vertex = ""
    source.source_fragment = ""

    var type = null
    for line in lines:
        if line == "#[vertex]":
            type = "vertex"
        elif line == "#[fragment]":
            type = "fragment"
        elif type == "vertex":
            source.source_vertex += line + "\n"
        elif type == "fragment":
            source.source_fragment += line + "\n"

    return source

func _build_stencil_copy_shader():
    print("building stencil copy shader")

    # load the stencil_copy_shader
    var source := RDShaderSource.new()
    source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
    source.source_vertex = """
        #version 450 core
        layout(location = 0) in vec3 vertex_attrib;

        void main()
        {
            gl_Position = vec4(vertex_attrib, 1.0);
        }
    """
    source.source_fragment = """
        #version 450 core
        layout (location = 0) out vec4 frag_color;
        layout (set = 0, binding = 0) uniform FrameData {
            vec2 resolution;
        };

        void main() {
            vec2 UV = gl_FragCoord.xy / resolution;
            frag_color.rgba = vec4(UV.x, UV.y, 1, 1);
        }
    """
    var shader_spirv: RDShaderSPIRV = rd.shader_compile_spirv_from_source(source)
    if shader_spirv.compile_error_vertex != "":
        push_error(shader_spirv.compile_error_vertex)
        return
    if shader_spirv.compile_error_fragment != "":
        push_error(shader_spirv.compile_error_fragment)
        return
    stencil_copy_shader = rd.shader_create_from_spirv(shader_spirv)

func _build_per_frame_uniform(size: Vector2i):
    print("building per-frame uniform")
    if per_frame_uniform_buffer.is_valid():
        rd.free_rid(per_frame_uniform_buffer)
        per_frame_uniform_buffer = RID()

    var buffer = PackedFloat32Array([size.x, size.y, 0, 0]).to_byte_array()
    per_frame_uniform_buffer = rd.uniform_buffer_create(buffer.size(), buffer)
    per_frame_uniform = RDUniform.new()
    per_frame_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
    per_frame_uniform.binding = 0
    per_frame_uniform.add_id(per_frame_uniform_buffer)


func _build_shader():
    print("rebuilding shader")

    mutex.lock()
    shader_dirty = false
    mutex.unlock()

    # destroy old stencil_copy_shader if present
    if stencil_copy_shader.is_valid():
        rd.free_rid(stencil_copy_shader)
        stencil_copy_shader = RID()
        # freeing the stencil_copy_shader will also free the stencil_copy_pipeline that was dependent on
        # the stencil_copy_shader
        stencil_copy_pipeline = RID()

    # load the stencil_copy_shader
    var shader_source = _load_glsl_from_file(glsl_shader_file)
    if not shader_source:
        push_error("failed to load stencil_copy_shader source: ", glsl_shader_file)
        return
    var shader_spirv: RDShaderSPIRV = rd.shader_compile_spirv_from_source(shader_source)
    if shader_spirv.compile_error_vertex != "":
        push_error(shader_spirv.compile_error_vertex)
        return
    if shader_spirv.compile_error_fragment != "":
        push_error(shader_spirv.compile_error_fragment)
        return
    stencil_copy_shader = rd.shader_create_from_spirv(shader_spirv)


# System notifications, we want to react on the notification that
# alerts us we are about to be destroyed.
func _notification(what):
    if what == NOTIFICATION_PREDELETE:
        if stencil_copy_pipeline.is_valid():
            rd.free_rid(stencil_copy_pipeline)
        if stencil_copy_shader.is_valid():
            rd.free_rid(stencil_copy_shader)
        if framebuffer.is_valid():
            rd.free_rid(framebuffer)
        if texture.is_valid():
            rd.free_rid(texture)
        if vertex_array.is_valid():
            rd.free_rid(vertex_array)
        if vertex_buffer.is_valid():
            rd.free_rid(vertex_buffer)

## Create the render stencil_copy_pipeline.
func _build_pipeline():
    print("building stencil_copy_pipeline")
    if stencil_copy_pipeline.is_valid():
        rd.free_rid(stencil_copy_pipeline)
        stencil_copy_pipeline = RID()

    #create the stencil_copy_pipeline
    var blend := RDPipelineColorBlendState.new()
    var blend_attachment := RDPipelineColorBlendStateAttachment.new()
    blend.attachments.push_back(blend_attachment)

    # stencil state
    var stencil_state = RDPipelineDepthStencilState.new()

    # If the first bit if the stencil is set, draw on that fragment
    stencil_state.enable_stencil = true
    stencil_state.front_op_compare = RenderingDevice.COMPARE_OP_EQUAL
    stencil_state.front_op_compare_mask = 0x1
    stencil_state.front_op_write_mask = 0
    stencil_state.front_op_reference = 1
    stencil_state.front_op_fail = RenderingDevice.STENCIL_OP_KEEP
    stencil_state.front_op_pass = RenderingDevice.STENCIL_OP_KEEP

    stencil_copy_pipeline = rd.render_pipeline_create(
        stencil_copy_shader,
        framebuf_format,
        vertex_format,
        RenderingDevice.RENDER_PRIMITIVE_TRIANGLES,
        RDPipelineRasterizationState.new(),
        RDPipelineMultisampleState.new(),
        stencil_state, # RDPipelineDepthStencilState.new(),
        blend,
    )
    assert(stencil_copy_pipeline.is_valid())

## Create a new color texture to use as the output for our render stencil_copy_pipeline.
## Note: this texture must be the same size as the depth texture, so we create
## it on demand.
func _build_texture(width: int, height: int):
    print("building output texture (", width, ", ", height, ")")
    
    # create our output texture
    texture_format = RDTextureFormat.new()
    texture_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
    texture_format.width = width
    texture_format.height = height
    texture_format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
    texture_format.usage_bits = RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
    var new_texture = rd.texture_create(texture_format, RDTextureView.new())
    assert(new_texture.is_valid())

    # we change this before freeing the old texture to prevent visual flicker
    # in a TextureRect using the output texture while resizing.
    output_texture.texture_rd_rid = new_texture

    # free the old texture if there was one
    if texture.is_valid():
        rd.free_rid(texture)
        texture = RID()
        # freeing the texture will also free the dependent framebuffer
        framebuffer = RID()

    # save the new texture rid
    texture = new_texture

## Build a framebuffer using the color texture and supplied depth texture.
## This function will return true if the format of the framebuffer changed,
## which means we need to rebuild the stencil_copy_pipeline.
func _build_framebuffer() -> bool:
    print("building framebuffer for depth texture ", depth_texture)
    if framebuffer.is_valid():
        rd.free_rid(framebuffer)
        framebuffer = RID()

    if not depth_texture.is_valid():
        return false

    var attachments = []
    # Add the draw texture format to the framebuffer attachments
    var attachment_format = RDAttachmentFormat.new()
    attachment_format.format = texture_format.format
    attachment_format.usage_flags = texture_format.usage_bits
    attachment_format.samples = RenderingDevice.TEXTURE_SAMPLES_1
    attachments.push_back(attachment_format)

    # Add the depth texture format to the framebuffer attachments
    var depth_format = rd.texture_get_format(depth_texture)
    attachment_format = RDAttachmentFormat.new()
    attachment_format.format = depth_format.format
    attachment_format.usage_flags = depth_format.usage_bits
    attachment_format.samples = RenderingDevice.TEXTURE_SAMPLES_1
    attachments.push_back(attachment_format)

    var format = rd.framebuffer_format_create(attachments)
    framebuffer = rd.framebuffer_create([texture, depth_texture], format)
    assert(framebuffer.is_valid())

    var out = format != framebuf_format
    framebuf_format = format
    return out 

# Called by the rendering thread every frame.
func _render_callback(_p_effect_callback_type, p_render_data):
    var buffers_changed := false
    var framebuf_format_changed := false
    var shader_changed := false

    if not rd:
        return
    if not stencil_copy_shader.is_valid():
        return

    # reload the stencil_copy_shader if it has changed on disk
    # if shader_dirty or not stencil_copy_shader.is_valid():
    #     _build_stencil_copy_shader()
    #     shader_changed = true

    # Get our render scene buffers object, this gives us access to our render
    # buffers. Note that implementation differs per renderer hence the need
    # for the cast.
    var render_scene_buffers: RenderSceneBuffersRD = p_render_data.get_render_scene_buffers()
    if not render_scene_buffers:
        return

    # Get our render size, this is the 3D render resolution!
    var size = render_scene_buffers.get_internal_size()
    if size.x == 0 and size.y == 0:
        return

    # Build the output texture the same size as the render resolution.
    # Note: the output texture must be the same size as the render resolution
    #       because the texture and depth texture must be the same resolution
    #       to create a framebuffer later.  If they are not the same size, we
    #       get an error in _build_framebuffer()
    if not texture.is_valid() or \
            texture_format.width != size.x or \
            texture_format.height != size.y:
        _build_texture(size.x, size.y)
        _build_per_frame_uniform(size)
        buffers_changed = true

    # if the depth texture has changed, we'll need to rebuild the framebuffer
    var depth_tex = render_scene_buffers.get_depth_layer(0)
    if depth_tex != depth_texture:
        depth_texture = depth_tex
        buffers_changed = true

    if buffers_changed:
        framebuf_format_changed = _build_framebuffer()

    if framebuf_format_changed or shader_changed:
        _build_pipeline()

    # Create a uniform buffer with resolution and stride
    # Update the uniform buffer with resolution (if changed)
    # get cached uniform set for stencil_copy & uniform buffer
    # draw the init stencil_copy_pipeline (stencil copy & init UV values)
    # draw finish
    # for stride in [4, 2, 1]:
    #   update the uniform buffer with stride
    #   get cached uniform set for jump flood & uniform buffer
    #   Do jump flood as a compute shader, no framebuffer!!
    #   
    #   

    var uniform_set = UniformSetCacheRD.get_cache(stencil_copy_shader, 0, [per_frame_uniform])
    # Perform the draw using the rendering stencil_copy_pipeline, and the stencil buffer
    # from the real stencil_copy_pipeline.
    assert(framebuffer.is_valid())
    assert(stencil_copy_pipeline.is_valid())
    var draw_list := rd.draw_list_begin(
        framebuffer,
        RenderingDevice.DRAW_CLEAR_COLOR_0,
        [Color.BLACK],
        1.0,
        0,
        Rect2(),
        RenderingDevice.OPAQUE_PASS)
    rd.draw_list_bind_render_pipeline(draw_list, stencil_copy_pipeline)
    rd.draw_list_bind_vertex_array(draw_list, vertex_array)
    rd.draw_list_bind_uniform_set(draw_list, uniform_set, 0)
    rd.draw_list_draw(draw_list, false, 3) # this is the 
    rd.draw_list_end()
