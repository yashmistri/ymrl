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
var aim:Vector3
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
	var mesh :MeshInstance3D = $Mesh
	
	#mesh.look_at(position+move)
	mesh.look_at(aim)
	mesh.rotation.x = 0.0
	if move:
		velocity = move * current_speed
	else:
		velocity = Vector3.ZERO

	move_and_slide()


#0.2 sec delay before attacking? slow down while attacking?
#param relative target position
#rewards attacker if attack hits by percent of targets health dealt and if attack kills
func attack(target_pos:Vector3):
	if not can_attack or is_attacking:
		return
	print("attack")
	
	if $hit:
		$hit.flash(target_pos)
	#wait 0.2 sec before attacking
	is_attacking=true
	await get_tree().create_timer(attack_startup).timeout
	is_attacking=false
	target_pos = target_pos.normalized()*attack_range
	var ray:RayCast3D= $ray
	ray.target_position = target_pos
	ray.force_raycast_update()
	var col =ray.get_collider()
	if col:
		var dmg_info:Dictionary = col.take_damage(damage)
		var percent_damage :float = dmg_info["percent_damage"]
		var is_kill:bool = dmg_info["is_kill"]
		if ai:
			ai.reward += clamp(percent_damage,-1.0,1.0)*attack_reward_factor
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
