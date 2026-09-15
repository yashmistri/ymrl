extends AIController2D

@onready var player:CharacterBody2D=$".."
var target:Node2D

var target_rel 
func get_obs() -> Dictionary:
	# Return observations (e.g., player position, environment state)
	if target:
		target_rel = target.global_position-global_position
		player.get_child(3).set_point_position(1,target_rel)
		return {"obs": [target_rel.x,target_rel.y]}
	
	return {"obs":[]}

func get_reward() -> float:
	# Define the reward (e.g., +1 for reaching a goal)
	
	var reward =0.0
	if target_rel:
		if target_rel.length()<10.0:
			reward += 10
			$"../..".reset()
		reward += target_rel.dot(player.velocity)
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
