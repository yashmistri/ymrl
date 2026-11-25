extends Node3D
class_name ArenaBase

signal hill_score_tick(blue_score: float, red_score: float, owner: int, contested: bool)
signal hill_captured(new_owner: int)
signal koth_won(winner_team: int)

@export var arena_name: String = "Generic Arena"
@export var arena_size: Vector2 = Vector2(30, 30)

@export_group("King of the Hill")
@export var has_hill: bool = false
@export var hill_radius: float = 6.5
@export var hill_win_score: float = 45.0
@export var hill_score_rate: float = 1.0
@export var hill_capture_time: float = 2.0
@export var hill_rotate_interval: float = 25.0
@export var hill_positions: Array[Vector3] = [Vector3.ZERO]

@onready var nav_region: NavigationRegion3D = $NavRegion
@onready var hill_zone: Node3D = get_node_or_null("HillZone")

var blue_hill_score: float = 0.0
var red_hill_score: float = 0.0
var hill_owner: int = -1 # -1 neutral, 0 blue, 1 red
var hill_contested: bool = false
var hill_capture_progress: float = 0.0 # +1.0 = Blue, 0.0 = Neutral, -1.0 = Red
var blue_on_hill: int = 0
var red_on_hill: int = 0
var _hill_idx: int = 0
var _hill_rotate_timer: float = 0.0
var _koth_finished: bool = false

func _ready() -> void:
	add_to_group("arena")
	if nav_region:
		if nav_region.navigation_mesh:
			nav_region.navigation_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
		# Bake navigation mesh dynamically using static colliders
		nav_region.bake_navigation_mesh(false)
		print("[Arena] %s initialized and NavigationMesh baked successfully." % arena_name)
	if has_hill:
		reset_koth()

func reset_koth() -> void:
	blue_hill_score = 0.0
	red_hill_score = 0.0
	hill_owner = -1
	hill_contested = false
	hill_capture_progress = 0.0
	blue_on_hill = 0
	red_on_hill = 0
	_hill_idx = 0
	_hill_rotate_timer = 0.0
	_koth_finished = false
	_sync_hill_transform()
	_update_hill_visuals()

func get_hill_world_position() -> Vector3:
	if hill_positions.is_empty():
		return global_position
	var local_pos: Vector3 = hill_positions[_hill_idx % hill_positions.size()]
	return to_global(local_pos)

func get_hill_state(team: int = 0) -> Dictionary:
	var own_score: float = blue_hill_score if team == 0 else red_hill_score
	var enemy_score: float = red_hill_score if team == 0 else blue_hill_score
	var owner_rel: float = 0.0
	if hill_owner != -1:
		owner_rel = 1.0 if hill_owner == team else -1.0
	return {
		"has_hill": has_hill,
		"position": get_hill_world_position(),
		"radius": hill_radius,
		"owner": hill_owner,
		"owner_relative": owner_rel,
		"contested": hill_contested,
		"capture_progress": hill_capture_progress,
		"own_score": own_score,
		"enemy_score": enemy_score,
		"win_score": hill_win_score,
		"blue_on_hill": blue_on_hill,
		"red_on_hill": red_on_hill,
	}

func _physics_process(delta: float) -> void:
	if not has_hill or _koth_finished:
		return

	if hill_rotate_interval > 0.0 and hill_positions.size() > 1:
		_hill_rotate_timer += delta
		if _hill_rotate_timer >= hill_rotate_interval:
			_hill_rotate_timer = 0.0
			_hill_idx = (_hill_idx + 1) % hill_positions.size()
			_sync_hill_transform()

	var hill_pos := get_hill_world_position()
	var r_sq := hill_radius * hill_radius
	blue_on_hill = _count_living_on_hill("soldier", hill_pos, r_sq)
	red_on_hill = _count_living_on_hill("enemy", hill_pos, r_sq)

	hill_contested = (blue_on_hill > 0 and red_on_hill > 0)
	if not hill_contested:
		var cap_rate := 1.0 / maxf(hill_capture_time, 0.25)
		if blue_on_hill > 0:
			var prev_owner := hill_owner
			var strength := minf(float(blue_on_hill), 3.0) * 0.5 + 0.5
			hill_capture_progress = minf(1.0, hill_capture_progress + cap_rate * strength * delta)
			if hill_capture_progress >= 1.0:
				hill_owner = 0
			elif hill_capture_progress > 0.0 and hill_owner == 1:
				hill_owner = -1
			if hill_owner == 0 and prev_owner != 0:
				hill_captured.emit(0)
		elif red_on_hill > 0:
			var prev_owner := hill_owner
			var strength := minf(float(red_on_hill), 3.0) * 0.5 + 0.5
			hill_capture_progress = maxf(-1.0, hill_capture_progress - cap_rate * strength * delta)
			if hill_capture_progress <= -1.0:
				hill_owner = 1
			elif hill_capture_progress < 0.0 and hill_owner == 0:
				hill_owner = -1
			if hill_owner == 1 and prev_owner != 1:
				hill_captured.emit(1)

	if not hill_contested and hill_owner != -1:
		if hill_owner == 0:
			blue_hill_score = minf(hill_win_score, blue_hill_score + hill_score_rate * delta)
		else:
			red_hill_score = minf(hill_win_score, red_hill_score + hill_score_rate * delta)
		hill_score_tick.emit(blue_hill_score, red_hill_score, hill_owner, hill_contested)

		if blue_hill_score >= hill_win_score:
			_koth_finished = true
			koth_won.emit(0)
		elif red_hill_score >= hill_win_score:
			_koth_finished = true
			koth_won.emit(1)

	_update_hill_visuals()

func _count_living_on_hill(group_name: String, hill_pos: Vector3, r_sq: float) -> int:
	var count := 0
	for node in get_tree().get_nodes_in_group(group_name):
		if node is Node3D and is_instance_valid(node) and not ("is_dead" in node and node.is_dead):
			var dx: float = node.global_position.x - hill_pos.x
			var dz: float = node.global_position.z - hill_pos.z
			if dx * dx + dz * dz <= r_sq:
				count += 1
	return count

func _sync_hill_transform() -> void:
	if hill_zone == null:
		hill_zone = get_node_or_null("HillZone")
	if hill_zone != null and not hill_positions.is_empty():
		var local_pos: Vector3 = hill_positions[_hill_idx % hill_positions.size()]
		hill_zone.position = Vector3(local_pos.x, 0.05, local_pos.z)

func _update_hill_visuals() -> void:
	if hill_zone == null:
		return
	var col := Color(0.85, 0.88, 0.92, 0.25) # Neutral
	if hill_contested:
		col = Color(1.0, 0.85, 0.15, 0.35) # Contested Amber
	elif hill_owner == 0:
		col = Color(0.2, 0.55, 1.0, 0.32) # Blue Owned
	elif hill_owner == 1:
		col = Color(1.0, 0.25, 0.22, 0.32) # Red Owned
	elif hill_capture_progress > 0.05:
		col = Color(0.5, 0.72, 1.0, 0.26)
	elif hill_capture_progress < -0.05:
		col = Color(1.0, 0.55, 0.5, 0.26)

	for child_name in ["FloorPad", "RingOutline"]:
		var mesh_node := hill_zone.get_node_or_null(child_name) as MeshInstance3D
		if mesh_node and mesh_node.material_override is StandardMaterial3D:
			var mat := mesh_node.material_override as StandardMaterial3D
			var target_col := col
			if child_name == "RingOutline":
				target_col.a = 0.85
			mat.albedo_color = target_col

## Returns all cover/obstacle nodes in this arena for tactical pathing
func get_cover_obstacles() -> Array[Node3D]:
	var result: Array[Node3D] = []
	for node in find_children("*", "StaticBody3D", true, false):
		if node.is_in_group("cover") and is_instance_valid(node) and node.is_inside_tree() and not node.is_queued_for_deletion():
			result.append(node)
	return result

## Finds the best cover position behind an obstacle relative to an enemy threat
func find_best_cover_point(soldier_pos: Vector3, threat_pos: Vector3) -> Vector3:
	var covers := get_cover_obstacles()
	if covers.is_empty():
		return soldier_pos

	var best_pos := soldier_pos
	var min_cost := INF

	for obs in covers:
		var obs_pos := obs.global_position
		# Cover direction points from threat through the obstacle
		var to_obs := obs_pos - threat_pos
		to_obs.y = 0.0
		if to_obs.length_squared() < 0.001:
			continue

		var safe_dir := to_obs.normalized()
		# Determine obstacle radius from collision shape if available
		var radius := 1.8
		var col = obs.get_node_or_null("CollisionShape3D")
		if col and col.shape:
			if col.shape is CylinderShape3D:
				radius = (col.shape as CylinderShape3D).radius + 0.6
			elif col.shape is BoxShape3D:
				var sz: Vector3 = (col.shape as BoxShape3D).size
				radius = maxf(sz.x, sz.z) * 0.5 + 0.6

		var candidate_point := obs_pos + safe_dir * radius
		var dist_to_soldier := soldier_pos.distance_to(candidate_point)
		# Cost balances proximity to soldier with distance from threat
		var cost := dist_to_soldier
		if cost < min_cost:
			min_cost = cost
			best_pos = candidate_point

	return best_pos
