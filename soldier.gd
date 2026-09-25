extends Char


var max_stamina:float = 100.0
var current_stamina:float

var requested_move:Vector2
var is_running:bool=false

func _ready():
	attack_range = 25.0
	current_stamina = max_stamina
	if ai:
		ai.init(self)
		
	super._ready()

func _unhandled_input(event: InputEvent) -> void:
	if ai.heuristic != "human":
		return
	if event.is_action_pressed("m1"):
		
		var m_pos = get_local_mouse_position()
		attack(m_pos)
	if event.is_action_pressed("run"):
		is_running = true
	elif event.is_action_released("run"):
		is_running = false
	

func _physics_process(delta: float) -> void:

	if ai.heuristic == "human":
		move= Vector2( Input.get_axis("left", "right"),Input.get_axis("up", "down"))
	else:
		move = requested_move
	var run := (1.5 if is_running else 1.0)
	var attack_slow := (0.5 if is_attacking else 1.0)
	current_speed = speed_stat * run * attack_slow
	super._physics_process(delta)

func die():
	ai.reward -= 100
func swing():
	pass
