extends Node3D

@export var fps_label: Label
@export var thickness_label: Label
@export var thickness_slider: HSlider
@export var color_picker: ColorPickerButton
@export var texture_rect: TextureRect
@export var texture_rect2: TextureRect
@export var camera: Camera3D
@export var arm: Node3D
@export var rotation_speed := 13.0

## Grab the CompositorEffect from the camera
@onready var outline_effect: StencilBasedOutlineCompositorEffect = camera.compositor.compositor_effects[0]

## Tracking the last modification time of the shader file; used in _process()
var timer : Timer

func _ready():
    thickness_slider.value = outline_effect.thickness
    thickness_slider.value_changed.connect(_on_thickness_changed)
    color_picker.color = outline_effect.outline_color
    color_picker.color_changed.connect(func(color): outline_effect.outline_color = color)

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

func _process(delta):
    arm.rotate_y(rotation_speed * delta)
    fps_label.text = "%.02f" % Engine.get_frames_per_second()

func _check_shader() -> void:
    outline_effect.check_for_shader_changes()

func _on_thickness_changed(value: float):
    thickness_label.text = str(int(value))
    outline_effect.thickness = int(value)
