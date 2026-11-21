extends CharacterBody3D
class_name Char3

@export var speed_stat = 3.0

const STRAFE_SPEED:float = 0.75
# Backpedalling uses the same factor as strafing. It was 0.5, which made
# retreating strictly worse than sidestepping and left attacking-while-retreating
# (5.0 * 0.5 attack * 0.5) at 1.25 -- far below the zombie's 4.0.
const BACKPEDAL_SPEED:float = 0.75
var current_speed:float
@export var damage:float = 10.0
@export var max_health:float = 100.0
var current_health:float
var move:Vector3
@export var attack_range:float =1.0
var attack_cd:float=0.7
var attack_startup:float=0.4
var can_attack:bool=true
var is_attacking:bool=false
var aim:Vector3=Vector3.FORWARD

var is_dead:bool=false
@onready var ai: AIController3D = find_child("AI")

# --- Soft separation -------------------------------------------------------
#
# Entity capsules do NOT collide with each other (layer 2 / layer 4 removed from
# both bodies' collision_mask; see soldier3.tscn and zombie3.tscn). They still
# collide with walls. Overlap is resolved here instead, by pushing bodies apart
# with a force rather than letting the physics engine refuse the move.
#
# Why: hard collision between converging bodies wedged the soldier in place --
# three zombies pressing from different angles left no free direction for
# move_and_slide to slide into, and it moved <0.15 m instead of 3 m. A soft
# force always produces some displacement, so an agent can push through a crowd.
#
# Radius is summed from both capsules: 0.5 + 0.5. Separation begins once the
# capsules overlap and ramps up as they interpenetrate further.
@export var separation_radius: float = 1.0
# Push speed at full overlap, in m/s. Applied as extra velocity, not teleported.
@export var separation_strength: float = 3.0
# Layer bits of OTHER entities to push away from. Default = char (2) + zombie
# (4), i.e. every entity, but never walls (1).
@export_flags_3d_physics var separation_mask: int = 6

# Extra velocity is computed per frame in compute_separation_velocity(); these
# are reused objects so the query does not allocate every physics tick.
var _separation_shape := SphereShape3D.new()
var _separation_query := PhysicsShapeQueryParameters3D.new()

# MEASURED (do not repeat this optimisation): throttling the query above to
# every 2nd or every 8th tick changed throughput by 0-1% -- 79 / 79 / 80 fps at
# interval 1 / 2 / 8 on the same build. The separation cost is NOT what caps
# training throughput, so there is nothing to win here and the per-tick query
# (which keeps the push exact) was restored. See docs/commands.txt.

# Combat logging is rate limited: a training run at 10x speedup fires hundreds
# of attacks per second, and an unthrottled print() floods the console and can
# dominate frame time. Set debug_logging = true on the node to see every event.
@export var debug_logging: bool = false
const DEBUG_LOG_INTERVAL_MSEC: int = 1000
var _debug_log_last_msec: Dictionary = {}

# Prints at most once per DEBUG_LOG_INTERVAL_MSEC per `tag`. With
# debug_logging on, every call prints.
func debug_log(tag: String, message: String) -> void:
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
	current_speed = speed_stat
	current_health = max_health

func _physics_process(delta: float) -> void:
	if is_dead:
		return
	
	#move = move.normalized()
	var mesh: MeshInstance3D = $Mesh

	# aim is a global point (cursor hit, target.global_position).
	var forward := aim - global_position
	forward.y = 0.0
	if forward.length_squared() > 0.000001:
		forward = forward.normalized()
		# look_at points the mesh's -Z at this point, so facing matches forward.
		mesh.look_at(global_position + forward)
	else:
		forward = -mesh.global_basis.z
		forward.y = 0.0
		if forward.length_squared() > 0.000001:
			forward = forward.normalized()
		else:
			forward = Vector3.FORWARD

	if move:
		# Facing -Z, right is +X: forward (0, 0, -1) -> right (1, 0, 0).
		var right := Vector3(-forward.z, 0.0, forward.x)
		# move.x: strafe, + is right. move.z: W is -1 (toward aim), S is +1.
		if move.z > 0.0:
			move.z *= BACKPEDAL_SPEED
		else:
			move.z *= 1.0
		velocity = (right * move.x * STRAFE_SPEED - forward * move.z) * current_speed
	else:
		velocity = Vector3.ZERO

	# Add the separation push on top of the intended motion, then move. Walls
	# still stop everything because they remain in collision_mask.
	velocity += compute_separation_velocity()
	move_and_slide()


# Returns a velocity that pushes this body out of any overlapping entity, or
# zero when nothing is overlapping. Bodies on layer 1 (walls) are never pushed
# away from -- separation_mask defaults to char + zombie only.
func compute_separation_velocity() -> Vector3:
	if is_dead:
		return Vector3.ZERO
	var space := get_world_3d().direct_space_state
	if space == null:
		return Vector3.ZERO

	# One sphere at the capsule's mid-height, radius = sum of both radii.
	_separation_shape.radius = separation_radius
	_separation_query.shape = _separation_shape
	_separation_query.transform = Transform3D(Basis(), global_position)
	_separation_query.collision_mask = separation_mask
	_separation_query.collide_with_bodies = true
	_separation_query.collide_with_areas = false
	# Do not push away from ourselves.
	_separation_query.exclude = [get_rid()]

	var hits := space.intersect_shape(_separation_query, 8)
	if hits.is_empty():
		return Vector3.ZERO

	var push := Vector3.ZERO
	var contacts := 0
	for hit in hits:
		var other = hit.get("collider")
		if other == null or not (other is Node3D):
			continue
		if "is_dead" in other and other.is_dead:
			continue
		var away: Vector3 = global_position - (other as Node3D).global_position
		away.y = 0.0
		var dist := away.length()
		if dist < 0.0001:
			# Exactly co-located: pick a deterministic direction so the pair
			# does not sit oscillating on top of each other.
			away = Vector3.RIGHT
			dist = 0.0001
		# Overlap fraction: 1 at dead centre, 0 at touching.
		var overlap := clampf(1.0 - dist / separation_radius, 0.0, 1.0)
		push += away.normalized() * overlap
		contacts += 1

	if contacts == 0:
		return Vector3.ZERO
	push /= float(contacts)
	# Ramp with interpenetration; capped at separation_strength.
	return push * separation_strength



# Startup delay, then a ray of length attack_range.
# target_pos is a global point (cursor hit or target.global_position).
func attack():
	if not can_attack or is_attacking:
		return
	debug_log("attack", "{0} attack".format([name]))

	# Snapshot the aim NOW. _physics_process overwrites `aim` every frame (from
	# the cursor in human mode, from requested_turn in AI mode), so by the time
	# the startup delay below elapses `aim` no longer points at what the caller
	# aimed at. Without this snapshot the ray fires along a stale direction and
	# every attack misses.
	var attack_aim := aim
	if $hit:
		$hit.flash(attack_aim)
	is_attacking = true
	await get_tree().create_timer(attack_startup).timeout
	if not is_inside_tree():
		return
	is_attacking = false

	# The body is not rotated toward aim; only the mesh is. RayCast3D.target_position
	# is local to the ray. Normalizing a world position aims from the world origin,
	# so the ray hits only when this body happens to stand on that line.
	# Cast from here toward the aim captured at attack time.
	var to_target := attack_aim - global_position
	var ray: RayCast3D = $ray
	if to_target.length_squared() > 0.000001:
		ray.target_position = ray.global_basis.inverse() * to_target.normalized() * attack_range
		ray.force_raycast_update()
		var col = ray.get_collider()
		if col:
			var dmg_info: Dictionary = col.take_damage(damage, self)
			var percent_damage: float = dmg_info["percent_damage"]
			var is_kill: bool = dmg_info["is_kill"]
			_on_attack_landed(percent_damage, is_kill)
			debug_log("hit", "{0} hit target".format([name]))
	can_attack = false
	start_attack_cd()
	return

func start_attack_cd():
	await get_tree().create_timer(attack_cd).timeout
	can_attack=true

func _on_attack_landed(_percent_damage: float, _is_kill: bool) -> void:
	pass

#returns dictionary with two values:
#true if taking this damage causes death
#percent of targets health removed by attack
func take_damage(damage:float, _attacker: Node3D = null) -> Dictionary:
	var is_kill = false
	if is_queued_for_deletion():
		return {"is_kill": is_kill,"percent_damage": 0.0}
	var percent_damage:float = damage/current_health
	current_health = clamp(current_health-damage,0.0,max_health)
	_on_damage_taken(percent_damage)
	if current_health == 0.0:
		die()
		is_kill = true
	return {"is_kill": is_kill,"percent_damage": percent_damage}

func _on_damage_taken(_percent_damage: float) -> void:
	pass

func die():
	debug_log("die", "{0} die".format([name]))
	is_dead=true
	queue_free()
