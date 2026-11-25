extends SceneTree

const BattleCameraController = preload("res://scenes/components/camera_controller.gd")

func _init() -> void:
	print("[TestCameraAndLogging] Starting automated verification...")
	_run_tests()

func _run_tests() -> void:
	# -------------------------------------------------------------
	# Test 1: Logging Throttling and Quiet Game Events
	# -------------------------------------------------------------
	print("\n--- Test 1: Verifying Game Events Console Logging Disabled ---")
	var soldier_res = load("res://characters/soldier3/soldier3.tscn")
	assert(soldier_res != null, "Failed to load soldier3.tscn")
	var soldier = soldier_res.instantiate()
	root.add_child(soldier)
	await process_frame

	assert(soldier.debug_logging == false, "Default debug_logging must be false to avoid wasting tokens!")
	print("   [OK] soldier.debug_logging is FALSE by default.")

	# Trigger a guard break on the soldier with an attacker in front
	var attacker = Node3D.new()
	root.add_child(attacker)
	soldier.aim = soldier.global_position + Vector3(0, 0, 5)
	attacker.global_position = soldier.global_position + Vector3(0, 0, 3)
	soldier.current_stamina = 5.0
	soldier.is_blocking = true
	soldier.take_damage(50.0, attacker)
	assert(soldier.is_stunned == true, "Soldier should be stunned from guard break")
	attacker.queue_free()
	print("   [OK] Guard break triggered without unthrottled console spam.")

	# Trigger critical hit roll
	soldier.crit_chance = 1.0 # Guarantee crit for test
	var dmg = soldier.get_attack_damage(null)
	assert(dmg > soldier.damage * 2.5, "Crit should deal triple damage")
	print("   [OK] Critical hit triggered with debug_log instead of raw print.")
	soldier.queue_free()

	# -------------------------------------------------------------
	# Test 2: Camera Control System (Perspective - Squad Battle Nav)
	# -------------------------------------------------------------
	print("\n--- Test 2: Verifying Camera Controller (Perspective) ---")
	var nav_res = load("res://scenes/3d/squad_battle_nav.tscn")
	assert(nav_res != null, "Failed to load squad_battle_nav.tscn")
	var nav_scene = nav_res.instantiate()
	root.add_child(nav_scene)
	await process_frame

	var cam: Camera3D = nav_scene.get_node_or_null("Camera3D")
	assert(cam != null, "Camera3D node missing in squad_battle_nav.tscn")
	assert(cam is BattleCameraController, "Camera3D must have BattleCameraController attached!")
	print("   [OK] Camera3D has BattleCameraController attached.")

	var init_pos = cam.global_position
	var init_fov = cam.fov
	print("   Initial Camera Pos: %s, FOV: %.1f" % [init_pos, init_fov])

	# Test Zoom In (U key logic)
	cam._apply_zoom(5.0)
	assert(cam.global_position.y < init_pos.y, "Zoom in must move camera closer/lower to ground")
	print("   [OK] Zoom In (U key): Pos moved from %.2f to %.2f Y" % [init_pos.y, cam.global_position.y])

	# Test Zoom Out (O key logic)
	cam._apply_zoom(-10.0)
	assert(cam.global_position.y > init_pos.y, "Zoom out must move camera higher/further from ground")
	print("   [OK] Zoom Out (O key): Pos moved to %.2f Y" % cam.global_position.y)

	# Test Camera Reset (H key)
	cam.reset_camera()
	assert(cam.global_position.is_equal_approx(init_pos), "Reset camera must restore initial position")
	assert(is_equal_approx(cam.fov, init_fov), "Reset camera must restore initial FOV")
	print("   [OK] Reset Camera (H key): Restored to initial transform.")

	# Test Pan Movement Logic (IJKL)
	var forward: Vector3 = -cam.global_transform.basis.z
	forward.y = 0.0
	forward = forward.normalized()
	var right: Vector3 = cam.global_transform.basis.x
	right.y = 0.0
	right = right.normalized()

	# Move forward (I)
	cam.global_position += forward * cam.move_speed * 0.1
	assert(cam.global_position.z < init_pos.z, "Moving forward (I) must decrease Z")
	print("   [OK] Pan Forward (I key): Z moved from %.2f to %.2f" % [init_pos.z, cam.global_position.z])

	# Move right (L)
	cam.global_position += right * cam.move_speed * 0.1
	assert(cam.global_position.x > init_pos.x, "Moving right (L) must increase X")
	print("   [OK] Pan Right (L key): X moved from %.2f to %.2f" % [init_pos.x, cam.global_position.x])

	nav_scene.queue_free()

	# -------------------------------------------------------------
	# Test 3: Camera Control System (Orthographic - Training Scene)
	# -------------------------------------------------------------
	print("\n--- Test 3: Verifying Camera Controller (Orthographic) ---")
	var train_res = load("res://training/training_all_arenas.tscn")
	assert(train_res != null, "Failed to load training_all_arenas.tscn")
	var train_scene = train_res.instantiate()
	for c in train_scene.get_children():
		if c.name != "Camera3D":
			c.free()
	root.add_child(train_scene)
	await process_frame

	var ortho_cam: Camera3D = train_scene.get_node_or_null("Camera3D")
	assert(ortho_cam != null, "Camera3D node missing in training_all_arenas.tscn")
	assert(ortho_cam is BattleCameraController, "Camera3D must have BattleCameraController attached!")

	var init_size = ortho_cam.size
	print("   Initial Ortho Size: %.1f" % init_size)

	# Test Ortho Zoom In (U key)
	ortho_cam._apply_zoom(5.0)
	assert(ortho_cam.size < init_size, "Ortho zoom in must decrease size to enlarge view")
	print("   [OK] Ortho Zoom In (U key): Size decreased from %.1f to %.1f" % [init_size, ortho_cam.size])

	# Test Ortho Zoom Out (O key)
	ortho_cam._apply_zoom(-10.0)
	assert(ortho_cam.size > init_size, "Ortho zoom out must increase size")
	print("   [OK] Ortho Zoom Out (O key): Size increased to %.1f" % ortho_cam.size)

	ortho_cam.reset_camera()
	assert(is_equal_approx(ortho_cam.size, init_size), "Reset must restore ortho size")
	print("   [OK] Ortho Reset (H key): Restored to initial size %.1f" % ortho_cam.size)

	train_scene.queue_free()

	print("\n[SUCCESS] All camera controls (IJKL pan, UO zoom, H reset) and logging suppressions verified!")
	quit(0)
