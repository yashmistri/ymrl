extends SceneTree

const SoldierScene = preload("res://characters/soldier3/soldier3.tscn")

func _init() -> void:
	print("[TestKOTHAndSensors] Starting comprehensive verification...")
	_run()

func _run() -> void:
	await process_frame

	# 1. EntitySensor3D (5 nearest slots + eviction when closer enemy appears)
	print("\n--- 1. Verifying EntitySensor3D 5-slot preemption ---")
	var blue_tank = SoldierScene.instantiate()
	blue_tank.team = 0
	blue_tank.role = 0
	blue_tank.is_bot = true
	root.add_child(blue_tank)
	blue_tank.global_position = Vector3(0, 1, 0)

	var enemies: Array = []
	for i in 8:
		var e = SoldierScene.instantiate()
		e.team = 1
		e.role = 3 # Basic
		e.is_bot = true
		root.add_child(e)
		e.global_position = Vector3(6.0 + float(i) * 2.0, 1, 0) # 6m .. 20m
		enemies.append(e)

	await physics_frame
	var es = blue_tank.get_node("EntitySensor")
	assert(es.max_slots == 5, "EntitySensor max_slots must be 5, got %d" % es.max_slots)
	es._refresh_slots()
	for i in 5:
		assert(es._slots[i] != null, "All 5 enemy slots should be filled when 8 enemies are in range")
		assert(blue_tank.global_position.distance_to(es._slots[i].global_position) <= 14.1, "Only 5 nearest enemies (<=14m) should hold initial slots")

	# Spawn a 9th enemy super close (2m) and confirm it evicts the farthest slot (14m)
	var ambush = SoldierScene.instantiate()
	ambush.team = 1
	ambush.role = 2
	ambush.is_bot = true
	root.add_child(ambush)
	ambush.global_position = Vector3(2.0, 1, 0)
	enemies.append(ambush)

	await physics_frame
	es._refresh_slots()
	assert(es._slot_of.has(ambush), "Closer 2m enemy must preempt one of the farther 5 slots!")
	assert(es.nearest_target() == ambush, "nearest_target() must see preempting 2m enemy")
	print("   [OK] EntitySensor3D 5-slot nearest preemption verified.")

	# 2. AllySensor3D: Normal soldier (5 nearest) vs Medic (2 nearest + 3 lowest HP)
	print("\n--- 2. Verifying AllySensor3D (5 nearest vs Medic 2 nearest + 3 lowest HP) ---")
	var blue_allies: Array = []
	# Spawn 2 healthy nearby allies (3m, 4m)
	for i in 2:
		var near_ally = SoldierScene.instantiate()
		near_ally.team = 0
		near_ally.role = 3
		near_ally.is_bot = true
		near_ally.randomize_level_on_spawn = false
		root.add_child(near_ally)
		near_ally.global_position = Vector3(-3.0 - float(i), 1, 0) # 3m, 4m
		blue_allies.append(near_ally)

	# Spawn 3 medium-distance healthy allies (7m, 8m, 9m)
	for i in 3:
		var mid_ally = SoldierScene.instantiate()
		mid_ally.team = 0
		mid_ally.role = 3
		mid_ally.is_bot = true
		mid_ally.randomize_level_on_spawn = false
		root.add_child(mid_ally)
		mid_ally.global_position = Vector3(-7.0 - float(i), 1, 0)
		blue_allies.append(mid_ally)

	# Spawn 3 far critical-HP allies (15m, 16m, 17m at 15% HP)
	var injured_list: Array = []
	for i in 3:
		var hurt_ally = SoldierScene.instantiate()
		hurt_ally.team = 0
		hurt_ally.role = 2
		hurt_ally.is_bot = true
		hurt_ally.randomize_level_on_spawn = false
		root.add_child(hurt_ally)
		hurt_ally.global_position = Vector3(-15.0 - float(i), 1, 0)
		hurt_ally.current_health = hurt_ally.max_health * 0.15
		blue_allies.append(hurt_ally)
		injured_list.append(hurt_ally)

	# Spawn a Blue Basic soldier and Blue Medic at origin
	var blue_basic = SoldierScene.instantiate()
	blue_basic.team = 0
	blue_basic.role = 3
	blue_basic.is_bot = true
	root.add_child(blue_basic)
	blue_basic.global_position = Vector3(0, 1, 1)

	var blue_medic = SoldierScene.instantiate()
	blue_medic.team = 0
	blue_medic.role = 1
	blue_medic.is_bot = true
	root.add_child(blue_medic)
	blue_medic.global_position = Vector3(0, 1, -1)

	await physics_frame
	var bs_ally = blue_basic.get_node("AllySensor")
	assert(bs_ally.max_slots == 5, "AllySensor max_slots must be 5")
	bs_ally._refresh_slots()
	var basic_has_far_injured := false
	for inj in injured_list:
		if bs_ally._slot_of.has(inj):
			basic_has_far_injured = true
	assert(not basic_has_far_injured, "Basic soldier must track 5 NEAREST allies, not 15-17m allies")

	var med_ally = blue_medic.get_node("AllySensor")
	med_ally._refresh_slots()
	var tracked_injured := 0
	for inj in injured_list:
		if med_ally._slot_of.has(inj):
			tracked_injured += 1
	assert(tracked_injured == 3, "Medic must reserve 3 slots for lowest-HP allies, got %d" % tracked_injured)
	assert(med_ally.nearest_injured_ally() in injured_list, "Medic nearest_injured_ally() must surface critical teammate")
	print("   [OK] Basic sees 5 nearest allies; Medic sees 2 nearest + 3 lowest HP allies.")

	# Cleanup temporary entities before scene tests
	blue_tank.queue_free()
	blue_basic.queue_free()
	blue_medic.queue_free()
	for n in enemies + blue_allies:
		n.queue_free()
	await process_frame

	# 3. Verify 5v5 KOTH Training Scene (4 cells, 20 agents, staggered repeat, KOTH scoring & win reward)
	print("\n--- 3. Verifying training_koth.tscn (5v5 x 4 cells = 20 agents) ---")
	var koth_train_res = load("res://training/training_koth.tscn")
	assert(koth_train_res != null, "Failed to load training_koth.tscn")
	var koth_train = koth_train_res.instantiate()
	var sync_node = koth_train.get_node_or_null("Sync")
	assert(sync_node != null, "training_koth.tscn must include Sync node")
	assert(sync_node.action_repeat == 8, "Sync action_repeat must be 8")
	koth_train.remove_child(sync_node)
	sync_node.free()
	root.add_child(koth_train)
	for _f in range(4):
		await process_frame

	var agents = get_nodes_in_group("AGENT")
	assert(agents.size() == 20, "Expected 20 learning agents across 4 KOTH cells (4x5), got %d" % agents.size())
	var seen_offsets := {}
	for a in agents:
		seen_offsets[int(a._action_repeat_counter)] = true
		var obs: Array = a.get_obs().get("obs", [])
		assert(obs.size() == 154, "KOTH agent obs must be 154 floats, got %d" % obs.size())
	assert(seen_offsets.size() >= 4, "Action repeat counters should be staggered across agents, got %s" % str(seen_offsets.keys()))

	var cell1 = koth_train.get_node("Cell_KOTH_1")
	var arena1 = cell1.arena_instance
	assert(arena1.has_hill, "ArenaKOTH must have has_hill=true")

	# Place Blue soldier on hill & move Red away -> verify Blue captures & scores + agents get hill reward
	for b in cell1._blue_soldiers:
		b.global_position = arena1.get_hill_world_position()
	for r in cell1._red_soldiers:
		r.global_position = arena1.get_hill_world_position() + Vector3(20, 0, 0)

	for _f in range(180): # 3s at 60Hz -> enough to finish 2.0s capture & start ticking score
		await physics_frame

	assert(arena1.hill_owner == 0, "Blue should capture uncontested hill, got owner=%d" % arena1.hill_owner)
	assert(arena1.blue_hill_score > 0.5, "Blue hill score should increase while holding point, got %.2f" % arena1.blue_hill_score)

	cell1._blue_soldiers[0].global_position = arena1.get_hill_world_position()
	var test_agent = cell1._blue_soldiers[0].get_node("AI")
	var pre_obs: Array = test_agent.get_obs().get("obs", [])
	# Objective block starts at index 147: [rel_x, rel_z, dist, in_hill, owner_rel, contested, score_diff]
	assert(pre_obs[150] == 1.0, "in_hill observation should be 1.0 on hill, got %s" % str(pre_obs[150]))
	assert(pre_obs[151] == 1.0, "owner_rel observation should be +1.0 for owner, got %s" % str(pre_obs[151]))

	var prev_ret: float = test_agent._episode_return
	cell1._on_koth_won(0)
	assert(test_agent._episode_return >= prev_ret + 14.9, "KOTH win must grant +15.0 bonus!")

	var roles_across_episodes := {}
	for _ep in range(4):
		cell1._end_episode(0)
		for s in cell1._blue_soldiers + cell1._red_soldiers:
			roles_across_episodes[int(s.role)] = true
	assert(roles_across_episodes.size() >= 3, "Random role mixes across episodes should cover multiple classes, got %s" % str(roles_across_episodes.keys()))
	print("   [OK] 5v5 KOTH cells, staggered inference, hill capture, objective obs, random role mixes, and win reward verified.")

	koth_train.queue_free()
	await process_frame

	# 4. 20v20 Showcase Stress Test on ArenaKOTH
	print("\n--- 4. Verifying 20v20 scale inference smoke test ---")
	var battle_res = load("res://scenes/3d/squad_battle_nav.tscn")
	var battle = battle_res.instantiate()
	battle.squad_size = 20
	battle.current_arena_key = "koth"
	battle.rotate_arenas = false
	root.add_child(battle)
	for _f in range(4):
		await process_frame
	assert(battle._blue_soldiers.size() == 20 and battle._red_soldiers.size() == 20, "Must spawn 20v20 soldiers")
	for _f in range(15):
		await physics_frame
	var s20_obs: Array = battle._blue_soldiers[19].get_node("AI").get_obs().get("obs", [])
	assert(s20_obs.size() == 154, "20v20 soldier obs must remain 154 floats")
	battle.queue_free()
	print("   [OK] 20v20 combat + 154-d obs verified without errors.")

	print("\n[SUCCESS] All sensor, Basic class, KOTH 5v5, and 20v20 checks passed!")
	quit(0)
