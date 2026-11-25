extends Node

## Global fullscreen toggle (F11 or Alt+Enter) without changing default window dimensions.
## Preserves the previous window mode and rect when exiting fullscreen.

var _prev_mode: Window.Mode = Window.MODE_WINDOWED
var _prev_size: Vector2i = Vector2i(1280, 720)
var _prev_pos: Vector2i = Vector2i.ZERO
var _has_prev_rect: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var win := get_window()
	if win:
		_prev_mode = win.mode
		if _prev_mode == Window.MODE_WINDOWED:
			_prev_size = win.size
			_prev_pos = win.position
			_has_prev_rect = true


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var key_ev := event as InputEventKey
		var is_f11 := (key_ev.keycode == KEY_F11 or key_ev.physical_keycode == KEY_F11)
		var is_alt_enter := (key_ev.alt_pressed and (
			key_ev.keycode == KEY_ENTER
			or key_ev.keycode == KEY_KP_ENTER
			or key_ev.physical_keycode == KEY_ENTER
			or key_ev.physical_keycode == KEY_KP_ENTER
		))
		if is_f11 or is_alt_enter:
			toggle_fullscreen()
			get_viewport().set_input_as_handled()


func toggle_fullscreen() -> void:
	var win := get_window()
	if win == null:
		return
	if is_fullscreen():
		var restore_mode := _prev_mode
		if (
			restore_mode == Window.MODE_FULLSCREEN
			or restore_mode == Window.MODE_EXCLUSIVE_FULLSCREEN
			or restore_mode == Window.MODE_MINIMIZED
		):
			restore_mode = Window.MODE_WINDOWED
		win.mode = restore_mode
		if restore_mode == Window.MODE_WINDOWED and _has_prev_rect:
			win.size = _prev_size
			win.position = _prev_pos
	else:
		_prev_mode = win.mode
		if win.mode == Window.MODE_WINDOWED:
			_prev_size = win.size
			_prev_pos = win.position
			_has_prev_rect = true
		win.mode = Window.MODE_FULLSCREEN


func is_fullscreen() -> bool:
	var win := get_window()
	if win == null:
		return false
	return win.mode == Window.MODE_FULLSCREEN or win.mode == Window.MODE_EXCLUSIVE_FULLSCREEN
