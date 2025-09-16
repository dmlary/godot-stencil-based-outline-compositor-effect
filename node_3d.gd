extends Node3D

@export var texture_rect: TextureRect
@export var texture_rect2: TextureRect
@export var camera: Camera3D
@export var mesh: MeshInstance3D

## Grab the CompositorEffect from the camera
@onready var outline_effect = camera.compositor.compositor_effects[0]

## Tracking the last modification time of the shader file; used in _process()
var _shader_mtime := 0
var timer : Timer

func _ready():
    # set the texture in the TextureRect to use the output texture of the
    # CompositorEffect
    texture_rect.texture = outline_effect.debug_textures[0]
    texture_rect2.texture = outline_effect.debug_textures[1]

    # create a timer to check for changes to the shader source file
    timer = Timer.new()
    timer.wait_time = 0.3
    timer.timeout.connect(_check_shader)
    timer.autostart = true
    add_child(timer)

func _check_shader() -> void:
    # Check to see if the shader file has been modified.  If so, mark the
    # shader as dirty so the CompositorEffect can reload it.
    var mtime = FileAccess.get_modified_time(outline_effect.glsl_shader_file)
    if mtime > _shader_mtime:
        print("shader updated")
        outline_effect.jf_shader_dirty = true
        _shader_mtime = mtime
