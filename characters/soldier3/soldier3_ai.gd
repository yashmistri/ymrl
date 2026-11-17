extends AIController3D

const HIT_REWARD_FACTOR: float = 1.0
const HURT_PENALTY_FACTOR: float = 1.0
const KILL_REWARD: float = 10.0
const DEATH_PENALTY: float = 10.0
# One-off cost for starting an attack or holding a block, charged on the
# first physics frame of the action only.
const ATTACK_COST: float = 0.05
const BLOCK_COST: float = 0.05
const MAX_HEALTH: float = 100.0
const MAX_STAMINA: float = 150.0
# Floor is 50 by 50, centered on the origin. Half of that maps an edge to ±1.
const ARENA_SIZE_X: float = 50.0
const ARENA_SIZE_Z: float = 50.0
# Episode length must match EpisodeTimer.wait_time in main3.tscn. The arena
# timer is what actually ends an episode; reset_after below is only a safety
# net for episodes that never terminate on their own.
const EPISODE_SECONDS: float = 30.0
const PHYSICS_TICKS_PER_SECOND: float = 60.0
# Potential-based shaping weight for closing on the nearest visible zombie.
#
# This MUST be applied as F = gamma * phi(s') - phi(s) with phi = -distance,
# not as a raw "reward per meter gained". Ng, Harada & Russell (ICML 1999)
# showed potential-based shaping is the only form that provably leaves the
# optimal policy unchanged. A raw per-meter reward pays for approaching but
# never charges for retreating, so the agent can farm it by oscillating in and
# out of sensor range -- the same bug that made a bicycle agent ride in
# circles. Keep this small: it only breaks the sparse-reward tie.
const APPROACH_SHAPING_WEIGHT: float = 0.02
# Must match the PPO gamma in tools/train_sb3.py. Potential-based shaping is
# only policy-invariant when this equals the learner's discount factor.
const SHAPING_GAMMA: float = 0.995
# Potential used when no zombie is visible. The potential must be defined for
# every state, otherwise losing sight of the zombie reintroduces the
# discontinuity that makes the reward farmable. Kept in sync with the entity
# sensor's max_range so "invisible" means "at the edge of perception".
const INVISIBLE_ZOMBIE_DISTANCE: float = 30.0

@onready var char:CharacterBody3D=$".."
@onready var wall_sensor: RayCastSensor3D = $"../WallSensor"
@onready var entity_sensor: EntitySensor3D = $"../EntitySensor"
var target:Node3D
# Distance to the nearest zombie seen last frame, in meters. -1 means "no
# zombie visible", which is distinct from "very far away".
var _prev_zombie_distance: float = -1.0
# Running reward total for the current episode, reported via get_info().
var _episode_return: float = 0.0

func _ready() -> void:
	super._ready()
	char.connect("got_hit", _on_got_hit)
	char.connect("died", _on_died)
	char.connect("hit_enemy", _on_hit_enemy)
	char.connect("killed_enemy", _on_killed_enemy)
	char.connect("blocked_attack", _on_blocked_attack)
	char.connect("attack_started", _on_attack_started)
	char.connect("block_started", _on_block_started)

func _on_got_hit(percent_damage: float) -> void:
	var penalty := clampf(percent_damage, -1.0, 1.0) * HURT_PENALTY_FACTOR
	reward -= penalty
	_episode_damage_taken += penalty
	_episode_return -= penalty

func _on_died() -> void:
	reward -= DEATH_PENALTY
	_episode_return -= DEATH_PENALTY

func _on_hit_enemy(percent_damage: float) -> void:
	var gain := clampf(percent_damage, -1.0, 1.0) * HIT_REWARD_FACTOR
	reward += gain
	_episode_damage_dealt += gain
	_episode_return += gain

func _on_killed_enemy() -> void:
	reward += KILL_REWARD
	_episode_kills += 1
	_episode_return += KILL_REWARD

func _on_blocked_attack(percent_blocked: float) -> void:
	var gain := clampf(percent_blocked, 0.0, 1.0) * HURT_PENALTY_FACTOR
	reward += gain
	_episode_return += gain

func _on_attack_started() -> void:
	reward -= ATTACK_COST
	_episode_return -= ATTACK_COST

func _on_block_started() -> void:
	reward -= BLOCK_COST
	_episode_return -= BLOCK_COST

# Called by the Sync node when an episode ends. Resetting the tracked distance
# to "invisible" means the first frame of the new episode starts from the same
# fallback potential a fresh episode would have, so the shaping telescopes
# cleanly across the episode boundary instead of paying out a jump.
#
# NOTE: the Sync node calls this AFTER get_info() has been read, so the
# episode counters reported to VecMonitor are intact. The arena must not call
# this directly at reset time or the episode would be reported as empty.
func reset() -> void:
	super.reset()
	_prev_zombie_distance = -1.0
	_episode_return = 0.0
	_episode_kills = 0
	_episode_damage_dealt = 0.0
	_episode_damage_taken = 0.0
	# Drop remembered entities so a new episode starts with empty slots rather
	# than stale positions from the previous one.
	if entity_sensor:
		entity_sensor.reset()

# The Sync node calls this once it has consumed the done flag. This is the
# correct point to clear per-episode state, since get_info() has already been
# read for the final step of the episode.
func set_done_false() -> void:
	super.set_done_false()
	reset()

# Per-episode counters, reported through get_info() so SB3's VecMonitor can
# log rollout/ep_rew_mean and rollout/ep_len_mean. Without an "episode" key
# in info, VecMonitor never sees an episode boundary and logs nothing.
var _episode_kills: int = 0
var _episode_damage_dealt: float = 0.0
var _episode_damage_taken: float = 0.0

# SB3 reads info["episode"] == {"r": return, "l": length} to close an episode.
# The Godot RL wrapper passes this dict straight through to VecMonitor, so
# supplying it here is what makes reward curves appear in TensorBoard.
#
# "r" is the episode's accumulated reward. AIController3D zeroes `reward`
# every step after reading it, so we track the running total separately.
func get_info() -> Dictionary:
	var info := {
		"kills": _episode_kills,
		"damage_dealt": _episode_damage_dealt,
		"damage_taken": _episode_damage_taken,
	}
	if done:
		info["episode"] = {"r": _episode_return, "l": n_steps}
		info["is_success"] = _episode_kills > 0
	return info


func get_obs() -> Dictionary:
	# Walls come from the raycast ring (geometry is what rays are good for).
	# Enemies come from the slot sensor: each tracked zombie contributes its
	# relative position, velocity, health and attack state directly, so the
	# network does not have to invert ray hits into an entity estimate.
	var wall_obs: Array = wall_sensor.get_observation()
	var entity_obs: Array = entity_sensor.get_observation()

	var result: Array = []
	result.append_array(wall_obs)
	result.append_array(entity_obs)

	_update_approach_reward(entity_obs)

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

# Potential-based shaping: F = gamma * phi(s') - phi(s), with phi = -distance.
#
# phi is defined for every state: when no zombie is visible the potential is
# -INVISIBLE_ZOMBIE_DISTANCE, so losing sight of the target is treated as
# "very far away" rather than as a discontinuity. That keeps the shaping
# telescoping over a whole episode -- the sum of F depends only on the start
# and end potentials -- which is what makes it impossible to farm by
# oscillating in and out of sensor range.
func _update_approach_reward(entity_obs: Array) -> void:
	var nearest := _nearest_zombie_distance(entity_obs)
	var distance := nearest if nearest >= 0.0 else INVISIBLE_ZOMBIE_DISTANCE
	var prev_distance := (
		_prev_zombie_distance if _prev_zombie_distance >= 0.0 else INVISIBLE_ZOMBIE_DISTANCE
	)
	var shaping := SHAPING_GAMMA * (-distance) - (-prev_distance)
	shaping *= APPROACH_SHAPING_WEIGHT
	reward += shaping
	_episode_return += shaping
	_prev_zombie_distance = nearest

# Reads the nearest visible enemy out of the slot sensor's flat output.
# Slot layout is [rel_x, rel_z, distance, bearing, vel_x, vel_z, health,
# is_attacking, is_visible]; slot 2 is distance normalized by max_range and
# slot 8 flags whether the entity was actually in range this frame.
func _nearest_zombie_distance(entity_obs: Array) -> float:
	var nearest := -1.0
	var slot_size := EntitySensor3D.SLOT_SIZE
	for i in range(0, entity_obs.size() - slot_size + 1, slot_size):
		if entity_obs[i + 8] <= 0.0:
			continue
		var meters: float = entity_obs[i + 2] * entity_sensor.max_range
		if nearest < 0.0 or meters < nearest:
			nearest = meters
	return nearest


func get_reward() -> float:
	# Define the reward (e.g., +1 for reaching a goal)
	
	return reward

func get_action_space() -> Dictionary:
	# 9-way movement replaces the separate forward/strafe heads. Those were
	# redundant: char3.gd normalizes the move vector, so forward+strafe moved at
	# the same speed as forward alone, leaving several distinct action tuples
	# that behaved identically. 9 x 2 x 2 x 2 = 72 combinations instead of 216.
	return {
		"move": {
			"size": 9,
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

# Movement index -> (forward, strafe), each in -1..1. Index 4 is idle.
const MOVE_DIRECTIONS: Array[Vector2] = [
	Vector2(0, 0),    # 0 idle
	Vector2(1, 0),    # 1 forward
	Vector2(1, -1),   # 2 forward-right
	Vector2(0, -1),   # 3 right
	Vector2(-1, -1),  # 4 back-right
	Vector2(-1, 0),   # 5 back
	Vector2(-1, 1),   # 6 back-left
	Vector2(0, 1),    # 7 left
	Vector2(1, 1),    # 8 forward-left
]

func set_action(action:Dictionary) -> void:
	if done:
		return
	var dir_index: int = clampi(int(action["move"]), 0, MOVE_DIRECTIONS.size() - 1)
	var dir: Vector2 = MOVE_DIRECTIONS[dir_index]
	# char.requested_move is (forward, strafe); soldier3.gd maps it to world.
	char.requested_move = dir
	# discrete goes from 0 to 2 therefore subtract 1
	char.requested_turn = action["turn"] - 1.0
	char.requested_sprint = action["sprint"] == 1
	char.requested_block = action["block"] == 1
	if action["attack"] == 1:
		char.attack()
	
	pass
