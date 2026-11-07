extends Char3

signal got_hit(percent_damage: float)
signal died
signal hit_enemy(percent_damage: float)
signal killed_enemy
signal blocked_attack(percent_blocked: float)

const ATTACK_STAMINA_COST:float = 20.0
const SPRINT_STAMINA_PER_SEC:float = 10.0
const BLOCKED_HIT_STAMINA:float = 10.0
const STAMINA_REGEN_PER_SEC:float = 10.0
const STAMINA_REGEN_DELAY:float = 2.0
# Attacks from inside this frontal arc are halved while blocking.
const BLOCK_ARC_DEGREES:float = 120.0
const BLOCK_SPEED_SCALE:float = 0.5

var max_stamina:float = 100.0
var current_stamina:float

var requested_move:Vector2
var requested_turn:float
var requested_sprint:bool
var requested_block:bool
@export
var turn_speed:float = 1.0
var is_running:bool=false
var is_blocking:bool=false
var spawn_pos:Vector3
var _time_since_stamina_use:float = STAMINA_REGEN_DELAY
var _shield: MeshInstance3D

func _ready():
	spawn_pos = global_position
	attack_range = 1.0
	current_stamina = max_stamina
	speed_stat=5.0
	if ai:
		ai.init(self)
	$hit.visible = false
	_create_shield()
	super._ready()

func respawn():
	global_position = spawn_pos
	current_health = max_health
	current_stamina = max_stamina
	_time_since_stamina_use = STAMINA_REGEN_DELAY
	is_dead = false
	ai.done=false
	visible = true

func _unhandled_input(event: InputEvent) -> void:
	if ai.heuristic != "human":
		return
	if event.is_action_pressed("attack"):
		
		#var m_pos = get_local_mouse_position()
		attack()
	if event.is_action_pressed("run"):
		is_running = true
	elif event.is_action_released("run"):
		is_running = false
	if event.is_action_pressed("block"):
		is_blocking = true
	elif event.is_action_released("block"):
		is_blocking = false

func attack():
	if not can_attack or is_attacking:
		return
	if current_stamina < ATTACK_STAMINA_COST:
		return
	_spend_stamina(ATTACK_STAMINA_COST)
	super.attack()

func _physics_process(delta: float) -> void:
	if is_dead:
		return
	if ai.heuristic == "human":
		
		aim = $"../Cursor".global_position
		move = Vector3(Input.get_axis("left", "right"), 0.0, Input.get_axis("up", "down"))
	else:
		# Positive forward walks toward aim. move.z is negative for that, matching W.
		move = Vector3(requested_move.y, 0.0, -requested_move.x)
		var aim_offset := aim - global_position
		aim_offset.y = 0.0
		if aim_offset.length_squared() < 0.000001:
			aim_offset = Vector3.FORWARD
		aim_offset = aim_offset.normalized().rotated(Vector3.UP, requested_turn * turn_speed*delta)
		aim = global_position + aim_offset
		is_running = requested_sprint
		is_blocking = requested_block
	var sprinting := _apply_stamina(delta)
	var run := (2.0 if sprinting else 1.0)
	var attack_slow := (0.5 if is_attacking else 1.0)
	var block_slow := (BLOCK_SPEED_SCALE if is_blocking else 1.0)
	current_speed = speed_stat * run * attack_slow * block_slow
	_shield.visible = is_blocking
	super._physics_process(delta)

func take_damage(damage:float, attacker: Node3D = null) -> Dictionary:
	var incoming := damage
	if _attack_is_blocked(attacker):
		incoming *= 0.5
		_spend_stamina(BLOCKED_HIT_STAMINA)
		var percent_blocked := 0.0
		if current_health > 0.0:
			percent_blocked = (damage - incoming) / current_health
		blocked_attack.emit(percent_blocked)
	return super.take_damage(incoming, attacker)

func _on_attack_landed(percent_damage: float, is_kill: bool) -> void:
	hit_enemy.emit(percent_damage)
	if is_kill:
		killed_enemy.emit()

func _on_damage_taken(percent_damage: float) -> void:
	got_hit.emit(percent_damage)

func die():
	died.emit()
	ai.done = true
	is_dead = true
	visible = false
	$"..".reset()
	print("die")
func swing():
	pass

# Drains sprint stamina. Holding block is free. Returns true when this frame is spent sprinting.
func _apply_stamina(delta: float) -> bool:
	if is_running and current_stamina > 0.0:
		_spend_stamina(minf(SPRINT_STAMINA_PER_SEC * delta, current_stamina))
		return true
	_time_since_stamina_use += delta
	if _time_since_stamina_use < STAMINA_REGEN_DELAY or current_stamina >= max_stamina:
		return false
	current_stamina = minf(current_stamina + STAMINA_REGEN_PER_SEC * delta, max_stamina)
	return false

# Cylinder axis is Y. Tip it so the disc faces the mesh's forward (-Z).
func _create_shield() -> void:
	_shield = MeshInstance3D.new()
	_shield.name = "Shield"
	var disc := CylinderMesh.new()
	disc.top_radius = 0.5
	disc.bottom_radius = 0.5
	disc.height = 0.1
	_shield.mesh = disc
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.45, 0.62, 0.82)
	mat.metallic = 0.8
	mat.roughness = 0.28
	_shield.material_override = mat
	_shield.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_shield.rotation.x = PI / 2.0
	_shield.position = Vector3(0.0, 0.25, -0.78)
	_shield.visible = false
	$Mesh.add_child(_shield)

func _attack_is_blocked(attacker: Node3D) -> bool:
	if not is_blocking or attacker == null:
		return false
	var to_attacker: Vector3 = attacker.global_position - global_position
	to_attacker.y = 0.0
	if to_attacker.length_squared() < 0.000001:
		return true
	var forward: Vector3 = -$Mesh.global_basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.000001:
		return false
	var facing_dot := forward.normalized().dot(to_attacker.normalized())
	return facing_dot >= cos(deg_to_rad(BLOCK_ARC_DEGREES * 0.5))

func _spend_stamina(amount: float) -> void:
	current_stamina = maxf(current_stamina - amount, 0.0)
	_time_since_stamina_use = 0.0
