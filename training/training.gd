extends Node

func _ready():
	for l in find_children("Light"):
		l.visible = false

	# Godot caps how many physics steps one main-loop frame may run
	# (max_physics_steps_per_frame, default 8). The Sync node raises
	# physics_ticks_per_second to speed_up * 60 and time_scale to speed_up, so at
	# speed_up 30 a 60 Hz main loop needs 30 steps per frame and the default cap
	# silently cuts the sim to 8/30 of the requested rate. Per-tick physics is
	# unchanged, so the task is unchanged -- but without this, `speed_up` above 8
	# does not mean what it says.
	#
	# MEASURED: throughput did not move (single-env build: 52 fps before, 50
	# after). The per-tick cost, not the clamp, is the limit -- frames simply get
	# proportionally longer. Kept because it makes speed_up honest; do not expect
	# it to buy speed. See docs/commands.txt.
	Engine.max_physics_steps_per_frame = 64
