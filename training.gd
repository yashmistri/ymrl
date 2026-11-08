extends Node

func _ready():
	for l in find_children("Light"):
		l.visible = false
