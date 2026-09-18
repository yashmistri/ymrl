extends Node2D


@export var wave_size:int = 1
@onready var enemy:PackedScene = preload("res://creature.tscn")

func _ready():
	for c in find_children("Creature*"):
		c.target = $Soldier

func spawn():
	var e = enemy.instantiate()
	var size = 300.0
	e.position.x = randf()

func reset():
	$Agent.position = Vector2(0.0,0.0)
	var r = 100.0
	$Target.position = Vector2(randf_range(-r,r),randf_range(-r,r))
	print("reset")
