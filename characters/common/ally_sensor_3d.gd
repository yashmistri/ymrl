@tool
extends Node3D
class_name AllySensor3D

## Slot-based ally perception for squad coordination.
##
## Tracks squad teammates in the "soldier" group, excluding the parent entity.
## Each slot contains 14 floats (all normalized to [-1, 1] or [0, 1]):
##   0  rel_x / max_range       left/right offset, ego-relative
##   1  rel_z / max_range       forward/back offset, ego-relative
##   2  distance / max_range    0 = touching, 1 = max_range
##   3  bearing / PI            -1 = behind, 0 = ahead
##   4  rel_vel_x / max_speed   ally velocity, ego-relative
##   5  rel_vel_z / max_speed
##   6  health / max_health     0 = dead, 1 = full
##   7  stamina / max_stamina   0 = empty, 1 = full
##   8  is_tank                 1.0 if Tank, else 0.0
##   9  is_medic                1.0 if Medic, else 0.0
##   10 is_striker              1.0 if Striker, else 0.0
##   11 level / 3.0             normalized level (0.33, 0.66, 1.0)
##   12 is_blocking             1.0 if holding block / channeling heal
##   13 is_visible              1.0 if alive and in range, 0.0 if empty/dead

const SLOT_SIZE := 14
const MAX_SPEED := 10.0

@export var max_slots: int = 2
@export var max_range: float = 30.0
@export var target_group: String = "soldier"

var _slot_of: Dictionary = {}
var _slots: Array = []
var _last_refresh_frame: int = -1

func _ready() -> void:
	_slots.resize(max_slots)

func reset() -> void:
	_slot_of.clear()
	for i in max_slots:
		_slots[i] = null

## Returns a flat array of max_slots * SLOT_SIZE floats.
func get_observation() -> Array:
	_refresh_slots()
	var out: Array = []
	for i in max_slots:
		var entity = _slots[i]
		if entity == null or not is_instance_valid(entity):
			out.append_array(_empty_slot())
			continue
		out.append_array(_slot_values(entity))
	return out

## Returns the ally with lowest HP percentage within range.
func nearest_injured_ally() -> Node3D:
	_refresh_slots()
	var best: Node3D = null
	var lowest_pct := 1.0
	for i in max_slots:
		var ally = _slots[i]
		if ally == null or not is_instance_valid(ally):
			continue
		if "is_dead" in ally and ally.is_dead:
			continue
		if _distance_to(ally) > max_range:
			continue
		var max_h: float = ally.max_health if "max_health" in ally else 1.0
		var cur_h: float = ally.current_health if "current_health" in ally else max_h
		var pct := cur_h / maxf(max_h, 0.001)
		if pct < lowest_pct:
			lowest_pct = pct
			best = ally
	return best

## Returns nearest living ally.
func nearest_ally() -> Node3D:
	_refresh_slots()
	var best: Node3D = null
	var best_dist := INF
	for i in max_slots:
		var ally = _slots[i]
		if ally == null or not is_instance_valid(ally):
			continue
		if "is_dead" in ally and ally.is_dead:
			continue
		var d: float = _distance_to(ally)
		if d > max_range or d >= best_dist:
			continue
		best_dist = d
		best = ally
	return best

func _refresh_slots() -> void:
	var cur_frame := Engine.get_physics_frames()
	if _last_refresh_frame == cur_frame:
		return
	_last_refresh_frame = cur_frame

	var candidates := _collect_candidates()
	var in_range := {}
	for entity in candidates:
		if _distance_to(entity) <= max_range:
			in_range[entity] = true

	# Drop dead, freed, or out-of-range allies
	for i in max_slots:
		var entity = _slots[i]
		if entity == null:
			continue
		if not is_instance_valid(entity) or ("is_dead" in entity and entity.is_dead):
			_slots[i] = null
			_slot_of.erase(entity)
		elif not in_range.has(entity):
			_slots[i] = null
			_slot_of.erase(entity)

	# Admit nearest candidates first
	for entity in candidates:
		if not in_range.has(entity) or _slot_of.has(entity):
			continue
		var free: int = _slots.find(null)
		if free == -1:
			break
		_slots[free] = entity
		_slot_of[entity] = free

func _collect_candidates() -> Array:
	var out: Array = []
	var parent_node: Node = get_parent()
	for node in get_tree().get_nodes_in_group(target_group):
		if node is Node3D and not node.is_queued_for_deletion():
			if node == self or node == parent_node:
				continue
			out.append(node)
	out.sort_custom(func(a, b): return _distance_to(a) < _distance_to(b))
	return out

func _distance_to(entity: Node3D) -> float:
	return global_position.distance_to(entity.global_position)

func _empty_slot() -> Array:
	var slot: Array = []
	slot.resize(SLOT_SIZE)
	slot.fill(0.0)
	return slot

func _slot_values(entity: Node3D) -> Array:
	var to_target := entity.global_position - global_position
	var distance := to_target.length()
	var flat := Vector3(to_target.x, 0.0, to_target.z)

	var local := global_transform.basis.inverse() * flat
	var bearing := atan2(local.x, -local.z)

	var velocity := Vector3.ZERO
	if "velocity" in entity:
		velocity = entity.velocity
	var local_vel := global_transform.basis.inverse() * Vector3(velocity.x, 0.0, velocity.z)

	var health := 1.0
	var max_health: float = entity.max_health if "max_health" in entity else 1.0
	if "current_health" in entity and max_health > 0.0:
		health = clampf(entity.current_health / max_health, 0.0, 1.0)

	var stamina := 1.0
	var max_stamina: float = entity.max_stamina if "max_stamina" in entity else 1.0
	if "current_stamina" in entity and max_stamina > 0.0:
		stamina = clampf(entity.current_stamina / max_stamina, 0.0, 1.0)

	var role_val: int = entity.role if "role" in entity else 2 # default Striker
	var is_tank: float = 1.0 if role_val == 0 else 0.0
	var is_medic: float = 1.0 if role_val == 1 else 0.0
	var is_striker: float = 1.0 if role_val == 2 else 0.0

	var lvl: float = float(entity.level if "level" in entity else 1) / 3.0
	var blocking: float = 1.0 if ("is_blocking" in entity and entity.is_blocking) else 0.0
	var visible_now: float = 1.0 if distance <= max_range else 0.0

	return [
		clampf(local.x / max_range, -1.0, 1.0),
		clampf(local.z / max_range, -1.0, 1.0),
		clampf(distance / max_range, 0.0, 1.0),
		clampf(bearing / PI, -1.0, 1.0),
		clampf(local_vel.x / MAX_SPEED, -1.0, 1.0),
		clampf(local_vel.z / MAX_SPEED, -1.0, 1.0),
		health,
		stamina,
		is_tank,
		is_medic,
		is_striker,
		lvl,
		blocking,
		visible_now,
	]
