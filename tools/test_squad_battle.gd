extends SceneTree

func _init() -> void:
	print("[TestSquadBattle] Starting automated verification...")
	var scene_res = load("res://scenes/3d/squad_battle.tscn")
	assert(scene_res != null, "Failed to load squad_battle.tscn")
	var battle = scene_res.instantiate()
	root.add_child(battle)

	# Allow _ready() to run
	await process_frame
	await process_frame

	print("[TestSquadBattle] Checking soldiers and models...")
	var blue_soldiers = battle._blue_soldiers
	var red_soldiers = battle._red_soldiers
	assert(blue_soldiers.size() == 3, "Expected 3 Blue soldiers, found %d" % blue_soldiers.size())
	assert(red_soldiers.size() == 3, "Expected 3 Red soldiers, found %d" % red_soldiers.size())

	for s in blue_soldiers + red_soldiers:
		assert(s.use_nn, "Soldier %s must have use_nn=true" % s.name)
		var ai = s.get_node_or_null("AI")
		assert(ai != null, "Soldier %s missing AI node" % s.name)
		assert(ai.onnx_model_path == "res://models/squad_rl_500k.onnx", "AI onnx_model_path should be squad_rl_500k.onnx")
		assert(ai.action_repeat == 8, "AI action_repeat must be 8, got %d" % ai.action_repeat)
		assert(s.level >= 1 and s.level <= 3, "Soldier %s level must be 1, 2, or 3, got %d" % [s.name, s.level])
		assert(s.crit_chance == 0.05, "Soldier %s crit_chance must be 0.05, got %f" % [s.name, s.crit_chance])
		assert(s.crit_multiplier == 3.0, "Soldier %s crit_multiplier must be 3.0, got %f" % [s.name, s.crit_multiplier])

		# Verify LevelLabel node exists and displays current level
		var lvl_lbl = s.get_node_or_null("LevelLabel") as Label3D
		assert(lvl_lbl != null, "Soldier %s missing LevelLabel node" % s.name)
		assert(lvl_lbl.text == str(s.level), "LevelLabel text should be '%d', got '%s'" % [s.level, lvl_lbl.text])
		assert(lvl_lbl.visible, "LevelLabel should be visible on alive soldier %s" % s.name)

		# Verify 25% damage boost and 8.0 medic healing
		if s.role == 0: # Tank
			assert(s.damage in [5.0, 6.875, 8.75], "Tank damage must have +25%% scaling, got %f" % s.damage)
		elif s.role == 1: # Medic
			assert(s.heal_per_sec == 8.0, "Medic heal_per_sec must be 8.0, got %f" % s.heal_per_sec)
			assert(s.damage in [2.5, 3.75, 5.0], "Medic damage must have +25%% scaling, got %f" % s.damage)
			print("   Verified Medic %s: Level %d | heal_per_sec = %.1f | dmg = %.2f" % [s.name, s.level, s.heal_per_sec, s.damage])
		elif s.role == 2: # Striker
			assert(s.damage in [12.5, 17.5, 22.5], "Striker damage must have +25%% scaling, got %f" % s.damage)

	print("[TestSquadBattle] Verifying 5% triple damage mechanic...")
	var test_soldier = blue_soldiers[0]
	var crit_observed := false
	for i in range(200):
		var dmg = test_soldier.get_attack_damage(null)
		if dmg >= test_soldier.damage * 2.9:
			crit_observed = true
			print("   Observed critical hit on attempt %d: %.1f dmg (base %.1f)" % [i + 1, dmg, test_soldier.damage])
			break
	assert(crit_observed, "Expected at least 1 critical hit across 200 attack rolls")

	print("[TestSquadBattle] Simulating Red Squad defeat...")
	for s in red_soldiers:
		s.die()

	# Give a frame for signals to propagate
	await process_frame
	await process_frame

	assert(battle.blue_score == 1, "Expected blue_score == 1, got %d" % battle.blue_score)
	assert(battle._is_round_ending, "Expected _is_round_ending == true")
	print("[TestSquadBattle] Win detected: Blue Score = %d, Red Score = %d" % [battle.blue_score, battle.red_score])

	print("[TestSquadBattle] Waiting for auto-reset (2.2s)...")
	var timer = create_timer(2.3)
	await timer.timeout

	assert(battle.round_number == 2, "Expected round_number == 2, got %d" % battle.round_number)
	assert(not battle._is_round_ending, "Expected _is_round_ending == false after reset")

	print("[TestSquadBattle] Verifying all soldiers respawned with full health...")
	for s in blue_soldiers + red_soldiers:
		assert(not s.is_dead, "Soldier %s should not be dead after reset" % s.name)
		assert(s.visible, "Soldier %s should be visible after reset" % s.name)
		assert(s.current_health == s.max_health, "Soldier %s HP should be reset to max_health" % s.name)

	print("[TestSquadBattle] SUCCESS: 2 teams NN inference and auto-reset verified completely!")
	quit(0)
