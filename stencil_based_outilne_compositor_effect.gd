extends CompositorEffect
class_name StencilBasedOutlineCompositorEffect

## Number of jump-flood passes to run to make the outline
@export var passes := 4

## GLSL sc_shader source file
@export_file("*.glsl") var glsl_shader_file = "res://./jump_flood.glsl"

var rd: RenderingDevice

## Vertex array for the stencil copy render pipeline
var sc_vertex_format : int
var sc_vertex_buffer : RID
var sc_vertex_array : RID

## stencil copy shader
var sc_shader: RID

## uniform buffer and set for stencil copy shader
var sc_uniform_buffer : RID
var sc_uniform_set: RID

## framebuffer used for the stencil copy render pipeline
var sc_framebuffer: RID
var sc_framebuffer_format: int

## stencil copy render pipeline
var sc_pipeline: RID

## Jump-flood stuffs
var jf_shader: RID
var jf_pipeline: RID
var jf_uniform_sets := [RID(), RID()]

## cached copy of the depth/stencil texture RID to detect when it changes
var depth_texture: RID
## cached render resolution; updated in _render_callback()
var resolution := Vector2i(1, 1)

## Textures used by both the stencil copy pipeline, and the jump flood pipeline
var _textures := [RID(), RID()]

## Exposed Texture2Ds to allow debugging of the various textures used in this
## CompositorEffect.
var debug_textures := [Texture2DRD.new(), Texture2DRD.new()]

## mutex for jf_shader_dirty
var mutex := Mutex.new()
## Set when the shader is dirty and needs to be rebuilt
@export var jf_shader_dirty := true :
    set(value):
        mutex.lock()
        jf_shader_dirty = value
        mutex.unlock()

# Called when this resource is constructed.
func _init():
    effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_OPAQUE

    # Grab the rendering device
    rd = RenderingServer.get_rendering_device()

    _build_sc_shader()
    ## We create the vertex & index arrays to draw a full-screen quad.

    # build the vertex format
    var vertex_attr = RDVertexAttribute.new()
    vertex_attr.location = 0
    vertex_attr.format = RenderingDevice.DATA_FORMAT_R32G32B32_SFLOAT
    vertex_attr.stride = 4 * 3
    sc_vertex_format = rd.vertex_format_create([vertex_attr])

    # These vertex points make a triangle that cover the entire screen.  The
    # points are declared in counter-clockwise winding order so that the front
    # of the quad is facing the camera.  This is important for the stencil
    # operations set in _build_sc_pipeline(), as we only set stencil front_ops.
    var vertex_data = PackedVector3Array([
        Vector3(-1, -1, 0),
        Vector3(3, -1, 0),
        Vector3(-1, 3, 0),
    ])
    var vertex_bytes = vertex_data.to_byte_array()
    sc_vertex_buffer = rd.vertex_buffer_create(vertex_bytes.size(), vertex_bytes)
    sc_vertex_array = rd.vertex_array_create(3, sc_vertex_format, [sc_vertex_buffer])

    # create uniform buffer and set for 
    var buffer = PackedFloat32Array([1, 1, 0, 0]).to_byte_array()
    sc_uniform_buffer = rd.uniform_buffer_create(buffer.size(), buffer)
    var uniform = RDUniform.new()
    uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
    uniform.binding = 0
    uniform.add_id(sc_uniform_buffer)
    sc_uniform_set = rd.uniform_set_create([uniform], sc_shader, 0)

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
    source.source_compute = ""

    var type = null
    for line in lines:
        if line == "#[vertex]":
            type = "vertex"
        elif line == "#[fragment]":
            type = "fragment"
        elif line == "#[compute]":
            type = "compute"
        elif type == "vertex":
            source.source_vertex += line + "\n"
        elif type == "fragment":
            source.source_fragment += line + "\n"
        elif type == "compute":
            source.source_compute += line + "\n"

    return source

func _build_sc_shader():
    print("building stencil copy shader")

    # load the sc_shader
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
            frag_color.rgba = vec4(UV.x, UV.y, 0, 1);
        }
    """
    var shader_spirv: RDShaderSPIRV = rd.shader_compile_spirv_from_source(source)
    if shader_spirv.compile_error_vertex != "":
        push_error(shader_spirv.compile_error_vertex)
        return
    if shader_spirv.compile_error_fragment != "":
        push_error(shader_spirv.compile_error_fragment)
        return
    sc_shader = rd.shader_create_from_spirv(shader_spirv)

func _update_sc_uniform_buffer(size: Vector2i):
    print("updating scene-copy uniform buffer");
    assert(sc_uniform_buffer.is_valid())
    var buffer = PackedFloat32Array([size.x, size.y, 0, 0]).to_byte_array()
    rd.buffer_update(sc_uniform_buffer, 0, buffer.size(), buffer)
    sc_uniform_buffer = rd.uniform_buffer_create(buffer.size(), buffer)


func _build_jf_shader_and_pipeline():
    print("rebuilding jump flood shader")

    mutex.lock()
    jf_shader_dirty = false
    mutex.unlock()

    if jf_shader.is_valid():
        rd.free_rid(jf_shader)
        jf_shader = RID()
        # freeing the jf_shader will also free the jf_pipeline that was
        # dependent on the shader
        jf_pipeline = RID()

    # load the jf_shader
    var shader_source = _load_glsl_from_file(glsl_shader_file)
    if not shader_source:
        push_error("failed to load jf_shader source: ", glsl_shader_file)
        return
    var shader_spirv: RDShaderSPIRV = rd.shader_compile_spirv_from_source(shader_source)
    if shader_spirv.compile_error_vertex != "":
        push_error(shader_spirv.compile_error_vertex)
        return
    if shader_spirv.compile_error_fragment != "":
        push_error(shader_spirv.compile_error_fragment)
        return
    jf_shader = rd.shader_create_from_spirv(shader_spirv)
    assert(jf_shader.is_valid())
    jf_pipeline = rd.compute_pipeline_create(jf_shader)

func _build_jf_uniform_sets():
    # not explicitly freeing the old sets here because they should have been
    # freed when the shader or textures were freed

    for group in [[0, _textures[0], _textures[1]],
                  [1, _textures[1], _textures[0]]]:
        var pass_number = group[0]
        var src_texture = group[1]
        var dest_texture = group[2]

        # clear the pass uniform sets
        jf_uniform_sets[pass_number] = [RID(), RID()]

        var src_uniform := RDUniform.new()
        src_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
        src_uniform.binding = 0
        src_uniform.add_id(src_texture)

        var dest_uniform = RDUniform.new()
        dest_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
        dest_uniform.binding = 1
        dest_uniform.add_id(dest_texture)

        jf_uniform_sets[pass_number] = rd.uniform_set_create(
            [src_uniform, dest_uniform], jf_shader, 0)

# System notifications, we want to react on the notification that
# alerts us we are about to be destroyed.
func _notification(what):
    if what == NOTIFICATION_PREDELETE:
        if jf_shader.is_valid():
            # freeing the shader will free the pipeline and the uniform sets
            rd.free_rid(jf_shader)
        if sc_pipeline.is_valid():
            rd.free_rid(sc_pipeline)
        if sc_shader.is_valid():
            rd.free_rid(sc_shader)
        if sc_framebuffer.is_valid():
            rd.free_rid(sc_framebuffer)
        for rid in _textures:
            if rid.is_valid():
                rd.free_rid(rid)
        if sc_vertex_array.is_valid():
            rd.free_rid(sc_vertex_array)
        if sc_vertex_buffer.is_valid():
            rd.free_rid(sc_vertex_buffer)

## Create the render sc_pipeline.
func _build_sc_pipeline():
    print("building sc_pipeline")
    if sc_pipeline.is_valid():
        rd.free_rid(sc_pipeline)
        sc_pipeline = RID()

    #create the sc_pipeline
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

    sc_pipeline = rd.render_pipeline_create(
        sc_shader,
        sc_framebuffer_format,
        sc_vertex_format,
        RenderingDevice.RENDER_PRIMITIVE_TRIANGLES,
        RDPipelineRasterizationState.new(),
        RDPipelineMultisampleState.new(),
        stencil_state, # RDPipelineDepthStencilState.new(),
        blend,
    )
    assert(sc_pipeline.is_valid())

## Create a new color texture to use as the output for our render sc_pipeline.
## Note: this texture must be the same size as the depth texture, so we create
## it on demand.
func _build_textures(size: Vector2i):
    var count = _textures.size()
    print("building ", count, " output textures ", size)


    # set up the texture format
    var texture_format = RDTextureFormat.new()
    texture_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
    texture_format.width = size.x
    texture_format.height = size.y
    # XXX may need to explore proper format to use here.
    texture_format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
    texture_format.usage_bits = (
        RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT |
        RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
        RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
        RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
    )

    var texture_view = RDTextureView.new()

    # build the new texture buffers
    for i in range(count):
        var rid: RID = rd.texture_create(texture_format, texture_view)
        assert(rid.is_valid())

        # Save off the old rid to be freed after we swap the value in the debug
        # texture.  If we don't do this, the debug textures will flicker.
        var old_rid: RID = _textures[i]

        # update the rids
        _textures[i] = rid
        debug_textures[i].texture_rd_rid = rid

        if old_rid.is_valid():
            rd.free_rid(old_rid)

## Build a sc_framebuffer using the color texture and supplied depth texture.
## This function will return true if the format of the sc_framebuffer changed,
## which means we need to rebuild the sc_pipeline.
func _build_framebuffer() -> bool:
    print("building sc_framebuffer for depth texture ", depth_texture)
    if sc_framebuffer.is_valid():
        rd.free_rid(sc_framebuffer)
        sc_framebuffer = RID()

    if not depth_texture.is_valid():
        return false

    var attachments = []
    var attachment_format = RDAttachmentFormat.new()

    # Add the draw texture format to the sc_framebuffer attachments
    var texture_format = rd.texture_get_format(_textures[0])
    attachment_format.format = texture_format.format
    attachment_format.usage_flags = texture_format.usage_bits
    attachment_format.samples = RenderingDevice.TEXTURE_SAMPLES_1
    attachments.push_back(attachment_format)

    # Add the depth texture format to the sc_framebuffer attachments
    var depth_format = rd.texture_get_format(depth_texture)
    attachment_format = RDAttachmentFormat.new()
    attachment_format.format = depth_format.format
    attachment_format.usage_flags = depth_format.usage_bits
    attachment_format.samples = RenderingDevice.TEXTURE_SAMPLES_1
    attachments.push_back(attachment_format)

    var format = rd.framebuffer_format_create(attachments)
    sc_framebuffer = rd.framebuffer_create([_textures[0], depth_texture], format)
    assert(sc_framebuffer.is_valid())

    var out = format != sc_framebuffer_format
    sc_framebuffer_format = format
    return out 

# Called by the rendering thread every frame.
func _render_callback(_p_effect_callback_type, p_render_data):
    var buffers_changed := false
    var framebuf_format_changed := false
    var jf_shader_changed := false

    if not rd:
        return
    if not sc_shader.is_valid():
        return

    # build the jump-flood shader
    if jf_shader_dirty or not jf_pipeline.is_valid():
        _build_jf_shader_and_pipeline()
        jf_shader_changed = true

    # XXX need to recreate jump-flood uniform sets when:
    # - jump flood shader changes
    # - textures are resized

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
    #       to create a sc_framebuffer later.  If they are not the same size, we
    #       get an error in _build_framebuffer()
    if not _textures[0].is_valid() or resolution != size:
        resolution = size
        _build_textures(size)
        _update_sc_uniform_buffer(size)
        buffers_changed = true

    # if the depth texture has changed, we'll need to rebuild the sc_framebuffer
    var depth_tex = render_scene_buffers.get_depth_layer(0)
    if depth_tex != depth_texture:
        depth_texture = depth_tex
        buffers_changed = true

    if buffers_changed:
        framebuf_format_changed = _build_framebuffer()

    if framebuf_format_changed:
        _build_sc_pipeline()

    if buffers_changed or jf_shader_changed:
        _build_jf_uniform_sets()


    # Perform the draw using the rendering sc_pipeline, and the stencil buffer
    # from the real sc_pipeline.
    assert(sc_framebuffer.is_valid())
    assert(sc_pipeline.is_valid())

    var draw_list := rd.draw_list_begin(
        sc_framebuffer,
        RenderingDevice.DRAW_CLEAR_COLOR_0,
        [Color.TRANSPARENT],
        1.0,
        0,
        Rect2(),
        RenderingDevice.OPAQUE_PASS)
    rd.draw_list_bind_render_pipeline(draw_list, sc_pipeline)
    rd.draw_list_bind_vertex_array(draw_list, sc_vertex_array)
    rd.draw_list_bind_uniform_set(draw_list, sc_uniform_set, 0)
    rd.draw_list_draw(draw_list, false, 3) # this is the 
    rd.draw_list_end()

    @warning_ignore("integer_division")
    var x_groups : int = (resolution.x - 1) / 8 + 1
    @warning_ignore("integer_division")
    var y_groups : int = (resolution.y - 1) / 8 + 1
    var push_constant := PackedByteArray()
    push_constant.resize(16) # minimum size



    # XXX next steps:
    # - create new rendering pipeline to draw outline for only those pixels not
    #   marked for outline in the stencil buffer
    # XXX Maybe write the outline back to the color layer instead of an output
    #     texture that needs to be hooked to a colorRect.

    var compute_list := rd.compute_list_begin()
    rd.compute_list_bind_compute_pipeline(compute_list, jf_pipeline)

    for i in range(passes):
        var stride = (1<<(passes-i-1))
        push_constant.encode_u32(0, stride)
        rd.compute_list_set_push_constant(compute_list, push_constant, push_constant.size())

        var uniform_set = jf_uniform_sets[i & 0x1]
        rd.compute_list_bind_uniform_set(
            compute_list,
            uniform_set,
            0)
        rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)

    rd.compute_list_end()
