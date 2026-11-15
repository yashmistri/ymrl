extends Char

var target:Node2D

func _ready():
	damage=0.5
	speed_stat = 90
	super._ready()

#todo keep attacking while touching soldier
func _physics_process(delta: float) -> void:
	move = Vector2.ZERO
	if target:
		if position.distance_to(target.position) < attack_range:
			attack(target.position-position)
		move = position.direction_to(target.position)
	
	super._physics_process(delta)
