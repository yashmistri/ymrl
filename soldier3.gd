extends Char3


var max_stamina:float = 100.0
var current_stamina:float

var requested_move:Vector2
var is_running:bool=false
var spawn_pos:Vector3
func _ready():
	spawn_pos = global_position
	attack_range = 1.0
	current_stamina = max_stamina
	speed_stat=5.0
	if ai:
		ai.init(self)
	$hit.visible = false
	super._ready()

func respawn():
	global_position = spawn_pos
	current_health = max_health
	current_stamina = max_stamina
	is_dead = false
	ai.done=false
	visible = true

func _unhandled_input(event: InputEvent) -> void:
	if ai.heuristic != "human":
		return
	if event.is_action_pressed("m1"):
		
		#var m_pos = get_local_mouse_position()
		var cursor = $"../Cursor"
		attack(cursor.position)
	if event.is_action_pressed("run"):
		is_running = true
	elif event.is_action_released("run"):
		is_running = false
	


func _physics_process(delta: float) -> void:
	if is_dead:
		return
	if ai.heuristic == "human":
		move= Vector3( Input.get_axis("left", "right"),0.0,Input.get_axis("up", "down"))
		
		aim = $"../Cursor".position
	else:
		move = Vector3(requested_move.x,0.0,requested_move.y)
	is_running = move.length() > 0.5
	var run := (2.0 if is_running else 1.0)
	var attack_slow := (0.5 if is_attacking else 1.0)
	current_speed = speed_stat * run * attack_slow
	super._physics_process(delta)

func die():
	ai.reward -= 10
	ai.done = true
	is_dead = true
	visible = false
	$"..".reset()
	print("die")
func swing():
	pass
