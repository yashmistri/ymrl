extends Node3D

@onready var cam:Camera3D = $Camera3D
@onready var zombie:PackedScene = load("res://zombie3.tscn")
@onready var spawn_point:PathFollow3D = $SpawnPath/SpawnPoint

func _ready():
	spawn()
	$SpawnTimer.start()

func reset():
	
	for s in find_children("Soldier*"):
		s.respawn()
	for z in find_children("Zombie*"):
		z.die()

func _physics_process(delta: float) -> void:
	$Cursor.position = get_cursor_position()
	#print($Cursor.position)

func get_cursor_position() -> Vector3:
	var out:Vector3=Vector3.ZERO
	const RAY_LENGTH = 10000.0
	var space_state = get_world_3d().direct_space_state
	var mousepos = get_viewport().get_mouse_position()
	var origin = cam.project_ray_origin(mousepos)
	var end = origin + cam.project_ray_normal(mousepos) * RAY_LENGTH
	var query:PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(origin, end)
	query.collision_mask = 0b01
	var result = space_state.intersect_ray(query)
	if result:
		var collision_object = result.collider
		out = result.position
		#print(collision_object.name)
	return out

func spawn():
	var z = zombie.instantiate()
	spawn_point.progress_ratio = randf()
	z.position = spawn_point.global_position
	z.target = $Soldier
	add_child(z)

func _on_episode_timer_timeout() -> void:
	reset()


func _on_spawn_timer_timeout() -> void:
	spawn()
