extends Node3D

@onready var cam:Camera3D = $Camera3D
@onready var zombie:PackedScene = load("res://characters/zombie3/zombie3.tscn")
@export var peaceful:bool=false
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
	if debug_logging:
		print(message)
		return
	var now := Time.get_ticks_msec()
	var last: int = _debug_log_last_msec.get(tag, -DEBUG_LOG_INTERVAL_MSEC)
	if now - last < DEBUG_LOG_INTERVAL_MSEC:
		return
	_debug_log_last_msec[tag] = now
	print(message)

func _ready():
	spawn()
	if zombies_spawned < zombies_per_episode:
		$SpawnTimer.start()
	_connect_soldiers()

# Soldiers are instantiated scene children, so wire their death signal here
# rather than in the scene file. The arena owns the reset.
func _connect_soldiers() -> void:
	for s in find_children("Soldier*"):
		if s.has_signal("died") and not s.died.is_connected(_on_soldier_died):
			s.died.connect(_on_soldier_died)

func _on_soldier_died() -> void:
	_end_episode()

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
		# The agent's per-episode counters are NOT cleared here. The Sync node
		# clears them via set_done_false() after reporting the episode to SB3;
		# clearing them now would report a zero-return episode.
	for z in find_children("Zombie*", "", true, false):
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
		if z.is_queued_for_deletion() or z.is_dead:
			continue
		count += 1
	return count

func _physics_process(delta: float) -> void:
	$Cursor.position = get_cursor_position()
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
	z.target = $Soldier
	z.name = "Zombie"
	zombies_spawned += 1
	if zombies_spawned >= zombies_per_episode:
		$SpawnTimer.stop()

# Uniformly random point in an annulus around the soldier, clamped to the
# arena. Distances are sampled as sqrt to keep the distribution uniform over
# area rather than biased toward the inner radius.
func _pick_spawn_position() -> Vector3:
	var soldier := $Soldier as Node3D
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
