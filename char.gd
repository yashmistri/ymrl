extends CharacterBody2D
class_name Char

var speed_stat = 100.0

var current_speed:float
var damage:float = 10.0
var max_health:float = 100.0
var current_health:float
var move:Vector2
var attack_range:float =20.0
var attack_cd:float=1.0
var can_attack:bool=true

@onready var ai: AIController2D = $AI
func _ready():
	current_speed = speed_stat
	current_health = max_health

func _physics_process(delta: float) -> void:
	if is_queued_for_deletion():
		return
	move = move.limit_length()
	if move:
		velocity = move * current_speed
	else:
		velocity = Vector2.ZERO

	move_and_slide()

#0.2 sec delay before attacking? slow down while attacking?
#param relative target position
#returns true if attack kills target
func attack(target_pos:Vector2)-> bool:
	var is_kill:=false
	if not can_attack:
		return is_kill
	target_pos = target_pos.normalized()*attack_range
	var ray:RayCast2D= $ray
	ray.target_position = target_pos
	ray.force_raycast_update()
	var col =$ray.get_collider()
	if col:
		is_kill = col.take_damage(damage)
		print("hit target")
	can_attack = false
	start_attack_cd()
	if is_kill and ai:
		ai.reward += 1.0
	return is_kill

func start_attack_cd():
	await get_tree().create_timer(attack_cd).timeout
	can_attack=true

#return true if char dies after taking this damage
func take_damage(damage) -> bool:
	if is_queued_for_deletion():
		return false
	current_health = clamp(current_health-damage,0.0,max_health)
	if current_health == 0.0:
		die()
		return true
	return false

func die():
	print("die")
	queue_free()
