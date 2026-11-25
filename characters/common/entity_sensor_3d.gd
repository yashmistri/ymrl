@tool
extends Node3D
class_name EntitySensor3D

## Slot-based entity perception.
##
## Raycasts encode "something is at angle θ, distance d". The network then has
## to invert that into "where is the enemy, which way is it moving, how hurt is
## it" before it can act on it. This sensor skips that step: each tracked
## entity occupies one fixed slot holding its state directly.
##
## Slots are stable within an episode. An entity entering range takes the
## lowest free slot and keeps it until it leaves range or dies, so the network
## sees a consistent entity across consecutive frames instead of a value that
## jumps slots.
##
## Per-slot layout (SLOT_SIZE floats, all normalized to roughly [-1, 1]):
##   0  rel_x / max_range      left/right offset, ego-relative
##   1  rel_z / max_range      forward/back offset, ego-relative
##   2  distance / max_range   0 = touching, 1 = at max_range
##   3  bearing / PI           -1 = behind, 0 = ahead
##   4  rel_vel_x / max_speed  target velocity, ego-relative
##   5  rel_vel_z / max_speed
##   6  health / max_health    0 = dead, 1 = full
##   7  is_attacking           0 or 1
##   8  is_visible             0 = remembered only, 1 = in range this frame
##   9  is_stunned             0 or 1 (allows Strikers to target & combo)
##
## Empty slots are all zeros, so "no enemy" is distinguishable from "enemy at
## distance 0" (which would have a 1 in slot 8).

const SLOT_SIZE := 10
const MAX_SPEED := 10.0

## How many entities to track. Beyond this, the nearest are kept.
@export var max_slots: int = 5
## Detection radius in metres. Entities outside this are not perceived.
@export var max_range: float = 30.0
## Group name to scan for. Zombies join "Zombie" via their node name; using a
## group keeps this decoupled from the scene tree layout.
@export var target_group: String = "enemy"
## When true, a tracked entity that leaves range keeps its last known state
## with is_visible = 0 instead of freeing its slot. Gives the policy a short
## memory without needing a recurrent network.
@export var remember_lost_targets: bool = true

## Entity -> slot index. Preserved across frames for slot stability.
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


## Nearest tracked, living, in-range enemy. Returns null when none is visible.
## Used by the soldier to snap its aim on attack, so the policy does not have
## to discover incremental turning in order to land a hit.
func nearest_target() -> Node3D:
	_refresh_slots()
	var best: Node3D = null
	var best_dist := INF
	for i in max_slots:
		var entity = _slots[i]
		if entity == null or not is_instance_valid(entity):
			continue
		if "is_dead" in entity and entity.is_dead:
			continue
		var d: float = _distance_to(entity)
		if d > max_range or d >= best_dist:
			continue
		best_dist = d
		best = entity
	return best

## Nearest stunned target for Striker execution combos.
func nearest_stunned_target() -> Node3D:
	_refresh_slots()
	var best: Node3D = null
	var best_dist := INF
	for i in max_slots:
		var entity = _slots[i]
		if entity == null or not is_instance_valid(entity):
			continue
		if "is_dead" in entity and entity.is_dead:
			continue
		if not ("is_stunned" in entity and entity.is_stunned):
			continue
		var d: float = _distance_to(entity)
		if d > max_range or d >= best_dist:
			continue
		best_dist = d
		best = entity
	return best

## Nearest unstunned target for Tank crowd control targeting.
func nearest_unstunned_target() -> Node3D:
	_refresh_slots()
	var best: Node3D = null
	var best_dist := INF
	for i in max_slots:
		var entity = _slots[i]
		if entity == null or not is_instance_valid(entity):
			continue
		if "is_dead" in entity and entity.is_dead:
			continue
		if "is_stunned" in entity and entity.is_stunned:
			continue
		var d: float = _distance_to(entity)
		if d > max_range or d >= best_dist:
			continue
		best_dist = d
		best = entity
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

	# Drop slots whose entity died, was freed, or left range.
	for i in max_slots:
		var entity = _slots[i]
		if entity == null:
			continue
		if not is_instance_valid(entity) or entity.is_dead:
			_slots[i] = null
			_slot_of.erase(entity)
		elif not in_range.has(entity) and not remember_lost_targets:
			_slots[i] = null
			_slot_of.erase(entity)

	# Admit new entities nearest-first; if full, preempt out-of-range or farther slots.
	for entity in candidates:
		if not in_range.has(entity) or _slot_of.has(entity):
			continue
		var free := _slots.find(null)
		if free != -1:
			_slots[free] = entity
			_slot_of[entity] = free
			continue
		var evict_idx := _find_evictable_slot(_distance_to(entity), in_range)
		if evict_idx == -1:
			break
		var old_entity = _slots[evict_idx]
		if old_entity != null:
			_slot_of.erase(old_entity)
		_slots[evict_idx] = entity
		_slot_of[entity] = evict_idx


func _find_evictable_slot(candidate_dist: float, in_range: Dictionary) -> int:
	var best_idx := -1
	var worst_remembered_dist := -1.0
	var worst_in_range_idx := -1
	var worst_in_range_dist := -1.0
	for i in max_slots:
		var slot_entity = _slots[i]
		if slot_entity == null or not is_instance_valid(slot_entity):
			return i
		var d: float = _distance_to(slot_entity)
		if not in_range.has(slot_entity):
			if d > worst_remembered_dist:
				worst_remembered_dist = d
				best_idx = i
		elif d > worst_in_range_dist:
			worst_in_range_dist = d
			worst_in_range_idx = i
	if best_idx != -1:
		return best_idx
	if worst_in_range_idx != -1 and candidate_dist + 0.5 < worst_in_range_dist:
		return worst_in_range_idx
	return -1


func _collect_candidates() -> Array:
	var out: Array = []
	for node in get_tree().get_nodes_in_group(target_group):
		if node is Node3D and not node.is_queued_for_deletion():
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

	# Ego-relative frame: forward is this node's -Z, right is +X. The sensor
	# node is parented under the soldier, so its basis already carries facing.
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

	var attacking: float = 1.0 if ("is_attacking" in entity and entity.is_attacking) else 0.0
	var visible_now: float = 1.0 if distance <= max_range else 0.0
	var stunned: float = 1.0 if ("is_stunned" in entity and entity.is_stunned) else 0.0

	return [
		clampf(local.x / max_range, -1.0, 1.0),
		clampf(local.z / max_range, -1.0, 1.0),
		clampf(distance / max_range, 0.0, 1.0),
		clampf(bearing / PI, -1.0, 1.0),
		clampf(local_vel.x / MAX_SPEED, -1.0, 1.0),
		clampf(local_vel.z / MAX_SPEED, -1.0, 1.0),
		health,
		attacking,
		visible_now,
		stunned,
	]
