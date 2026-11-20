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
var spawn_pos:Vector3
var target:Node3D
func _ready():
	spawn_pos = global_position
	# Lets EntitySensor3D find zombies without walking the scene tree.
	add_to_group("enemy")
	if ai:
		ai.init(self)
	$hit.visible = false
	super._ready()

func respawn():
	global_position = spawn_pos
	current_health = max_health
	is_dead = false
	ai.done=false
	visible = true


func _physics_process(delta: float) -> void:
	if is_dead:
		return
	move= Vector3.ZERO
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
	if info["is_kill"] and attacker == target:
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
