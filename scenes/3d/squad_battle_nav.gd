extends Node3D

@export var round_duration: float = 90.0
@export var squad_size: int = 5
@export var respawn_delay: float = 5.0
@export var randomize_roles_per_episode: bool = true
@export var onnx_model_path: String = "res://models/squad_v2_navmesh.onnx"
@export var win_celebration_time: float = 2.5
@export var rotate_arenas: bool = true

const ARENA_SCENES := {
	"koth": "res://scenes/3d/arenas/arena_koth.tscn",
	"pillars": "res://scenes/3d/arenas/arena_pillars.tscn",
	"dividers": "res://scenes/3d/arenas/arena_dividers.tscn",
	"alcoves": "res://scenes/3d/arenas/arena_alcoves.tscn",
	"compound": "res://scenes/3d/arenas/arena_compound.tscn"
}

const ARENA_KEYS := ["koth", "pillars", "dividers", "alcoves", "compound"]
const SoldierScene = preload("res://characters/soldier3/soldier3.tscn")
const ROLE_ORDER := [0, 1, 2, 3, 2] # Tank, Medic, Striker, Basic, Striker
const ROLE_NAMES := ["Tank", "Medic", "Striker", "Basic"]

var blue_score: int = 0
var red_score: int = 0
var round_number: int = 1
var current_arena_key: String = "koth"
var _current_arena_node: Node3D = null
var mirror_nn: bool = false

var _blue_soldiers: Array[CharacterBody3D] = []
var _red_soldiers: Array[CharacterBody3D] = []
var _respawn_timers: Dictionary = {}

var _is_round_ending: bool = false
var _time_remaining: float = 90.0

@onready var arena_container: Node3D = $ArenaContainer
@onready var round_timer: Timer = $RoundTimer
@onready var blue_score_lbl: Label = $BattleHUD/Margin/TopBar/ScoreBox/BlueScore
@onready var red_score_lbl: Label = $BattleHUD/Margin/TopBar/ScoreBox/RedScore
@onready var round_lbl: Label = $BattleHUD/Margin/TopBar/ScoreBox/RoundLabel
@onready var arena_name_lbl: Label = $BattleHUD/Margin/TopBar/ScoreBox/ArenaLabel
@onready var timer_lbl: Label = $BattleHUD/Margin/TopBar/TimerLabel
@onready var announcement_lbl: Label = $BattleHUD/CenterAnnouncement/Label
@onready var blue_list: VBoxContainer = $BattleHUD/Margin/BottomRow/BluePanel/BlueList
@onready var red_list: VBoxContainer = $BattleHUD/Margin/BottomRow/RedPanel/RedList
@onready var blue_title_lbl: Label = $BattleHUD/Margin/BottomRow/BluePanel/BlueTitle
@onready var red_title_lbl: Label = $BattleHUD/Margin/BottomRow/RedPanel/RedTitle

func _ready() -> void:
	var forced_arena := false
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--arena="):
			var selected = arg.substr(8).to_lower()
			if ARENA_SCENES.has(selected):
				current_arena_key = selected
				rotate_arenas = false
				forced_arena = true
		elif arg == "--koth":
			current_arena_key = "koth"
			rotate_arenas = false
			forced_arena = true
		elif arg.begins_with("--squad-size="):
			squad_size = maxi(1, int(arg.substr(13)))
		elif arg == "--20v20":
			squad_size = 20
		elif arg == "--mirror" or arg == "--red-nn":
			mirror_nn = true

	var has_nn: bool = FileAccess.file_exists(onnx_model_path)
	if blue_title_lbl:
		blue_title_lbl.text = "BLUE SQUAD %dv%d (ONNX: %s)" % [squad_size, squad_size, onnx_model_path.get_file()] if has_nn else "BLUE SQUAD %dv%d (HEURISTIC BOT)" % [squad_size, squad_size]
	if red_title_lbl:
		red_title_lbl.text = "RED SQUAD %dv%d (ONNX: %s)" % [squad_size, squad_size, onnx_model_path.get_file()] if (has_nn and mirror_nn) else "RED SQUAD %dv%d (HEURISTIC BOT)" % [squad_size, squad_size]

	# Use pre-placed arena from scene hierarchy unless CLI requested a different one
	_init_or_load_arena(forced_arena)
	_collect_or_spawn_squads()

	_time_remaining = round_duration
	round_timer.wait_time = round_duration
	round_timer.timeout.connect(_on_round_timer_timeout)
	round_timer.start()

	_update_hud()
	_show_announcement("ROUND 1 - %s!" % ("KING OF THE HILL" if _is_koth_active() else "ENGAGE"), 2.0)

func _is_koth_active() -> bool:
	return _current_arena_node != null and "has_hill" in _current_arena_node and _current_arena_node.has_hill

func _init_or_load_arena(forced_arena: bool) -> void:
	if not forced_arena and arena_container:
		for child in arena_container.get_children():
			if child is Node3D and child.has_method("find_best_cover_point"):
				_current_arena_node = child
				current_arena_key = "koth" if ("has_hill" in child and child.has_hill) else current_arena_key
				if _current_arena_node.has_signal("koth_won") and not _current_arena_node.koth_won.is_connected(_on_koth_won):
					_current_arena_node.koth_won.connect(_on_koth_won)
				if arena_name_lbl:
					arena_name_lbl.text = "Arena: " + _current_arena_node.arena_name
				return
	_load_arena(current_arena_key)

func _load_arena(key: String) -> void:
	if _current_arena_node != null and is_instance_valid(_current_arena_node):
		_current_arena_node.queue_free()

	current_arena_key = key
	var scene_path: String = ARENA_SCENES.get(key, ARENA_SCENES["koth"])
	var scene = load(scene_path)
	if scene:
		_current_arena_node = scene.instantiate()
		arena_container.add_child(_current_arena_node)
		if _current_arena_node.has_signal("koth_won"):
			_current_arena_node.koth_won.connect(_on_koth_won)
		print("[SquadBattleNav] Loaded Arena: %s" % _current_arena_node.arena_name)
		if arena_name_lbl:
			arena_name_lbl.text = "Arena: " + _current_arena_node.arena_name

func _collect_or_spawn_squads() -> void:
	var use_nn_blue: bool = FileAccess.file_exists(onnx_model_path)
	var use_nn_red: bool = use_nn_blue and mirror_nn
	var is_koth := _is_koth_active()

	var scene_blue: Array[CharacterBody3D] = []
	var scene_red: Array[CharacterBody3D] = []
	for child in get_children():
		if child is CharacterBody3D:
			if "team" in child and child.team == 1:
				scene_red.append(child)
			else:
				scene_blue.append(child)

	# Use pre-placed scene soldiers directly when they match the requested squad_size
	if scene_blue.size() == squad_size and scene_red.size() == squad_size:
		_blue_soldiers = scene_blue
		_red_soldiers = scene_red
		for i in _blue_soldiers.size():
			_reset_and_wire_soldier(_blue_soldiers[i], 0, i, squad_size, use_nn_blue, is_koth)
		for i in _red_soldiers.size():
			_reset_and_wire_soldier(_red_soldiers[i], 1, i, squad_size, use_nn_red, is_koth)
		return

	# Dynamic fallback only when squad_size differs (e.g. --squad-size=20)
	_respawn_timers.clear()
	for s in _blue_soldiers + _red_soldiers + scene_blue + scene_red:
		if is_instance_valid(s):
			s.queue_free()
	_blue_soldiers.clear()
	_red_soldiers.clear()

	var count := maxi(squad_size, 1)
	for i in count:
		var role_id: int = ROLE_ORDER[i % ROLE_ORDER.size()]
		_blue_soldiers.append(_spawn_soldier("Blue_%s_%d" % [ROLE_NAMES[role_id], i + 1], 0, role_id, i, count, use_nn_blue, is_koth))
	for i in count:
		var role_id: int = ROLE_ORDER[i % ROLE_ORDER.size()]
		_red_soldiers.append(_spawn_soldier("Red_%s_%d" % [ROLE_NAMES[role_id], i + 1], 1, role_id, i, count, use_nn_red, is_koth))

func _spawn_pos_for(team: int, idx: int, count: int) -> Vector3:
	var arena_half_x := 14.0
	if _current_arena_node and "arena_size" in _current_arena_node:
		arena_half_x = float(_current_arena_node.arena_size.x) * 0.5
	var base_x := -(arena_half_x - 6.0) if team == 0 else (arena_half_x - 6.0)
	var row := idx / 5
	var col := idx % mini(count, 5)
	var row_dir := -1.0 if team == 0 else 1.0
	var z_off := (float(col) - float(mini(count, 5) - 1) * 0.5) * 2.5
	var x_off := base_x + float(row) * 2.2 * row_dir
	return Vector3(x_off, 1.0, z_off)

func _reset_and_wire_soldier(s: CharacterBody3D, team_id: int, slot_idx: int, count: int, use_nn_flag: bool, is_koth: bool) -> void:
	s.end_episode_on_death = not is_koth
	if s.ai and "onnx_model_path" in s.ai:
		s.ai.onnx_model_path = onnx_model_path
	s.use_nn = use_nn_flag
	s.spawn_pos = _spawn_pos_for(team_id, slot_idx, count)
	if randomize_roles_per_episode and s.has_method("set_random_role"):
		s.set_random_role()
	if s.has_method("respawn"):
		s.respawn()
	s.aim = s.global_position + (Vector3(5, 0, 0) if team_id == 0 else Vector3(-5, 0, 0))
	if not s.died.is_connected(_on_soldier_died):
		s.died.connect(_on_soldier_died.bind(s))

func _spawn_soldier(s_name: String, team_id: int, role_id: int, slot_idx: int, count: int, use_nn_flag: bool, is_koth: bool) -> CharacterBody3D:
	var s = SoldierScene.instantiate()
	s.name = s_name
	s.team = team_id
	s.role = role_id
	s.squad_slot_index = slot_idx
	s.end_episode_on_death = not is_koth
	s.randomize_level_on_spawn = true
	s.is_bot = true
	if s.ai and "onnx_model_path" in s.ai:
		s.ai.onnx_model_path = onnx_model_path
	s.use_nn = use_nn_flag
	add_child(s)
	s.global_position = _spawn_pos_for(team_id, slot_idx, count)
	s.spawn_pos = s.global_position
	s.aim = s.global_position + (Vector3(5, 0, 0) if team_id == 0 else Vector3(-5, 0, 0))
	s.died.connect(_on_soldier_died.bind(s))
	return s

func _process(delta: float) -> void:
	if not _is_round_ending and round_timer:
		_time_remaining = maxf(0.0, round_timer.time_left)
		_update_hud()

func _physics_process(delta: float) -> void:
	if _is_round_ending or not _is_koth_active() or _respawn_timers.is_empty():
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

func _on_soldier_died(soldier: CharacterBody3D = null) -> void:
	if _is_round_ending:
		return

	if _is_koth_active():
		if soldier != null and is_instance_valid(soldier) and not _respawn_timers.has(soldier):
			_respawn_timers[soldier] = respawn_delay
		_update_hud()
		return

	var blue_alive := _count_alive(_blue_soldiers)
	var red_alive := _count_alive(_red_soldiers)
	print("[SquadBattleNav] Casualty! Blue: %d alive | Red: %d alive" % [blue_alive, red_alive])
	_update_hud()

	if blue_alive == 0 or red_alive == 0:
		_finish_round(0 if blue_alive > 0 else (1 if red_alive > 0 else -1), false)

func _on_koth_won(winner_team: int) -> void:
	if _is_round_ending:
		return
	_finish_round(winner_team, false, "KOTH VICTORY!")

func _on_round_timer_timeout() -> void:
	if _is_round_ending:
		return
	var winner := -1
	if _is_koth_active() and "blue_hill_score" in _current_arena_node:
		if _current_arena_node.blue_hill_score > _current_arena_node.red_hill_score:
			winner = 0
		elif _current_arena_node.red_hill_score > _current_arena_node.blue_hill_score:
			winner = 1
		_finish_round(winner, true, "TIME OUT! KOTH SCORE LEAD")
	else:
		var blue_hp := _total_health(_blue_soldiers)
		var red_hp := _total_health(_red_soldiers)
		if blue_hp > red_hp:
			winner = 0
		elif red_hp > blue_hp:
			winner = 1
		_finish_round(winner, true, "TIME OUT! HP LEAD")

func _finish_round(winner_team: int, is_timeout: bool, suffix: String = "") -> void:
	_is_round_ending = true
	_respawn_timers.clear()
	round_timer.stop()
	var winner := "DRAW"
	if winner_team == 0:
		winner = "BLUE SQUAD"
		blue_score += 1
	elif winner_team == 1:
		winner = "RED SQUAD"
		red_score += 1

	var victory_msg := "%s%s WINS ROUND %d!" % [winner, (" (" + suffix + ")") if suffix != "" else "", round_number]
	if is_timeout and winner_team == -1:
		victory_msg = "TIME OUT! DRAW IN ROUND %d!" % round_number
	print("[SquadBattleNav] Round Ended: %s (Score: Blue %d - %d Red)" % [victory_msg, blue_score, red_score])
	_show_announcement(victory_msg, win_celebration_time)
	get_tree().create_timer(win_celebration_time).timeout.connect(_reset_round)

func _reset_round() -> void:
	round_number += 1
	_is_round_ending = false
	_respawn_timers.clear()

	if rotate_arenas:
		var next_idx := (ARENA_KEYS.find(current_arena_key) + 1) % ARENA_KEYS.size()
		_load_arena(ARENA_KEYS[next_idx])
	elif _current_arena_node and _current_arena_node.has_method("reset_koth"):
		_current_arena_node.reset_koth()

	var is_koth := _is_koth_active()
	var use_nn_blue: bool = FileAccess.file_exists(onnx_model_path)
	var use_nn_red: bool = use_nn_blue and mirror_nn
	for i in _blue_soldiers.size():
		if is_instance_valid(_blue_soldiers[i]):
			_reset_and_wire_soldier(_blue_soldiers[i], 0, i, squad_size, use_nn_blue, is_koth)
	for i in _red_soldiers.size():
		if is_instance_valid(_red_soldiers[i]):
			_reset_and_wire_soldier(_red_soldiers[i], 1, i, squad_size, use_nn_red, is_koth)

	_time_remaining = round_duration
	round_timer.wait_time = round_duration
	round_timer.start()

	_update_hud()
	_show_announcement("ROUND %d - %s!" % [round_number, "KING OF THE HILL" if _is_koth_active() else "ENGAGE"], 2.0)

func _count_alive(soldiers: Array[CharacterBody3D]) -> int:
	var count := 0
	for s in soldiers:
		if is_instance_valid(s) and ("is_dead" not in s or not s.is_dead) and s.current_health > 0:
			count += 1
	return count

func _total_health(soldiers: Array[CharacterBody3D]) -> float:
	var total := 0.0
	for s in soldiers:
		if is_instance_valid(s) and ("is_dead" not in s or not s.is_dead):
			total += maxf(0.0, s.current_health)
	return total

func _update_hud() -> void:
	if blue_score_lbl:
		blue_score_lbl.text = str(blue_score)
	if red_score_lbl:
		red_score_lbl.text = str(red_score)
	if round_lbl:
		round_lbl.text = "ROUND %d" % round_number
	if arena_name_lbl and _current_arena_node:
		if _is_koth_active():
			var b_h: float = _current_arena_node.blue_hill_score
			var r_h: float = _current_arena_node.red_hill_score
			var w_h: float = _current_arena_node.hill_win_score
			var owner_txt := "NEUTRAL"
			if _current_arena_node.hill_contested:
				owner_txt = "CONTESTED"
			elif _current_arena_node.hill_owner == 0:
				owner_txt = "BLUE HILL"
			elif _current_arena_node.hill_owner == 1:
				owner_txt = "RED HILL"
			arena_name_lbl.text = "KOTH [%.0f - %.0f / %.0f | %s]" % [b_h, r_h, w_h, owner_txt]
		else:
			arena_name_lbl.text = "Arena: " + _current_arena_node.arena_name
	if timer_lbl:
		timer_lbl.text = "%02d:%02d" % [int(_time_remaining) / 60, int(_time_remaining) % 60]

	_populate_soldier_list(blue_list, _blue_soldiers, Color(0.3, 0.6, 1.0))
	_populate_soldier_list(red_list, _red_soldiers, Color(1.0, 0.35, 0.35))

func _populate_soldier_list(container: VBoxContainer, soldiers: Array[CharacterBody3D], col: Color) -> void:
	if not container:
		return
	const MAX_ROWS := 8
	for i in MAX_ROWS:
		var row_lbl := container.get_node_or_null("Row%d" % i) as Label
		if row_lbl == null:
			continue
		if i >= soldiers.size() or not is_instance_valid(soldiers[i]):
			row_lbl.visible = false
			continue
		var s := soldiers[i]
		var alive: bool = ("is_dead" not in s or not s.is_dead) and s.current_health > 0
		var role_name: String = ROLE_NAMES[clampi(int(s.role), 0, ROLE_NAMES.size() - 1)]
		var anchor_name := ""
		if "current_anchor" in s:
			match int(s.current_anchor):
				0: anchor_name = "Engage"
				1: anchor_name = "Flank"
				2: anchor_name = "Focus"
				3: anchor_name = "Regroup"
				4: anchor_name = "Support"
				5: anchor_name = "Cover"
				6: anchor_name = "Hold"
				7: anchor_name = "PushHill"
				8: anchor_name = "GuardHill"
		var status_str := anchor_name
		if not alive:
			if _respawn_timers.has(s):
				status_str = "RESPAWN %.1fs" % maxf(0.0, float(_respawn_timers[s]))
			else:
				status_str = "DEAD"
		row_lbl.text = "%s Lv%d [%s]: %d/%d HP" % [
			role_name,
			s.level,
			status_str,
			maxi(0, int(s.current_health)),
			int(s.max_health)
		]
		row_lbl.modulate = col if alive else Color(0.5, 0.5, 0.5, 0.6)
		row_lbl.visible = true

	var overflow_lbl := container.get_node_or_null("OverflowLabel") as Label
	if overflow_lbl:
		if soldiers.size() > MAX_ROWS:
			overflow_lbl.text = "+%d more (%d alive)" % [soldiers.size() - MAX_ROWS, _count_alive(soldiers)]
			overflow_lbl.modulate = col
			overflow_lbl.visible = true
		else:
			overflow_lbl.visible = false

func _show_announcement(text: String, duration: float) -> void:
	if not announcement_lbl:
		return
	announcement_lbl.text = text
	announcement_lbl.visible = true
	get_tree().create_timer(duration).timeout.connect(func():
		if announcement_lbl:
			announcement_lbl.visible = false
	)
