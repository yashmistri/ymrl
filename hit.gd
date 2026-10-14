extends Node3D

func flash(aim:Vector3):
	look_at(position+aim)
	rotation.x = 0.0
	await get_tree().create_timer(0.2).timeout
	visible = true
	await get_tree().create_timer(0.1).timeout
	visible = false
