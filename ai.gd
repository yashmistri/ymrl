extends AIController2D

@onready var player:CharacterBody2D=$".."

func get_obs() -> Dictionary:
	# Return observations (e.g., player position, environment state)
	return {"obs": []}

func get_reward() -> float:
	# Define the reward (e.g., +1 for reaching a goal)
	var reward = player.velocity.length()
	return reward

func get_action_space() -> Dictionary:
	# Define action space (continuous or discrete)
	return {
		"move": {
			"size": 2,
			"action_type": "continuous"
		},
		"example_actions_discrete": {
			"size": 2,
			"action_type": "discrete"
		}
	}

func set_action(action) -> void:
	# Apply the action (e.g., move character based on action values)
	player.requested_move = Vector2(action["move"][0],action["move"][1])
	pass
