extends SceneTree
## Pre-training env check: 7 zombies spawn, damage is 12.5, obs shape is still
## 103 (10 slots >= 7), and the animator does not error under training load.
## Bounded so it cannot hang.

func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var root: Node = load("res://training/Training3Solo.tscn").instantiate()
	get_root().add_child(root)
	await physics_frame

	var main: Node = root.get_node("Main3")
	print("zombies_per_episode (scene) = ", main.get("zombies_per_episode"))

	# Let the spawn timer produce the full wave.
	for i in 600:
		await physics_frame
		if get_nodes_in_group("enemy").size() >= 7:
			break
	var enemies := get_nodes_in_group("enemy")
	print("zombies alive = ", enemies.size())
	if enemies.size() > 0:
		var z: Node = enemies[0]
		print("zombie damage = ", z.get("damage"), "  max_health = ", z.get("max_health"))
		print("zombie has Animator = ", z.get_node_or_null("Animator") != null)

	var ai: Node = root.find_child("AI", true, false)
	if ai:
		var obs: Dictionary = ai.call("get_obs")
		print("obs size = ", obs["obs"].size())
		var act: Dictionary = ai.call("get_action_space")
		var keys := []
		for k in act:
			keys.append("%s:%s" % [k, act[k]["size"]])
		print("action space = ", keys)

	# Run a few hundred frames of simulated play and watch for errors.
	for i in 300:
		await physics_frame
	print("survived 300 frames; zombies still = ", get_nodes_in_group("enemy").size())
	quit(0)
