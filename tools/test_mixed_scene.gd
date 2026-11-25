extends SceneTree

func _init() -> void:
	print("--- Testing TrainingSquadMixed scene ---")
	var scene_res = load("res://training/training_squad_mixed.tscn")
	if not scene_res:
		printerr("Failed to load res://training/training_squad_mixed.tscn")
		quit(1)
		return
	
	var inst = scene_res.instantiate()
	root.add_child(inst)
	
	# Give it a frame to run _ready
	await process_frame
	await process_frame
	
	var agents = get_nodes_in_group("AGENT")
	print("Total nodes in group 'AGENT': ", agents.size())
	for a in agents:
		var parent_name = a.get_parent().name if a.get_parent() else "no_parent"
		var arena_name = a.get_parent().get_parent().name if a.get_parent() and a.get_parent().get_parent() else "no_arena"
		var obs = a.get_obs()
		var obs_len = len(obs["obs"]) if obs and obs.has("obs") else -1
		print("  Agent: %s in %s (Arena: %s), control_mode=%s, obs_len=%d" % [
			a.name, parent_name, arena_name, a.control_mode, obs_len
		])
	
	var red_agents = []
	for node in inst.find_children("Red*"):
		if node is CharacterBody3D:
			var a = node.get_node_or_null("AI")
			if a:
				red_agents.append(a)
				print("  Red Opponent: %s, policy_source=%s, in_AGENT_group=%s, is_bot=%s" % [
					node.name, a.policy_source, a.is_in_group("AGENT"), a.is_bot
				])
	
	print("--- Finished Test successfully ---")
	quit(0)
