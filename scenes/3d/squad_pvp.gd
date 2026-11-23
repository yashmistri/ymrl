extends Node3D

@onready var cam: Camera3D = $Camera3D
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
	for node in get_tree().get_nodes_in_group("soldier") + get_tree().get_nodes_in_group("enemy"):
		if node is CharacterBody3D and node.has_signal("died"):
			if not node.died.is_connected(_on_soldier_died):
				node.died.connect(_on_soldier_died)
			if "is_bot" in node:
				node.is_bot = true
			var a = node.get_node_or_null("AI")
			if a:
				a.is_bot = true
				a.heuristic = "bot"

func _on_soldier_died() -> void:
	if _resetting:
		return
	var blue_alive := _living_count("team_blue")
	var red_alive := _living_count("team_red")

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

func _living_count(group: String) -> int:
	var count := 0
	for node in get_tree().get_nodes_in_group(group):
		if node is CharacterBody3D and not node.is_queued_for_deletion() and not ("is_dead" in node and node.is_dead):
			count += 1
	return count

func _end_episode() -> void:
	for node in get_tree().get_nodes_in_group("team_blue") + get_tree().get_nodes_in_group("team_red"):
		if node is Node3D:
			var agent = node.get_node_or_null("AI")
			if agent:
				agent.done = true
	reset()

func reset() -> void:
	_resetting = true
	_debug_log("reset", "PvP Arena reset")
	for node in get_tree().get_nodes_in_group("team_blue") + get_tree().get_nodes_in_group("team_red"):
		if node is Node3D and node.has_method("respawn"):
			node.respawn()
		if "is_bot" in node:
			node.is_bot = true
		var a = node.get_node_or_null("AI")
		if a:
			a.is_bot = true
			a.heuristic = "bot"

	_resetting = false
	$EpisodeTimer.wait_time = episode_duration
	$EpisodeTimer.start()

func _on_episode_timer_timeout() -> void:
	draws += 1
	_debug_log("match", "[PvP] Time Out! (Score: Blue %d - %d Red)" % [blue_score, red_score])
	_end_episode()
