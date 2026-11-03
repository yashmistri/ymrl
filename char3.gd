extends CharacterBody3D
class_name Char3

var speed_stat = 3.0

var current_speed:float
var damage:float = 10.0
var max_health:float = 100.0
var current_health:float
var move:Vector3
var attack_range:float =1.0
var attack_cd:float=0.7
var attack_startup:float=0.4
var can_attack:bool=true
var is_attacking:bool=false
var aim:Vector3=Vector3.FORWARD
static var attack_reward_factor:float = 1.0
static var damage_punish_factor:float = 1.0

var is_dead:bool=false
@onready var ai: AIController3D = find_child("AI")
func _ready():
	current_speed = speed_stat
	current_health = max_health

func _physics_process(delta: float) -> void:
	if is_dead:
		return
	
	move = move.normalized()
	var mesh: MeshInstance3D = $Mesh

	# aim is a global point (cursor hit, target.global_position).
	var forward := aim - global_position
	forward.y = 0.0
	if forward.length_squared() > 0.000001:
		forward = forward.normalized()
		# look_at points the mesh's -Z at this point, so facing matches forward.
		mesh.look_at(global_position + forward)
	else:
		forward = -mesh.global_basis.z
		forward.y = 0.0
		if forward.length_squared() > 0.000001:
			forward = forward.normalized()
		else:
			forward = Vector3.FORWARD

	if move:
		# Facing -Z, right is +X: forward (0, 0, -1) -> right (1, 0, 0).
		var right := Vector3(-forward.z, 0.0, forward.x)
		# move.x: strafe, + is right. move.z: W is -1 (toward aim), S is +1.
		velocity = (right * move.x - forward * move.z) * current_speed
	else:
		velocity = Vector3.ZERO

	move_and_slide()


# Startup delay, then a ray of length attack_range.
# target_pos is a global point (cursor hit or target.global_position).
# Rewards the attacker by the fraction of health dealt, and on a kill.
func attack(target_pos:Vector3):
	if not can_attack or is_attacking:
		return
	print("{0} attack".format([name]))

	if $hit:
		$hit.flash(target_pos)
	is_attacking = true
	await get_tree().create_timer(attack_startup).timeout
	if not is_inside_tree():
		return
	is_attacking = false

	# The body is not rotated toward aim; only the mesh is. RayCast3D.target_position
	# is local to the ray. Normalizing a world position aims from the world origin,
	# so the ray hits only when this body happens to stand on that line.
	# Cast from here toward the current aim. Check: aim one unit on +Z, unrotated
	# ray -> target_position (0, 0, attack_range).
	var to_target := aim - global_position
	var ray: RayCast3D = $ray
	if to_target.length_squared() > 0.000001:
		ray.target_position = ray.global_basis.inverse() * to_target.normalized() * attack_range
		ray.force_raycast_update()
		var col = ray.get_collider()
		if col:
			var dmg_info: Dictionary = col.take_damage(damage)
			var percent_damage: float = dmg_info["percent_damage"]
			var is_kill: bool = dmg_info["is_kill"]
			if ai:
				ai.reward += clamp(percent_damage, -1.0, 1.0) * attack_reward_factor
				ai.reward += 10.0 if is_kill else 0.0
			print("hit target")
	can_attack = false
	start_attack_cd()
	return

func start_attack_cd():
	await get_tree().create_timer(attack_cd).timeout
	can_attack=true


#returns dictionary with two values:
#true if taking this damage causes death
#percent of targets health removed by attack
func take_damage(damage:float) -> Dictionary:
	var is_kill = false
	if is_queued_for_deletion():
		return {"is_kill": is_kill,"percent_damage": 0.0}
	var percent_damage:float = damage/current_health
	current_health = clamp(current_health-damage,0.0,max_health)
	
	if ai:
		ai.reward -= clamp(percent_damage,-1.0,1.0)*damage_punish_factor
	if current_health == 0.0:
		die()
		is_kill = true
	return {"is_kill": is_kill,"percent_damage": percent_damage}

func die():
	print("die")
	is_dead=true
	queue_free()
