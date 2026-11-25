extends SceneTree

func _init() -> void:
	print("[TestSquadBattleNav] Starting automated verification...")
	_run_test()

func _run_test() -> void:
	var scene_res = load("res://scenes/3d/squad_battle_nav.tscn")
	assert(scene_res != null, "Failed to load squad_battle_nav.tscn")
	var battle = scene_res.instantiate()
	root.add_child(battle)

	# Allow _ready() and navmesh baking to complete
	for f in range(6):
		await process_frame

	print("[TestSquadBattleNav] Checking 5v5 squads and KOTH startup...")
	assert(battle._blue_soldiers.size() == 5, "Expected 5 Blue soldiers, found %d" % battle._blue_soldiers.size())
	assert(battle._red_soldiers.size() == 5, "Expected 5 Red soldiers, found %d" % battle._red_soldiers.size())
	assert(battle.current_arena_key == "koth", "Default arena should be koth")

	for s in battle._blue_soldiers + battle._red_soldiers:
		assert(s.level >= 1 and s.level <= 3, "Soldier %s level must be 1, 2, or 3, got %d" % [s.name, s.level])
		assert(int(s.role) >= 0 and int(s.role) <= 3, "Soldier %s role must be in 0..3, got %d" % [s.name, int(s.role)])
		assert(s._nav_agent != null, "Soldier %s must have a NavigationAgent3D" % s.name)
		assert(s._nav_agent.avoidance_enabled, "Soldier %s NavAgent must have RVO avoidance enabled" % s.name)
		var ai = s.get_node("AI")
		assert(ai != null, "AI controller missing on %s" % s.name)
		var obs: Array = ai.get_obs().get("obs", [])
		assert(obs.size() == 154, "Observation vector must be 154 floats, got %d" % obs.size())

	# Simulate 40 physics frames of 5v5 KOTH combat navigation
	print("[TestSquadBattleNav] Simulating 40 physics frames of 5v5 KOTH...")
	for f in range(40):
		await physics_frame

	var blue_tank = battle._blue_soldiers[0]
	print("   Blue Tank pos after 40 frames: (%.2f, %.2f)" % [blue_tank.global_position.x, blue_tank.global_position.z])
	assert(blue_tank.global_position.x > blue_tank.spawn_pos.x, "Blue Tank should advance toward KOTH center/enemy!")

	# Test KOTH casualty queues respawn instead of ending round
	var red_victim = battle._red_soldiers[0]
	red_victim.die()
	await process_frame
	assert(battle._respawn_timers.has(red_victim), "KOTH casualty must queue respawn timer")
	assert(not battle._is_round_ending, "Single KOTH casualty must not end round")

	# Trigger KOTH win and check rotation to Pillars (elimination mode)
	battle._current_arena_node.koth_won.emit(0)
	await process_frame
	await process_frame
	assert(battle.blue_score == 1, "Blue score should be 1 after KOTH win, got %d" % battle.blue_score)

	print("   Waiting for auto-reset (2.6s)...")
	var prev_arena = battle.current_arena_key
	for f in range(160):
		await physics_frame

	assert(battle.round_number == 2, "Round number should have advanced to 2!")
	assert(battle.current_arena_key != prev_arena, "Arena should have rotated on new round!")
	assert(battle._blue_soldiers.size() == 5, "New 5 Blue soldiers should be spawned!")
	assert(battle._red_soldiers.size() == 5, "New 5 Red soldiers should be spawned!")

	# Round 2 is Pillars (elimination mode): wiping Red ends round
	for s in battle._red_soldiers:
		s.die()
	await process_frame
	await process_frame
	assert(battle.blue_score == 2, "Blue score should advance to 2 after elimination wipe, got %d" % battle.blue_score)

	battle.queue_free()
	print("\n[SUCCESS] Squad Battle Nav 5v5, all 4 classes, KOTH respawns, elimination & arena rotation verified!")
	quit(0)
