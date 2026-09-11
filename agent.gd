extends CharacterBody2D


const SPEED = 300.0
var move:Vector2
var requested_move:Vector2
@onready var ai: AIController2D = $AI

func _ready():
	ai.init(self)

func _physics_process(delta: float) -> void:


	# Get the input direction and handle the movement/deceleration.
	# As good practice, you should replace UI actions with custom gameplay actions.
	#print(requested_move)
	if ai.control_mode ==AIController2D.ControlModes.HUMAN:
		move= Vector2( Input.get_axis("left", "right"),Input.get_axis("up", "down"))
	else:
		move = requested_move
	
	move = move.normalized()
	if move:
		velocity = move * SPEED
	else:
		velocity = Vector2.ZERO

	move_and_slide()
