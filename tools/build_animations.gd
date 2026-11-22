extends SceneTree
## Builds in-place locomotion clips for the paladin rig.
##
##   godot --headless --path . --import
##   godot --headless --path . --script res://tools/build_animations.gd
##
## Each Mixamo clip is imported on its own skeleton whose bones are named
## mixamorig_Hips, while the characters used here carry the same rig with bare
## names (Hips). The clips are therefore copied track-by-track with the prefix
## stripped, and root translation is dropped: movement comes from char3.gd, so
## playing baked forward travel would slide the character across the arena.

const ANIM_DIR := "res://assets/Animations"
const OUT_DIR := "res://animations"

# Direction names are the ones measured from Hips travel in local space
# (paladin faces +Z, its left is -X):
#   walk.fbx            +Z  forward
#   walk (2).fbx        -Z  backward
#   strafe.fbx          -X  left
#   strafe (2).fbx      +X  right
const CLIPS := {
	"walk_forward": "sword and shield walk.fbx",
	"walk_backward": "sword and shield walk (2).fbx",
	"walk_left": "sword and shield strafe.fbx",
	"walk_right": "sword and shield strafe (2).fbx",
}
const HIPS := "mixamorig_Hips"


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var failed := false
	for key in CLIPS:
		if not _build(key, CLIPS[key]):
			failed = true
	quit(1 if failed else 0)


func _build(key: String, file: String) -> bool:
	var scene_path := ANIM_DIR + "/" + file
	var packed: PackedScene = load(scene_path)
	if packed == null:
		printerr("cannot load ", scene_path)
		return false
	var inst: Node = packed.instantiate()
	var player: AnimationPlayer = inst.get_node_or_null("AnimationPlayer")
	if player == null:
		printerr("no AnimationPlayer in ", scene_path)
		inst.free()
		return false
	var lib: AnimationLibrary = player.get_animation_library("")
	var names := lib.get_animation_list()
	if names.is_empty():
		printerr("no animation in ", scene_path)
		inst.free()
		return false
	var source: Animation = lib.get_animation(names[0])

	var anim := Animation.new()
	anim.length = source.length
	anim.loop_mode = Animation.LOOP_LINEAR
	anim.step = source.step

	var kept := 0
	var dropped_position := 0
	for i in source.get_track_count():
		var path := String(source.track_get_path(i))
		if not path.begins_with("Skeleton3D:"):
			continue
		# Tracks address bones relative to the player's root_node, which the
		# animator points AT the skeleton, so the "Skeleton3D:" prefix must go.
		# The mixamorig_ prefix stays: that is the actual bone name Godot
		# imported (mixamorig_Hips), and removing it fails to resolve.
		var bone := path.trim_prefix("Skeleton3D:")
		var type := source.track_get_type(i)
		# Root translation is authored motion (Hips travel up to 1.5 m per
		# cycle); the character's position is owned by char3.gd. Rotation,
		# including the Hips, is kept so the gait still reads.
		if bone == HIPS and type == Animation.TYPE_POSITION_3D:
			dropped_position += 1
			continue
		var t := anim.add_track(type)
		anim.track_set_path(t, NodePath("Skeleton3D:" + bone))
		for k in source.track_get_key_count(i):
			anim.track_insert_key(t, source.track_get_key_time(i, k), source.track_get_key_value(i, k))
		kept += 1
	inst.free()

	var out_path := OUT_DIR + "/" + key + ".res"
	var err := ResourceSaver.save(anim, out_path)
	print("%-14s <- %-32s tracks=%d  hips_pos_dropped=%d  len=%.2fs  save=%d"
		% [key, file, kept, dropped_position, anim.length, err])
	return err == OK
