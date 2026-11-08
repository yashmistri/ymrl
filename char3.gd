extends CharacterBody3D
class_name Char3

@export var speed_stat = 3.0

const STRAFE_SPEED:float = 0.75
var current_speed:float
@export var damage:float = 10.0
var max_health:float = 100.0
var current_health:float
var move:Vector3
@export var attack_range:float =1.0
var attack_cd:float=0.7
var attack_startup:float=0.4
var can_attack:bool=true
var is_attacking:bool=false
var aim:Vector3=Vector3.FORWARD

var is_dead:bool=false
@onready var ai: AIController3D = find_child("AI")

# Combat logging is rate limited: a training run at 10x speedup fires hundreds
# of attacks per second, and an unthrottled print() floods the console and can
# dominate frame time. Set debug_logging = true on the node to see every event.
@export var debug_logging: bool = false
const DEBUG_LOG_INTERVAL_MSEC: int = 1000
var _debug_log_last_msec: Dictionary = {}

# Prints at most once per DEBUG_LOG_INTERVAL_MSEC per `tag`. With
# debug_logging on, every call prints.
func debug_log(tag: String, message: String) -> void:
	if debug_logging:
		print(message)
		return
	var now := Time.get_ticks_msec()
	var last: int = _debug_log_last_msec.get(tag, -DEBUG_LOG_INTERVAL_MSEC)
	if now - last < DEBUG_LOG_INTERVAL_MSEC:
		return
	_debug_log_last_msec[tag] = now
	print(message)

func _ready():
	current_speed = speed_stat
	current_health = max_health

func _physics_process(delta: float) -> void:
	if is_dead:
		return
	
	#move = move.normalized()
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
		# strafing 0.75 and backpedaling 0.5 of speed
		if move.z > 0.0:
			move.z *= 0.5
		velocity = (right * move.x * STRAFE_SPEED - forward * move.z) * current_speed
	else:
		velocity = Vector3.ZERO

	move_and_slide()


# Startup delay, then a ray of length attack_range.
# target_pos is a global point (cursor hit or target.global_position).
func attack():
	if not can_attack or is_attacking:
		return
	debug_log("attack", "{0} attack".format([name]))

	if $hit:
		$hit.flash(aim)
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
			var dmg_info: Dictionary = col.take_damage(damage, self)
			var percent_damage: float = dmg_info["percent_damage"]
			var is_kill: bool = dmg_info["is_kill"]
			_on_attack_landed(percent_damage, is_kill)
			debug_log("hit", "{0} hit target".format([name]))
	can_attack = false
	start_attack_cd()
	return

func start_attack_cd():
	await get_tree().create_timer(attack_cd).timeout
	can_attack=true

func _on_attack_landed(_percent_damage: float, _is_kill: bool) -> void:
	pass

#returns dictionary with two values:
#true if taking this damage causes death
#percent of targets health removed by attack
func take_damage(damage:float, _attacker: Node3D = null) -> Dictionary:
	var is_kill = false
	if is_queued_for_deletion():
		return {"is_kill": is_kill,"percent_damage": 0.0}
	var percent_damage:float = damage/current_health
	current_health = clamp(current_health-damage,0.0,max_health)
	_on_damage_taken(percent_damage)
	if current_health == 0.0:
		die()
		is_kill = true
	return {"is_kill": is_kill,"percent_damage": percent_damage}

func _on_damage_taken(_percent_damage: float) -> void:
	pass

func die():
	debug_log("die", "{0} die".format([name]))
	is_dead=true
	queue_free()
