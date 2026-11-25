extends SceneTree

func _init() -> void:
	print("[TestAnimationsAndPlaceholders] Starting automated verification...")
	_run_tests()

func _run_tests() -> void:
	var soldier_res = load("res://characters/soldier3/soldier3.tscn")
	assert(soldier_res != null, "Failed to load soldier3.tscn")
	var soldier = soldier_res.instantiate()
	root.add_child(soldier)
	await process_frame
	await process_frame

	var animator = soldier.get_node_or_null("Animator")
	assert(animator != null, "Animator node missing on soldier")
	var player: AnimationPlayer = animator.get_node_or_null("LocomotionPlayer")
	assert(player != null, "LocomotionPlayer missing inside Animator")

	print("\n--- 0. Verifying Scene Hierarchy Nodes ---")
	assert(soldier.get_node_or_null("NavAgent") != null, "NavAgent missing in scene")
	assert(soldier.get_node_or_null("LevelLabel") != null, "LevelLabel missing in scene")
	assert(soldier.get_node_or_null("StunIndicator") != null, "StunIndicator missing in scene")
	assert(soldier.get_node_or_null("Shield") != null, "Shield missing in scene")
	assert(soldier.get_node_or_null("HealBeam") != null, "HealBeam missing in scene")
	print("   [OK] NavAgent, LevelLabel, StunIndicator, Shield, and HealBeam present in scene hierarchy.")

	print("\n--- 0b. Verifying Body & Helmet Meshes, Skinning, Alignment, and Level Visibility ---")
	var skel := soldier.get_node_or_null("Skeleton3D") as Skeleton3D
	var body_mesh := soldier.get_node_or_null("Mesh") as MeshInstance3D
	var body_outline := soldier.get_node_or_null("Outline") as MeshInstance3D
	var helmet_mesh := soldier.get_node_or_null("Paladin_J_Nordstrom_Helmet") as MeshInstance3D
	var helmet_outline := soldier.get_node_or_null("OutlineHelmet") as MeshInstance3D
	assert(skel != null and body_mesh != null and body_outline != null and helmet_mesh != null and helmet_outline != null, "Core character visual nodes missing")
	assert(body_mesh.mesh.get_aabb().size.y > 1.5, "Mesh must be the full body (~1.7m), got height %.2f" % body_mesh.mesh.get_aabb().size.y)
	assert(helmet_mesh.mesh.get_aabb().size.y < 0.5, "Paladin_J_Nordstrom_Helmet must be the helmet (<0.5m), got height %.2f" % helmet_mesh.mesh.get_aabb().size.y)
	for visual_node in [body_mesh, body_outline, helmet_mesh, helmet_outline]:
		assert(visual_node.skin != null, "%s must have a Skin bound" % visual_node.name)
		assert(visual_node.transform.is_equal_approx(skel.transform), "%s transform %s must match Skeleton3D transform %s so it does not float/mirror" % [visual_node.name, visual_node.transform, skel.transform])
	for lvl in [1, 2, 3]:
		soldier.level = lvl
		assert(body_mesh.visible == true and body_outline.visible == true, "Body mesh & outline must remain visible at level %d!" % lvl)
		assert(helmet_mesh.visible == (lvl >= 2) and helmet_outline.visible == (lvl >= 2), "Helmet visibility mismatch at level %d" % lvl)

	var zombie_res = load("res://characters/zombie3/zombie3.tscn")
	assert(zombie_res != null, "Failed to load zombie3.tscn")
	var zombie = zombie_res.instantiate()
	var z_skel := zombie.get_node_or_null("Skeleton3D") as Skeleton3D
	var z_body := zombie.get_node_or_null("Mesh") as MeshInstance3D
	var z_helmet := zombie.get_node_or_null("Paladin_J_Nordstrom_Helmet") as MeshInstance3D
	assert(z_body.mesh.get_aabb().size.y > 1.5, "Zombie Mesh must be full body")
	assert(z_helmet.mesh.get_aabb().size.y < 0.5, "Zombie Helmet must be helmet")
	assert(z_body.transform.is_equal_approx(z_skel.transform), "Zombie Mesh transform must match Skeleton3D")
	assert(z_helmet.transform.is_equal_approx(z_skel.transform), "Zombie Helmet transform must match Skeleton3D")
	zombie.free()
	print("   [OK] Body/helmet meshes, skins, transforms, and level 1-3 visibility verified on Soldier & Zombie.")

	print("\n--- 0c. Verifying Default Window Size & Fullscreen Toggle ---")
	assert(ProjectSettings.get_setting("display/window/size/viewport_width") == 1280, "Default viewport_width must stay 1280")
	assert(ProjectSettings.get_setting("display/window/size/viewport_height") == 720, "Default viewport_height must stay 720")
	var wc := root.get_node_or_null("WindowControls")
	assert(wc != null, "WindowControls autoload must be registered")
	assert(wc.has_method("toggle_fullscreen") and wc.has_method("is_fullscreen"), "WindowControls missing fullscreen methods")
	print("   [OK] Default window dimensions (1280x720) preserved and WindowControls autoload ready.")

	print("\n--- 1. Verifying Animation Library Loaded ---")
	var expected_clips := ["walk_forward", "walk_backward", "walk_left", "walk_right", "idle", "attack", "slash", "block", "cast"]
	for clip in expected_clips:
		assert(player.has_animation(clip), "AnimationPlayer must have clip: %s" % clip)
		print("   [OK] Loaded clip: %s (duration: %.2fs, loop: %s)" % [
			clip,
			player.get_animation(clip).length,
			player.get_animation(clip).loop_mode == Animation.LOOP_LINEAR
		])

	print("\n--- 2. Verifying Idle State ---")
	soldier.move = Vector3.ZERO
	animator._physics_process(0.016)
	assert(animator._current == "idle", "Stationary character must play idle animation, got: %s" % animator._current)
	print("   [OK] Idle animation playing when stationary.")

	print("\n--- 3. Verifying Locomotion State ---")
	soldier.move = Vector3(0, 0, -1)
	animator._physics_process(0.016)
	assert(animator._current == "walk_forward", "Moving -Z must play walk_forward, got: %s" % animator._current)
	print("   [OK] Forward walk animation playing when moving.")

	print("\n--- 4. Verifying Blocking & Placeholder Hidden ---")
	soldier.requested_block = true
	soldier.is_blocking = true
	animator._physics_process(0.016)
	assert(animator._current == "block", "Blocking character must play block animation, got: %s" % animator._current)
	assert(soldier._shield.visible == false, "Placeholder shield disc must be HIDDEN when blocking!")
	print("   [OK] Block animation playing and placeholder shield disc is hidden.")
	soldier.requested_block = false
	soldier.is_blocking = false

	print("\n--- 5. Verifying Attacking (Tank = attack, Striker = slash) ---")
	soldier.role = 0 # Tank
	soldier.is_attacking = true
	animator._physics_process(0.016)
	assert(animator._current == "attack", "Tank attacking must play 'attack' animation, got: %s" % animator._current)
	print("   [OK] Tank attack animation playing.")

	soldier.role = 2 # Striker
	soldier.is_attacking = true
	animator._physics_process(0.016)
	assert(animator._current == "slash", "Striker attacking must play 'slash' animation, got: %s" % animator._current)
	print("   [OK] Striker slash animation playing.")
	soldier.is_attacking = false

	print("\n--- 6. Verifying Casting Hold at Midpoint (Medic Heal) & Placeholder Hidden ---")
	soldier.move = Vector3.ZERO
	soldier.role = 1 # Medic
	soldier.is_casting = true
	var mid_time: float = player.get_animation("cast").length * 0.5
	for _i in 20:
		if player.is_playing():
			player.advance(0.1)
		animator._physics_process(0.1)
	assert(animator._current == "cast", "Medic casting must play 'cast' animation, got: %s" % animator._current)
	assert(not player.is_playing(), "Cast animation must pause/hold at midpoint while is_casting is true")
	assert(absf(player.current_animation_position - mid_time) < 0.05, "Cast must hold at midpoint (%.2f), got %.2f" % [mid_time, player.current_animation_position])
	for _i in 10:
		if player.is_playing():
			player.advance(0.1)
		animator._physics_process(0.1)
	assert(absf(player.current_animation_position - mid_time) < 0.05, "Cast must remain held at midpoint across frames, got %.2f" % player.current_animation_position)
	soldier._show_heal_vfx(soldier.global_position + Vector3(3, 0, 0))
	assert(soldier._heal_beam.visible == false, "Placeholder heal beam cylinder must be HIDDEN!")
	soldier.is_casting = false
	animator._physics_process(0.016)
	assert(animator._current == "idle", "Stopping cast must transition back to idle, got: %s" % animator._current)
	assert(player.is_playing(), "AnimationPlayer must resume playing after exiting cast hold")
	print("   [OK] Cast animation holds at midpoint while casting, resumes on exit, and placeholder heal beam is hidden.")

	print("\n--- 7. Verifying Attack Flash Placeholder Hidden ---")
	var hit_node = soldier.get_node_or_null("hit")
	assert(hit_node != null, "Hit node missing")
	hit_node.flash(soldier.global_position + Vector3(0, 0, 5))
	assert(hit_node.visible == false, "Attack hit placeholder must remain hidden during flash!")
	print("   [OK] Attack placeholder mesh remains hidden.")

	print("\n--- 8. Verifying Team-Matched Role Outline Colors & Basic Class ---")
	var outline_mesh := soldier.get_node_or_null("Outline") as MeshInstance3D
	assert(outline_mesh != null, "Outline MeshInstance3D missing")
	var blue_colors: Array[Color] = []
	soldier.team = 0
	for r in [0, 1, 2, 3]:
		soldier.role = r
		soldier._apply_role_visuals()
		var mat := outline_mesh.material_override as ShaderMaterial
		assert(mat != null, "Outline ShaderMaterial missing")
		var c: Color = mat.get_shader_parameter("outline_color")
		assert(c.b > c.r and c.b > 0.7, "Team 0 role %d outline must be a shade of blue, got %s" % [r, str(c)])
		assert(not blue_colors.has(c), "Team 0 role outlines must be distinct shades of blue")
		blue_colors.append(c)
	var red_colors: Array[Color] = []
	soldier.team = 1
	for r in [0, 1, 2, 3]:
		soldier.role = r
		soldier._apply_role_visuals()
		var mat := outline_mesh.material_override as ShaderMaterial
		assert(mat != null, "Outline ShaderMaterial missing")
		var c: Color = mat.get_shader_parameter("outline_color")
		assert(c.r > c.b and c.r > 0.7, "Team 1 role %d outline must be a shade of red, got %s" % [r, str(c)])
		assert(not red_colors.has(c), "Team 1 role outlines must be distinct shades of red")
		red_colors.append(c)

	soldier.role = 3 # Basic
	assert(soldier.stun_duration == 0.0 and soldier.knockback_force == 0.0 and soldier.stun_aoe_radius == 0.0, "Basic class must have no stun/AoE abilities")
	assert(soldier.heal_per_sec == 0.0 and soldier.stun_damage_multiplier == 1.0, "Basic class must have no heal or execution abilities")
	soldier.is_attacking = true
	animator._physics_process(0.016)
	assert(animator._current == "attack", "Basic soldier attacking must play attack clip, got %s" % animator._current)
	soldier.is_attacking = false
	print("   [OK] All 4 classes have distinct team-matched outlines and Basic class has no special abilities.")

	soldier.queue_free()
	print("\n[SUCCESS] All attack, block, cast, idle animations, outlines, and hidden placeholders verified!")
	quit(0)
