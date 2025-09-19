extends CompositorEffect
class_name StencilBasedOutlineCompositorEffect

## Color of outlines
@export var outline_color := Color.GOLD

## Thickness of outline in pixels
@export_range(0, 181) var thickness : int= 4 :
    set(value):
        value = clampi(value, 0, 181)
        thickness = value
        _passes = 0
        while value > 0:
            value = value >> 1
            _passes += 1
        print("thickness ", thickness, ", _passes ", _passes)

## Stencil value that denotes pixels to be outlined
@export var stencil_value := 1

## Stencil mask to use when checking the stencil value
@export var stencil_mask := 1

## Enable hot-reload of shaders; only set this if you're actively editing the
## shaders.
var _hot_reload := false

## Number of jump-flood _passes to run to make the outline; automatically set
## by the thickness setter.
var _passes := 1

## GLSL shader definitions for each of our shaders
var _shader_dir = get_script().get_path().get_base_dir() + "/shaders/"
var jf_shader_file = _shader_dir + "jump_flood.glsl"
var sc_shader_file = _shader_dir + "stencil_copy.glsl"
var do_shader_file = _shader_dir + "draw_outline.glsl"

var rd: RenderingDevice

## stencil copy shader render pipeline
var sc_shader: RID
var sc_uniform_set: RID
var sc_framebuffer: RID
var sc_pipeline: RID

## draw outline render pipeline
var do_shader: RID
var do_pipeline: RID

## Vertex array for the stencil copy and draw outline pipelines
var scdo_vertex_format : int
var scdo_vertex_buffer : RID
var scdo_vertex_array : RID

## uniform buffer that contains resolution, shared between stencil copy and
## draw outline pipelines
var scdo_uniform_buffer : RID

## Jump-flood stuffs
var jf_shader: RID
var jf_pipeline: RID
var jf_uniform_sets := [RID(), RID()]

## cached copy of the color texture RID to detect when it changes
var color_texture: RID
## cached copy of the depth/stencil texture RID to detect when it changes
var depth_texture: RID
## cached render resolution; updated in _render_callback()
var resolution := Vector2i(1, 1)

## Textures used by both the stencil copy pipeline, and the jump flood pipeline
## And one random debug texture we can do whatever we want to
var _textures := [RID(), RID(), RID()]

## Exposed Texture2Ds to allow debugging of the various textures used in this
## CompositorEffect.
var debug_textures := [Texture2DRD.new(), Texture2DRD.new(), Texture2DRD.new()]

## mutex for rebuild_pipelines
var mutex := Mutex.new()
## Set when the shader is dirty and needs to be rebuilt
@export var rebuild_pipelines := true :
    set(value):
        mutex.lock()
        rebuild_pipelines = value
        mutex.unlock()

## Tracks the highest modification time for any of the shaders to trigger a
## reload
var _shader_mtime := 0

## Check if any of the shaders have been updated, and if so, kick off a rebuild
## of the pipelines
func check_for_shader_changes() -> void:
    var rebuild = false
    for path in [sc_shader_file, jf_shader_file, do_shader_file]:
        var mtime = FileAccess.get_modified_time(path)
        if mtime > _shader_mtime:
            rebuild = true
            _shader_mtime = mtime

    if rebuild:
        rebuild_pipelines = true

# Called when this resource is constructed.
func _init():
    effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_OPAQUE

    # Grab the rendering device
    rd = RenderingServer.get_rendering_device()

    ## We create the vertex & index arrays to draw a full-screen quad.

    # build the vertex format
    var vertex_attr = RDVertexAttribute.new()
    vertex_attr.location = 0
    vertex_attr.format = RenderingDevice.DATA_FORMAT_R32G32B32_SFLOAT
    vertex_attr.stride = 4 * 3
    scdo_vertex_format = rd.vertex_format_create([vertex_attr])

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
    scdo_vertex_buffer = rd.vertex_buffer_create(vertex_bytes.size(), vertex_bytes)
    scdo_vertex_array = rd.vertex_array_create(3, scdo_vertex_format, [scdo_vertex_buffer])

    # Create the uniform buffer for the screen resolution used for both the
    # stencil copy, and draw outline pipelines.  Each pipeline will have its
    # own uniform set for this buffer.
    var buffer = PackedFloat32Array([1, 1, 0, 0]).to_byte_array()
    scdo_uniform_buffer = rd.uniform_buffer_create(buffer.size(), buffer)

    ## mark ourselves as dirty so everything else is created when we know the
    ## render resolution
    rebuild_pipelines = true

# System notifications, we want to react on the notification that
# alerts us we are about to be destroyed.
func _notification(what):
    if what == NOTIFICATION_PREDELETE:
        if jf_shader.is_valid():
            # freeing the shader will free the pipeline and the uniform sets
            rd.free_rid(jf_shader)
        if sc_shader.is_valid():
            rd.free_rid(sc_shader)
        if do_shader.is_valid():
            rd.free_rid(do_shader)
        for rid in _textures:
            if rid.is_valid():
                rd.free_rid(rid)
        if scdo_vertex_buffer.is_valid():
            rd.free_rid(scdo_vertex_buffer)
        if scdo_uniform_buffer.is_valid():
            rd.free_rid(scdo_uniform_buffer)

## Load GLSL from a specific resource path
## Returns:
##  false: failed to load or compile shader
##  RDShaderSPIRV: compiled shader
func _load_glsl_from_file(path) -> Variant:
    # hot-reload of shaders via RDShaderFile does not work by default.  See
    # https://github.com/godotengine/godot/issues/110468 for details.
    if not _hot_reload:
        var shader_file: RDShaderFile = ResourceLoader.load(path)
        return shader_file.get_spirv()

    # Manually reload & compile the shader using RDShaderSource
    var lines = []
    if not FileAccess.file_exists(path):
        push_error("_load_glsl_from_file() file not found: ", path)
        return null
    
    var file = FileAccess.open(path, FileAccess.READ)
    if not file:
        push_error("_load_glsl_from_file() failed to open `", path, "`: ", FileAccess.get_open_error())
        return

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

    var spirv: RDShaderSPIRV = rd.shader_compile_spirv_from_source(source)
    if spirv.compile_error_vertex != "":
        push_error("Failed to compile shader: ", path, "\n",
                   spirv.compile_error_vertex)
        return
    if spirv.compile_error_fragment != "":
        push_error("Failed to compile shader: ", path, "\n",
                   spirv.compile_error_fragment)
        return
    if spirv.compile_error_compute != "":
        push_error("Failed to compile shader: ", path, "\n",
                   spirv.compile_error_compute)
        return
    return spirv

## build the stencil-copy render pipeline
## This pipeline is responsible for initializing the jump-flood state from the
## stencil buffer.
func _build_sc_pipeline():
    print("building stencil copy pipeline")
    if sc_shader.is_valid():
        rd.free_rid(sc_shader)
        sc_shader = RID()

    # load the shader
    var shader_spirv = _load_glsl_from_file(sc_shader_file)
    if not shader_spirv:
        push_error("failed to load stencil copy shader")
        return
    sc_shader = rd.shader_create_from_spirv(shader_spirv)
    assert(sc_shader.is_valid())

    # create the uniform set
    assert(scdo_uniform_buffer.is_valid())
    var uniform = RDUniform.new()
    uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
    uniform.binding = 0
    uniform.add_id(scdo_uniform_buffer)
    sc_uniform_set = rd.uniform_set_create([uniform], sc_shader, 0)

    # Make the framebuffer
    assert(_textures[0].is_valid())
    assert(depth_texture.is_valid())

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

    # Create the pipeline
    var blend := RDPipelineColorBlendState.new()
    var blend_attachment := RDPipelineColorBlendStateAttachment.new()
    blend.attachments.push_back(blend_attachment)

    # If the masked stencil value equals our reference value, write that
    # fragment
    var stencil_state = RDPipelineDepthStencilState.new()
    stencil_state.enable_stencil = true
    stencil_state.front_op_compare = RenderingDevice.COMPARE_OP_EQUAL
    stencil_state.front_op_compare_mask = stencil_mask
    stencil_state.front_op_reference = stencil_value
    stencil_state.front_op_fail = RenderingDevice.STENCIL_OP_KEEP
    stencil_state.front_op_pass = RenderingDevice.STENCIL_OP_KEEP
    sc_pipeline = rd.render_pipeline_create(
        sc_shader,
        format,
        scdo_vertex_format,
        RenderingDevice.RENDER_PRIMITIVE_TRIANGLES,
        RDPipelineRasterizationState.new(),
        RDPipelineMultisampleState.new(),
        stencil_state,
        blend,
    )
    assert(sc_pipeline.is_valid())

## Build the draw-outline render pipeline
## This pipeline will use the stencil buffer to draw the generated outlines
## to the frame being rendered.
func _build_do_pipeline():
    print("building draw-outline pipeline")
    if do_shader.is_valid():
        rd.free_rid(do_shader)
        do_shader = RID()

    # load the shader
    var shader_spirv = _load_glsl_from_file(do_shader_file)
    if not shader_spirv:
        push_error("failed to load stencil copy shader")
        return
    do_shader = rd.shader_create_from_spirv(shader_spirv)
    assert(do_shader.is_valid())

    do_pipeline = rd.compute_pipeline_create(do_shader)
    assert(do_pipeline.is_valid())

func _build_jf_pipeline():
    print("building jump flood pipeline")

    if jf_shader.is_valid():
        rd.free_rid(jf_shader)
        jf_shader = RID()

    # load the jump-flood shader
    var shader_spirv = _load_glsl_from_file(jf_shader_file)
    if not shader_spirv:
        push_error("failed to load jump flood shader")
        return
    jf_shader = rd.shader_create_from_spirv(shader_spirv)
    assert(jf_shader.is_valid())

    # build the pipeline
    jf_pipeline = rd.compute_pipeline_create(jf_shader)
    assert(jf_pipeline.is_valid())

    # now build the uniform sets we'll use through the _passes
    assert(_textures[0].is_valid())
    assert(_textures[1].is_valid())
    for group in [[0, _textures[0], _textures[1]],
                  [1, _textures[1], _textures[0]]]:
        var pass_number = group[0]
        var src_texture = group[1]
        var dest_texture = group[2]

        # clear the pass uniform sets; they were already freed when the shader
        # was destroyed.
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

## Create a new color texture to use as the output for our render sc_pipeline.
## Note: this texture must be the same size as the depth texture, so we create
## it on demand.
func _build_textures():
    var count = _textures.size()
    print("building ", count, " output textures ", resolution)

    # set up the texture format
    var texture_format = RDTextureFormat.new()
    texture_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
    texture_format.width = resolution.x
    texture_format.height = resolution.y
    # XXX may need to explore proper format to use here.
    texture_format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
    # texture_format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
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

## Update uniform buffer shared between the stencil-copy and draw-outline
## pipelines
func _update_common_buffers():
    print("updating common uniform buffer");
    assert(scdo_uniform_buffer.is_valid())

    # update the render resolution
    var buffer = PackedFloat32Array([resolution.x, resolution.y, 0, 0]).to_byte_array()
    rd.buffer_update(scdo_uniform_buffer, 0, buffer.size(), buffer)

# Called by the rendering thread every frame.
func _render_callback(_p_effect_callback_type, p_render_data):
    var rebuild := false

    if not rd:
        return

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

    # check if shaders are dirty; if so rebuild
    if rebuild_pipelines:
        mutex.lock()
        rebuild_pipelines = false
        mutex.unlock()
        rebuild = true

    # Build the output texture the same size as the render resolution.
    # Note: the output texture must be the same size as the render resolution
    #       because the texture and depth texture must be the same resolution
    #       to create a sc_framebuffer later.  If they are not the same size, we
    #       get an error in _build_framebuffer()
    if resolution != size:
        resolution = size
        rebuild = true

    # if the depth texture has changed, we'll need to rebuild the pipelines
    var color_tex = render_scene_buffers.get_color_layer(0)
    if color_tex != color_texture:
        color_texture = color_tex
        rebuild = true

    # if the depth texture has changed, we'll need to rebuild the pipelines
    var depth_tex = render_scene_buffers.get_depth_layer(0)
    if depth_tex != depth_texture:
        depth_texture = depth_tex
        rebuild = true


    if rebuild:
        _build_textures()
        _update_common_buffers()
        _build_sc_pipeline()
        _build_jf_pipeline()
        _build_do_pipeline()

    # Perform the draw using the rendering sc_pipeline, and the stencil buffer
    # from the real render pipeline.
    var draw_list := rd.draw_list_begin(
        sc_framebuffer,
        RenderingDevice.DRAW_CLEAR_COLOR_0,
        [Color(-1, -1, 2**15, -1)],
        1.0,
        0,
        Rect2(),
        RenderingDevice.OPAQUE_PASS)
    rd.draw_list_bind_render_pipeline(draw_list, sc_pipeline)
    rd.draw_list_bind_vertex_array(draw_list, scdo_vertex_array)
    rd.draw_list_bind_uniform_set(draw_list, sc_uniform_set, 0)
    rd.draw_list_draw(draw_list, false, 3) # this is the 
    rd.draw_list_end()

    # Create our group counts for the next two compute shaders: jump-flood, and
    # draw-outlines
    @warning_ignore("integer_division")
    var x_groups : int = (resolution.x - 1) / 8 + 1
    @warning_ignore("integer_division")
    var y_groups : int = (resolution.y - 1) / 8 + 1
    var push_constant := PackedByteArray()
    push_constant.resize(16) # Must be a multiple of 16 bytes

    # Run the jump-flood pipeline the required number of passes, swapping the
    # textures between each pass.
    var compute_list := rd.compute_list_begin()
    rd.compute_list_bind_compute_pipeline(compute_list, jf_pipeline)

    for i in range(_passes):
        var stride = (1<<(_passes-i-1))
        push_constant.encode_u32(0, stride)
        rd.compute_list_set_push_constant(compute_list, push_constant, push_constant.size())

        # pick the uniform set based on the pass number so we ping-pong between
        # the two textures.
        rd.compute_list_bind_uniform_set(
            compute_list,
            jf_uniform_sets[i & 0x1],
            0)
        rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)

    rd.compute_list_end()


    # next we run the draw outline pipeline

    # Because the color layer can vanish during resize, we just create the
    # uniform set here.
    # XXX need to open an issue about resizing debounce because the depth and
    # color textures can be freed underneath you during resize.
    var src_uniform := RDUniform.new()
    src_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
    src_uniform.binding = 0
    src_uniform.add_id(_textures[_passes & 0x1])
    var dest_uniform = RDUniform.new()
    dest_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
    dest_uniform.binding = 1
    dest_uniform.add_id(color_texture)
    var uniform_set = UniformSetCacheRD.get_cache(do_shader, 0, [src_uniform, dest_uniform])
    assert(uniform_set.is_valid())

    # construct the push constant for drawing our outlines.  It contains the
    # outline color, and the outline thickness squared
    var do_push_constant = PackedByteArray()
    do_push_constant.resize(32)
    do_push_constant.encode_float(0, outline_color.r)
    do_push_constant.encode_float(4, outline_color.g)
    do_push_constant.encode_float(8, outline_color.b)
    do_push_constant.encode_float(12, outline_color.a)
    do_push_constant.encode_u32(16, thickness**2)

    compute_list = rd.compute_list_begin()
    rd.compute_list_bind_compute_pipeline(compute_list, do_pipeline)
    rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
    rd.compute_list_set_push_constant(compute_list, do_push_constant, do_push_constant.size())
    rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
    rd.compute_list_end()
