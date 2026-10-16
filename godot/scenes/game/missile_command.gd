extends Control
## Meteor Shield (Missile Command), first playable. Words fall toward the moon
## base; read one aloud and Nora's cannon zaps it (docs/game-design.md).
##
## House rule (2026-10-16, overrides the design doc): a wrong word, a cough, a
## duplicate recognition, or a word that is no longer on screen changes nothing.
## A word only leaves when it is read. A word that reaches the bottom costs one
## shield pip (once) and then hovers above its dome, still readable, until read.
##
## Dev aids: type a word + Enter to zap it without the mic. Command line
## `-- --autostart` skips the start screen, `--no-mic` plays without the
## recognizer, `--shot <png>` saves a screenshot after 8 s (`--shot-after <s>`). Recognizer events
## are printed to stdout.

const LevelCurve := preload("res://scenes/game/level_curve.gd")
const Spawner := preload("res://scenes/game/word_spawner.gd")
const FallingWord := preload("res://scenes/game/falling_word.gd")
const Fx := preload("res://scenes/game/fx.gd")

const LEVEL_INDEX := "res://data/wordlists/levels/index.json"
const LEVEL_DIR := "res://data/wordlists/levels/"

# Colours from godot/art/STYLE.md.
const NAVY := Color("1B1F4B")
const OUTLINE := Color("141836")
const BLUE := Color("2B3A8C")
const PLUM := Color("9B5D8C")
const TEAL := Color("2EC4B6")
const GOLD := Color("FFC93C")
const ORANGE := Color("FF7A45")
const CREAM := Color("FFF4DC")
const GROUND := Color("252A63")

# Playfield, in the 1280x720 design size.
const HUD_H := 60.0
const SPAWN_Y := 118.0
const HOVER_Y := 500.0
const GROUND_Y := 668.0
const SLOTS := [200.0, 420.0, 640.0, 860.0, 1080.0]  # lanes at the top, landing spots below
const CANNON := Vector2(640, 600)  # barrel pivot; slot 2 is the cannon, the rest are domes
const BARREL := 58.0
const SHIELD_MAX := 5
const STREAK_REFILL := 5
const CHARGE_TIMEOUT := 1.5
const CORGI_GAP := 8.0

const LINES_HIT := ["Woof! Got it!", "Zap-tastic!", "You read it!", "Nice reading!"]
const LINES_MISS := ["So close! Try again!", "Almost! Say it again!", "Ooh, nearly!"]
const LINES_LAND := ["We've got this!", "Shields are okay. Keep going!"]
const LINES_LOW := ["Take a breath. Pick one word."]
const BRIEFINGS := ["Meteors ahead! Your voice is our shield.",
	"Read the words to protect the base.", "Your reading powers the laser. Let's go!",
	"Same words, faster speed. You know these!"]

var use_mic := true  # tests turn this off before adding the scene
var auto_spawn := true  # tests turn this off to place words themselves

# What to play (the parent picks the reading level; all Worlds are open).
var levels: Array = []
var worlds: Array = []
var reading_idx := 1  # L1 First Sight Words
var world_idx := 0
var level_num := 1
var speed := "Normal"

# Run state.
var playing := false
var time_left := 0.0
var shields := SHIELD_MAX
var stars := 0
var streak := 0
var words_read: Array = []
var landings := 0
var active := {}  # word -> FallingWord, every word on screen that can still be read
var spawner := Spawner.new()
var fall_time := 14.0
var spawn_interval := 5.0
var max_on_screen := 3
var since_spawn := 0.0
var empty_for := 0.0
var retry_in := 0.0
var listened := PackedStringArray()  # last word set sent to the listener
var charge := 0.0
var charge_timer := 0.0
var aim := -PI / 2.0
var dome_flash := [0.0, 0.0, 0.0, 0.0, 0.0]
var corgi_wait := 0.0
var typed := ""
var shot_path := ""
var stars_bg := PackedVector2Array()

# Nodes.
var listener: WordListener
var capture: AudioEffectCapture
var field: Node2D
var word_layer: Node2D
var fx_layer: Node2D
var time_bar: ProgressBar
var star_label: Label
var pips: Control
var mic_meter: Control
var caption: Label
var typed_label: Label
var start_panel: Control
var result_panel: Control
var reading_opt: OptionButton
var world_opt: OptionButton
var level_opt: OptionButton
var speed_opt: OptionButton
var start_btn: Button
var status_label: Label
var briefing: Label
var nora_tex: Texture2D
var aaron_tex: Texture2D
var corgi_tex: Texture2D


func _ready() -> void:
	nora_tex = _tex("res://art/characters/hero_nora.svg")
	aaron_tex = _tex("res://art/characters/commander_aaron.svg")
	corgi_tex = _tex("res://art/characters/corgi_sidekick.svg")
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 70:
		stars_bg.append(Vector2(rng.randf_range(0, 1280), rng.randf_range(HUD_H, GROUND_Y - 40)))
	_build_field()
	_build_hud()
	_build_start_panel()
	_build_result_panel()
	_load_levels()
	_show_start()
	var args := OS.get_cmdline_user_args()
	if "--no-mic" in args:
		use_mic = false
	if use_mic:
		_setup_mic()
		_load_listener()
	var shot := args.find("--shot")
	if shot >= 0 and shot + 1 < args.size():
		shot_path = args[shot + 1]
		var at := args.find("--shot-after")
		var secs := float(args[at + 1]) if at >= 0 and at + 1 < args.size() else 8.0
		get_tree().create_timer(secs).timeout.connect(func():
			get_viewport().get_texture().get_image().save_png(shot_path)
			print("screenshot: ", shot_path))
	if "--autostart" in args:
		start_level.call_deferred()


func _tex(path: String) -> Texture2D:
	return load(path) if ResourceLoader.exists(path) else null


# --- Levels and Worlds ------------------------------------------------------

func _load_levels() -> void:
	var idx = JSON.parse_string(FileAccess.get_file_as_string(LEVEL_INDEX))
	levels = idx["levels"] if idx else []
	reading_opt.clear()
	for l in levels:
		reading_opt.add_item("%s %s" % [l["id"], l["name"]])
	reading_idx = clampi(reading_idx, 0, levels.size() - 1)
	reading_opt.select(reading_idx)
	_load_worlds()


func _load_worlds() -> void:
	var l: Dictionary = levels[reading_idx]
	var data = JSON.parse_string(FileAccess.get_file_as_string(LEVEL_DIR + l["file"]))
	worlds = data["worlds"] if data else []
	world_idx = clampi(world_idx, 0, worlds.size() - 1)
	world_opt.clear()
	for i in worlds.size():
		world_opt.add_item("World %d: %s" % [i + 1, worlds[i]["name"]])
	world_opt.select(world_idx)


# --- Level flow -------------------------------------------------------------

func start_level() -> void:
	_clear_words()
	var world: Dictionary = worlds[world_idx]
	spawner.setup(world, reading_idx <= 2)
	fall_time = LevelCurve.fall_time(level_num, reading_idx, speed)
	spawn_interval = LevelCurve.spawn_interval(level_num)
	max_on_screen = LevelCurve.max_on_screen(level_num)
	time_left = LevelCurve.LEVEL_SECONDS
	shields = SHIELD_MAX
	stars = 0
	streak = 0
	landings = 0
	words_read.clear()
	since_spawn = 0.0
	empty_for = 0.0
	retry_in = 0.0
	charge = 0.0
	charge_timer = 0.0
	corgi_wait = 0.0
	typed = ""
	start_panel.visible = false
	result_panel.visible = false
	playing = true
	_say("%s, level %d. Read a word!" % [world["name"], level_num])
	if auto_spawn:
		spawn_word("", 1.0 / 3.0)  # something to read right away
	_push_words()
	_update_hud()


func _finish_level() -> void:
	playing = false
	for w in active:
		active[w].float_away()
	active.clear()
	_push_words()
	_show_results(true)


func _recharge() -> void:
	# Shields at 0: stop gently. Never "you lose".
	playing = false
	for w in active:
		active[w].float_away()
	active.clear()
	_push_words()
	_show_results(false)


func _clear_words() -> void:
	for c in word_layer.get_children():
		c.queue_free()
	active.clear()


## The game clock. _process calls it; tests call it directly to fast-forward.
func tick(delta: float) -> void:
	if not playing:
		return
	time_left -= delta
	corgi_wait -= delta
	for i in dome_flash.size():
		dome_flash[i] = maxf(0.0, dome_flash[i] - delta * 1.5)
	if charge_timer > 0.0:
		charge_timer -= delta
		charge = minf(1.0, charge + delta / 0.3)
	else:
		charge = maxf(0.0, charge - delta * 2.0)
		aim = lerp_angle(aim, -PI / 2.0, minf(1.0, delta * 3.0))

	# Spawning (§3.1): interval, the top-up rule, and the on-screen cap.
	since_spawn += delta
	spawner.cool(delta)
	empty_for = empty_for + delta if active.is_empty() else 0.0
	retry_in -= delta
	if auto_spawn and active.size() < max_on_screen and retry_in <= 0.0:
		var due := since_spawn >= spawn_interval \
			or (empty_for >= LevelCurve.TOP_UP_EMPTY and since_spawn >= LevelCurve.MIN_SPAWN_GAP)
		if due and not spawn_word():
			retry_in = 0.5

	for w in active.keys():
		if active[w].advance(delta):
			_on_landed(w)
			if not playing:
				return

	if time_left <= 0.0:
		_finish_level()
	_update_hud()


## Put a word on screen. With no word given, the spawner picks one.
func spawn_word(w: String = "", start_progress: float = 0.0) -> bool:
	var lane := _pick_lane()
	var slot := _pick_slot(lane)
	if lane < 0 or slot < 0:
		return false
	if w == "":
		w = spawner.next_word(active.keys())
	if w == "" or active.has(w):
		return false  # never the same word twice on screen
	if spawner.is_cooling(w):
		return false  # a late echo of its zap must not hit the new copy
	var fw := FallingWord.new()
	fw.setup(w, Vector2(SLOTS[lane], SPAWN_Y), Vector2(SLOTS[slot], HOVER_Y), fall_time, start_progress)
	fw.lane = lane
	fw.slot = slot
	word_layer.add_child(fw)
	active[w] = fw
	since_spawn = 0.0
	_push_words()
	return true


func _pick_lane() -> int:
	# Never share a lane with a word still in the top 40% of its fall (§4.6).
	var free := []
	for i in SLOTS.size():
		if not active.values().any(func(fw): return fw.lane == i and fw.progress < 0.4):
			free.append(i)
	return free.pick_random() if free.size() else -1


func _pick_slot(lane: int) -> int:
	# One word per landing spot, so landed words never overlap.
	var free := []
	for i in SLOTS.size():
		if not active.values().any(func(fw): return fw.slot == i):
			free.append(i)
	if free.is_empty():
		return -1
	var near := free.filter(func(i): return absi(i - lane) <= 2)
	return (near if near.size() else free).pick_random()


func _on_landed(w: String) -> void:
	var fw = active[w]
	shields -= 1
	landings += 1
	streak = 0
	spawner.note_reached_base(w)
	dome_flash[fw.slot] = 1.0
	if shields <= 0:
		_update_hud()
		_recharge()
		return
	_corgi(LINES_LOW if shields <= 2 else LINES_LAND)


func _push_words() -> void:
	# The recognizer only listens for words that can still be read.
	var ws := PackedStringArray(active.keys())
	if ws == listened:
		return
	listened = ws
	if listener and listener.is_loaded():
		listener.set_words(ws)


# --- Listener events ----------------------------------------------------------

func _on_voice_started() -> void:
	if playing:
		charge_timer = CHARGE_TIMEOUT  # the cannon charges while the word is recognized


func _on_word_heard(word: String, heard: String = "", latency_ms: float = 0.0) -> void:
	if not playing or not active.has(word):
		print("heard %s (\"%s\"): not on screen, no effect" % [word, heard])
		return  # duplicate, late or off-screen recognition: no effect
	print("zap %s (\"%s\", %d ms)" % [word, heard, latency_ms])
	var fw = active[word]
	active.erase(word)
	spawner.note_zapped(word)
	_push_words()
	stars += 1
	streak += 1
	words_read.append(word)
	aim = (fw.position - CANNON).angle()
	var tip := CANNON + Vector2.from_angle(aim) * BARREL
	fx_layer.add_child(Fx.laser(tip, fw.position))
	fx_layer.add_child(Fx.burst(fw.position))
	fw.zap()
	charge = 0.0
	charge_timer = 0.0
	if streak % STREAK_REFILL == 0 and shields < SHIELD_MAX:
		shields += 1
		_say("Five in a row! Shield back!")
		corgi_wait = CORGI_GAP
	elif randi() % 4 == 0:
		_corgi(LINES_HIT)
	_bump(star_label)
	_update_hud()


func _on_heard_other(heard: String) -> void:
	if not playing:
		return
	print("heard other \"%s\": no effect" % heard)
	# Speech that matched nothing: a small fizzle at the cannon, nothing else.
	charge_timer = 0.0
	fx_layer.add_child(Fx.fizzle(CANNON + Vector2.from_angle(aim) * BARREL))
	_corgi(LINES_MISS)


func _corgi(lines: Array) -> void:
	if corgi_wait > 0.0:
		return
	corgi_wait = CORGI_GAP
	_say("Rex: " + lines.pick_random())


func _say(text: String) -> void:
	caption.text = text
	caption.modulate.a = 1.0
	var tw := caption.create_tween()
	tw.tween_interval(3.0)
	tw.tween_property(caption, "modulate:a", 0.0, 0.6)


func _unhandled_input(event: InputEvent) -> void:
	# Dev aid: type a word and press Enter (same path as the recognizer).
	if not playing or not (event is InputEventKey) or not event.pressed:
		return
	var k := event as InputEventKey
	if k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER:
		if typed != "":
			if active.has(typed):
				_on_word_heard(typed, typed, 0.0)
			else:
				_on_heard_other(typed)
		typed = ""
	elif k.keycode == KEY_BACKSPACE:
		typed = typed.left(-1)
	elif k.unicode >= 32:
		typed += char(k.unicode).to_lower()
	typed_label.text = typed


# --- Audio --------------------------------------------------------------------

func _setup_mic() -> void:
	# Mic -> muted bus with a capture effect: raw samples, no playback.
	var bus := AudioServer.get_bus_index("GameMic")
	if bus < 0:
		bus = AudioServer.bus_count
		AudioServer.add_bus(bus)
		AudioServer.set_bus_name(bus, "GameMic")
		AudioServer.set_bus_mute(bus, true)
		var cap := AudioEffectCapture.new()
		cap.buffer_length = 0.5
		AudioServer.add_bus_effect(bus, cap)
	capture = AudioServer.get_bus_effect(bus, 0)
	var mic := AudioStreamPlayer.new()
	mic.stream = AudioStreamMicrophone.new()
	mic.bus = "GameMic"
	add_child(mic)
	mic.play()


func _load_listener() -> void:
	start_btn.disabled = true
	status_label.text = "Warming up the listening ears..."
	await get_tree().process_frame
	await get_tree().process_frame
	var preset: String = HeroSpeech.PRESETS.keys()[0]
	var l := WordListener.new()
	add_child(l)
	if not l.load_model(HeroSpeech.config_for(preset)):
		status_label.text = "Speech model missing (%s). Type words + Enter to play." % HeroSpeech.models_root()
		l.queue_free()
		start_btn.disabled = false
		return
	listener = l
	listener.voice_started.connect(_on_voice_started)
	listener.word_heard.connect(_on_word_heard)
	listener.heard_other.connect(_on_heard_other)
	listener.set_words(listened)
	status_label.text = "Ready! Say the words out loud."
	start_btn.disabled = false


func _process(delta: float) -> void:
	if listener and capture:
		var n := capture.get_frames_available()
		if n > 0:
			listener.push_frames(capture.get_buffer(n), int(AudioServer.get_mix_rate()))
	elif capture:
		capture.clear_buffer()
	tick(delta)
	mic_meter.queue_redraw()
	field.queue_redraw()


# --- Drawing --------------------------------------------------------------------

func _build_field() -> void:
	field = Node2D.new()
	field.draw.connect(_draw_field)
	add_child(field)
	word_layer = Node2D.new()
	add_child(word_layer)
	fx_layer = Node2D.new()
	add_child(fx_layer)


func _draw_field() -> void:
	field.draw_rect(Rect2(0, 0, 1280, 720), NAVY)
	for i in stars_bg.size():
		field.draw_circle(stars_bg[i], 1.5 + (i % 3) * 0.7, Color(CREAM, 0.35 + (i % 4) * 0.12))
	field.draw_rect(Rect2(0, GROUND_Y, 1280, 720 - GROUND_Y), GROUND)
	field.draw_line(Vector2(0, GROUND_Y), Vector2(1280, GROUND_Y), OUTLINE, 6.0)
	for i in SLOTS.size():
		if i != 2:
			_draw_dome(Vector2(SLOTS[i], GROUND_Y), i)
	# Cannon: barrel (glows while charging), tower, Nora in the window.
	var tip := CANNON + Vector2.from_angle(aim) * BARREL
	field.draw_line(CANNON, tip, OUTLINE, 30.0, true)
	field.draw_line(CANNON, tip, BLUE, 20.0, true)
	field.draw_circle(tip, 10.0 + 18.0 * charge, Color(TEAL, 0.35 + 0.6 * charge))
	_draw_half_disc(Vector2(CANNON.x, GROUND_Y), 84.0, PLUM)
	_draw_shield_arc(Vector2(CANNON.x, GROUND_Y), 100.0, 2)
	if nora_tex:
		var r := 46.0
		if charge > 0.0:
			field.draw_circle(Vector2(CANNON.x, 640), r + 4 + 6 * charge, Color(TEAL, 0.8))
		field.draw_texture_rect(nora_tex, Rect2(CANNON.x - r, 640 - r, r * 2, r * 2), false)
	if corgi_tex:
		field.draw_texture_rect(corgi_tex, Rect2(4, GROUND_Y - 40, 92, 92), false)


func _draw_dome(base: Vector2, slot: int) -> void:
	_draw_half_disc(base, 58.0, BLUE)
	for k in 3:  # dome lights
		field.draw_circle(base + Vector2(-24 + 24 * k, -24), 6.0, GOLD)
	_draw_shield_arc(base, 74.0, slot)


func _draw_half_disc(c: Vector2, r: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 25:
		pts.append(c + Vector2.from_angle(PI + PI * i / 24.0) * r)
	field.draw_colored_polygon(pts, col)
	pts.append(pts[0])
	field.draw_polyline(pts, OUTLINE, 5.0, true)


func _draw_shield_arc(c: Vector2, r: float, slot: int) -> void:
	var f: float = dome_flash[slot]
	var a := 0.25 + 0.6 * f * (0.5 + 0.5 * sin(Time.get_ticks_msec() / 40.0))
	field.draw_arc(c, r, PI, TAU, 32, Color(TEAL, a), 4.0 + 4.0 * f, true)


# --- HUD and panels ---------------------------------------------------------------

func _build_hud() -> void:
	var bar := HBoxContainer.new()
	bar.position = Vector2(12, 10)
	bar.size = Vector2(1256, 40)
	bar.add_theme_constant_override("separation", 16)
	add_child(bar)
	var back := Button.new()
	back.text = "  <  "
	back.focus_mode = Control.FOCUS_NONE
	back.pressed.connect(_show_start)
	bar.add_child(back)
	time_bar = ProgressBar.new()  # fills up like a fuel gauge (§3.3)
	time_bar.show_percentage = false
	time_bar.max_value = LevelCurve.LEVEL_SECONDS
	time_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	time_bar.custom_minimum_size = Vector2(0, 26)
	time_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var fill := StyleBoxFlat.new()
	fill.bg_color = TEAL
	fill.set_corner_radius_all(10)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(OUTLINE, 0.8)
	bg.set_corner_radius_all(10)
	time_bar.add_theme_stylebox_override("fill", fill)
	time_bar.add_theme_stylebox_override("background", bg)
	bar.add_child(time_bar)
	var star_icon := Control.new()
	star_icon.custom_minimum_size = Vector2(34, 34)
	star_icon.draw.connect(func(): _draw_star(star_icon, Vector2(17, 20), 16.0, GOLD))
	bar.add_child(star_icon)
	star_label = _label("0", 30, GOLD)
	star_label.custom_minimum_size = Vector2(56, 0)
	bar.add_child(star_label)
	pips = Control.new()
	pips.custom_minimum_size = Vector2(5 * 30, 34)
	pips.draw.connect(_draw_pips)
	bar.add_child(pips)
	mic_meter = Control.new()
	mic_meter.custom_minimum_size = Vector2(90, 34)
	mic_meter.draw.connect(_draw_mic)
	bar.add_child(mic_meter)

	caption = _label("", 24, CREAM)
	caption.position = Vector2(104, GROUND_Y + 12)
	caption.size = Vector2(900, 36)
	add_child(caption)
	typed_label = _label("", 20, Color(CREAM, 0.6))
	typed_label.position = Vector2(1080, GROUND_Y + 16)
	add_child(typed_label)


func _draw_pips() -> void:
	# Shields are shapes that empty out, not red/green (§9).
	for i in SHIELD_MAX:
		var c := Vector2(15 + 30 * i, 18)
		if i < shields:
			pips.draw_circle(c, 11.0, TEAL)
		pips.draw_circle(c, 11.0, CREAM, false, 3.0, true)


func _draw_mic() -> void:
	var s := mic_meter.size
	var lvl := 0.0
	var voice := false
	if listener:
		lvl = clampf(listener.get_level(), 0.0, 1.0)
		voice = listener.is_hearing_voice()
	var col := TEAL if voice else Color(CREAM, 0.6)
	# Mic body.
	mic_meter.draw_rect(Rect2(6, 6, 12, 18), col, false, 3.0)
	mic_meter.draw_line(Vector2(12, 24), Vector2(12, 30), col, 3.0)
	# Level bar.
	mic_meter.draw_rect(Rect2(26, 12, s.x - 30, 12), Color(OUTLINE, 0.8))
	mic_meter.draw_rect(Rect2(26, 12, (s.x - 30) * lvl, 12), col)


func _draw_star(c: CanvasItem, at: Vector2, r: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 10:
		var rr := r if i % 2 == 0 else r * 0.45
		pts.append(at + Vector2.from_angle(-PI / 2.0 + PI / 5.0 * i) * rr)
	c.draw_colored_polygon(pts, col)


func _update_hud() -> void:
	time_bar.value = LevelCurve.LEVEL_SECONDS - maxf(time_left, 0.0)
	star_label.text = str(stars)
	pips.queue_redraw()


func _bump(c: Control) -> void:
	c.pivot_offset = c.size / 2.0
	var tw := c.create_tween()
	tw.tween_property(c, "scale", Vector2(1.4, 1.4), 0.08)
	tw.tween_property(c, "scale", Vector2.ONE, 0.15)


func _panel() -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(OUTLINE, 0.92)
	sb.set_corner_radius_all(28)
	sb.set_border_width_all(6)
	sb.border_color = TEAL
	sb.set_content_margin_all(28)
	p.add_theme_stylebox_override("panel", sb)
	add_child(p)
	return p


func _center(p: Control) -> void:
	p.reset_size()
	p.position = (Vector2(1280, 720) - p.get_combined_minimum_size()) / 2.0


func _label(text: String, size: int, col: Color = CREAM) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	return l


func _button(text: String, size: int, main: bool = false) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", size)
	b.custom_minimum_size = Vector2(0, 64 if main else 52)
	for state in ["normal", "hover", "pressed", "focus"]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = (TEAL if main else BLUE).lightened(0.12 if state == "hover" else 0.0)
		if state == "focus":
			sb.draw_center = false
			sb.set_border_width_all(4)
			sb.border_color = GOLD
		sb.set_corner_radius_all(18)
		sb.set_content_margin_all(12)
		b.add_theme_stylebox_override(state, sb)
	b.add_theme_color_override("font_color", OUTLINE if main else CREAM)
	b.add_theme_color_override("font_hover_color", OUTLINE if main else CREAM)
	b.add_theme_color_override("font_pressed_color", OUTLINE if main else CREAM)
	return b


func _build_start_panel() -> void:
	start_panel = _panel()
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	start_panel.add_child(box)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 20)
	box.add_child(head)
	var face := TextureRect.new()
	face.texture = aaron_tex
	face.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	face.custom_minimum_size = Vector2(150, 150)
	head.add_child(face)
	var words := VBoxContainer.new()
	words.alignment = BoxContainer.ALIGNMENT_CENTER
	head.add_child(words)
	words.add_child(_label("Meteor Shield", 44, GOLD))
	briefing = _label("", 26, CREAM)
	briefing.custom_minimum_size = Vector2(520, 0)
	briefing.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	words.add_child(briefing)
	words.add_child(_label("- Commander Aaron", 18, Color(CREAM, 0.6)))

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 10)
	box.add_child(grid)
	reading_opt = OptionButton.new()
	world_opt = OptionButton.new()
	level_opt = OptionButton.new()
	speed_opt = OptionButton.new()
	for i in 5:
		level_opt.add_item("Level %d" % (i + 1))
	for s in LevelCurve.SPEEDS:
		speed_opt.add_item(s)
	for row in [["Reading level", reading_opt], ["World", world_opt], ["Level", level_opt], ["Speed", speed_opt]]:
		grid.add_child(_label(row[0], 22, Color(CREAM, 0.8)))
		var opt: OptionButton = row[1]
		opt.add_theme_font_size_override("font_size", 22)
		opt.custom_minimum_size = Vector2(420, 44)
		grid.add_child(opt)
	reading_opt.item_selected.connect(func(i):
		reading_idx = i
		world_idx = 0
		_load_worlds())
	world_opt.item_selected.connect(func(i): world_idx = i)
	level_opt.item_selected.connect(func(i): level_num = i + 1)
	speed_opt.item_selected.connect(func(i): speed = speed_opt.get_item_text(i))
	speed_opt.select(1)

	start_btn = _button("START MISSION", 32, true)
	start_btn.pressed.connect(start_level)
	box.add_child(start_btn)
	status_label = _label("", 18, Color(CREAM, 0.7))
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(status_label)
	var dev := _button("Back to dev menu", 18)
	dev.custom_minimum_size = Vector2(0, 40)
	dev.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/menu.tscn"))
	box.add_child(dev)


func _show_start() -> void:
	playing = false
	_clear_words()
	_push_words()
	result_panel.visible = false
	briefing.text = BRIEFINGS.pick_random()
	level_opt.select(level_num - 1)
	if worlds.size():
		world_opt.select(world_idx)
	start_panel.visible = true
	_center.call_deferred(start_panel)


func _build_result_panel() -> void:
	result_panel = _panel()
	result_panel.visible = false


func _show_results(complete: bool) -> void:
	for c in result_panel.get_children():
		c.queue_free()
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	result_panel.add_child(box)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 20)
	box.add_child(head)
	var face := TextureRect.new()
	face.texture = aaron_tex if complete else corgi_tex
	face.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	face.custom_minimum_size = Vector2(130, 130)
	head.add_child(face)
	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	head.add_child(col)
	col.add_child(_label("Mission complete!" if complete else "Shields need a recharge!", 40, GOLD))
	col.add_child(_label("You read like a star." if complete else "Rex: Let's try again together!", 24))
	var n := words_read.size()
	box.add_child(_label("You read %d word%s!   Stars: %d" % [n, "" if n == 1 else "s", stars], 30))
	if n:
		var list := _label(", ".join(words_read), 22, Color(CREAM, 0.75))
		list.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		list.custom_minimum_size = Vector2(560, 0)
		box.add_child(list)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	box.add_child(row)
	if complete:
		var next := _button("Next level", 28, true)
		next.pressed.connect(_next_level)
		row.add_child(next)
		var again := _button("Replay", 24)
		again.pressed.connect(start_level)
		row.add_child(again)
	else:
		var again := _button("Try again", 30, true)
		again.pressed.connect(start_level)
		row.add_child(again)
	var menu := _button("Menu", 24)
	menu.pressed.connect(_show_start)
	row.add_child(menu)
	result_panel.visible = true
	_center.call_deferred(result_panel)
	(row.get_child(0) as Button).grab_focus.call_deferred()


func _next_level() -> void:
	level_num += 1
	if level_num > LevelCurve.LEVELS.size():
		level_num = 1
		world_idx = (world_idx + 1) % worlds.size()
	start_level()
