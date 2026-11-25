extends SceneTree

func _init():
	var arenas = [
		"res://scenes/3d/arenas/arena_koth.tscn",
		"res://scenes/3d/arenas/arena_pillars.tscn",
		"res://scenes/3d/arenas/arena_dividers.tscn",
		"res://scenes/3d/arenas/arena_alcoves.tscn",
		"res://scenes/3d/arenas/arena_compound.tscn"
	]
	for a_path in arenas:
		var res = load(a_path)
		assert(res != null, "Failed to load %s" % a_path)
		var instance = res.instantiate()
		assert(instance != null, "Failed to instantiate %s" % a_path)
		root.add_child(instance)
		print("Successfully loaded and instantiated: %s (Arena: %s)" % [a_path, instance.arena_name])
		instance.queue_free()

	print("[SUCCESS] All 4 arena scenes verified!")
	quit(0)
