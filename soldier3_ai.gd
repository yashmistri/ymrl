extends AIController3D

@onready var char:CharacterBody3D=$".."
var target:Node3D

var target_rel 
func get_obs() -> Dictionary:
	# Return observations (e.g., player position, environment state)
	var result :Array = []
	var wallray_obs = $"../WallSensor".get_observation()
	result.append_array(wallray_obs)
	
	var charray_obs = $"../CharSensor".get_observation()
	result.append_array(charray_obs)
	
	return {"obs": result}
	

func get_reward() -> float:
	# Define the reward (e.g., +1 for reaching a goal)
	
	return reward

func get_action_space() -> Dictionary:
	# Define action space (continuous or discrete)
	return {
		"move": {
			"size": 2,
			"action_type": "continuous"
		},
		"aim": {
			"size": 2,
			"action_type": "continuous"
		},
		"attack": {
			"size": 2,
			"action_type": "discrete"
		}
	}

func set_action(action:Dictionary) -> void:
	if done:
		return
	# Apply the action (e.g., move character based on action values)
	char.aim = Vector3(action["aim"][0],0.0,action["aim"][1])
	var reach:=5.0
	char.aim *= reach
	char.requested_move = Vector2(action["move"][0],action["move"][1])
	if action["attack"] == 1:
		char.attack(char.aim)
	pass
