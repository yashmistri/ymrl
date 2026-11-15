extends Node3D

func flash(aim:Vector3):
	# aim is a global point. look_at expects one; position+aim does not face it.
	var flat := Vector3(aim.x, global_position.y, aim.z)
	if flat.distance_squared_to(global_position) > 0.000001:
		look_at(flat)
	await get_tree().create_timer(0.2).timeout
	visible = true
	await get_tree().create_timer(0.1).timeout
	visible = false
