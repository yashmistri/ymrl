extends Node3D

@onready var cam: Camera3D = $Camera3D
enum PvPControlMode { HEURISTIC_BOTS, NEURAL_NETWORK, FROZEN_SELFPLAY }
@export var pvp_mode: PvPControlMode = PvPControlMode.HEURISTIC_BOTS
@export var episode_duration: float = 60.0
@export var debug_logging: bool = false

var blue_score: int = 0
var red_score: int = 0
var draws: int = 0
var _resetting: bool = false

var _debug_log_last_msec: Dictionary = {}

func _debug_log(tag: String, message: String) -> void:
	if not debug_logging:
		return
	var now := Time.get_ticks_msec()
	var last: int = _debug_log_last_msec.get(tag, -1000)
	if now - last < 1000:
		return
	_debug_log_last_msec[tag] = now
	print(message)

func _ready() -> void:
	if "--debug" in OS.get_cmdline_args() or "--debug-logging" in OS.get_cmdline_args():
		debug_logging = true

	var cursor_node := get_node_or_null("Cursor") as Node3D
	if cursor_node:
		cursor_node.visible = false

	_setup_soldiers()
	$EpisodeTimer.wait_time = episode_duration
	$EpisodeTimer.start()

func _setup_soldiers() -> void:
	if "--selfplay" in OS.get_cmdline_args() or "--frozen" in OS.get_cmdline_args():
		pvp_mode = PvPControlMode.FROZEN_SELFPLAY
	elif "--nn" in OS.get_cmdline_args() or "--onnx" in OS.get_cmdline_args():
		pvp_mode = PvPControlMode.NEURAL_NETWORK
	elif "--bot" in OS.get_cmdline_args() or "--bots" in OS.get_cmdline_args():
		pvp_mode = PvPControlMode.HEURISTIC_BOTS

	for node in find_children("Blue*") + find_children("Red*"):
		if node is CharacterBody3D and node.has_signal("died"):
			if not node.died.is_connected(_on_soldier_died):
				node.died.connect(_on_soldier_died)
	_apply_control_modes()

func _apply_control_modes() -> void:
	match pvp_mode:
		PvPControlMode.FROZEN_SELFPLAY:
			# Blue Team: Learning RL agents
			for node in find_children("Blue*"):
				if "is_bot" in node:
					node.is_bot = false
				if "use_nn" in node:
					node.use_nn = false
				var a = node.get_node_or_null("AI")
				if a:
					a.policy_source = a.PolicySource.HUMAN
					a.control_mode = a.ControlModes.TRAINING
					a.is_bot = false
					a.heuristic = "human"
					if not a.is_in_group("AGENT"):
						a.add_to_group("AGENT")
			# Red Team: Frozen Opponents running onnx model
			for node in find_children("Red*"):
				if "is_bot" in node:
					node.is_bot = true
				if "use_nn" in node:
					node.use_nn = true
				var a = node.get_node_or_null("AI")
				if a:
					a.onnx_model_path = "res://models/frozen_opponent.onnx"
					a.policy_source = a.PolicySource.NEURAL_NETWORK
					a.control_mode = a.ControlModes.HUMAN
					a.is_bot = true
					if a.is_in_group("AGENT"):
						a.remove_from_group("AGENT")
		PvPControlMode.NEURAL_NETWORK:
			for node in find_children("Blue*"):
				if "use_nn" in node:
					node.use_nn = true
				var a = node.get_node_or_null("AI")
				if a:
					a.onnx_model_path = "res://models/squad_rl_500k.onnx"
					a.policy_source = a.PolicySource.NEURAL_NETWORK
					a.control_mode = a.ControlModes.HUMAN
			for node in find_children("Red*"):
				if "use_nn" in node:
					node.use_nn = true
				var a = node.get_node_or_null("AI")
				if a:
					a.onnx_model_path = "res://models/frozen_opponent.onnx"
					a.policy_source = a.PolicySource.NEURAL_NETWORK
					a.control_mode = a.ControlModes.HUMAN
		PvPControlMode.HEURISTIC_BOTS:
			for node in find_children("Blue*") + find_children("Red*"):
				if "is_bot" in node:
					node.is_bot = true
				if "use_nn" in node:
					node.use_nn = false
				var a = node.get_node_or_null("AI")
				if a:
					a.policy_source = a.PolicySource.BOT_HEURISTIC
					a.is_bot = true
					a.heuristic = "bot"

func _on_soldier_died() -> void:
	if _resetting:
		return
	var blue_alive := _living_count("Blue")
	var red_alive := _living_count("Red")

	if blue_alive == 0 or red_alive == 0:
		if blue_alive > 0 and red_alive == 0:
			blue_score += 1
			_debug_log("match", "[PvP] Blue Squad Wins! (Score: Blue %d - %d Red)" % [blue_score, red_score])
		elif red_alive > 0 and blue_alive == 0:
			red_score += 1
			_debug_log("match", "[PvP] Red Squad Wins! (Score: Blue %d - %d Red)" % [blue_score, red_score])
		else:
			draws += 1
			_debug_log("match", "[PvP] Draw! (Score: Blue %d - %d Red)" % [blue_score, red_score])
		_end_episode()

func _living_count(prefix: String) -> int:
	var count := 0
	for node in find_children(prefix + "*"):
		if node is CharacterBody3D and not node.is_queued_for_deletion() and not ("is_dead" in node and node.is_dead):
			count += 1
	return count

func _end_episode() -> void:
	for node in find_children("Blue*"):
		if node is Node3D:
			var agent = node.get_node_or_null("AI")
			if agent and agent.is_in_group("AGENT"):
				agent.done = true
	if pvp_mode != PvPControlMode.FROZEN_SELFPLAY:
		for node in find_children("Red*"):
			if node is Node3D:
				var agent = node.get_node_or_null("AI")
				if agent and agent.is_in_group("AGENT"):
					agent.done = true
	reset()

func reset() -> void:
	_resetting = true
	_debug_log("reset", "PvP Arena reset")
	for node in find_children("Blue*") + find_children("Red*"):
		if node is Node3D and node.has_method("respawn"):
			node.respawn()
	_apply_control_modes()
	_resetting = false
	$EpisodeTimer.wait_time = episode_duration
	$EpisodeTimer.start()

func _on_episode_timer_timeout() -> void:
	draws += 1
	_debug_log("match", "[PvP] Time Out! (Score: Blue %d - %d Red)" % [blue_score, red_score])
	_end_episode()
