extends Node3D

@onready var fill: MeshInstance3D = $Fill

var bar_width: float
var fill_material: StandardMaterial3D

func _ready() -> void:
	bar_width = (fill.mesh as QuadMesh).size.x
	fill_material = (fill.get_surface_override_material(0) as StandardMaterial3D).duplicate()
	fill.set_surface_override_material(0, fill_material)

func _process(_delta: float) -> void:
	if not is_visible_in_tree():
		return
	_face_camera()
	var body := get_parent() as Char3
	if body == null or body.max_health <= 0.0:
		return
	var ratio := clampf(body.current_health / body.max_health, 0.0, 1.0)
	fill.visible = ratio > 0.0
	if ratio <= 0.0:
		return
	fill.scale.x = ratio
	fill.position.x = (ratio - 1.0) * bar_width * 0.5
	fill_material.albedo_color = Color(1.0 - ratio, ratio, 0.05)

func _face_camera() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var to_cam := cam.global_position - global_position
	if to_cam.length_squared() < 0.0001:
		return
	if absf(to_cam.normalized().dot(Vector3.UP)) > 0.999:
		return
	look_at(cam.global_position, Vector3.UP)
	# QuadMesh faces +Z. look_at aims -Z at the camera, so turn around.
	rotate_object_local(Vector3.UP, PI)
