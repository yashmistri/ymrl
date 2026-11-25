extends Node3D

@export var show_placeholder_mesh: bool = false

func flash(aim: Vector3):
	var flat := Vector3(aim.x, global_position.y, aim.z)
	if flat.distance_squared_to(global_position) > 0.000001:
		look_at(flat)
	if show_placeholder_mesh:
		await get_tree().create_timer(0.2).timeout
		visible = true
		await get_tree().create_timer(0.1).timeout
		visible = false
	else:
		visible = false
