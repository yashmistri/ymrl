extends Char3


var requested_move:Vector2
var is_running:bool=false
var spawn_pos:Vector3
var target:Node3D
func _ready():
	spawn_pos = global_position
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
		aim = target.global_position
		move = Vector3(0.0, 0.0, -1.0)
	if position.distance_to(target.position) < 1.1 * attack_range:
		attack()
	is_running = move.length() > 0.5
	var run := (2.0 if is_running else 1.0)
	var attack_slow := (0.5 if is_attacking else 1.0)
	current_speed = speed_stat * run * attack_slow
	super._physics_process(delta)

func take_damage(damage:float, attacker: Node3D = null) -> Dictionary:
	var info: Dictionary = super.take_damage(damage, attacker)
	if info["is_kill"] and attacker == target:
		var arena: Node = get_parent()
		if arena and arena.has_method("zombie_killed_by_soldier"):
			arena.zombie_killed_by_soldier()
	return info

func die():
	is_dead = true
	visible = false
	print("zombie die")
	queue_free()
func swing():
	pass
