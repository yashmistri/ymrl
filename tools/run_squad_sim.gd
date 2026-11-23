extends SceneTree

var _timer: float = 0.0
var _max_time: float = 25.0
var _arena: Node = null

func _init():
	var squad_scene = load("res://scenes/3d/squad3.tscn")
	if not squad_scene:
		print("ERROR: Failed to load squad3.tscn")
		quit(1)
		return
	_arena = squad_scene.instantiate()
	root.add_child(_arena)
	print("Squad arena loaded successfully!")

func _process(delta: float) -> bool:
	_timer += delta
	if int(_timer) != int(_timer - delta):
		# Print status every second
		var status := "[Sim %2.0fs] " % _timer
		for s in _arena.find_children("Soldier*"):
			if s is Char3:
				var role_str := "Tank" if s.role == 0 else ("Medic" if s.role == 1 else "Striker")
				var ai_node = s.find_child("AI")
				var stuns: int = ai_node._episode_stuns if ai_node else 0
				var heals: float = ai_node._episode_heals if ai_node else 0.0
				var execs: int = ai_node._episode_executions if ai_node else 0
				var kills: int = ai_node._episode_kills if ai_node else 0
				var blocks_hit: int = ai_node._episode_blocks_successful if ai_node else 0
				status += "%s(HP:%.0f, Stun:%d, Heal:%.1f, Exec:%d, Blk:%d, K:%d) " % [
					role_str, s.current_health, stuns, heals, execs, blocks_hit, kills
				]
		var zombies := _arena.find_children("Zombie*", "", true, false)
		var living_z := 0
		var stunned_z := 0
		for z in zombies:
			if not z.is_dead and not z.is_queued_for_deletion():
				living_z += 1
				if "is_stunned" in z and z.is_stunned:
					stunned_z += 1
		status += "| LivingZ: %d (Stunned: %d)" % [living_z, stunned_z]
		print(status)

	if _timer >= _max_time:
		print("Simulation finished successfully!")
		quit(0)
		return true
	return false
