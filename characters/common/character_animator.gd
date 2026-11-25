extends Node
## Manages character animations for locomotion, combat, and class abilities.
## Deliberately reads movement and combat flags from the CharacterBody3D:
##   - is_dead: death / stopped pose
##   - is_attacking: attack (Tank/Medic) or slash (Striker)
##   - is_casting: casting (Medic heal / class abilities)
##   - is_blocking: shield block pose
##   - move / current_speed: locomotion (walk_forward, walk_backward, walk_left, walk_right)
##   - stationary: idle

const CLIP_FORWARD := "walk_forward"
const CLIP_BACKWARD := "walk_backward"
const CLIP_LEFT := "walk_left"
const CLIP_RIGHT := "walk_right"
const CLIP_IDLE := "idle"
const CLIP_ATTACK := "attack"
const CLIP_SLASH := "slash"
const CLIP_BLOCK := "block"
const CLIP_CAST := "cast"

const ALL_CLIPS := [
	CLIP_FORWARD, CLIP_BACKWARD, CLIP_LEFT, CLIP_RIGHT,
	CLIP_IDLE, CLIP_ATTACK, CLIP_SLASH, CLIP_BLOCK, CLIP_CAST
]

## Below this requested speed the character is treated as standing still.
const IDLE_SPEED_EPSILON := 0.05
const IDLE_TRANSITION_DELAY := 0.15
const PLAYBACK_SCALE := 1.0

@export var body_path: NodePath = ^".."
@export var animation_library_dir: String = "res://animations"

var _body: CharacterBody3D
var _player: AnimationPlayer
var _skeleton: Skeleton3D
var _root_bones: Array[int] = []
var _current := ""
var _idle_timer: float = 0.0


func _ready() -> void:
	_body = get_node_or_null(body_path)
	if _body == null:
		push_warning("%s: no body at %s; animation disabled" % [name, body_path])
		set_physics_process(false)
		return
	_player = get_node_or_null("LocomotionPlayer") as AnimationPlayer
	if _player == null:
		push_warning("%s: no LocomotionPlayer child in scene; animation disabled" % name)
		set_physics_process(false)
		return

	var skeleton := _body.get_node_or_null("Skeleton3D") as Skeleton3D
	if skeleton == null:
		push_warning("%s: no Skeleton3D on %s; animation disabled" % [name, _body.name])
		set_physics_process(false)
		return
	if _player.root_node.is_empty() or _player.get_node_or_null(_player.root_node) == null:
		_player.root_node = _player.get_path_to(skeleton.get_parent())
	if not _player.animation_finished.is_connected(_on_animation_finished):
		_player.animation_finished.connect(_on_animation_finished)
	_skeleton = skeleton
	for i in skeleton.get_bone_count():
		if skeleton.get_bone_parent(i) == -1:
			_root_bones.append(i)
	_load_clips()


func _load_clips() -> void:
	var lib: AnimationLibrary
	if _player.has_animation_library(""):
		lib = _player.get_animation_library("")
	else:
		lib = AnimationLibrary.new()
		_player.add_animation_library("", lib)

	for clip in ALL_CLIPS:
		var path := "%s/%s.res" % [animation_library_dir, clip]
		if not ResourceLoader.exists(path):
			continue
		var anim: Animation = load(path)
		if anim:
			lib.add_animation(clip, anim)


func _physics_process(delta: float) -> void:
	if _player == null or _body == null:
		return

	# Priority 1: Death
	if _body.get("is_dead"):
		_idle_timer = 0.0
		if _current != "":
			_current = ""
			_player.stop()
		return

	# Priority 2: Attacking
	if _body.get("is_attacking"):
		_idle_timer = 0.0
		var role_val: int = _body.get("role") if ("role" in _body) else 0
		var atk_clip := CLIP_SLASH if role_val == 2 else CLIP_ATTACK
		var atk_speed := 2.2 if role_val == 2 else (2.5 if role_val == 3 else 2.8)
		_play_clip(atk_clip, 0.1, atk_speed)
		return

	# Priority 3: Casting (Medic Healing) - play up to midpoint and hold while casting
	if _body.get("is_casting"):
		_idle_timer = 0.0
		_play_clip(CLIP_CAST, 0.1, 2.5)
		if _player.has_animation(CLIP_CAST):
			var mid_time: float = _player.get_animation(CLIP_CAST).length * 0.5
			if _player.is_playing() and _player.current_animation == CLIP_CAST and _player.current_animation_position >= mid_time:
				_player.seek(mid_time, true)
				_player.pause()
		return

	# Priority 4: Blocking
	if _body.get("is_blocking"):
		_idle_timer = 0.0
		_play_clip(CLIP_BLOCK, 0.15, 1.0)
		return

	# Priority 5: Locomotion (Moving)
	var move: Vector3 = _body.get("move")
	var speed: float = _body.get("current_speed")
	var is_moving := (move.length() * speed > IDLE_SPEED_EPSILON)
	if is_moving:
		_idle_timer = 0.0
		var walk_clip := _clip_for(move)
		_play_clip(walk_clip, 0.2, PLAYBACK_SCALE)
		return

	# Priority 6: Idle (with debounce for locomotion)
	var was_walking := (_current in [CLIP_FORWARD, CLIP_BACKWARD, CLIP_LEFT, CLIP_RIGHT])
	if was_walking and _idle_timer < IDLE_TRANSITION_DELAY:
		_idle_timer += delta
		return

	_idle_timer = 0.0
	if _player.has_animation(CLIP_IDLE):
		_play_clip(CLIP_IDLE, 0.25, 1.0)
	else:
		if _current != "":
			_current = ""
			_player.stop()


func _play_clip(clip: String, blend_time: float, speed: float) -> void:
	if _current != clip:
		_current = clip
		if _player.has_animation(clip):
			_player.play(clip, blend_time, speed)


func _clip_for(move: Vector3) -> String:
	var forward_weight := -move.z
	var backward_weight := move.z
	var right_weight := move.x
	var left_weight := -move.x

	const HYSTERESIS_BIAS := 0.25
	match _current:
		CLIP_FORWARD:
			forward_weight += HYSTERESIS_BIAS
		CLIP_BACKWARD:
			backward_weight += HYSTERESIS_BIAS
		CLIP_RIGHT:
			right_weight += HYSTERESIS_BIAS
		CLIP_LEFT:
			left_weight += HYSTERESIS_BIAS

	var best_clip := CLIP_FORWARD
	var best_weight := forward_weight

	if backward_weight > best_weight:
		best_clip = CLIP_BACKWARD
		best_weight = backward_weight
	if right_weight > best_weight:
		best_clip = CLIP_RIGHT
		best_weight = right_weight
	if left_weight > best_weight:
		best_clip = CLIP_LEFT
		best_weight = left_weight

	return best_clip


func _on_animation_finished(_anim: String) -> void:
	_current = ""
