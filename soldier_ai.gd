extends AIController2D

const KILL_REWARD: float = 1.0
const DEATH_PENALTY: float = 100.0

@onready var player:CharacterBody2D=$".."
var target:Node2D

func _ready() -> void:
	super._ready()
	player.connect("killed_enemy", _on_killed_enemy)
	player.connect("died", _on_died)

func _on_killed_enemy() -> void:
	reward += KILL_REWARD

func _on_died() -> void:
	reward -= DEATH_PENALTY

var target_rel 
func get_obs() -> Dictionary:
	# Return observations (e.g., player position, environment state)
	
	return {"obs": [
		]}
	

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
	# Apply the action (e.g., move character based on action values)
	var aim:Vector2 = Vector2(action["aim"][0],action["aim"][1])
	var reach:=30.0
	aim *= reach
	player.requested_move = Vector2(action["move"][0],action["move"][1])
	if action["attack"] == 1.0:
		player.attack(aim)
	pass
