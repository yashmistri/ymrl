extends Char3


var requested_move:Vector2
var is_running:bool=false
var spawn_pos:Vector3
var target:Node3D
func _ready():
	spawn_pos = global_position
	attack_range = 0.7
	speed_stat = 4.0
	if ai:
		ai.init(self)
	$hit.visible = false
	super._ready()

func respawn():
	global_position = spawn_pos
	current_health = max_health
	is_dead = false
	ai.done=false
	visible = true


func _physics_process(delta: float) -> void:
	if is_dead:
		return
	move= Vector3.ZERO
	if target:
		move = position.direction_to(target.position).normalized()
		aim = target.position
	if position.distance_to(target.position) < 1.1 * attack_range:
		attack(aim)
		print("zombie attack")
	is_running = move.length() > 0.5
	var run := (2.0 if is_running else 1.0)
	var attack_slow := (0.5 if is_attacking else 1.0)
	current_speed = speed_stat * run * attack_slow
	super._physics_process(delta)

func die():
	is_dead = true
	visible = false
	print("zombie die")
	queue_free()
func swing():
	pass
