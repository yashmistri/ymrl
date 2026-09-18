extends Char


var max_stamina:float = 100.0
var current_stamina:float

var requested_move:Vector2
var is_sprinting:bool=false

func _ready():
	attack_range = 25.0
	if ai:
		ai.init(self)
		
	super._ready()

func _unhandled_input(event: InputEvent) -> void:
	if ai.heuristic != "human":
		return
	if event.is_action_pressed("m1"):
		
		var m_pos = get_local_mouse_position()
		var is_kill = attack(m_pos)

func _physics_process(delta: float) -> void:

	if ai.heuristic == "human":
		move= Vector2( Input.get_axis("left", "right"),Input.get_axis("up", "down"))
	else:
		move = requested_move
	
	super._physics_process(delta)

func die():
	ai.reward -= 100
func swing():
	pass
