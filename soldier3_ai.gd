extends AIController3D

const HIT_REWARD_FACTOR: float = 1.0
const HURT_PENALTY_FACTOR: float = 1.0
const KILL_REWARD: float = 10.0
const DEATH_PENALTY: float = 10.0
const MAX_HEALTH: float = 100.0
const MAX_STAMINA: float = 100.0
# Floor is 50 by 50, centered on the origin. Half of that maps an edge to ±1.
const ARENA_SIZE_X: float = 50.0
const ARENA_SIZE_Z: float = 50.0

@onready var char:CharacterBody3D=$".."
var target:Node3D

func _ready() -> void:
	super._ready()
	char.connect("got_hit", _on_got_hit)
	char.connect("died", _on_died)
	char.connect("hit_enemy", _on_hit_enemy)
	char.connect("killed_enemy", _on_killed_enemy)
	char.connect("blocked_attack", _on_blocked_attack)

func _on_got_hit(percent_damage: float) -> void:
	reward -= clampf(percent_damage, -1.0, 1.0) * HURT_PENALTY_FACTOR

func _on_died() -> void:
	reward -= DEATH_PENALTY

func _on_hit_enemy(percent_damage: float) -> void:
	reward += clampf(percent_damage, -1.0, 1.0) * HIT_REWARD_FACTOR

func _on_killed_enemy() -> void:
	reward += KILL_REWARD

func _on_blocked_attack(percent_blocked: float) -> void:
	reward += clampf(percent_blocked, 0.0, 1.0) * HURT_PENALTY_FACTOR

var target_rel 
func get_obs() -> Dictionary:
	# Return observations (e.g., player position, environment state)
	var result :Array = []
	var wallray_obs = $"../WallSensor".get_observation()
	result.append_array(wallray_obs)
	
	var charray_obs = $"../CharSensor".get_observation()
	result.append_array(charray_obs)
	#var aim_offset :Vector3= char.aim - char.global_position
	#var aim2:Vector2=Vector2(aim_offset.x,aim_offset.z).normalized()
	# The body stays unrotated. Facing is the mesh yaw, wrapped to -1..1.
	var facing: MeshInstance3D = $"../Mesh"
	var yaw: float = wrapf(facing.global_rotation.y, -PI, PI) / PI
	result.append_array([
		char.current_health / MAX_HEALTH,
		char.current_stamina / MAX_STAMINA,
		char.global_position.x / (ARENA_SIZE_X * 0.5),
		char.global_position.z / (ARENA_SIZE_Z * 0.5),
		yaw,
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
		},
		"block": {
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
	char.requested_block = action["block"] == 1
	if action["attack"] == 1:
		char.attack()
	
	pass
