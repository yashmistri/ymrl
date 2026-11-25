extends SceneTree

func _init() -> void:
	print("[TestTrainingAllArenas] Starting verification...")
	_run_test()

func _run_test() -> void:
	var scene_res = load("res://training/training_all_arenas.tscn")
	assert(scene_res != null, "Failed to load training_all_arenas.tscn")
	var root_node = scene_res.instantiate()
	var sync_node = root_node.get_node_or_null("Sync")
	assert(sync_node != null, "training_all_arenas.tscn must include Sync node")
	assert(sync_node.action_repeat == 8, "Sync action_repeat must be 8")
	root_node.remove_child(sync_node)
	sync_node.free()
	root.add_child(root_node)

	for f in range(6):
		await process_frame

	print("[TestTrainingAllArenas] Checking all arena cells...")
	var cells = [
		root_node.get_node("Cell_Pillars"),
		root_node.get_node("Cell_Dividers"),
		root_node.get_node("Cell_Alcoves"),
		root_node.get_node("Cell_Compound")
	]

	for cell in cells:
		assert(cell != null, "Arena cell node missing!")
		assert(cell.arena_instance != null, "Arena instance not created in cell %s!" % cell.name)
		print("   Cell %s -> Arena: %s" % [cell.name, cell.arena_instance.arena_name])
		assert(cell._blue_soldiers.size() == 3, "Expected 3 Blue soldiers in cell %s" % cell.name)
		assert(cell._red_soldiers.size() == 3, "Expected 3 Red soldiers in cell %s" % cell.name)

	# Verify Sync node and total agents in group AGENT
	var agents = get_nodes_in_group("AGENT")
	print("[TestTrainingAllArenas] Total learning agents in group 'AGENT': %d (Expected: 12)" % agents.size())
	assert(agents.size() == 12, "Expected exactly 12 learning agents across 4 arenas, got %d" % agents.size())

	for a in agents:
		assert(a.control_mode == a.ControlModes.TRAINING, "Agent %s must have control_mode = TRAINING" % a.get_parent().name)
		assert(not a.is_bot, "Learning agent %s must have is_bot = false" % a.get_parent().name)
		var obs: Array = a.get_obs().get("obs", [])
		assert(obs.size() == 154, "Observation vector must be 154 floats, got %d" % obs.size())

	# Run 30 physics frames of simultaneous 4-arena combat
	print("[TestTrainingAllArenas] Simulating 30 physics frames across all 4 arenas simultaneously...")
	for f in range(30):
		await physics_frame

	print("\n[SUCCESS] training_all_arenas.tscn verified: 4 arenas, 12 learning agents, 154-d obs space!")
	quit(0)
