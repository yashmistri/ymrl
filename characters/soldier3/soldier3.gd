extends Char3

signal got_hit(percent_damage: float)
signal died
signal hit_enemy(percent_damage: float)
signal killed_enemy
signal blocked_attack(percent_blocked: float)
# Emitted on the first physics frame an attack starts / block is held.
signal attack_started
signal block_started
# Emitted when an attack was requested but refused because stamina was too low.
signal attack_blocked_by_stamina

# Stamina economy.
#
# Keep this tuned against COMBINED actions. The first attempt was tuned against
# attacking alone and broke: the policy sprints and blocks while attacking, and
# those stack. At cost=15 / sprint=8 / regen=8 the bar emptied in 4.7 s of
# sprint+attack, so stamina never recovered, attacks_stamina_blocked hit ~348
# per episode, and the agent abandoned attacking entirely.
#
# Current numbers (attack 1.43/s at the 0.7 s cooldown):
#   attack drain      17.1/s
#   sprint drain       4.0/s
#   combined drain    21.1/s  vs 11.0/s regen -> net +10.1/s
#   => ~9.9 s of sprint+attack empties the bar, ~9 s to refill
#
# Still a real constraint (it drains), but recovering is achievable inside an
# episode, so resting pays off instead of being hopeless.
const ATTACK_STAMINA_COST:float = 12.0
const SPRINT_STAMINA_PER_SEC:float = 4.0
const BLOCKED_HIT_STAMINA:float = 3.0
const STAMINA_REGEN_PER_SEC:float = 11.0
const STAMINA_REGEN_DELAY:float = 1.2
# Sprinting cannot drain the bar past this floor. Without it, a policy that
# holds sprint permanently starves every other action.
const SPRINT_STAMINA_FLOOR:float = 10.0
# Attacks from inside this frontal arc are halved while blocking.
const BLOCK_ARC_DEGREES:float = 120.0
const BLOCK_SPEED_SCALE:float = 0.7
const SPRINT_SPEED:float = 1.5
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
	# attack_range is NOT set here. It is an @export on Char3, configured in
	# soldier3.tscn (currently 3.0). This function used to hardcode it to 1.0,
	# which silently overrode the scene and left the soldier with a reach
	# shorter than the zombie's (1.1 * 2.0 = 2.2m), so attacks could only land
	# at point-blank range and damage_dealt read 0 in almost every episode.
	current_stamina = max_stamina
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
	# `done` is deliberately NOT cleared here. The arena sets it when an episode
	# ends and the Sync node clears it via set_done_false() after reporting the
	# episode to SB3. Clearing it during respawn would make the episode
	# invisible to VecMonitor.
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
		# Tell the agent its attack was REJECTED for lack of stamina. Without
		# this the attempt is indistinguishable from a hit that missed, so the
		# agent cannot learn that resting would let it attack again.
		attack_blocked_by_stamina.emit()
		return
	_spend_stamina(ATTACK_STAMINA_COST)
	# Snap aim to the nearest enemy for the attack frame.
	#
	# The policy's only way to change `aim` is the 3-way `turn` head, applied
	# incrementally in _physics_process. Starting from Vector3.FORWARD, the agent
	# has to discover that turning changes where an attack lands -- and a live
	# run showed it attacking 123 degrees away from a zombie standing 1 m in
	# front of it, so no hit ever connected. Aiming is a perception problem the
	# EntitySensor has already solved, not something worth learning.
	#
	# `turn` still steers movement (it rotates the aim point that move is
	# relative to), so the policy keeps its mobility. If no enemy is visible the
	# attempt keeps whatever aim it already had.
	if ai and ai.heuristic != "human":
		var sensor = get_node_or_null("EntitySensor")
		if sensor and sensor.has_method("nearest_target"):
			var target: Node3D = sensor.nearest_target()
			if target:
				aim = target.global_position
	# Emitted HERE, not from the is_attacking edge in _physics_process.
	# super.attack() sets is_attacking = true synchronously, so the edge check
	# in _physics_process always saw it already set and never fired. That meant
	# ATTACK_COST was never charged and attacks_started never counted.
	attack_started.emit()
	super.attack()

func _physics_process(delta: float) -> void:
	if is_dead:
		return
	# Edge detection for the per-action cost signals below. Both flags are
	# assigned every frame (human input or requested action), so comparing
	# against the previous frame's value gives exactly one emit per action.
	var was_blocking := is_blocking
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
	var run := (SPRINT_SPEED if sprinting else 1.0)
	var attack_slow := (0.5 if is_attacking else 1.0)
	var block_slow := (BLOCK_SPEED_SCALE if is_blocking else 1.0)
	current_speed = speed_stat * run * attack_slow * block_slow
	_shield.visible = is_blocking
	if is_blocking and not was_blocking:
		block_started.emit()
	# attack_started is emitted from attack() itself, not here: super.attack()
	# sets is_attacking synchronously, so this edge never saw the transition.
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
	ai.done = true
	is_dead = true
	visible = false
	debug_log("die", "{0} die".format([name]))
	# The arena owns episode resets; listen for `died` instead of resetting here.
	died.emit()
func swing():
	pass

# Drains sprint stamina, but never below SPRINT_STAMINA_FLOOR. Holding block is
# free. Returns true when this frame is spent sprinting.
#
# The floor exists so sprint cannot starve the bar: a policy that holds sprint
# permanently previously drove stamina to zero and then could not afford an
# attack (or recover, since sprint kept resetting the regen delay).
func _apply_stamina(delta: float) -> bool:
	if is_running and current_stamina > SPRINT_STAMINA_FLOOR:
		_spend_stamina(minf(SPRINT_STAMINA_PER_SEC * delta, current_stamina - SPRINT_STAMINA_FLOOR))
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
	# Unshaded: the arena has no lights, so metallic/roughness have nothing to
	# react to. A bright flat colour keeps the shield readable when blocking.
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.62, 0.82, 1.0)
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
