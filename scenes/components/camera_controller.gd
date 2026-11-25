extends Camera3D
class_name BattleCameraController

## Free-roam battle camera controller.
## Controls:
##   I / K: Move Forward / Backward (along ground projection)
##   J / L: Move Left / Right
##   U / O: Zoom In / Zoom Out
##   Shift: Boost movement & zoom speed (2x)
##   H: Reset camera to initial position & zoom
##   Mouse Wheel: Zoom in / out

@export var move_speed: float = 28.0
@export var zoom_speed: float = 24.0
@export var sprint_multiplier: float = 2.0
@export var min_height: float = 4.0
@export var max_height: float = 120.0
@export var min_ortho_size: float = 10.0
@export var max_ortho_size: float = 250.0

var _initial_transform: Transform3D
var _initial_size: float
var _initial_fov: float

func _ready() -> void:
	_initial_transform = global_transform
	_initial_size = size
	_initial_fov = fov

func _process(delta: float) -> void:
	var speed_mult := sprint_multiplier if Input.is_key_pressed(KEY_SHIFT) else 1.0
	var cur_move_speed := move_speed * speed_mult
	var cur_zoom_speed := zoom_speed * speed_mult

	# 1. Calculate ground-plane movement vectors (XZ plane)
	var forward: Vector3 = -global_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() > 0.001:
		forward = forward.normalized()
	else:
		forward = Vector3(0, 0, -1)

	var right: Vector3 = global_transform.basis.x
	right.y = 0.0
	if right.length_squared() > 0.001:
		right = right.normalized()
	else:
		right = Vector3(1, 0, 0)

	var move_vec := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_I) or Input.is_key_pressed(KEY_I):
		move_vec += forward
	if Input.is_physical_key_pressed(KEY_K) or Input.is_key_pressed(KEY_K):
		move_vec -= forward
	if Input.is_physical_key_pressed(KEY_J) or Input.is_key_pressed(KEY_J):
		move_vec -= right
	if Input.is_physical_key_pressed(KEY_L) or Input.is_key_pressed(KEY_L):
		move_vec += right

	if move_vec.length_squared() > 0.001:
		global_position += move_vec.normalized() * cur_move_speed * delta

	# 2. Zoom Controls: U = Zoom In, O = Zoom Out
	var zoom_input := 0.0
	if Input.is_physical_key_pressed(KEY_U) or Input.is_key_pressed(KEY_U):
		zoom_input += 1.0
	if Input.is_physical_key_pressed(KEY_O) or Input.is_key_pressed(KEY_O):
		zoom_input -= 1.0

	if zoom_input != 0.0:
		_apply_zoom(zoom_input * cur_zoom_speed * delta)

	# 3. Quick Reset on H key
	if Input.is_physical_key_pressed(KEY_H) or Input.is_key_pressed(KEY_H):
		reset_camera()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.is_pressed():
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_apply_zoom(zoom_speed * 0.15)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_apply_zoom(-zoom_speed * 0.15)

func _apply_zoom(amount: float) -> void:
	if projection == PROJECTION_ORTHOGONAL:
		size = clampf(size - amount * 2.0, min_ortho_size, max_ortho_size)
	else:
		var dolly_dir := -global_transform.basis.z.normalized()
		var new_pos := global_position + dolly_dir * amount
		if new_pos.y >= min_height and new_pos.y <= max_height:
			global_position = new_pos
		else:
			new_pos.y = clampf(new_pos.y, min_height, max_height)
			global_position = new_pos

func reset_camera() -> void:
	global_transform = _initial_transform
	size = _initial_size
	fov = _initial_fov
