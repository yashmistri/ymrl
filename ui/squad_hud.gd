extends CanvasLayer

var _tank: Node
var _medic: Node
var _striker: Node

@onready var container: HBoxContainer = $Margin/VBox/SquadList
@onready var elapsed_label: Label = $Margin/VBox/Header/ElapsedLabel
@onready var zombies_label: Label = $Margin/VBox/Header/EnemyCountLabel

var _time_elapsed: float = 0.0

func _ready() -> void:
	_tank = get_node_or_null("../Soldier_Tank")
	_medic = get_node_or_null("../Soldier_Medic")
	_striker = get_node_or_null("../Soldier_Striker")

func _process(delta: float) -> void:
	_time_elapsed += delta
	var minutes := int(_time_elapsed) / 60
	var seconds := fmod(_time_elapsed, 60.0)
	if elapsed_label:
		elapsed_label.text = "MISSION TIME: %02d:%04.1f" % [minutes, seconds]
	
	var arena = get_parent()
	if arena and zombies_label:
		var z_nodes := arena.find_children("Zombie*", "", true, false)
		var living := 0
		var stunned := 0
		for z in z_nodes:
			if "is_dead" in z and not z.is_dead and not z.is_queued_for_deletion():
				living += 1
				if "is_stunned" in z and z.is_stunned:
					stunned += 1
		zombies_label.text = "ZOMBIES: %d Active (%d Stunned)" % [living, stunned]

	_update_member_card("TankCard", _tank, Color(0.2, 0.55, 1.0))
	_update_member_card("MedicCard", _medic, Color(0.2, 0.9, 0.4))
	_update_member_card("StrikerCard", _striker, Color(1.0, 0.35, 0.15))

func _update_member_card(card_name: String, member: Node, color: Color) -> void:
	var card = container.get_node_or_null(card_name)
	if not card or not member or not is_instance_valid(member):
		return
	
	var hp_bar: ProgressBar = card.get_node_or_null("VBox/HPBar")
	var hp_lbl: Label = card.get_node_or_null("VBox/HPRow/HPValue")
	var sta_bar: ProgressBar = card.get_node_or_null("VBox/StaBar")
	var stats_lbl: Label = card.get_node_or_null("VBox/StatsValue")
	
	if "current_health" in member and "max_health" in member:
		var max_h: float = maxf(member.max_health, 1.0)
		var cur_h: float = clampf(member.current_health, 0.0, max_h)
		if hp_bar:
			hp_bar.max_value = max_h
			hp_bar.value = cur_h
		if hp_lbl:
			hp_lbl.text = "%.0f / %.0f" % [cur_h, max_h]
	
	if "current_stamina" in member and "max_stamina" in member and sta_bar:
		var max_s: float = maxf(member.max_stamina, 1.0)
		var cur_s: float = clampf(member.current_stamina, 0.0, max_s)
		sta_bar.max_value = max_s
		sta_bar.value = cur_s
		
	var ai = member.get_node_or_null("AI")
	if stats_lbl and ai:
		var role_val: int = member.role if "role" in member else 2
		if role_val == 0:
			var st: int = ai._episode_stuns if "_episode_stuns" in ai else 0
			var blk: int = ai._episode_blocks_successful if "_episode_blocks_successful" in ai else 0
			stats_lbl.text = "Stuns: %d | Blocks: %d" % [st, blk]
		elif role_val == 1:
			var he: float = ai._episode_heals if "_episode_heals" in ai else 0.0
			stats_lbl.text = "Healed: %.0f HP" % [he]
		else:
			var ex: int = ai._episode_executions if "_episode_executions" in ai else 0
			var k: int = ai._episode_kills if "_episode_kills" in ai else 0
			stats_lbl.text = "Execs: %d | Kills: %d" % [ex, k]
