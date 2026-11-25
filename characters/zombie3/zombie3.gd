extends Char3


# While pressing against the soldier, the zombie stops moving entirely.
#
# Crowd softness: without it, three zombies converging pin the soldier in place.
# Measured with a ring of 3 zombies at varying radii, soldier walking 3.0 m/s:
#
#   scale 1.0 (no change)  moved 0.06-0.90 m   pinned
#   scale 0.5              moved 0.06-0.90 m   still pinned
#   scale 0.25             moved 0.47-3.30 m   escapes except at r=1.2
#   scale 0.0              moved 0.98-3.35 m   escapes at every radius
#
# Partial slowing was not enough: with three bodies pressing at slightly
# different angles the tangential slide components cancel, so only a near-zero
# zombie speed leaves real headway. 0.0 was also the only setting that
# reproduced consistently across runs.
#
# The zombie still closes to contact range at full speed -- this only stops it
# once the capsules are actually touching (CONTACT_DISTANCE), so approach and
# surround pressure are unchanged.
const CONTACT_SPEED_SCALE:float = 0.0
# Sum of both capsule radii (0.5 + 0.5) plus a small margin. Inside this the two
# bodies are touching or overlapping.
const CONTACT_DISTANCE:float = 1.1

var requested_move:Vector2
var is_running:bool=false
var is_stunned:bool=false
var _stun_timer:float=0.0
@onready var _stun_indicator:MeshInstance3D = get_node_or_null("StunIndicator")
var spawn_pos:Vector3
var target:Node3D

func _ready():
	spawn_pos = global_position
	# Lets EntitySensor3D find zombies without walking the scene tree.
	add_to_group("enemy")
	_create_stun_indicator()
	if ai:
		ai.init(self)
	$hit.visible = false
	super._ready()

func _create_stun_indicator() -> void:
	if not _stun_indicator:
		_stun_indicator = get_node_or_null("StunIndicator")
	if _stun_indicator:
		_stun_indicator.visible = false

func stun(duration: float) -> void:
	if is_dead:
		return
	is_stunned = true
	_stun_timer = maxf(_stun_timer, duration)
	is_attacking = false
	if _stun_indicator:
		_stun_indicator.visible = true

func apply_knockback(force: Vector3) -> void:
	if is_dead:
		return
	super.apply_knockback(force)

func respawn():
	global_position = spawn_pos
	current_health = max_health
	is_dead = false
	is_stunned = false
	_stun_timer = 0.0
	locomotion_velocity = Vector3.ZERO
	knockback_velocity = Vector3.ZERO
	velocity = Vector3.ZERO
	move = Vector3.ZERO
	if _stun_indicator:
		_stun_indicator.visible = false
	ai.done=false
	visible = true


func _physics_process(delta: float) -> void:
	if is_dead:
		return

	if _stun_timer > 0.0:
		_stun_timer -= delta
		if _stun_timer <= 0.0:
			is_stunned = false
			if _stun_indicator:
				_stun_indicator.visible = false
		current_speed = 0.0
		move = Vector3.ZERO
		locomotion_velocity = Vector3.ZERO
		super._physics_process(delta)
		return

	move= Vector3.ZERO
	if target == null or ("is_dead" in target and target.is_dead):
		var soldiers := get_tree().get_nodes_in_group("soldier")
		var nearest: Node3D = null
		var min_dist: float = 1e9
		for s in soldiers:
			if s is Node3D and ("is_dead" not in s or not s.is_dead):
				var d: float = global_position.distance_to(s.global_position)
				if d < min_dist:
					min_dist = d
					nearest = s
		target = nearest

	# Commit to the attack: stop moving during the wind-up so backing off can
	# actually escape it. Without this the zombie keeps closing at 2.0 while
	# winding up, which is faster than a backpedalling soldier (1.88), so the
	# telegraph was pure decoration -- the hit landed regardless.
	if not is_attacking and target:
		aim = target.global_position
		move = Vector3(0.0, 0.0, -1.0)
		if global_position.distance_to(target.global_position) < 1.1 * attack_range:
			attack()
	# Walk normally, run once wounded. is_running used to be
	# `move.length() > 0.5`, but move is always a unit vector when a target
	# exists, so that was permanently true and the zombie moved at 2x forever --
	# there was no walk state at all.
	#
	# Below half health it starts running (2x). That gives the soldier a reason
	# to finish a wounded zombie rather than switch targets, and restores some
	# closing pressure late in a fight when kiting would otherwise be free.
	is_running = current_health < max_health * 0.5
	var run := (2.0 if is_running else 1.0)
	var attack_slow := (0.5 if is_attacking else 1.0)
	# Ease off while pressed against the soldier so a crowd can be pushed
	# through instead of pinning it. Applied on top of the other factors.
	var contact_slow := 1.0
	if target and global_position.distance_to(target.global_position) < CONTACT_DISTANCE:
		contact_slow = CONTACT_SPEED_SCALE
	current_speed = speed_stat * run * attack_slow * contact_slow
	super._physics_process(delta)

func take_damage(damage:float, attacker: Node3D = null) -> Dictionary:
	var info: Dictionary = super.take_damage(damage, attacker)
	var is_soldier_attacker = attacker and (attacker == target or attacker.is_in_group("soldier"))
	if info["is_kill"] and is_soldier_attacker:
		var arena: Node = get_parent()
		if arena and arena.has_method("zombie_killed_by_soldier"):
			arena.zombie_killed_by_soldier()
	return info

func die():
	is_dead = true
	visible = false
	debug_log("die", "{0} die".format([name]))
	queue_free()
func swing():
	pass
