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
# Ability signals for squad coordination and training rewards.
signal stunned_enemy(duration: float)
signal healed_ally(amount: float)
signal executed_stunned_enemy(bonus_damage: float)
signal critical_hit(damage: float)

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
const BLOCK_STAMINA_PER_SEC:float = 6.0
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

enum Role { TANK, MEDIC, STRIKER, BASIC }
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
@export var randomize_level_on_spawn: bool = true
@export var randomize_role_on_spawn: bool = false
@export var crit_chance: float = 0.05
@export var crit_multiplier: float = 3.0

@onready var _level_label: Label3D = get_node_or_null("LevelLabel")

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
var is_casting: bool = false
var _stun_timer: float = 0.0
@onready var _stun_indicator: MeshInstance3D = get_node_or_null("StunIndicator")

@export var is_bot: bool = true:
	set(val):
		is_bot = val
		if ai:
			ai.is_bot = val
			if not use_nn:
				if val:
					ai.policy_source = ai.PolicySource.BOT_HEURISTIC
					ai.heuristic = "bot"
				else:
					ai.policy_source = ai.PolicySource.HUMAN
					ai.heuristic = "human"

@export var use_nn: bool = false:
	set(val):
		use_nn = val
		if ai:
			if val:
				ai.policy_source = ai.PolicySource.NEURAL_NETWORK
			elif is_bot:
				ai.policy_source = ai.PolicySource.BOT_HEURISTIC
				ai.heuristic = "bot"
			else:
				ai.policy_source = ai.PolicySource.HUMAN
				ai.heuristic = "human"

enum TacticalAnchor {
	ENGAGE_TARGET,       # 0: Path directly toward combat target, spaced by combat stance
	FLANK_TARGET,        # 1: Path to lateral flank (2.5m offset) of target
	FOCUS_LOW_HP,        # 2: Path toward lowest HP living enemy
	REGROUP_ALLY,        # 3: Path toward nearest living ally (+ formation offset)
	SUPPORT_INJURED,     # 4: Path toward most injured ally (heal/peel)
	SEEK_COVER,          # 5: Path to cover breaking line-of-sight from primary threat
	HOLD_GROUND,         # 6: Hold position (zero movement)
	PUSH_HILL,           # 7: Push inside the active King of the Hill zone
	GUARD_HILL_PERIMETER # 8: Hold edge/approach perimeter of the active King of the Hill zone
}

enum CombatStance {
	MELEE,            # 0: Close distance ~1.2m
	STANDARD,         # 1: Standard combat distance ~2.2m
	KITE              # 2: Defensive / kiting distance ~4.0m
}

const STANCE_DISTANCES: Array[float] = [1.2, 2.2, 4.0]

@export var current_anchor: TacticalAnchor = TacticalAnchor.ENGAGE_TARGET
@export var current_stance: int = 1 # 0: Melee, 1: Standard, 2: Kite
@export var squad_slot_index: int = -1
@export var end_episode_on_death: bool = true

@onready var _nav_agent: NavigationAgent3D = get_node_or_null("NavAgent")
var _safe_nav_velocity: Vector3 = Vector3.ZERO
var _has_safe_nav_velocity: bool = false
var _stuck_timer: float = 0.0
var _prev_pos: Vector3 = Vector3.ZERO
var actual_speed: float = 0.0

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
@onready var _shield: MeshInstance3D = get_node_or_null("Shield")
@onready var _heal_beam: MeshInstance3D = get_node_or_null("HealBeam")

func _ready():
	spawn_pos = global_position
	_prev_pos = global_position
	if _nav_agent == null:
		_nav_agent = get_node_or_null("NavAgent")
	if _nav_agent != null and _nav_agent.avoidance_enabled and not _nav_agent.velocity_computed.is_connected(_on_nav_velocity_computed):
		_nav_agent.velocity_computed.connect(_on_nav_velocity_computed)
	if _level_label == null:
		_level_label = get_node_or_null("LevelLabel")
	if _stun_indicator == null:
		_stun_indicator = get_node_or_null("StunIndicator")
	if _shield == null:
		_shield = get_node_or_null("Shield")
	if _heal_beam == null:
		_heal_beam = get_node_or_null("HealBeam")

	if randomize_role_on_spawn:
		role = randi_range(0, 3) as Role
	if randomize_level_on_spawn:
		level = randi_range(1, 3)
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
	if use_role_preset_stats:
		_apply_role_stats()
	_apply_role_visuals()
	current_health = max_health
	current_stamina = max_stamina
	if ai:
		if is_bot:
			ai.is_bot = true
			ai.heuristic = "bot"
			ai.policy_source = ai.PolicySource.BOT_HEURISTIC
		else:
			ai.is_bot = false
			ai.heuristic = "human"
			ai.policy_source = ai.PolicySource.HUMAN
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
					damage = 5.0 # +25% (was 4.0)
					attack_range = 2.2
					max_stamina = 120.0
					stun_duration = 1.0
					knockback_force = 2.0
					stun_aoe_radius = 0.0
				2:
					max_health = 325.0
					speed_stat = 2.5
					damage = 6.875 # +25% (was 5.5)
					attack_range = 2.6
					max_stamina = 140.0
					stun_duration = 1.6
					knockback_force = 3.2
					stun_aoe_radius = 0.0
				3:
					max_health = 400.0
					speed_stat = 2.6
					damage = 8.75 # +25% (was 7.0)
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
					damage = 2.5 # +25% (was 2.0)
					attack_range = 1.8
					max_stamina = 100.0
					heal_per_sec = 8.0
					heal_range = 6.0
					heal_stamina_cost_per_sec = 12.0
					heal_is_aoe = false
				2:
					max_health = 130.0
					speed_stat = 3.7
					damage = 3.75 # +25% (was 3.0)
					attack_range = 2.0
					max_stamina = 115.0
					heal_per_sec = 8.0
					heal_range = 9.0
					heal_stamina_cost_per_sec = 10.0
					heal_is_aoe = false
				3:
					max_health = 160.0
					speed_stat = 4.0
					damage = 5.0 # +25% (was 4.0)
					attack_range = 2.2
					max_stamina = 130.0
					heal_per_sec = 8.0
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
					damage = 12.5 # +25% (was 10.0)
					attack_range = 2.8
					max_stamina = 100.0
					stun_damage_multiplier = 2.0
				2:
					max_health = 190.0
					speed_stat = 3.2
					damage = 17.5 # +25% (was 14.0)
					attack_range = 3.2
					max_stamina = 110.0
					stun_damage_multiplier = 2.5
				3:
					max_health = 220.0
					speed_stat = 3.5
					damage = 22.5 # +25% (was 18.0)
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
		Role.BASIC:
			match level:
				1:
					max_health = 180.0
					speed_stat = 3.1
					damage = 8.5
					attack_range = 2.4
					max_stamina = 110.0
				2:
					max_health = 225.0
					speed_stat = 3.25
					damage = 11.5
					attack_range = 2.6
					max_stamina = 125.0
				3:
					max_health = 270.0
					speed_stat = 3.4
					damage = 14.5
					attack_range = 2.8
					max_stamina = 140.0
			stun_duration = 0.0
			knockback_force = 0.0
			stun_aoe_radius = 0.0
			stun_damage_multiplier = 1.0
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
				outline_color = Color(0.10, 0.30, 0.90, 1.0) # Deep Royal Blue
				shield_color = Color(0.10, 0.30, 0.90, 0.85)
				shield_radius = 0.65
			Role.MEDIC:
				outline_color = Color(0.45, 0.82, 1.0, 1.0) # Bright Sky Blue
				shield_color = Color(0.45, 0.82, 1.0, 0.75)
				shield_radius = 0.45
			Role.STRIKER:
				outline_color = Color(0.18, 0.52, 1.0, 1.0) # Cobalt Blue
				shield_color = Color(0.18, 0.52, 1.0, 0.75)
				shield_radius = 0.45
			Role.BASIC:
				outline_color = Color(0.32, 0.58, 0.82, 1.0) # Steel Blue
				shield_color = Color(0.32, 0.58, 0.82, 0.75)
				shield_radius = 0.48
	else:
		match role:
			Role.TANK:
				outline_color = Color(0.78, 0.08, 0.12, 1.0) # Deep Crimson Red
				shield_color = Color(0.78, 0.08, 0.12, 0.85)
				shield_radius = 0.65
			Role.MEDIC:
				outline_color = Color(1.0, 0.45, 0.45, 1.0) # Light Coral Red
				shield_color = Color(1.0, 0.45, 0.45, 0.75)
				shield_radius = 0.45
			Role.STRIKER:
				outline_color = Color(1.0, 0.16, 0.14, 1.0) # Bright Scarlet Red
				shield_color = Color(1.0, 0.16, 0.14, 0.75)
				shield_radius = 0.45
			Role.BASIC:
				outline_color = Color(0.82, 0.28, 0.24, 1.0) # Brick Red
				shield_color = Color(0.82, 0.28, 0.24, 0.75)
				shield_radius = 0.48

	for part_name in ["Outline", "OutlineHelmet"]:
		var part = get_node_or_null(part_name) as MeshInstance3D
		if part and part.material_override is ShaderMaterial:
			var mat = part.material_override.duplicate() as ShaderMaterial
			mat.set_shader_parameter("outline_color", outline_color)
			mat.set_shader_parameter("outline_width", outline_width)
			part.material_override = mat

	var helmet = get_node_or_null("Paladin_J_Nordstrom_Helmet") as MeshInstance3D
	var outline_helmet = get_node_or_null("OutlineHelmet") as MeshInstance3D
	if helmet:
		helmet.visible = (level >= 2)
	if outline_helmet:
		outline_helmet.visible = (level >= 2)

	if _shield:
		var disc: CylinderMesh = _shield.mesh as CylinderMesh
		if disc:
			disc.top_radius = shield_radius
			disc.bottom_radius = shield_radius
		if _shield.material_override is StandardMaterial3D:
			(_shield.material_override as StandardMaterial3D).albedo_color = shield_color

	_update_level_indicator()

func _create_level_indicator() -> void:
	if _level_label == null:
		_level_label = get_node_or_null("LevelLabel")
	_update_level_indicator()

func _update_level_indicator() -> void:
	if not _level_label:
		return
	_level_label.text = str(level)
	match level:
		1:
			_level_label.modulate = Color(0.9, 0.9, 0.95) # Silver
		2:
			_level_label.modulate = Color(0.3, 0.85, 1.0) # Azure
		3:
			_level_label.modulate = Color(1.0, 0.85, 0.15) # Gold

func set_random_role() -> void:
	role = randi_range(0, 3) as Role
	if use_role_preset_stats:
		_apply_role_stats()
	_apply_role_visuals()
	current_health = max_health
	current_stamina = max_stamina

func set_random_level() -> void:
	level = randi_range(1, 3)
	if use_role_preset_stats:
		_apply_role_stats()
	_apply_role_visuals()
	current_health = max_health
	current_stamina = max_stamina

func respawn():
	global_position = spawn_pos
	if randomize_role_on_spawn:
		role = randi_range(0, 3) as Role
	if randomize_level_on_spawn:
		level = randi_range(1, 3)
	if use_role_preset_stats:
		_apply_role_stats()
	_apply_role_visuals()
	current_health = max_health
	current_stamina = max_stamina
	_time_since_stamina_use = STAMINA_REGEN_DELAY
	is_dead = false
	is_stunned = false
	_stun_timer = 0.0
	locomotion_velocity = Vector3.ZERO
	knockback_velocity = Vector3.ZERO
	velocity = Vector3.ZERO
	move = Vector3.ZERO
	if _stun_indicator:
		_stun_indicator.visible = false
	if _level_label:
		_level_label.visible = true
	if has_node("Col"):
		$Col.disabled = false
	_has_safe_nav_velocity = false
	_safe_nav_velocity = Vector3.ZERO
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

func _get_combat_target() -> Node3D:
	var sensor = get_node_or_null("EntitySensor")
	var target: Node3D = null
	if sensor:
		if role == Role.STRIKER and sensor.has_method("nearest_stunned_target"):
			target = sensor.nearest_stunned_target()
		elif role == Role.TANK and sensor.has_method("nearest_unstunned_target"):
			target = sensor.nearest_unstunned_target()
		if not target and sensor.has_method("nearest_target"):
			target = sensor.nearest_target()
	if not target:
		var enemy_group := "enemy" if team == 0 else "soldier"
		var min_d := 35.0
		for node in get_tree().get_nodes_in_group(enemy_group):
			if node is Node3D and is_instance_valid(node) and ("is_dead" not in node or not node.is_dead):
				var d := global_position.distance_to(node.global_position)
				if d < min_d:
					min_d = d
					target = node
	return target

func _get_lowest_hp_enemy() -> Node3D:
	var enemy_group := "enemy" if team == 0 else "soldier"
	var target: Node3D = null
	var min_hp := INF
	for node in get_tree().get_nodes_in_group(enemy_group):
		if node is Node3D and is_instance_valid(node) and ("is_dead" not in node or not node.is_dead):
			if global_position.distance_to(node.global_position) <= 35.0:
				var hp: float = node.current_health if "current_health" in node else 100.0
				if hp < min_hp:
					min_hp = hp
					target = node
	return target

func _get_lowest_hp_ally() -> Node3D:
	var sensor = get_node_or_null("AllySensor")
	if sensor and sensor.has_method("nearest_injured_ally"):
		var injured = sensor.nearest_injured_ally()
		if injured:
			return injured
	var ally_group := "soldier" if team == 0 else "enemy"
	var target: Node3D = null
	var min_hp_ratio := 1.0
	for node in get_tree().get_nodes_in_group(ally_group):
		if node != self and node is Node3D and is_instance_valid(node) and ("is_dead" not in node or not node.is_dead):
			if global_position.distance_to(node.global_position) <= 35.0:
				var cur_h: float = node.current_health if "current_health" in node else 1.0
				var max_h: float = node.max_health if "max_health" in node else 1.0
				var ratio := cur_h / maxf(max_h, 0.001)
				if ratio < min_hp_ratio:
					min_hp_ratio = ratio
					target = node
	return target

func _get_nearest_ally() -> Node3D:
	var sensor = get_node_or_null("AllySensor")
	if sensor and sensor.has_method("nearest_ally"):
		var ally = sensor.nearest_ally()
		if ally:
			return ally
	var ally_group := "soldier" if team == 0 else "enemy"
	var target: Node3D = null
	var min_d := 35.0
	for node in get_tree().get_nodes_in_group(ally_group):
		if node != self and node is Node3D and is_instance_valid(node) and ("is_dead" not in node or not node.is_dead):
			var d := global_position.distance_to(node.global_position)
			if d < min_d:
				min_d = d
				target = node
	return target

func _on_nav_velocity_computed(safe_velocity: Vector3) -> void:
	_safe_nav_velocity = Vector3(safe_velocity.x, 0.0, safe_velocity.z)
	_has_safe_nav_velocity = true

func _find_arena() -> Node:
	var p := get_parent()
	while p:
		if p.has_method("get_hill_state") or p.has_method("find_best_cover_point"):
			if p.is_inside_tree() and not p.is_queued_for_deletion():
				return p
		if "arena_instance" in p and p.arena_instance != null and is_instance_valid(p.arena_instance) and p.arena_instance.is_inside_tree() and not p.arena_instance.is_queued_for_deletion():
			return p.arena_instance
		if "_current_arena_node" in p and p._current_arena_node != null and is_instance_valid(p._current_arena_node) and p._current_arena_node.is_inside_tree() and not p._current_arena_node.is_queued_for_deletion():
			return p._current_arena_node
		p = p.get_parent()
	for node in get_tree().get_nodes_in_group("arena"):
		if is_instance_valid(node) and node.is_inside_tree() and not node.is_queued_for_deletion():
			return node
	return null

func _anchor_spread_offset(spread_radius: float) -> Vector3:
	var slot_idx: int = squad_slot_index if squad_slot_index >= 0 else posmod(int(get_instance_id()), 16)
	var angle: float = float(slot_idx) * 2.3999632 # Golden angle distributes 5..20+ units evenly
	return Vector3(cos(angle) * spread_radius, 0.0, sin(angle) * spread_radius)

func _resolve_anchor_position(anchor: int, stance: int) -> Vector3:
	var stance_dist: float = STANCE_DISTANCES[clampi(stance, 0, 2)]
	match anchor:
		TacticalAnchor.ENGAGE_TARGET:
			var target := _get_combat_target()
			if target:
				var to_self := global_position - target.global_position
				to_self.y = 0.0
				var dir := to_self.normalized() if to_self.length_squared() > 0.01 else Vector3.BACK
				return target.global_position + dir * stance_dist + _anchor_spread_offset(0.7)
			return global_position

		TacticalAnchor.FLANK_TARGET:
			var target := _get_combat_target()
			if target:
				var to_self := global_position - target.global_position
				to_self.y = 0.0
				var dir := to_self.normalized() if to_self.length_squared() > 0.01 else Vector3.BACK
				var flank_dir := Vector3(-dir.z, 0.0, dir.x)
				return target.global_position + dir * stance_dist + flank_dir * 2.5
			return global_position

		TacticalAnchor.FOCUS_LOW_HP:
			var target := _get_lowest_hp_enemy()
			if not target:
				target = _get_combat_target()
			if target:
				var to_self := global_position - target.global_position
				to_self.y = 0.0
				var dir := to_self.normalized() if to_self.length_squared() > 0.01 else Vector3.BACK
				return target.global_position + dir * stance_dist + _anchor_spread_offset(0.7)
			return global_position

		TacticalAnchor.REGROUP_ALLY:
			var ally := _get_nearest_ally()
			if ally:
				var to_self := global_position - ally.global_position
				to_self.y = 0.0
				var dir := to_self.normalized() if to_self.length_squared() > 0.01 else Vector3.RIGHT
				return ally.global_position + dir * 2.0 + _anchor_spread_offset(1.2)
			return global_position

		TacticalAnchor.SUPPORT_INJURED:
			var injured := _get_lowest_hp_ally()
			if injured:
				var to_self := global_position - injured.global_position
				to_self.y = 0.0
				var dir := to_self.normalized() if to_self.length_squared() > 0.01 else Vector3.BACK
				var desired_range := (heal_range * 0.6) if role == Role.MEDIC else 2.0
				return injured.global_position + dir * maxf(desired_range, 1.5)
			return global_position

		TacticalAnchor.SEEK_COVER:
			var threat := _get_combat_target()
			var threat_pos: Vector3 = threat.global_position if threat else (global_position + Vector3.FORWARD * 6.0)
			var arena := _find_arena()
			if arena and arena.has_method("find_best_cover_point"):
				return arena.find_best_cover_point(global_position, threat_pos) + _anchor_spread_offset(0.8)
			else:
				var away := global_position - threat_pos
				away.y = 0.0
				var dir := away.normalized() if away.length_squared() > 0.01 else Vector3.BACK
				return global_position + dir * 4.0

		TacticalAnchor.PUSH_HILL:
			var arena := _find_arena()
			if arena and arena.has_method("get_hill_state"):
				var hill: Dictionary = arena.get_hill_state(team)
				var h_pos: Vector3 = hill.get("position", global_position)
				var h_rad: float = float(hill.get("radius", 6.0))
				return h_pos + _anchor_spread_offset(h_rad * 0.5)
			elif arena and arena is Node3D:
				return arena.global_position + _anchor_spread_offset(2.5)
			return global_position

		TacticalAnchor.GUARD_HILL_PERIMETER:
			var arena := _find_arena()
			var center_pos := global_position
			var ring_rad := 5.5
			if arena and arena.has_method("get_hill_state"):
				var hill: Dictionary = arena.get_hill_state(team)
				center_pos = hill.get("position", global_position)
				ring_rad = float(hill.get("radius", 6.0)) * 0.85
			elif arena and arena is Node3D:
				center_pos = arena.global_position
			var base_dir := Vector3(-1.0 if team == 0 else 1.0, 0.0, 0.0)
			var slot_idx: int = squad_slot_index if squad_slot_index >= 0 else posmod(int(get_instance_id()), 16)
			var fan_angle: float = clampf((float(slot_idx % 5) - 2.0) * 0.45, -1.2, 1.2)
			var radial := base_dir.rotated(Vector3.UP, fan_angle)
			return center_pos + radial * ring_rad

		TacticalAnchor.HOLD_GROUND, _:
			return global_position

func attack():
	if not can_attack or is_attacking:
		return
	if current_stamina < ATTACK_STAMINA_COST:
		attack_blocked_by_stamina.emit()
		return
	_spend_stamina(ATTACK_STAMINA_COST)
	if is_bot or (ai and (ai.heuristic != "human" or ("is_bot" in ai and ai.is_bot))):
		var target := _get_combat_target()
		if target:
			aim = target.global_position
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
		move = Vector3.ZERO
		locomotion_velocity = Vector3.ZERO
		if _shield:
			_shield.visible = false
		_hide_heal_vfx()
		super._physics_process(delta)
		return

	# Track actual displacement speed and stuck timer
	var disp := global_position - _prev_pos
	disp.y = 0.0
	actual_speed = disp.length() / maxf(delta, 0.0001)
	_prev_pos = global_position

	var wants_to_move := (current_anchor != TacticalAnchor.HOLD_GROUND)
	if wants_to_move and actual_speed < 0.2:
		_stuck_timer += delta
	else:
		_stuck_timer = maxf(0.0, _stuck_timer - delta * 2.0)

	# Edge detection for the per-action cost signals below.
	var was_blocking := is_blocking
	var is_human: bool = (not is_bot and not use_nn and (ai == null or (ai.control_mode == ai.ControlModes.HUMAN and ai.policy_source == ai.PolicySource.HUMAN)))
	if is_human:
		var cursor := get_node_or_null("../Cursor") as Node3D
		if cursor != null:
			aim = cursor.global_position
		var raw_input := Vector3(Input.get_axis("left", "right"), 0.0, Input.get_axis("up", "down"))
		move = move.move_toward(raw_input, 14.0 * delta)
	else:
		var combat_tgt := _get_combat_target()
		if combat_tgt:
			aim = combat_tgt.global_position
		elif role == Role.MEDIC:
			var injured := _get_lowest_hp_ally()
			if injured:
				aim = injured.global_position

		is_running = requested_sprint
		is_blocking = requested_block

		if current_anchor == TacticalAnchor.HOLD_GROUND:
			_has_safe_nav_velocity = false
			if _nav_agent != null and _nav_agent.avoidance_enabled:
				_nav_agent.set_velocity(Vector3.ZERO)
			move = move.move_toward(Vector3.ZERO, 12.0 * delta)
		elif _nav_agent != null:
			var target_dest := _resolve_anchor_position(current_anchor, current_stance)
			_nav_agent.target_position = target_dest
			var dist_to_dest := global_position.distance_to(target_dest)

			var target_move := Vector3.ZERO
			if dist_to_dest > 0.4 and not _nav_agent.is_target_reached():
				var next_point := _nav_agent.get_next_path_position()
				var desired_dir := next_point - global_position
				desired_dir.y = 0.0

				# If no combat target, face travel direction
				if not combat_tgt and desired_dir.length_squared() > 0.01:
					aim = global_position + desired_dir.normalized() * 3.0

				if desired_dir.length_squared() > 0.01:
					desired_dir = desired_dir.normalized()
					if _nav_agent.avoidance_enabled:
						_nav_agent.max_speed = maxf(speed_stat * (SPRINT_SPEED if requested_sprint else 1.0), 0.5)
						_nav_agent.set_velocity(desired_dir * _nav_agent.max_speed)
						if _has_safe_nav_velocity and _safe_nav_velocity.length_squared() > 0.01:
							desired_dir = _safe_nav_velocity.normalized()
					var forward := aim - global_position
					forward.y = 0.0
					if forward.length_squared() > 0.000001:
						forward = forward.normalized()
					else:
						forward = Vector3.FORWARD
					var right := Vector3(-forward.z, 0.0, forward.x)

					var dot_forward := desired_dir.dot(forward)
					var dot_right := desired_dir.dot(right)

					target_move.x = dot_right / STRAFE_SPEED
					if dot_forward < 0.0:
						target_move.z = -dot_forward / BACKPEDAL_SPEED
					else:
						target_move.z = -dot_forward
			elif _nav_agent.avoidance_enabled:
				_nav_agent.set_velocity(Vector3.ZERO)
				_has_safe_nav_velocity = false
			move = move.move_toward(target_move, 12.0 * delta)
		elif requested_move.length_squared() > 0.001:
			var target_move := Vector3(requested_move.y, 0.0, -requested_move.x)
			move = move.move_toward(target_move, 12.0 * delta)
			var aim_offset := aim - global_position
			aim_offset.y = 0.0
			if aim_offset.length_squared() < 0.000001:
				aim_offset = Vector3.FORWARD
			var effective_turn_speed: float = 8.0 if is_bot else turn_speed
			aim_offset = aim_offset.normalized().rotated(Vector3.UP, requested_turn * effective_turn_speed * delta)
			aim = global_position + aim_offset
		else:
			move = move.move_toward(Vector3.ZERO, 12.0 * delta)
	var sprinting := _apply_stamina(delta)
	var run := (SPRINT_SPEED if sprinting else 1.0)
	var attack_slow := (0.5 if is_attacking else 1.0)
	var block_slow := (BLOCK_SPEED_SCALE if is_blocking else 1.0)
	current_speed = speed_stat * run * attack_slow * block_slow
	_shield.visible = false # Placeholder disc hidden; character_animator plays the 3D block animation
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
		is_casting = false
		_hide_heal_vfx()
	if is_blocking and not was_blocking:
		block_started.emit()
	# attack_started is emitted from attack() itself, not here: super.attack()
	# sets is_attacking synchronously, so this edge never saw the transition.
	super._physics_process(delta)

func take_damage(damage:float, attacker: Node3D = null) -> Dictionary:
	var incoming := damage
	if _attack_is_blocked(attacker):
		var block_drain := BLOCKED_HIT_STAMINA + damage * 0.4
		if current_stamina <= block_drain:
			# Guard Break! Stamina depleted by heavy impact
			current_stamina = 0.0
			is_blocking = false
			requested_block = false
			stun(1.5)
			debug_log("guard_break", "[GUARD BREAK] %s's guard was broken by %s!" % [name, attacker.name if attacker else "attacker"])
		else:
			_spend_stamina(block_drain)
			var mitigation := 0.75 if role == Role.TANK else 0.5
			incoming *= (1.0 - mitigation)
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

	# 5% chance of dealing triple damage (critical hit)
	if crit_chance > 0.0 and randf() < crit_chance:
		final_dmg *= crit_multiplier
		critical_hit.emit(final_dmg)
		debug_log("crit", "[CRIT] %s landed a TRIPLE DAMAGE critical hit: %.1f dmg!" % [name, final_dmg])

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
	if end_episode_on_death and ai:
		ai.done = true
	is_dead = true
	is_stunned = false
	is_casting = false
	is_blocking = false
	_stun_timer = 0.0
	_has_safe_nav_velocity = false
	_safe_nav_velocity = Vector3.ZERO
	if _nav_agent != null and _nav_agent.avoidance_enabled:
		_nav_agent.set_velocity(Vector3.ZERO)
	if has_node("Col"):
		$Col.set_deferred("disabled", true)
	if _stun_indicator:
		_stun_indicator.visible = false
	if _level_label:
		_level_label.visible = false
	visible = false
	_hide_heal_vfx()
	debug_log("die", "{0} die".format([name]))
	# The arena owns episode resets; listen for `died` instead of resetting here.
	died.emit()
func swing():
	pass

func _create_stun_indicator() -> void:
	if _stun_indicator == null:
		_stun_indicator = get_node_or_null("StunIndicator")
	if _stun_indicator:
		_stun_indicator.visible = false

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
	super.apply_knockback(force)

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
	if is_blocking:
		_spend_stamina(BLOCK_STAMINA_PER_SEC * delta)
		if current_stamina <= 0.0:
			current_stamina = 0.0
			is_blocking = false
			requested_block = false
		return false
	_time_since_stamina_use += delta
	if _time_since_stamina_use < STAMINA_REGEN_DELAY or current_stamina >= max_stamina:
		return false
	current_stamina = minf(current_stamina + STAMINA_REGEN_PER_SEC * delta, max_stamina)
	return false

# Cylinder axis is Y. Tip it so the disc faces the mesh's forward (-Z).
func _create_shield() -> void:
	if _shield == null:
		_shield = get_node_or_null("Shield")
	if _shield:
		_shield.visible = false


# Puts the shield 0.78 m ahead of the character, along `aim`, matching the
# direction the block arc test uses. Only meaningful while blocking.
func _update_shield_pose() -> void:
	var dir := aim - global_position
	dir.y = 0.0
	if dir.length_squared() < 0.000001:
		return
	dir = dir.normalized()
	_shield.global_position = global_position + dir * 0.78 + Vector3.UP * 0.05
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
		is_casting = true
		_spend_stamina(cost)
	else:
		is_casting = false
		_hide_heal_vfx()

func _create_heal_vfx() -> void:
	if _heal_beam == null:
		_heal_beam = get_node_or_null("HealBeam")
	if _heal_beam:
		_heal_beam.visible = false

func _show_heal_vfx(target_pos: Vector3) -> void:
	if not _heal_beam:
		return
	_heal_beam.visible = false # Placeholder hidden; character_animator plays the 3D casting animation

func _hide_heal_vfx() -> void:
	if _heal_beam and _heal_beam.visible:
		_heal_beam.visible = false
