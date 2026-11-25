extends Node3D

@onready var cam:Camera3D = $Camera3D
@onready var zombie:PackedScene = load("res://characters/zombie3/zombie3.tscn")
@export var peaceful:bool=false
enum SquadControlMode { HEURISTIC_BOTS, NEURAL_NETWORK, PLAYER_CONTROL, TRAINING }
@export var squad_mode: SquadControlMode = SquadControlMode.HEURISTIC_BOTS
@export var squad_bots: bool = true
@export var zombies_per_episode:int = 5
# Spawn-distance curriculum. Zombies appear at a uniformly random distance in
# [min_spawn_distance, max_spawn_distance] from the soldier, in metres, instead
# of always on the far ring. Always starting far away forces the agent through
# a long unrewarded approach before it can ever learn what an attack does;
# mixing in short-range starts gives it solvable credit-assignment problems
# that compose into the long-range behaviour. This is the "random legal
# resets" trick that made sparse-reward PPO competitive with search-based
# baselines in the Othello/Hex/Go self-play work.
@export var min_spawn_distance:float = 3.0
@export var max_spawn_distance:float = 22.0
# Keep spawns clear of the arena walls so a zombie cannot appear inside one.
const ARENA_HALF_EXTENT:float = 23.0
var zombies_spawned:int = 0
var zombies_killed:int = 0
var _resetting:bool = false
# Arena logging is rate limited so four arenas resetting at 10x speedup do not
# flood the console. Set debug_logging = true to see every event.
@export var debug_logging: bool = false
const DEBUG_LOG_INTERVAL_MSEC: int = 1000
var _debug_log_last_msec: Dictionary = {}

# Prints at most once per DEBUG_LOG_INTERVAL_MSEC per `tag`. With
# debug_logging on, every call prints.
func _debug_log(tag: String, message: String) -> void:
	if not debug_logging:
		return
	var now := Time.get_ticks_msec()
	var last: int = _debug_log_last_msec.get(tag, -DEBUG_LOG_INTERVAL_MSEC)
	if now - last < DEBUG_LOG_INTERVAL_MSEC:
		return
	_debug_log_last_msec[tag] = now
	print(message)

func _ready():
	if "--debug" in OS.get_cmdline_args() or "--debug-logging" in OS.get_cmdline_args():
		debug_logging = true
	if "--training" in OS.get_cmdline_args() or "--train" in OS.get_cmdline_args():
		squad_mode = SquadControlMode.TRAINING
	elif "--nn" in OS.get_cmdline_args() or "--onnx" in OS.get_cmdline_args():
		squad_mode = SquadControlMode.NEURAL_NETWORK
	elif "--bot" in OS.get_cmdline_args() or "--bots" in OS.get_cmdline_args():
		squad_mode = SquadControlMode.HEURISTIC_BOTS
	elif "--human" in OS.get_cmdline_args():
		squad_mode = SquadControlMode.PLAYER_CONTROL

	_apply_control_modes()
	spawn()
	if zombies_spawned < zombies_per_episode:
		$SpawnTimer.start()
	_connect_soldiers()
	$EpisodeTimer.start()

func _apply_control_modes() -> void:
	match squad_mode:
		SquadControlMode.TRAINING:
			for s in find_children("Soldier*"):
				if "is_bot" in s:
					s.is_bot = false
				if "use_nn" in s:
					s.use_nn = false
				var a = s.get_node_or_null("AI")
				if a:
					a.policy_source = a.PolicySource.HUMAN
					a.control_mode = a.ControlModes.TRAINING
					a.is_bot = false
					a.heuristic = "human"
					if not a.is_in_group("AGENT"):
						a.add_to_group("AGENT")
			var cursor_node := get_node_or_null("Cursor") as Node3D
			if cursor_node:
				cursor_node.visible = false
		SquadControlMode.NEURAL_NETWORK:
			for s in find_children("Soldier*"):
				if "use_nn" in s:
					s.use_nn = true
				var a = s.get_node_or_null("AI")
				if a:
					a.policy_source = a.PolicySource.NEURAL_NETWORK
					a.control_mode = a.ControlModes.HUMAN
			var cursor_node := get_node_or_null("Cursor") as Node3D
			if cursor_node:
				cursor_node.visible = false
		SquadControlMode.HEURISTIC_BOTS:
			for s in find_children("Soldier*"):
				if "is_bot" in s:
					s.is_bot = true
				if "use_nn" in s:
					s.use_nn = false
				var a = s.get_node_or_null("AI")
				if a:
					a.policy_source = a.PolicySource.BOT_HEURISTIC
					a.is_bot = true
					a.heuristic = "bot"
			var cursor_node := get_node_or_null("Cursor") as Node3D
			if cursor_node:
				cursor_node.visible = false
		SquadControlMode.PLAYER_CONTROL:
			for s in find_children("Soldier*"):
				if "is_bot" in s:
					s.is_bot = false
				if "use_nn" in s:
					s.use_nn = false
				var a = s.get_node_or_null("AI")
				if a:
					a.policy_source = a.PolicySource.HUMAN
					a.is_bot = false
					a.heuristic = "human"
	spawn()
	if zombies_spawned < zombies_per_episode:
		$SpawnTimer.start()
	_connect_soldiers()
	# Start the episode clock explicitly. The scene sets autostart = true, but
	# that flag is not reliable across instancing (observed false at runtime),
	# and without it an episode only ends on a death or a full clear -- so a
	# passive policy runs until the trainer's step cap.
	$EpisodeTimer.start()

# Soldiers are instantiated scene children, so wire their death signal here
# rather than in the scene file. The arena owns the reset.
func _connect_soldiers() -> void:
	for s in find_children("Soldier*"):
		if s.has_signal("died") and not s.died.is_connected(_on_soldier_died):
			s.died.connect(_on_soldier_died)

func _on_soldier_died() -> void:
	if _living_soldier_count() == 0:
		_end_episode()

func _living_soldier_count() -> int:
	var count := 0
	for s in find_children("Soldier*"):
		if not s.is_queued_for_deletion() and not s.is_dead:
			count += 1
	return count

# Marks the episode done so the Sync node reports it to SB3, then resets the
# arena. `done` must be set before reset() clears the agent's episode counters,
# otherwise get_info() reports a zero-length, zero-reward episode.
func _end_episode() -> void:
	for s in find_children("Soldier*"):
		var agent = s.get_node_or_null("AI")
		if agent:
			agent.done = true
	reset()

func reset():
	# Episode boundaries are low-frequency, but four arenas resetting at 10x
	# speedup still adds up. Rate limit per arena via the shared helper.
	_debug_log("reset", "{0} reset".format([name]))
	zombies_spawned = 0
	zombies_killed = 0
	# Guard against a second reset from zombie_killed_by_soldier() while this
	# one is still tearing down the old zombies.
	_resetting = true
	for s in find_children("Soldier*"):
		if s.has_method("respawn"):
			s.respawn()
		if squad_mode == SquadControlMode.HEURISTIC_BOTS and squad_bots:
			if "is_bot" in s:
				s.is_bot = true
			var a = s.get_node_or_null("AI")
			if a:
				a.is_bot = true
				a.heuristic = "bot"
		elif squad_mode == SquadControlMode.TRAINING:
			if "is_bot" in s:
				s.is_bot = false
			var a = s.get_node_or_null("AI")
			if a:
				a.policy_source = a.PolicySource.HUMAN
				a.control_mode = a.ControlModes.TRAINING
				a.is_bot = false
				a.heuristic = "human"
		# The agent's per-episode counters are NOT cleared here. The Sync node
		# clears them via set_done_false() after reporting the episode to SB3;
		# clearing them now would report a zero-return episode.
	for z in find_children("Zombie*", "", true, false):
		if z.has_method("die"):
			z.die()
	# die() queue_frees, so the zombies are still children this frame. Drop the
	# count so a kill landing mid-teardown cannot re-enter reset().
	_resetting = false
	$EpisodeTimer.start()
	spawn()
	if zombies_spawned < zombies_per_episode:
		$SpawnTimer.start()
	else:
		$SpawnTimer.stop()

func zombie_killed_by_soldier() -> void:
	if _resetting:
		return
	zombies_killed += 1
	if zombies_spawned < zombies_per_episode:
		return
	if _living_zombie_count() > 0:
		return
	_end_episode()

func _living_zombie_count() -> int:
	var count := 0
	for z in find_children("Zombie*", "", true, false):
		if not ("is_dead" in z):
			continue
		if z.is_queued_for_deletion() or z.is_dead:
			continue
		count += 1
	return count

func _physics_process(delta: float) -> void:
	var cursor: Node3D = get_node_or_null("Cursor") as Node3D
	if cursor:
		cursor.position = get_cursor_position()
	#print($Cursor.position)

func get_cursor_position() -> Vector3:
	var out:Vector3=Vector3.ZERO
	const RAY_LENGTH = 10000.0
	var space_state = get_world_3d().direct_space_state
	var mousepos = get_viewport().get_mouse_position()
	var origin = cam.project_ray_origin(mousepos)
	var end = origin + cam.project_ray_normal(mousepos) * RAY_LENGTH
	var query:PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(origin, end)
	query.collision_mask = 0b01
	var result = space_state.intersect_ray(query)
	if result:
		var collision_object = result.collider
		out = result.position
		#print(collision_object.name)
	return out

func spawn():
	if peaceful:
		return
	if zombies_spawned >= zombies_per_episode:
		$SpawnTimer.stop()
		return
	var z = zombie.instantiate()
	# Parent first, then set global_position. Assigning global_position to
	# `position` before parenting would be re-offset by this node's transform,
	# which pushes zombies outside the walls in the translated Main3 clones.
	add_child(z, true)
	z.global_position = _pick_spawn_position()
	var s_node: Node3D = get_node_or_null("Soldier") as Node3D
	if not s_node:
		var s_list := find_children("Soldier*")
		if not s_list.is_empty() and s_list[0] is Node3D:
			s_node = s_list[0] as Node3D
	z.target = s_node
	z.name = "Zombie"
	zombies_spawned += 1
	if zombies_spawned >= zombies_per_episode:
		$SpawnTimer.stop()

# Uniformly random point in an annulus around the soldier, clamped to the
# arena. Distances are sampled as sqrt to keep the distribution uniform over
# area rather than biased toward the inner radius.
func _pick_spawn_position() -> Vector3:
	var soldier := get_node_or_null("Soldier") as Node3D
	if not soldier:
		var s_list := find_children("Soldier*")
		if not s_list.is_empty() and s_list[0] is Node3D:
			soldier = s_list[0] as Node3D
	var origin := soldier.global_position if soldier else global_position
	var low := minf(min_spawn_distance, max_spawn_distance)
	var high := maxf(min_spawn_distance, max_spawn_distance)
	var radius := sqrt(randf_range(low * low, high * high))
	var angle := randf() * TAU
	var offset := Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
	var pos := origin + offset
	# Clamp into the arena so a spawn near a wall cannot land outside it.
	var local := to_local(pos)
	local.x = clampf(local.x, -ARENA_HALF_EXTENT, ARENA_HALF_EXTENT)
	local.z = clampf(local.z, -ARENA_HALF_EXTENT, ARENA_HALF_EXTENT)
	pos = to_global(local)
	pos.y = origin.y
	return pos

func _on_episode_timer_timeout() -> void:
	_end_episode()


func _on_spawn_timer_timeout() -> void:
	spawn()
