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
	var aim_offset :Vector3= char.aim - char.global_position
	var aim2:Vector2=Vector2(aim_offset.x,aim_offset.z).normalized()
	result.append_array([
		aim2.x,
		aim2.y
		])
	return {"obs": result}
	

func get_reward() -> float:
	# Define the reward (e.g., +1 for reaching a goal)
	
	return reward

func get_action_space() -> Dictionary:
	# Define action space (continuous or discrete)
	return {
		"move_forward": {
			"size": 3,
			"action_type": "discrete"
		},
		"move_strafe": {
			"size": 3,
			"action_type": "discrete"
		},
		"turn": {
			"size": 3,
			"action_type": "discrete"
		},
		"attack": {
			"size": 2,
			"action_type": "discrete"
		},
		"sprint": {
			"size": 2,
			"action_type": "discrete"
		}
	}

func set_action(action:Dictionary) -> void:
	if done:
		return
	# discrete goes from 0 to 2 therefore subtract 1
	char.requested_move = Vector2(action["move_forward"]-1.0,action["move_strafe"]-1.0)
	char.requested_turn = action["turn"]
	char.requested_sprint = action["sprint"]
	if action["attack"] == 1:
		char.attack(char.aim)
	
	pass
