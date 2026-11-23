extends Char3

const AllySensor3D = preload("res://characters/common/ally_sensor_3d.gd")

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
# Ability signals for squad coordination and training rewards.
signal stunned_enemy(duration: float)
signal healed_ally(amount: float)
signal executed_stunned_enemy(bonus_damage: float)

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

enum Role { TANK, MEDIC, STRIKER }
@export var role: Role = Role.STRIKER:
	set(val):
		role = val
		if is_node_ready() and use_role_preset_stats:
			_apply_role_stats()
			_apply_role_visuals()

@export_range(1, 3, 1) var level: int = 1:
	set(val):
		level = clampi(val, 1, 3)
		if is_node_ready() and use_role_preset_stats:
			_apply_role_stats()
			_apply_role_visuals()

@export var team: int = 0: # 0 = Blue, 1 = Red
	set(val):
		team = val
		if is_node_ready() and use_role_preset_stats:
			_apply_role_visuals()

@export var use_role_preset_stats: bool = true

# Ability stats scaled by role and level
var stun_duration: float = 0.0
var knockback_force: float = 0.0
var stun_aoe_radius: float = 0.0
var stun_damage_multiplier: float = 1.0
var heal_per_sec: float = 0.0
var heal_range: float = 0.0
var heal_stamina_cost_per_sec: float = 0.0
var heal_is_aoe: bool = false

var is_stunned: bool = false
var _stun_timer: float = 0.0
var _stun_indicator: MeshInstance3D

@export var is_bot: bool = true:
	set(val):
		is_bot = val
		if ai:
			ai.is_bot = val
			if val:
				ai.heuristic = "bot"
			elif ai.heuristic == "bot":
				ai.heuristic = "human"

var requested_move: Vector2
var requested_turn: float
var requested_sprint: bool
var requested_block: bool
@export
var turn_speed: float = 1.0
var is_running: bool = false
var is_blocking: bool = false
var spawn_pos: Vector3
var _time_since_stamina_use: float = STAMINA_REGEN_DELAY
var _shield: MeshInstance3D
var _heal_beam: MeshInstance3D

func _ready():
	spawn_pos = global_position
	if team == 0:
		add_to_group("soldier")
		add_to_group("team_blue")
		collision_layer = 2
		$ray.collision_mask = 4
	else:
		add_to_group("enemy")
		add_to_group("team_red")
		collision_layer = 4
		$ray.collision_mask = 2
	if not has_node("AllySensor"):
		var a_sensor = AllySensor3D.new()
		a_sensor.name = "AllySensor"
		add_child(a_sensor)
	_create_shield()
	_create_heal_vfx()
	_create_stun_indicator()
	if use_role_preset_stats:
		_apply_role_stats()
	_apply_role_visuals()
	current_health = max_health
	current_stamina = max_stamina
	if is_bot and ai:
		ai.is_bot = true
		ai.heuristic = "bot"
	if ai:
		ai.init(self)
	$hit.visible = false
	super._ready()

func _apply_role_stats() -> void:
	match role:
		Role.TANK:
			match level:
				1:
					max_health = 250.0
					speed_stat = 2.4
					damage = 4.0
					attack_range = 2.2
					max_stamina = 120.0
					stun_duration = 1.0
					knockback_force = 2.0
					stun_aoe_radius = 0.0
				2:
					max_health = 325.0
					speed_stat = 2.5
					damage = 5.5
					attack_range = 2.6
					max_stamina = 140.0
					stun_duration = 1.6
					knockback_force = 3.2
					stun_aoe_radius = 0.0
				3:
					max_health = 400.0
					speed_stat = 2.6
					damage = 7.0
					attack_range = 3.0
					max_stamina = 160.0
					stun_duration = 2.2
					knockback_force = 4.5
					stun_aoe_radius = 3.5
			stun_damage_multiplier = 1.0
			heal_per_sec = 0.0
			heal_range = 0.0
			heal_stamina_cost_per_sec = 0.0
			heal_is_aoe = false
		Role.MEDIC:
			match level:
				1:
					max_health = 100.0
					speed_stat = 3.4
					damage = 2.0
					attack_range = 1.8
					max_stamina = 100.0
					heal_per_sec = 15.0
					heal_range = 6.0
					heal_stamina_cost_per_sec = 12.0
					heal_is_aoe = false
				2:
					max_health = 130.0
					speed_stat = 3.7
					damage = 3.0
					attack_range = 2.0
					max_stamina = 115.0
					heal_per_sec = 25.0
					heal_range = 9.0
					heal_stamina_cost_per_sec = 10.0
					heal_is_aoe = false
				3:
					max_health = 160.0
					speed_stat = 4.0
					damage = 4.0
					attack_range = 2.2
					max_stamina = 130.0
					heal_per_sec = 35.0
					heal_range = 12.0
					heal_stamina_cost_per_sec = 8.0
					heal_is_aoe = true
			stun_duration = 0.0
			knockback_force = 0.0
			stun_aoe_radius = 0.0
			stun_damage_multiplier = 1.0
		Role.STRIKER:
			match level:
				1:
					max_health = 160.0
					speed_stat = 3.0
					damage = 10.0
					attack_range = 2.8
					max_stamina = 100.0
					stun_damage_multiplier = 2.0
				2:
					max_health = 190.0
					speed_stat = 3.2
					damage = 14.0
					attack_range = 3.2
					max_stamina = 110.0
					stun_damage_multiplier = 2.5
				3:
					max_health = 220.0
					speed_stat = 3.5
					damage = 18.0
					attack_range = 3.6
					max_stamina = 120.0
					stun_damage_multiplier = 3.0
			stun_duration = 0.0
			knockback_force = 0.0
			stun_aoe_radius = 0.0
			heal_per_sec = 0.0
			heal_range = 0.0
			heal_stamina_cost_per_sec = 0.0
			heal_is_aoe = false

func _apply_role_visuals() -> void:
	var outline_color: Color
	var outline_width: float = 0.015 + (float(level) - 1.0) * 0.005
	var shield_color: Color
	var shield_radius: float = 0.5
	if team == 0:
		match role:
			Role.TANK:
				outline_color = Color(0.25, 0.55, 1.0, 1.0) # Vibrant Blue
				shield_color = Color(0.25, 0.55, 1.0, 0.85)
				shield_radius = 0.65
			Role.MEDIC:
				outline_color = Color(0.2, 1.0, 0.45, 1.0) # Emerald Green
				shield_color = Color(0.2, 1.0, 0.45, 0.75)
				shield_radius = 0.45
			Role.STRIKER:
				outline_color = Color(1.0, 0.35, 0.15, 1.0) # Fiery Orange/Red
				shield_color = Color(1.0, 0.4, 0.2, 0.75)
				shield_radius = 0.45
	else:
		match role:
			Role.TANK:
				outline_color = Color(0.95, 0.2, 0.2, 1.0) # Crimson Red
				shield_color = Color(0.95, 0.2, 0.2, 0.85)
				shield_radius = 0.65
			Role.MEDIC:
				outline_color = Color(0.85, 0.2, 0.9, 1.0) # Violet / Magenta
				shield_color = Color(0.85, 0.2, 0.9, 0.75)
				shield_radius = 0.45
			Role.STRIKER:
				outline_color = Color(1.0, 0.75, 0.1, 1.0) # Golden Amber
				shield_color = Color(1.0, 0.75, 0.1, 0.75)
				shield_radius = 0.45

	for part_name in ["Outline", "OutlineHelmet"]:
		var part = get_node_or_null(part_name) as MeshInstance3D
		if part and part.material_override is ShaderMaterial:
			var mat = part.material_override.duplicate() as ShaderMaterial
			mat.set_shader_parameter("outline_color", outline_color)
			mat.set_shader_parameter("outline_width", outline_width)
			part.material_override = mat

	if _shield:
		var disc: CylinderMesh = _shield.mesh as CylinderMesh
		if disc:
			disc.top_radius = shield_radius
			disc.bottom_radius = shield_radius
		if _shield.material_override is StandardMaterial3D:
			(_shield.material_override as StandardMaterial3D).albedo_color = shield_color

func respawn():
	global_position = spawn_pos
	if use_role_preset_stats:
		_apply_role_stats()
	current_health = max_health
	current_stamina = max_stamina
	_time_since_stamina_use = STAMINA_REGEN_DELAY
	is_dead = false
	is_stunned = false
	_stun_timer = 0.0
	if _stun_indicator:
		_stun_indicator.visible = false
	_hide_heal_vfx()
	# `done` is deliberately NOT cleared here. The arena sets it when an episode
	# ends and the Sync node clears it via set_done_false() after reporting the
	# episode to SB3. Clearing it during respawn would make the episode
	# invisible to VecMonitor.
	visible = true

func _unhandled_input(event: InputEvent) -> void:
	if is_bot or ai == null or ai.heuristic != "human" or ("is_bot" in ai and ai.is_bot):
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
	if is_bot or (ai and (ai.heuristic != "human" or ("is_bot" in ai and ai.is_bot))):
		var sensor = get_node_or_null("EntitySensor")
		if sensor and sensor.has_method("nearest_target"):
			var target: Node3D = null
			if role == Role.STRIKER and sensor.has_method("nearest_stunned_target"):
				target = sensor.nearest_stunned_target()
			elif role == Role.TANK and sensor.has_method("nearest_unstunned_target"):
				target = sensor.nearest_unstunned_target()
			if not target:
				target = sensor.nearest_target()
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
	if _stun_timer > 0.0:
		_stun_timer -= delta
		if _stun_timer <= 0.0:
			is_stunned = false
			if _stun_indicator:
				_stun_indicator.visible = false
		current_speed = 0.0
		if _shield:
			_shield.visible = false
		_hide_heal_vfx()
		super._physics_process(delta)
		return
	# Edge detection for the per-action cost signals below. Both flags are
	# assigned every frame (human input or requested action), so comparing
	# against the previous frame's value gives exactly one emit per action.
	var was_blocking := is_blocking
	var is_human: bool = (not is_bot and ai != null and ai.heuristic == "human" and not ("is_bot" in ai and ai.is_bot))
	if is_human:
		
		# The Cursor is optional: character scenes are also opened on their own
		# (AssetLib-style previews, the _probe_models render harness), where
		# there is no arena to own it. Fall back to the aim already held.
		var cursor := get_node_or_null("../Cursor") as Node3D
		if cursor != null:
			aim = cursor.global_position
		move = Vector3(Input.get_axis("left", "right"), 0.0, Input.get_axis("up", "down"))
	else:
		# Positive forward walks toward aim. move.z is negative for that, matching W.
		move = Vector3(requested_move.y, 0.0, -requested_move.x)
		
		var aim_offset := aim - global_position
		aim_offset.y = 0.0
		if aim_offset.length_squared() < 0.000001:
			aim_offset = Vector3.FORWARD
		var effective_turn_speed: float = 8.0 if is_bot else turn_speed
		aim_offset = aim_offset.normalized().rotated(Vector3.UP, requested_turn * effective_turn_speed * delta)
		aim = global_position + aim_offset
		is_running = requested_sprint
		is_blocking = requested_block
	var sprinting := _apply_stamina(delta)
	var run := (SPRINT_SPEED if sprinting else 1.0)
	var attack_slow := (0.5 if is_attacking else 1.0)
	var block_slow := (BLOCK_SPEED_SCALE if is_blocking else 1.0)
	current_speed = speed_stat * run * attack_slow * block_slow
	_shield.visible = is_blocking
	if is_blocking:
		_update_shield_pose()
		if role == Role.MEDIC:
			_channel_heal(delta)
			var ally_sens = get_node_or_null("AllySensor")
			if ally_sens and ally_sens.has_method("nearest_injured_ally"):
				var injured: Node3D = ally_sens.nearest_injured_ally()
				if injured:
					aim = injured.global_position
	else:
		_hide_heal_vfx()
	if is_blocking and not was_blocking:
		block_started.emit()
	# attack_started is emitted from attack() itself, not here: super.attack()
	# sets is_attacking synchronously, so this edge never saw the transition.
	super._physics_process(delta)

func take_damage(damage:float, attacker: Node3D = null) -> Dictionary:
	var incoming := damage
	if _attack_is_blocked(attacker):
		var mitigation := 0.75 if role == Role.TANK else 0.5
		incoming *= (1.0 - mitigation)
		_spend_stamina(BLOCKED_HIT_STAMINA)
		var percent_blocked := 0.0
		if current_health > 0.0:
			percent_blocked = (damage - incoming) / current_health
		blocked_attack.emit(percent_blocked)
	return super.take_damage(incoming, attacker)

func get_attack_damage(target: Node3D) -> float:
	var final_dmg := damage
	if role == Role.STRIKER and target != null:
		if "is_stunned" in target and target.is_stunned:
			final_dmg *= stun_damage_multiplier
			var bonus := final_dmg - damage
			executed_stunned_enemy.emit(bonus)
			debug_log("execution", "{0} executed stunned target for {1} dmg!".format([name, final_dmg]))
	return final_dmg

func _on_attack_landed(percent_damage: float, is_kill: bool) -> void:
	hit_enemy.emit(percent_damage)
	if is_kill:
		killed_enemy.emit()

	if role == Role.TANK and last_hit_target != null:
		if last_hit_target.has_method("stun"):
			last_hit_target.stun(stun_duration)
			stunned_enemy.emit(stun_duration)
		if last_hit_target.has_method("apply_knockback"):
			var kb_dir := (last_hit_target.global_position - global_position)
			kb_dir.y = 0.0
			if kb_dir.length_squared() > 0.0001:
				kb_dir = kb_dir.normalized()
			else:
				kb_dir = -global_basis.z
			last_hit_target.apply_knockback(kb_dir * knockback_force)

		# Level 3 Tank AoE shockwave
		if stun_aoe_radius > 0.0:
			var e_group := "enemy" if team == 0 else "soldier"
			var enemies = get_tree().get_nodes_in_group(e_group)
			for enemy in enemies:
				if enemy != last_hit_target and enemy is Node3D and not ("is_dead" in enemy and enemy.is_dead):
					var dist: float = global_position.distance_to(enemy.global_position)
					if dist <= stun_aoe_radius:
						if enemy.has_method("stun"):
							enemy.stun(stun_duration * 0.5)
						if enemy.has_method("apply_knockback"):
							var away: Vector3 = (enemy.global_position - global_position)
							away.y = 0.0
							if away.length_squared() > 0.0001:
								enemy.apply_knockback(away.normalized() * (knockback_force * 0.5))

func _on_damage_taken(percent_damage: float) -> void:
	got_hit.emit(percent_damage)

func die():
	ai.done = true
	is_dead = true
	is_stunned = false
	_stun_timer = 0.0
	if _stun_indicator:
		_stun_indicator.visible = false
	visible = false
	_hide_heal_vfx()
	debug_log("die", "{0} die".format([name]))
	# The arena owns episode resets; listen for `died` instead of resetting here.
	died.emit()
func swing():
	pass

func _create_stun_indicator() -> void:
	_stun_indicator = MeshInstance3D.new()
	_stun_indicator.name = "StunHalo"
	var torus := TorusMesh.new()
	torus.inner_radius = 0.25
	torus.outer_radius = 0.35
	_stun_indicator.mesh = torus
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.9, 0.2, 0.9)
	_stun_indicator.material_override = mat
	_stun_indicator.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_stun_indicator.position = Vector3(0.0, 2.05, 0.0)
	_stun_indicator.visible = false
	add_child(_stun_indicator)

func stun(duration: float) -> void:
	if is_dead:
		return
	is_stunned = true
	_stun_timer = maxf(_stun_timer, duration)
	is_attacking = false
	is_blocking = false
	if _stun_indicator:
		_stun_indicator.visible = true

func apply_knockback(force: Vector3) -> void:
	if is_dead:
		return
	velocity += force

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
	# Parented to the character rather than $Mesh: the body is a skinned mesh
	# whose orientation is driven by the skeleton, so a child of $Mesh would
	# never turn. _update_shield_pose() places it in front of `aim` instead.
	add_child(_shield)


# Puts the shield 0.78 m ahead of the character, along `aim`, matching the
# direction the block arc test uses. Only meaningful while blocking.
func _update_shield_pose() -> void:
	var dir := aim - global_position
	dir.y = 0.0
	if dir.length_squared() < 0.000001:
		return
	dir = dir.normalized()
	_shield.global_position = global_position + dir * 0.78 + Vector3.UP * 1.05
	_shield.global_basis = Basis.looking_at(dir, Vector3.UP)

func _attack_is_blocked(attacker: Node3D) -> bool:
	if not is_blocking or attacker == null:
		return false
	var to_attacker: Vector3 = attacker.global_position - global_position
	to_attacker.y = 0.0
	if to_attacker.length_squared() < 0.000001:
		return true
	# Facing comes from `aim`, not from $Mesh: the body is a skinned mesh whose
	# orientation is driven by the skeleton (CharacterAnimator yaws the root
	# bones), so $Mesh.global_basis never changes and reading it would make
	# blocking work in every direction.
	var face := aim - global_position
	face.y = 0.0
	if face.length_squared() < 0.000001:
		return false
	var facing_dot := face.normalized().dot(to_attacker.normalized())
	return facing_dot >= cos(deg_to_rad(BLOCK_ARC_DEGREES * 0.5))

func _spend_stamina(amount: float) -> void:
	current_stamina = maxf(current_stamina - amount, 0.0)
	_time_since_stamina_use = 0.0

func _channel_heal(delta: float) -> void:
	if role != Role.MEDIC or not is_blocking:
		_hide_heal_vfx()
		return
	var cost := heal_stamina_cost_per_sec * delta
	if current_stamina < cost:
		_hide_heal_vfx()
		return

	var group_name := "soldier" if team == 0 else "team_red"
	var allies := get_tree().get_nodes_in_group(group_name)
	var healed_any := false

	if heal_is_aoe:
		for ally in allies:
			if ally != self and ally is Node3D and not ("is_dead" in ally and ally.is_dead):
				if global_position.distance_to(ally.global_position) <= heal_range:
					if ally.current_health < ally.max_health:
						var heal_amt := minf(heal_per_sec * delta, ally.max_health - ally.current_health)
						ally.current_health += heal_amt
						healed_ally.emit(heal_amt)
						healed_any = true
						_show_heal_vfx(ally.global_position)
	else:
		var lowest_ally: Node3D = null
		var lowest_pct: float = 1.0
		for ally in allies:
			if ally != self and ally is Node3D and not ("is_dead" in ally and ally.is_dead):
				var d: float = global_position.distance_to(ally.global_position)
				if d <= heal_range and ally.current_health < ally.max_health:
					var pct: float = ally.current_health / maxf(ally.max_health, 0.001)
					if pct < lowest_pct:
						lowest_pct = pct
						lowest_ally = ally
		if lowest_ally:
			var heal_amt := minf(heal_per_sec * delta, lowest_ally.max_health - lowest_ally.current_health)
			lowest_ally.current_health += heal_amt
			healed_ally.emit(heal_amt)
			healed_any = true
			_show_heal_vfx(lowest_ally.global_position)
		elif current_health < max_health:
			var self_heal := minf(heal_per_sec * 0.5 * delta, max_health - current_health)
			current_health += self_heal
			healed_any = true
			_show_heal_vfx(global_position)

	if healed_any:
		_spend_stamina(cost)
	else:
		_hide_heal_vfx()

func _create_heal_vfx() -> void:
	_heal_beam = MeshInstance3D.new()
	_heal_beam.name = "HealBeam"
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.08
	cyl.bottom_radius = 0.08
	cyl.height = 1.0
	_heal_beam.mesh = cyl
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.2, 1.0, 0.45, 0.8)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_heal_beam.material_override = mat
	_heal_beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_heal_beam.visible = false
	add_child(_heal_beam)

func _show_heal_vfx(target_pos: Vector3) -> void:
	if not _heal_beam:
		return
	var start_pos := global_position + Vector3.UP * 0.9
	var end_pos := target_pos + Vector3.UP * 0.9
	var diff := end_pos - start_pos
	var dist := diff.length()
	if dist < 0.2:
		_heal_beam.visible = true
		_heal_beam.global_position = start_pos
		var cyl: CylinderMesh = _heal_beam.mesh as CylinderMesh
		if cyl:
			cyl.top_radius = 0.5
			cyl.bottom_radius = 0.5
			cyl.height = 1.8
		_heal_beam.global_basis = Basis()
		return
	_heal_beam.visible = true
	var cyl: CylinderMesh = _heal_beam.mesh as CylinderMesh
	if cyl:
		cyl.top_radius = 0.08
		cyl.bottom_radius = 0.08
		cyl.height = dist
	_heal_beam.global_position = start_pos + diff * 0.5
	var dir := diff.normalized()
	var up := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	var look := Basis.looking_at(dir, up)
	_heal_beam.global_basis = look * Basis(Vector3.RIGHT, PI / 2.0)

func _hide_heal_vfx() -> void:
	if _heal_beam and _heal_beam.visible:
		_heal_beam.visible = false
