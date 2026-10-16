extends Control
## Dev launcher: pick a tool. (The real title screen comes later.)

const TOOLS := [
	["Play: Missile Command", "res://scenes/game/missile_command.tscn"],
	["Word match  (live view of what the mic hears and how it matches)", "res://scenes/match_viz.tscn"],
	["Speech test  (read words, see zaps + latency)", "res://scenes/stt_test.tscn"],
	["Record voices  (calibration takes for the benchmark)", "res://scenes/recorder.tscn"],
]


func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.106, 0.122, 0.294)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.add_theme_constant_override("separation", 24)
	add_child(box)
	var title := Label.new()
	title.text = "Hero Reader - dev tools"
	title.add_theme_font_size_override("font_size", 40)
	box.add_child(title)
	for t in TOOLS:
		var b := Button.new()
		b.text = t[0]
		b.custom_minimum_size = Vector2(640, 72)
		b.add_theme_font_size_override("font_size", 24)
		b.pressed.connect(func(): get_tree().change_scene_to_file(t[1]))
		box.add_child(b)
	box.position = (get_viewport_rect().size - box.get_combined_minimum_size()) / 2
