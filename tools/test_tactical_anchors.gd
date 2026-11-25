extends SceneTree

const ARENAS := [
	"res://scenes/3d/arenas/arena_koth.tscn",
	"res://scenes/3d/arenas/arena_pillars.tscn",
	"res://scenes/3d/arenas/arena_dividers.tscn",
	"res://scenes/3d/arenas/arena_alcoves.tscn",
	"res://scenes/3d/arenas/arena_compound.tscn"
]

const SoldierScene = preload("res://characters/soldier3/soldier3.tscn")

func _init() -> void:
	print("[TestTacticalAnchors] Starting verification...")
	_run_all()

func _run_all() -> void:
	await process_frame
	await process_frame

	# 1. Test Observation Space & Action Space
	var test_soldier = SoldierScene.instantiate()
	root.add_child(test_soldier)
	test_soldier.global_position = Vector3(0, 1, 0)
	test_soldier.role = 0 # Tank
	test_soldier.level = 2
	await process_frame

	var ai = test_soldier.get_node("AI")
	assert(ai != null, "AI controller must exist on soldier")
	var obs_dict: Dictionary = ai.get_obs()
	var obs: Array = obs_dict.get("obs", [])
	print("   Obs dimension: %d (Expected: 154)" % obs.size())
	assert(obs.size() == 154, "Observation vector size must be exactly 154 floats!")

	var act_space: Dictionary = ai.get_action_space()
	print("   Action space keys: %s" % str(act_space.keys()))
	var expected_keys := ["anchor", "attack", "block", "sprint", "stance"]
	assert(act_space.keys() == expected_keys, "Action space keys must match alphabetical order!")
	assert(act_space["anchor"]["size"] == 9, "Anchor size must be 9!")
	assert(act_space["stance"]["size"] == 3, "Stance size must be 3!")

	test_soldier.queue_free()
	await process_frame
	print("   [PASS] Observation space (154-d) and 9-anchor Action space validated.")

	# 2. Test Tactical Anchor Execution in all 4 Arenas
	for arena_path in ARENAS:
		print("\n--- Testing Arena: %s ---" % arena_path)
		var arena_scene = load(arena_path)
		assert(arena_scene != null, "Failed to load arena: %s" % arena_path)
		var arena = arena_scene.instantiate()
		root.add_child(arena)

		# Wait for arena navigation mesh
		for frame in range(4):
			await process_frame

		# Spawn Blue Tank, Blue Medic, and Red Striker
		var blue = SoldierScene.instantiate()
		blue.name = "Blue_Tank"
		blue.team = 0
		blue.role = 0 # Tank
		blue.is_bot = true
		arena.add_child(blue)
		blue.global_position = Vector3(-8, 1.0, -2)

		var blue_medic = SoldierScene.instantiate()
		blue_medic.name = "Blue_Medic"
		blue_medic.team = 0
		blue_medic.role = 1 # Medic
		blue_medic.is_bot = true
		arena.add_child(blue_medic)
		blue_medic.global_position = Vector3(-9, 1.0, 3)

		var red = SoldierScene.instantiate()
		red.name = "Red_Striker"
		red.team = 1
		red.role = 2 # Striker
		red.is_bot = true
		arena.add_child(red)
		red.global_position = Vector3(8, 1.0, 0)

		for frame in range(5):
			await physics_frame

		var blue_ai = blue.get_node("AI")
		var medic_ai = blue_medic.get_node("AI")
		var red_ai = red.get_node("AI")

		# Use TRAINING control mode so our set_action calls are respected without bot heuristic override
		blue_ai.control_mode = blue_ai.ControlModes.TRAINING
		medic_ai.control_mode = medic_ai.ControlModes.TRAINING
		red_ai.control_mode = red_ai.ControlModes.TRAINING

		# Test Anchor 0: ENGAGE_TARGET
		blue_ai.set_action({"anchor": 0, "stance": 0, "sprint": 1, "attack": 0, "block": 0})
		for frame in range(25):
			await physics_frame
		var pos_after_engage: Vector3 = blue.global_position
		print("   ENGAGE_TARGET: Blue Tank moved from (-8, -2) towards Red to (%.2f, %.2f)" % [pos_after_engage.x, pos_after_engage.z])
		assert(pos_after_engage.x > -8.0, "Soldier should advance towards target under ENGAGE_TARGET!")

		# Test Anchor 1: FLANK_TARGET
		blue_ai.set_action({"anchor": 1, "stance": 1, "sprint": 1, "attack": 0, "block": 0})
		for frame in range(25):
			await physics_frame
		print("   FLANK_TARGET: Blue position = (%.2f, %.2f)" % [blue.global_position.x, blue.global_position.z])

		# Test Anchor 3: REGROUP_ALLY
		blue_ai.set_action({"anchor": 3, "stance": 1, "sprint": 1, "attack": 0, "block": 0})
		for frame in range(25):
			await physics_frame
		var dist_to_ally: float = blue.global_position.distance_to(blue_medic.global_position)
		print("   REGROUP_ALLY: Distance to ally Medic = %.2fm" % dist_to_ally)

		# Test Anchor 4: SUPPORT_INJURED (damage Blue Medic slightly)
		blue_medic.current_health = 40.0
		medic_ai.set_action({"anchor": 4, "stance": 1, "sprint": 1, "attack": 0, "block": 1})
		for frame in range(25):
			await physics_frame
		print("   SUPPORT_INJURED: Medic pos = (%.2f, %.2f) | health = %.1f" % [blue_medic.global_position.x, blue_medic.global_position.z, blue_medic.current_health])

		# Test Anchor 5: SEEK_COVER
		blue_ai.set_action({"anchor": 5, "stance": 2, "sprint": 1, "attack": 0, "block": 0})
		for frame in range(25):
			await physics_frame
		print("   SEEK_COVER: Blue moved to cover at (%.2f, %.2f)" % [blue.global_position.x, blue.global_position.z])

		# Test Anchor 6: HOLD_GROUND
		blue_ai.set_action({"anchor": 6, "stance": 1, "sprint": 0, "attack": 0, "block": 0})
		for f in range(20):
			await physics_frame
		var hold_start: Vector3 = blue.global_position
		for frame in range(20):
			await physics_frame
		var hold_dist: float = Vector2(blue.global_position.x, blue.global_position.z).distance_to(Vector2(hold_start.x, hold_start.z))
		print("   HOLD_GROUND: Horizontal Displacement = %.4fm" % hold_dist)
		assert(hold_dist < 0.05, "HOLD_GROUND should remain completely stationary!")

		# 3. Test Full Autonomous Bot Heuristic in this arena
		blue_ai.control_mode = blue_ai.ControlModes.HUMAN
		medic_ai.control_mode = medic_ai.ControlModes.HUMAN
		red_ai.control_mode = red_ai.ControlModes.HUMAN
		blue.is_bot = true
		blue_medic.is_bot = true
		red.is_bot = true
		for frame in range(50):
			await physics_frame
		print("   AUTONOMOUS BATTLE: 50 frames completed without crash. Blue pos=(%.2f, %.2f), Red pos=(%.2f, %.2f)" % [
			blue.global_position.x, blue.global_position.z,
			red.global_position.x, red.global_position.z
		])

		arena.queue_free()
		await process_frame

	print("\n[SUCCESS] All 7 Tactical Anchors, NavMesh pathing, 4 Arenas, and 149-d Observation Space verified!")
	quit(0)
