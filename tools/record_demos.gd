extends SceneTree

# Record demonstration data for both PvE and PvP
var mode: String = "all" # "pve", "pvp", or "all"
var target_samples: int = 35000
var decision_interval: int = 4
var speed_up: float = 8.0

var _current_stage: String = ""
var _arena: Node = null
var _samples_recorded: int = 0
var _tick_counter: int = 0

var _obs_buffer: PackedFloat32Array = PackedFloat32Array()
var _act_buffer: PackedByteArray = PackedByteArray()

func _init() -> void:
	# Parse command line arguments
	var all_cmd_args: Array = OS.get_cmdline_user_args()
	all_cmd_args.append_array(OS.get_cmdline_args())
	for arg in all_cmd_args:
		if arg.begins_with("--mode="):
			mode = arg.trim_prefix("--mode=")
		elif arg.begins_with("--samples="):
			target_samples = int(arg.trim_prefix("--samples="))
		elif arg.begins_with("--repeat="):
			decision_interval = int(arg.trim_prefix("--repeat="))
		elif arg.begins_with("--speedup="):
			speed_up = float(arg.trim_prefix("--speedup="))

	print("[Recorder] Initializing with mode=%s, samples=%d, repeat=%d, speedup=%.1f" % [
		mode, target_samples, decision_interval, speed_up
	])

	Engine.time_scale = speed_up
	Engine.physics_ticks_per_second = int(60 * speed_up)
	Engine.max_physics_steps_per_frame = 128

	var dir = DirAccess.open("res://")
	if not dir.dir_exists("demos"):
		dir.make_dir("demos")

	if mode == "all" or mode == "pve":
		_start_stage("pve")
	elif mode == "pvp":
		_start_stage("pvp")

var _last_printed_sample: int = 0

func _start_stage(stage: String) -> void:
	_current_stage = stage
	_samples_recorded = 0
	_tick_counter = 0
	_last_printed_sample = 0

	_obs_buffer.clear()
	_obs_buffer.resize(target_samples * 145)
	_act_buffer.clear()
	_act_buffer.resize(target_samples * 5)

	if _arena:
		_arena.queue_free()
		_arena = null

	var scene_path: String = ""
	if stage == "pve":
		scene_path = "res://scenes/3d/squad3.tscn"
	elif stage == "pvp":
		scene_path = "res://scenes/3d/squad_pvp.tscn"

	print("\n[Recorder] ========================================")
	print("[Recorder] Starting Stage: %s (%s)" % [stage.to_upper(), scene_path])
	print("[Recorder] ========================================")

	var packed = load(scene_path)
	if not packed:
		print("ERROR: Failed to load scene: %s" % scene_path)
		quit(1)
		return

	_arena = packed.instantiate()
	root.add_child(_arena)

func _process(delta: float) -> bool:
	if not _arena:
		return false

	_tick_counter += 1
	if _tick_counter % decision_interval != 0:
		return false

	# Collect samples from all active soldiers
	var soldiers: Array = []
	for s in _arena.find_children("*"):
		if s is Char3 and s.has_node("AI"):
			if not s.is_dead and not s.is_queued_for_deletion():
				soldiers.append(s)

	for s in soldiers:
		if _samples_recorded >= target_samples:
			break

		var ai_node = s.get_node("AI")
		var obs_dict: Dictionary = ai_node.get_obs()
		var obs: Array = obs_dict["obs"]
		if obs.size() != 145:
			continue

		var act: Dictionary = ai_node.get_bot_action()

		# Store in buffers
		var obs_offset := _samples_recorded * 145
		for j in 145:
			_obs_buffer[obs_offset + j] = float(obs[j])

		var act_offset := _samples_recorded * 5
		_act_buffer[act_offset + 0] = clampi(int(act.get("attack", 0)), 0, 1)
		_act_buffer[act_offset + 1] = clampi(int(act.get("block", 0)), 0, 1)
		_act_buffer[act_offset + 2] = clampi(int(act.get("move", 0)), 0, 8)
		_act_buffer[act_offset + 3] = clampi(int(act.get("sprint", 0)), 0, 1)
		_act_buffer[act_offset + 4] = clampi(int(act.get("turn", 1)), 0, 2)

		_samples_recorded += 1

	if _samples_recorded - _last_printed_sample >= 2500:
		_last_printed_sample = _samples_recorded
		var pct := float(_samples_recorded) / float(target_samples) * 100.0
		print("[Recorder] %s: %d / %d samples (%.1f%%)" % [_current_stage.to_upper(), _samples_recorded, target_samples, pct])

	if _samples_recorded >= target_samples:
		_save_current_stage()

		if mode == "all" and _current_stage == "pve":
			_start_stage("pvp")
		else:
			print("\n[Recorder] ALL RECORDING FINISHED SUCCESSFULLY!")
			quit(0)
			return true

	return false

func _save_current_stage() -> void:
	var out_path := "res://demos/%s_demos.bin" % _current_stage
	print("\n[Recorder] Saving %d samples to %s..." % [_samples_recorded, out_path])

	var file := FileAccess.open(out_path, FileAccess.WRITE)
	if not file:
		print("ERROR: Failed to open file for writing: %s" % out_path)
		quit(1)
		return

	# Header: count, obs_dim, act_dim
	file.store_32(_samples_recorded)
	file.store_32(145)
	file.store_32(5)

	# Data payloads
	file.store_buffer(_obs_buffer.to_byte_array())
	file.store_buffer(_act_buffer)
	file.close()

	print("[Recorder] Saved %s successfully! File size: %d bytes" % [
		out_path,
		12 + _samples_recorded * 145 * 4 + _samples_recorded * 5
	])
