extends Control

## Screen HUD for the soldier: health bar, health number, and stamina bar.

@export var soldier_path: NodePath = ^"../../Soldier"

@onready var health_bar: ProgressBar = $Panel/Rows/HealthRow/HealthBar
@onready var health_value: Label = $Panel/Rows/HealthRow/HealthValue
@onready var stamina_bar: ProgressBar = $Panel/Rows/StaminaRow/StaminaBar
@onready var stamina_value: Label = $Panel/Rows/StaminaRow/StaminaValue

var _soldier: Node
var _health_fill: StyleBoxFlat

func _ready() -> void:
	_ignore_mouse(self)
	_soldier = _resolve_soldier()
	var panel := $Panel as PanelContainer
	panel.add_theme_stylebox_override("panel", _panel_style())
	_health_fill = _bar_fill(Color(0.22, 0.78, 0.32))
	health_bar.add_theme_stylebox_override("fill", _health_fill)
	health_bar.add_theme_stylebox_override("background", _bar_track())
	stamina_bar.add_theme_stylebox_override("fill", _bar_fill(Color(0.93, 0.74, 0.18)))
	stamina_bar.add_theme_stylebox_override("background", _bar_track())
	_place_panel()
	_refresh()

func _place_panel() -> void:
	# Style margins are known only after the styleboxes above are assigned.
	var min_size := get_combined_minimum_size()
	anchor_left = 0.0
	anchor_top = 1.0
	anchor_right = 0.0
	anchor_bottom = 1.0
	offset_left = 20.0
	offset_bottom = -20.0
	offset_right = 20.0 + min_size.x
	offset_top = -20.0 - min_size.y

func _process(_delta: float) -> void:
	_refresh()

func _resolve_soldier() -> Node:
	var node := get_node_or_null(soldier_path)
	if node != null:
		return node
	var scene := get_tree().current_scene
	if scene == null:
		return null
	return scene.find_child("Soldier", true, false)

func _refresh() -> void:
	if _soldier == null or not is_instance_valid(_soldier):
		_soldier = _resolve_soldier()
		if _soldier == null:
			return
	var max_hp: float = maxf(_soldier.max_health, 0.001)
	var hp: float = clampf(_soldier.current_health, 0.0, max_hp)
	health_bar.max_value = max_hp
	health_bar.value = hp
	health_value.text = "%d / %d" % [roundi(hp), roundi(max_hp)]
	_health_fill.bg_color = _health_color(hp / max_hp)

	var max_stamina: float = maxf(_soldier.max_stamina, 0.001)
	var stamina: float = clampf(_soldier.current_stamina, 0.0, max_stamina)
	stamina_bar.max_value = max_stamina
	stamina_bar.value = stamina
	stamina_value.text = "%d / %d" % [roundi(stamina), roundi(max_stamina)]

func _health_color(ratio: float) -> Color:
	var high := Color(0.22, 0.78, 0.32)
	var mid := Color(0.92, 0.72, 0.12)
	var low := Color(0.86, 0.18, 0.16)
	if ratio >= 0.5:
		return mid.lerp(high, (ratio - 0.5) / 0.5)
	return low.lerp(mid, ratio / 0.5)

func _panel_style() -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.05, 0.06, 0.07, 0.78)
	box.set_corner_radius_all(6)
	box.content_margin_left = 12.0
	box.content_margin_right = 12.0
	box.content_margin_top = 10.0
	box.content_margin_bottom = 10.0
	box.set_border_width_all(1)
	box.border_color = Color(1, 1, 1, 0.16)
	return box

func _bar_fill(color: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.set_corner_radius_all(3)
	return box

func _bar_track() -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0, 0, 0, 0.55)
	box.set_corner_radius_all(3)
	return box

func _ignore_mouse(node: Node) -> void:
	if node is Control:
		var control := node as Control
		control.mouse_filter = Control.MOUSE_FILTER_IGNORE
		control.focus_mode = Control.FOCUS_NONE
	for child in node.get_children():
		_ignore_mouse(child)
