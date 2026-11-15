extends Node2D



# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	$Agent/AI.target = $Target


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	#distance between agent and target
	var dist = ($Agent.position-$Target.position).length()
	#print(dist)
func reset():
	$Agent.position = Vector2(0.0,0.0)
	var r = 100.0
	$Target.position = Vector2(randf_range(-r,r),randf_range(-r,r))
	print("reset")
