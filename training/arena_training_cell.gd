extends Node3D
class_name ArenaTrainingCell

@export var arena_scene: PackedScene
@export var episode_duration: float = 60.0
@export var squad_size: int = 3
@export var koth_mode: bool = false
@export var respawn_delay: float = 5.0
@export var randomize_roles_per_episode: bool = true

const SoldierScene = preload("res://characters/soldier3/soldier3.tscn")
const ROLE_ORDER := [0, 1, 2, 3, 2] # Tank, Medic, Striker, Basic, Striker
const ROLE_NAMES := ["Tank", "Medic", "Striker", "Basic"]

var _blue_soldiers: Array[CharacterBody3D] = []
var _red_soldiers: Array[CharacterBody3D] = []
var _respawn_timers: Dictionary = {}
var _is_resetting: bool = false
var arena_instance: Node3D = null

@onready var _timer: Timer = get_node_or_null("CellEpisodeTimer")

func _ready() -> void:
	for child in get_children():
		if child is Node3D and child.has_method("find_best_cover_point"):
			arena_instance = child
			break
	if arena_instance == null and arena_scene:
		arena_instance = arena_scene.instantiate()
		add_child(arena_instance)

	if arena_instance:
		if "has_hill" in arena_instance and arena_instance.has_hill:
			koth_mode = true
		if koth_mode and arena_instance.has_signal("koth_won"):
			arena_instance.koth_won.connect(_on_koth_won)

	if _timer == null:
		push_warning("%s: CellEpisodeTimer missing from scene hierarchy" % name)
	else:
		if not _timer.timeout.is_connected(_on_timeout):
			_timer.timeout.connect(_on_timeout)
		_timer.wait_time = episode_duration
		_timer.start()

	_collect_or_spawn_squads()

func _physics_process(delta: float) -> void:
	if not koth_mode or _is_resetting or _respawn_timers.is_empty():
		return
	var to_respawn: Array[CharacterBody3D] = []
	for s in _respawn_timers.keys():
		if not is_instance_valid(s):
			_respawn_timers.erase(s)
			continue
		_respawn_timers[s] -= delta
		if _respawn_timers[s] <= 0.0:
			to_respawn.append(s)
	for s in to_respawn:
		_respawn_timers.erase(s)
		if is_instance_valid(s) and s.has_method("respawn"):
			s.respawn()

func _collect_or_spawn_squads() -> void:
	_blue_soldiers.clear()
	_red_soldiers.clear()
	for child in get_children():
		if child is CharacterBody3D:
			var is_red: bool = ("team" in child and child.team == 1)
			_wire_soldier(child, is_red)
			if is_red:
				_red_soldiers.append(child)
			else:
				_blue_soldiers.append(child)

	# Only instantiate dynamically if no scene soldiers were placed in the hierarchy
	if _blue_soldiers.is_empty() and _red_soldiers.is_empty():
		var count := maxi(squad_size, 1)
		for i in count:
			var role_id: int = randi_range(0, 3) if randomize_roles_per_episode else ROLE_ORDER[i % ROLE_ORDER.size()]
			var s := _spawn_soldier("Blue_%s_%d" % [ROLE_NAMES[role_id], i + 1], 0, role_id, i, count, false)
			_blue_soldiers.append(s)
		for i in count:
			var role_id: int = randi_range(0, 3) if randomize_roles_per_episode else ROLE_ORDER[i % ROLE_ORDER.size()]
			var s := _spawn_soldier("Red_%s_%d" % [ROLE_NAMES[role_id], i + 1], 1, role_id, i, count, true)
			_red_soldiers.append(s)
	elif randomize_roles_per_episode:
		for s in _blue_soldiers + _red_soldiers:
			if is_instance_valid(s) and s.has_method("set_random_role"):
				s.set_random_role()

func _wire_soldier(s: CharacterBody3D, bot_controlled: bool) -> void:
	s.end_episode_on_death = not koth_mode
	s.spawn_pos = s.global_position
	s.aim = s.global_position + (Vector3(-5, 0, 0) if bot_controlled else Vector3(5, 0, 0))
	if not s.died.is_connected(_on_soldier_died):
		s.died.connect(_on_soldier_died.bind(s))

	var ai = s.get_node_or_null("AI")
	if ai:
		if not bot_controlled:
			ai.policy_source = ai.PolicySource.HUMAN
			ai.control_mode = ai.ControlModes.TRAINING
			ai.is_bot = false
			ai.heuristic = "human"
			if not ai.is_in_group("AGENT"):
				ai.add_to_group("AGENT")
		else:
			ai.policy_source = ai.PolicySource.BOT_HEURISTIC
			ai.control_mode = ai.ControlModes.HUMAN
			ai.is_bot = true
			ai.heuristic = "bot"
			if ai.is_in_group("AGENT"):
				ai.remove_from_group("AGENT")

func _spawn_offset_for(team: int, idx: int, count: int) -> Vector3:
	var arena_half_x := 14.0
	if arena_instance and "arena_size" in arena_instance:
		arena_half_x = float(arena_instance.arena_size.x) * 0.5
	var base_x: float = -(arena_half_x - 6.0) if team == 0 else (arena_half_x - 6.0)
	var row := idx / 5
	var col := idx % mini(count, 5)
	var row_dir := -1.0 if team == 0 else 1.0
	var z_off := (float(col) - float(mini(count, 5) - 1) * 0.5) * 2.5
	var x_off := base_x + float(row) * 2.2 * row_dir
	return Vector3(x_off, 1.0, z_off)

func _spawn_soldier(s_name: String, team_id: int, role_id: int, slot_idx: int, count: int, bot_controlled: bool) -> CharacterBody3D:
	var s = SoldierScene.instantiate()
	s.name = s_name
	s.team = team_id
	s.role = role_id
	s.squad_slot_index = slot_idx
	s.randomize_level_on_spawn = true
	s.is_bot = bot_controlled
	s.use_nn = false
	add_child(s)
	s.global_position = global_position + _spawn_offset_for(team_id, slot_idx, count)
	_wire_soldier(s, bot_controlled)
	return s

func _on_soldier_died(soldier: CharacterBody3D = null) -> void:
	if _is_resetting:
		return
	if koth_mode:
		if soldier != null and is_instance_valid(soldier) and not _respawn_timers.has(soldier):
			_respawn_timers[soldier] = respawn_delay
		return
	var blue_alive := _count_alive(_blue_soldiers)
	var red_alive := _count_alive(_red_soldiers)
	if blue_alive == 0 or red_alive == 0:
		_end_episode()

func _on_koth_won(winner_team: int) -> void:
	if _is_resetting:
		return
	_end_episode(winner_team)

func _on_timeout() -> void:
	if _is_resetting:
		return
	var winner := -1
	if koth_mode and arena_instance and "blue_hill_score" in arena_instance:
		if arena_instance.blue_hill_score > arena_instance.red_hill_score:
			winner = 0
		elif arena_instance.red_hill_score > arena_instance.blue_hill_score:
			winner = 1
	_end_episode(winner)

func _end_episode(winner_team: int = -1) -> void:
	_is_resetting = true
	_respawn_timers.clear()
	for s in _blue_soldiers:
		if is_instance_valid(s):
			var ai = s.get_node_or_null("AI")
			if ai and ai.is_in_group("AGENT"):
				if koth_mode and ai.has_method("notify_koth_result"):
					ai.notify_koth_result(winner_team)
				else:
					ai.done = true

	if arena_instance and arena_instance.has_method("reset_koth"):
		arena_instance.reset_koth()

	for s in _blue_soldiers + _red_soldiers:
		if is_instance_valid(s):
			if randomize_roles_per_episode and s.has_method("set_random_role"):
				s.set_random_role()
			if s.has_method("respawn"):
				s.respawn()

	_is_resetting = false
	if _timer:
		_timer.wait_time = episode_duration
		_timer.start()

func _count_alive(soldiers: Array[CharacterBody3D]) -> int:
	var count := 0
	for s in soldiers:
		if is_instance_valid(s) and ("is_dead" not in s or not s.is_dead) and s.current_health > 0:
			count += 1
	return count
