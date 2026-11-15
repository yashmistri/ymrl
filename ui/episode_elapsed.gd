extends Label

@onready var episode_timer: Timer = $"../../EpisodeTimer"

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _process(_delta: float) -> void:
	text = _format_elapsed(_seconds_since_start())

func _seconds_since_start() -> float:
	#if episode_timer.is_stopped():
		#return episode_timer.wait_time
	return episode_timer.wait_time - episode_timer.time_left

func _format_elapsed(seconds: float) -> String:
	var total_tenths := int(round(maxf(seconds, 0.0) * 10.0))
	var tenths := total_tenths % 10
	var whole := total_tenths / 10
	var minutes := whole / 60
	var secs := whole % 60
	return "%d:%02d.%d" % [minutes, secs, tenths]
