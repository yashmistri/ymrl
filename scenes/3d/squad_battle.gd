extends Node3D

@export var round_duration: float = 60.0
@export var onnx_model_path: String = "res://models/squad_rl_500k.onnx"
@export var win_celebration_time: float = 2.0

var blue_score: int = 0
var red_score: int = 0
var round_number: int = 1

var _blue_soldiers: Array[CharacterBody3D] = []
var _red_soldiers: Array[CharacterBody3D] = []

var _spawn_transforms: Dictionary = {}
var _spawn_aims: Dictionary = {}
var _is_round_ending: bool = false
var _time_remaining: float = 60.0

# UI References
@onready var round_timer: Timer = $RoundTimer
@onready var blue_score_lbl: Label = $BattleHUD/Margin/TopBar/ScoreBox/BlueScore
@onready var red_score_lbl: Label = $BattleHUD/Margin/TopBar/ScoreBox/RedScore
@onready var round_lbl: Label = $BattleHUD/Margin/TopBar/ScoreBox/RoundLabel
@onready var timer_lbl: Label = $BattleHUD/Margin/TopBar/TimerLabel
@onready var announcement_lbl: Label = $BattleHUD/CenterAnnouncement/Label
@onready var blue_list: VBoxContainer = $BattleHUD/Margin/BottomRow/BluePanel/BlueList
@onready var red_list: VBoxContainer = $BattleHUD/Margin/BottomRow/RedPanel/RedList

func _ready() -> void:
	# Hide mouse cursor
	var cursor_node := get_node_or_null("Cursor") as Node3D
	if cursor_node:
		cursor_node.visible = false

	# Resolve model path
	if not FileAccess.file_exists(onnx_model_path):
		if FileAccess.file_exists("res://models/squad_rl_500k.onnx"):
			onnx_model_path = "res://models/squad_rl_500k.onnx"
		elif FileAccess.file_exists("res://models/frozen_opponent.onnx"):
			onnx_model_path = "res://models/frozen_opponent.onnx"
		elif FileAccess.file_exists("res://models/bc_squad_pretrained.onnx"):
			onnx_model_path = "res://models/bc_squad_pretrained.onnx"

	print("[Squad Battle] Initialized with NN model: %s" % onnx_model_path)

	# Collect Blue soldiers
	for node in find_children("Blue*", "CharacterBody3D", false):
		_blue_soldiers.append(node)
		_setup_soldier(node, 0)

	# Collect Red soldiers
	for node in find_children("Red*", "CharacterBody3D", false):
		_red_soldiers.append(node)
		_setup_soldier(node, 1)

	_time_remaining = round_duration
	round_timer.wait_time = round_duration
	round_timer.timeout.connect(_on_round_timer_timeout)
	round_timer.start()

	_update_hud()
	_show_announcement("ROUND 1 - FIGHT!", 1.5)

func _setup_soldier(s: CharacterBody3D, team_id: int) -> void:
	s.team = team_id
	s.is_bot = true
	s.use_nn = true

	# Randomize level 1, 2, or 3
	if s.has_method("set_random_level"):
		s.set_random_level()
	else:
		s.level = randi_range(1, 3)
		if "use_role_preset_stats" in s and s.use_role_preset_stats:
			s._apply_role_stats()
		if s.has_method("_apply_role_visuals"):
			s._apply_role_visuals()
		s.current_health = s.max_health
		s.current_stamina = s.max_stamina

	# Store initial transform & aim
	_spawn_transforms[s] = s.global_transform
	var forward_dir := Vector3(0, 0, -5) if team_id == 0 else Vector3(0, 0, 5)
	_spawn_aims[s] = s.global_position + forward_dir
	s.aim = _spawn_aims[s]

	if not s.died.is_connected(_on_soldier_died):
		s.died.connect(_on_soldier_died)

	var ai = s.get_node_or_null("AI")
	if ai:
		ai.policy_source = ai.PolicySource.NEURAL_NETWORK
		ai.control_mode = ai.ControlModes.HUMAN
		ai.onnx_model_path = onnx_model_path
		ai.is_bot = true
		if ai.is_in_group("AGENT"):
			ai.remove_from_group("AGENT")

var _debug_timer: float = 0.0

func _process(delta: float) -> void:
	if not _is_round_ending and round_timer:
		_time_remaining = maxf(0.0, round_timer.time_left)
		if timer_lbl:
			timer_lbl.text = "TIME: %04.1fs" % _time_remaining

	_debug_timer += delta
	if _debug_timer >= 3.0:
		_debug_timer = 0.0
		var b_alive := _living_count(_blue_soldiers)
		var r_alive := _living_count(_red_soldiers)
		var b_hp := _total_health(_blue_soldiers)
		var r_hp := _total_health(_red_soldiers)
		print("[Battle Status] Round %d | Time: %.1fs | Blue: %d alive (%.0f HP) vs Red: %d alive (%.0f HP)" % [round_number, _time_remaining, b_alive, b_hp, r_alive, r_hp])
		for s in _blue_soldiers:
			print("   Blue %s: pos=%s vel=%s block=%s" % [s.name, s.global_position, s.velocity, s.is_blocking])
		for s in _red_soldiers:
			print("   Red %s: pos=%s vel=%s block=%s" % [s.name, s.global_position, s.velocity, s.is_blocking])

	_update_hud_unit_cards()

func _on_soldier_died() -> void:
	if _is_round_ending:
		return

	var blue_alive := _living_count(_blue_soldiers)
	var red_alive := _living_count(_red_soldiers)

	print("[Squad Battle] Casualty! Blue Alive: %d | Red Alive: %d" % [blue_alive, red_alive])

	# Check win condition
	if blue_alive == 0 or red_alive == 0:
		if blue_alive > 0 and red_alive == 0:
			blue_score += 1
			_end_round("BLUE SQUAD WINS ROUND %d!" % round_number, Color(0.2, 0.6, 1.0))
		elif red_alive > 0 and blue_alive == 0:
			red_score += 1
			_end_round("RED SQUAD WINS ROUND %d!" % round_number, Color(1.0, 0.25, 0.25))
		else:
			_end_round("ROUND %d DRAW!" % round_number, Color(1.0, 0.85, 0.2))

func _on_round_timer_timeout() -> void:
	if _is_round_ending:
		return

	var blue_alive := _living_count(_blue_soldiers)
	var red_alive := _living_count(_red_soldiers)

	if blue_alive > red_alive:
		blue_score += 1
		_end_round("TIME OUT - BLUE SQUAD WINS!", Color(0.2, 0.6, 1.0))
	elif red_alive > blue_alive:
		red_score += 1
		_end_round("TIME OUT - RED SQUAD WINS!", Color(1.0, 0.25, 0.25))
	else:
		# Tiebreaker on total remaining HP
		var blue_hp := _total_health(_blue_soldiers)
		var red_hp := _total_health(_red_soldiers)
		if blue_hp > red_hp:
			blue_score += 1
			_end_round("TIME OUT - BLUE WINS ON HP!", Color(0.2, 0.6, 1.0))
		elif red_hp > blue_hp:
			red_score += 1
			_end_round("TIME OUT - RED WINS ON HP!", Color(1.0, 0.25, 0.25))
		else:
			_end_round("TIME OUT - DRAW!", Color(1.0, 0.85, 0.2))

func _end_round(message: String, color: Color) -> void:
	_is_round_ending = true
	round_timer.stop()
	print("[Squad Battle] Round Ended: %s (Score: Blue %d - %d Red)" % [message, blue_score, red_score])

	_update_hud()
	_show_announcement(message, win_celebration_time + 0.5, color)

	# Wait celebration delay, then reset
	await get_tree().create_timer(win_celebration_time).timeout
	reset_round()

func reset_round() -> void:
	round_number += 1
	_is_round_ending = false
	print("[Squad Battle] Resetting for Round %d..." % round_number)

	# Full reset of all soldiers
	for s in _blue_soldiers + _red_soldiers:
		if not is_instance_valid(s):
			continue

		# Randomize level 1, 2, or 3 for the new round
		if s.has_method("set_random_level"):
			s.set_random_level()
		else:
			s.level = randi_range(1, 3)
			if "use_role_preset_stats" in s and s.use_role_preset_stats:
				s._apply_role_stats()
			if s.has_method("_apply_role_visuals"):
				s._apply_role_visuals()
			s.current_health = s.max_health
			s.current_stamina = s.max_stamina

		# Restore transform & velocity
		if _spawn_transforms.has(s):
			s.global_transform = _spawn_transforms[s]
		s.velocity = Vector3.ZERO

		# Restore health & stamina
		s.current_health = s.max_health
		s.current_stamina = s.max_stamina
		s._time_since_stamina_use = 0.0

		# Clear state flags
		s.is_dead = false
		s.is_stunned = false
		s._stun_timer = 0.0
		s.is_blocking = false
		s.is_running = false
		s.is_attacking = false
		s.visible = true

		if _spawn_aims.has(s):
			s.aim = _spawn_aims[s]

		# Clear VFX
		if "_stun_indicator" in s and s._stun_indicator:
			s._stun_indicator.visible = false
		if s.has_method("_hide_heal_vfx"):
			s._hide_heal_vfx()

		# Reset AI sensors and action history
		var ai = s.get_node_or_null("AI")
		if ai:
			ai.policy_source = ai.PolicySource.NEURAL_NETWORK
			ai.control_mode = ai.ControlModes.HUMAN
			ai.onnx_model_path = onnx_model_path
			ai.done = false
			if ai.has_method("reset"):
				ai.reset()
			if ai.has_method("set_done_false"):
				ai.set_done_false()

	# Restart round timer
	_time_remaining = round_duration
	round_timer.wait_time = round_duration
	round_timer.start()

	_update_hud()
	_show_announcement("ROUND %d - FIGHT!" % round_number, 1.2, Color.WHITE)

func _living_count(team: Array[CharacterBody3D]) -> int:
	var count := 0
	for s in team:
		if is_instance_valid(s) and not s.is_queued_for_deletion() and not s.is_dead:
			count += 1
	return count

func _total_health(team: Array[CharacterBody3D]) -> float:
	var total := 0.0
	for s in team:
		if is_instance_valid(s) and not s.is_queued_for_deletion() and not s.is_dead:
			total += s.current_health
	return total

func _update_hud() -> void:
	if blue_score_lbl:
		blue_score_lbl.text = str(blue_score)
	if red_score_lbl:
		red_score_lbl.text = str(red_score)
	if round_lbl:
		round_lbl.text = "ROUND %d" % round_number

func _show_announcement(text: String, duration: float, color: Color = Color.WHITE) -> void:
	if not announcement_lbl:
		return
	announcement_lbl.text = text
	announcement_lbl.modulate = color
	announcement_lbl.visible = true

	# Fade out after duration
	var tween := create_tween()
	tween.tween_interval(maxf(0.1, duration - 0.4))
	tween.tween_property(announcement_lbl, "modulate:a", 0.0, 0.4)
	tween.tween_callback(func(): announcement_lbl.visible = false; announcement_lbl.modulate.a = 1.0)

func _update_hud_unit_cards() -> void:
	_update_team_cards(_blue_soldiers, blue_list, Color(0.25, 0.6, 1.0))
	_update_team_cards(_red_soldiers, red_list, Color(1.0, 0.3, 0.3))

func _update_team_cards(soldiers: Array[CharacterBody3D], container: VBoxContainer, color: Color) -> void:
	if not container:
		return

	for s in soldiers:
		if not is_instance_valid(s):
			continue
		var role_str := "Tank"
		if s.role == 1:
			role_str = "Medic"
		elif s.role == 2:
			role_str = "Striker"

		var card = container.get_node_or_null(role_str + "Card")
		if not card:
			continue

		var hp_bar: ProgressBar = card.get_node_or_null("HPBar")
		var hp_val: Label = card.get_node_or_null("HPRow/HPVal")
		var name_lbl: Label = card.get_node_or_null("HPRow/Name")

		if name_lbl:
			name_lbl.text = "%s (Lv%d)" % [role_str, s.level]

		if hp_bar:
			hp_bar.max_value = s.max_health
			hp_bar.value = 0.0 if s.is_dead else s.current_health
		if hp_val:
			if s.is_dead:
				hp_val.text = "DOWN"
				hp_val.modulate = Color(0.6, 0.6, 0.6)
			else:
				hp_val.text = "%.0f" % s.current_health
				hp_val.modulate = Color.WHITE

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_R:
			print("[Squad Battle] Manual reset requested (Key R)")
			blue_score = 0
			red_score = 0
			round_number = 0
			reset_round()
		elif event.keycode == KEY_K:
			print("[Squad Battle] Test trigger: Defeating Red Squad")
			for s in _red_soldiers:
				if is_instance_valid(s) and not s.is_dead:
					s.take_damage(999.0)
		elif event.keycode == KEY_L:
			print("[Squad Battle] Test trigger: Defeating Blue Squad")
			for s in _blue_soldiers:
				if is_instance_valid(s) and not s.is_dead:
					s.take_damage(999.0)
