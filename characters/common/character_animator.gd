extends Node
## Plays in-place locomotion clips for a character, chosen from the movement
## vector the character's own controller already produces (char3.gd sets
## `move`, `current_speed` and `is_dead` on its CharacterBody3D).
##
## Deliberately ignorant of actions and reward: it only reads `move`, so it
## cannot influence the policy. It is purely cosmetic.
##
## Movement axes come from char3.gd:
##   move.z < 0  walking toward the aim (forward)
##   move.z > 0  backing away from the aim
##   move.x > 0  strafing right of the aim, < 0 left
## The blend favours the dominant axis, so diagonal movement reads as the larger
## component rather than flickering between clips.

const CLIP_FORWARD := "walk_forward"
const CLIP_BACKWARD := "walk_backward"
const CLIP_LEFT := "walk_left"
const CLIP_RIGHT := "walk_right"
## Below this requested speed the character is treated as standing still.
const IDLE_SPEED_EPSILON := 0.05
## Speed multiplier applied per clip, so the feet land near the ground speed.
## Tuned by eye against the soldier's 3.0 m/s run and 1.93 m/s walk-and-block.
const PLAYBACK_SCALE := 1.0

@export var body_path: NodePath = ^".."
@export var animation_library_dir: String = "res://animations"

var _body: CharacterBody3D
var _player: AnimationPlayer
var _skeleton: Skeleton3D
var _root_bones: Array[int] = []
var _current := ""


func _ready() -> void:
	_body = get_node_or_null(body_path)
	if _body == null:
		push_warning("%s: no body at %s; animation disabled" % [name, body_path])
		set_physics_process(false)
		return
	_player = AnimationPlayer.new()
	_player.name = "LocomotionPlayer"
	add_child(_player)
	# Track paths are written as "Skeleton3D:mixamorig_Hips" (copied from the
	# imported clips). AnimationPlayer resolves those relative to its own
	# root_node, which defaults to "..". This player lives under Animator, so
	# ".." was Animator and "Skeleton3D" did not exist there: every track
	# logged "couldn't resolve track" and the model stayed in its rest pose.
	# Pointing root_node at the skeleton's PARENT (the character) makes
	# "Skeleton3D:<bone>" resolve, which is the form the clips use.
	var skeleton := _body.get_node_or_null("Skeleton3D") as Skeleton3D
	if skeleton == null:
		push_warning("%s: no Skeleton3D on %s; animation disabled" % [name, _body.name])
		set_physics_process(false)
		return
	_player.root_node = _player.get_path_to(skeleton.get_parent())
	_player.animation_finished.connect(_on_animation_finished)
	_skeleton = skeleton
	# Root bones (no parent) carry the rig's orientation; yawing them turns the
	# whole body without fighting the clips, which animate their descendants.
	for i in skeleton.get_bone_count():
		if skeleton.get_bone_parent(i) == -1:
			_root_bones.append(i)
	_load_clips()


func _load_clips() -> void:
	# A fresh AnimationPlayer has NO default library, so get_animation_library("")
	# fails (and logs an ERROR) at _ready time. Conversely, once a library named
	# "" exists, add_animation_library("", ...) is a silent no-op that discards
	# the new animations. Both behaviours are traps; check explicitly.
	var lib: AnimationLibrary
	if _player.has_animation_library(""):
		lib = _player.get_animation_library("")
	else:
		lib = AnimationLibrary.new()
		_player.add_animation_library("", lib)
	for clip in [CLIP_FORWARD, CLIP_BACKWARD, CLIP_LEFT, CLIP_RIGHT]:
		var path := "%s/%s.res" % [animation_library_dir, clip]
		if not ResourceLoader.exists(path):
			push_warning("%s: missing clip %s (run tools/build_animations.gd)" % [name, path])
			continue
		lib.add_animation(clip, load(path))


func _physics_process(_delta: float) -> void:
	if _player == null or _body == null:
		return
	_face_aim()
	var move: Vector3 = _body.get("move")
	var speed: float = _body.get("current_speed")
	if not _body.get("is_dead") and move.length() * speed > IDLE_SPEED_EPSILON:
		var clip := _clip_for(move)
		if clip != _current:
			_current = clip
			if _player.has_animation(clip):
				_player.play(clip, -1.0, PLAYBACK_SCALE)
		return
	if _current != "":
		_current = ""
		# Stopping abruptly is fine: the skeleton holds its last pose while the
		# body stands still, which matches the unanimated rest pose the game
		# used before clips existed.
		_player.stop()


# Turns the rig to face the character's aim.
#
# char3.gd faces the old capsule with mesh.look_at(aim), i.e. the MESH's -Z
# points at the aim. The paladin's SkinnedMeshResources cannot be rotated
# directly -- the skeleton drives them -- so this rotates the bones instead:
# every root bone gets a yaw so the rig's -Z aims at the aim point.
#
# The paladin was authored facing +Z, which is why the build yaws the MESH by
# 180 degrees. The bones are NOT yawed at build time, so the rig's own forward
# is +Z; measured against the eight compass directions, adding 180 here made
# the model face exactly backwards. No flip needed.
const RIG_FORWARD_FLIP := 0.0


func _face_aim() -> void:
	# Facing is applied to the CharacterBody3D node in Char3._physics_process(),
	# which turns the entire body (skeleton, meshes, animations, helmet, outline).
	pass


# Dominant axis wins; ties go to forward/back so walking reads before strafing.
func _clip_for(move: Vector3) -> String:
	if absf(move.z) >= absf(move.x):
		return CLIP_FORWARD if move.z < 0.0 else CLIP_BACKWARD
	return CLIP_RIGHT if move.x > 0.0 else CLIP_LEFT


func _on_animation_finished(_anim: String) -> void:
	# Looping clips never emit this, but a clip that somehow stops must not
	# leave the animator thinking it is still playing one.
	_current = ""
