extends AIController3D

const HIT_REWARD_FACTOR: float = 1.0
# Per-hit damage penalty multiplier. percent_damage for one zombie hit is
# 5.0 / 200 max health = 0.025. At the original factor of 1.0 a hit cost 0.025
# against a kill worth +10 -- about 400 hits per kill, so damage was free.
#
# This was raised to 20.0, which over-corrected: with FIVE zombies attacking at
# once the damage term dominated the return (ep_rew_mean sat at ~-95) and the
# kill signal was lost -- success oscillated 0.28-0.62 over 100k steps instead
# of converging. 5.0 gives 0.125 per hit, ~80 hits per kill: still a real cost,
# but small enough that kills remain the dominant signal with multiple enemies.
const HURT_PENALTY_FACTOR: float = 5.0
# Block reward multiplier. Deliberately NOT shared with HURT_PENALTY_FACTOR:
# raising the hurt penalty to 20 also multiplied the per-block REWARD by 20,
# which would have paid +20 for absorbing a hit and recreated the block-farming
# exploit at twenty times the scale.
const BLOCK_REWARD_FACTOR: float = 1.0
const KILL_REWARD: float = 10.0
const DEATH_PENALTY: float = 10.0
# Costs charged on the first physics frame of the action.
const ATTACK_COST: float = 0.05
const BLOCK_COST: float = 0.05
# Charged EVERY step block is held, in addition to the one-off BLOCK_COST.
#
# Without this, blocking was nearly free: one 0.05 press against a per-hit
# reward of up to +1.0. A trained policy held block on 100% of steps and farmed
# damage_blocked while never attacking. A per-step charge makes uptime cost
# scale with duration, so blocking has to be selective.
const BLOCK_HOLD_COST_PER_STEP: float = 0.004
# Charged EVERY step, unconditionally. This is what makes delay cost something.
#
# Without it the reward prices damage (HURT_PENALTY_FACTOR) and killing
# (KILL_REWARD) but not elapsed time, so the cheapest way to raise return is to
# never get hit and kill whenever. That is exactly what the v10 -> v11 50k
# continuation learned: same kills per episode (2.92), damage taken 2.36 ->
# 0.77, but episode length 268 -> 315 and idle fraction 0.07 -> 0.21, for a
# higher return (32.28 -> 34.68). The soldier orbits and loiters instead of
# committing.
#
# 0.004/step is deliberate: it is the same magnitude as
# BLOCK_HOLD_COST_PER_STEP, which is already known to be strong enough to stop
# block-farming on this reward scale. Over a 315-step episode it costs ~1.3
# against KILL_REWARD 10.0 -- present, not dominant.
#
# MEASURED (50k fine-tunes from soldier_v11, n=50 each, 3 zombies):
#   without it  idle 0.21, attack_frac 0.57, length 315, damage 0.77
#   with it     idle 0.10, attack_frac 0.68, length 296, damage 0.48
# Same kill rate (100%) and slightly more kills/episode. It does what it says:
# it converts loitering into engagement without costing safety. The 5-zombie
# experiment ran with this OFF and idle fell to 0.02 on its own -- a harder
# scene removes the spare time that loitering feeds on. See docs/commands.txt.
const TIME_COST_PER_STEP: float = 0.004
# Floor is 50 by 50, centered on the origin. Half of that maps an edge to ±1.
const ARENA_SIZE_X: float = 50.0
const ARENA_SIZE_Z: float = 50.0
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
	char.connect("attack_blocked_by_stamina", _on_attack_blocked_by_stamina)

func _on_got_hit(percent_damage: float) -> void:
	var penalty := clampf(percent_damage, -1.0, 1.0) * HURT_PENALTY_FACTOR
	reward -= penalty
	_episode_damage_taken += penalty
	_episode_return -= penalty

func _on_died() -> void:
	reward -= DEATH_PENALTY
	_episode_return -= DEATH_PENALTY
	_episode_deaths += 1

func _on_hit_enemy(percent_damage: float) -> void:
	var gain := clampf(percent_damage, -1.0, 1.0) * HIT_REWARD_FACTOR
	reward += gain
	_episode_damage_dealt += gain
	_episode_return += gain
	_episode_attacks_hit += 1
	if _steps_to_first_hit < 0:
		_steps_to_first_hit = _step_total

func _on_killed_enemy() -> void:
	reward += KILL_REWARD
	_episode_kills += 1
	_episode_return += KILL_REWARD

func _on_blocked_attack(percent_blocked: float) -> void:
	var gain := clampf(percent_blocked, 0.0, 1.0) * BLOCK_REWARD_FACTOR
	reward += gain
	_episode_return += gain
	_episode_blocks_successful += 1
	_episode_damage_blocked += clampf(percent_blocked, 0.0, 1.0)

func _on_attack_started() -> void:
	reward -= ATTACK_COST
	_episode_return -= ATTACK_COST
	_episode_attacks_started += 1

func _on_block_started() -> void:
	reward -= BLOCK_COST
	_episode_return -= BLOCK_COST
	_episode_blocks_started += 1

func _on_attack_blocked_by_stamina() -> void:
	_episode_attacks_stamina_blocked += 1

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
	_episode_attacks_started = 0
	_episode_attacks_hit = 0
	_episode_attacks_stamina_blocked = 0
	_episode_blocks_started = 0
	_episode_blocks_successful = 0
	_episode_damage_blocked = 0.0
	_episode_deaths = 0
	_steps_to_first_hit = -1
	_step_idle = 0
	_step_at_full_stamina = 0
	_step_total = 0
	_step_sprint = 0
	_step_block = 0
	_step_attack = 0
	_step_attack_requested = false
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
#
# The rest are diagnostics: they do not affect reward or training. They exist
# so behaviour that the scalar reward hides (block-spam, never resting, bad
# aim) is visible in evaluate.py output. Add them to METRIC_KEYS there.
var _episode_kills: int = 0
var _episode_damage_dealt: float = 0.0
var _episode_damage_taken: float = 0.0
# Combat.
var _episode_attacks_started: int = 0
var _episode_attacks_hit: int = 0
# Attacks refused for lack of stamina. High counts mean the policy is spamming
# attacks it cannot afford; near-zero means it is pacing itself.
var _episode_attacks_stamina_blocked: int = 0
# Blocking. "started" counts engagements (one per press, see block_started);
# "successful" counts hits actually absorbed, so the ratio says whether
# blocking is effective or just noise.
var _episode_blocks_started: int = 0
var _episode_blocks_successful: int = 0
var _episode_damage_blocked: float = 0.0
# Survival.
var _episode_deaths: int = 0
# Per-step accumulators, sampled in get_obs() (one call per decision step).
var _step_idle: int = 0
var _step_at_full_stamina: int = 0
var _step_total: int = 0
var _step_sprint: int = 0
var _step_block: int = 0
var _step_attack: int = 0
# Set by set_action() so _sample_step_stats() can see an attack issued this
# step even after char.is_attacking has cleared.
var _step_attack_requested: bool = false
# First hit latency, in decision steps. -1 = never landed one this episode.
var _steps_to_first_hit: int = -1

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
		"attacks_started": _episode_attacks_started,
		"attacks_hit": _episode_attacks_hit,
		"attack_hit_rate": _ratio(_episode_attacks_hit, _episode_attacks_started),
		"attacks_stamina_blocked": _episode_attacks_stamina_blocked,
		"blocks_started": _episode_blocks_started,
		"blocks_successful": _episode_blocks_successful,
		# NOT a success rate: one block press can absorb several hits, so this
		# legitimately exceeds 1.0. It measures hits absorbed per engagement --
		# high means blocking does real work, low means it is held while
		# nothing lands (the block-spam signature).
		"blocks_per_engagement": _ratio(_episode_blocks_successful, _episode_blocks_started),
		"damage_blocked": _episode_damage_blocked,
		"deaths": _episode_deaths,
		"steps_to_first_hit": _steps_to_first_hit,
		"idle_fraction": _ratio(_step_idle, _step_total),
		"full_stamina_fraction": _ratio(_step_at_full_stamina, _step_total),
		# Action distribution: catches degenerate policies (e.g. blocking on
		# almost every step) that a healthy-looking reward curve would hide.
		"sprint_fraction": _ratio(_step_sprint, _step_total),
		"block_fraction": _ratio(_step_block, _step_total),
		"attack_fraction": _ratio(_step_attack, _step_total),
	}
	if done:
		# "l" must be DECISION steps, not physics frames. n_steps from
		# AIController3D increments every _physics_process tick (600/s at
		# speed_up 10), while a decision happens once per action_repeat frames
		# (75/s). Reporting n_steps made every episode length 8x too large in
		# both train_sb3.py's ep_len_mean and evaluate.py's length.
		# _step_total is incremented in get_obs(), i.e. once per decision.
		info["episode"] = {"r": _episode_return, "l": _step_total}
		info["is_success"] = _episode_kills > 0
	return info

# Safe ratio: 0.0 rather than a NaN/inf when the denominator is zero, since a
# NaN would poison the summary statistics in evaluate.py.
func _ratio(numerator: int, denominator: int) -> float:
	if denominator <= 0:
		return 0.0
	return float(numerator) / float(denominator)


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
	_sample_step_stats()

	# Facing, wrapped to -1..1. This is an OBSERVATION the trained policies
	# consume (float 5 of 103), so its meaning must not drift: it used to read
	# the yaw of $Mesh, which char3.gd kept pointed at `aim` via look_at(aim).
	# The body is now a skinned mesh turned by the skeleton, so $Mesh never
	# rotates and its yaw would be a constant -- that would silently feed every
	# checkpoint a dead input. Derive the same value from `aim` instead.
	var to_aim: Vector3 = char.aim - char.global_position
	to_aim.y = 0.0
	var yaw := 0.0
	if to_aim.length_squared() > 0.000001:
		# look_at makes -Z point at the target, and its yaw is atan2(-x, -z).
		# Verified against the old look_at(aim) behaviour for all 8 compass-ish
		# directions; the naive atan2(x, -z) has the wrong sign on every axis.
		yaw = wrapf(atan2(-to_aim.x, -to_aim.z), -PI, PI) / PI
	# Read the maxima from the soldier rather than hardcoding them, so tuning
	# health or stamina on the character cannot silently push observations
	# outside 0..1.
	result.append_array([
		char.current_health / maxf(char.max_health, 0.001),
		char.current_stamina / maxf(char.max_stamina, 0.001),
		char.global_position.x / (ARENA_SIZE_X * 0.5),
		char.global_position.z / (ARENA_SIZE_Z * 0.5),
		yaw,
		])
	return {"obs": result}

# Samples per-step behaviour once per decision step.
#
# get_obs() is called exactly once per action/observation cycle, which makes it
# the right hook: sampling in _physics_process would count physics ticks, not
# decisions, and would be off by action_repeat.
#
# "idle" means no movement and no attack was requested this step -- the
# behaviour we would expect if the agent had learned to rest for stamina.
func _sample_step_stats() -> void:
	_step_total += 1
	# Charge for the step itself. See TIME_COST_PER_STEP for why this exists.
	reward -= TIME_COST_PER_STEP
	_episode_return -= TIME_COST_PER_STEP
	if char.current_stamina >= char.max_stamina - 0.01:
		_step_at_full_stamina += 1
	var moving: bool = char.requested_move.length_squared() > 0.0001
	var attacking: bool = char.is_attacking or _step_attack_requested
	if not moving and not attacking:
		_step_idle += 1
	if char.requested_sprint:
		_step_sprint += 1
	if char.requested_block:
		_step_block += 1
		# Charge for holding block. This is what stops the "hold block forever"
		# exploit: the reward for absorbing a hit is up to +1.0, so a one-off
		# press cost let the policy farm damage_blocked at 100% uptime.
		reward -= BLOCK_HOLD_COST_PER_STEP
		_episode_return -= BLOCK_HOLD_COST_PER_STEP
	# The action head, not char.is_attacking: the latter only holds during the
	# startup window, so it would undercount.
	if _step_attack_requested:
		_step_attack += 1
	_step_attack_requested = false

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


# The Sync node reads this each step and zeroes it, so the reward accumulated
# by the signal handlers above is consumed exactly once.
func get_reward() -> float:
	return reward

func get_action_space() -> Dictionary:
	# 9-way movement replaces the separate forward/strafe heads. Those were
	# redundant: char3.gd normalizes the move vector, so forward+strafe moved at
	# the same speed as forward alone, leaving several distinct action tuples
	# that behaved identically. 9 x 3 x 2 x 2 x 2 = 216 combinations.
	#
	# KEYS ARE IN ALPHABETICAL ORDER ON PURPOSE -- DO NOT REORDER.
	# Godot's JSON.stringify emits dictionary keys alphabetically, so the
	# trainer builds its MultiDiscrete from an alphabetical order. But
	# sync.gd::_extract_action_dict slices the action array using this live
	# dictionary's keys() order, which is insertion order. If the two differ,
	# every action is sliced against the wrong head sizes -- silently, with no
	# error, because the total count still matches. Declaring the keys
	# alphabetically makes insertion order equal to wire order.
	return {
		"attack": {
			"size": 2,
			"action_type": "discrete"
		},
		"block": {
			"size": 2,
			"action_type": "discrete"
		},
		"move": {
			"size": 9,
			"action_type": "discrete"
		},
		"sprint": {
			"size": 2,
			"action_type": "discrete"
		},
		"turn": {
			"size": 3,
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
		# Read by _sample_step_stats() so an attack counts as "not idle" for
		# this step even if is_attacking has already cleared.
		_step_attack_requested = true
