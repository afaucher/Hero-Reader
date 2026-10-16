extends Control
## Word-match POC: five words from a real World, your mic, and a live view of
## how the recognizer's guesses map onto the on-screen words.
##
## - Mic strip: input level history and the voice-detected lamp.
## - "Hearing": the model's current hypothesis (grey = partial, white = final).
## - Word cards: per word, how the latest hypothesis matched it (exact,
##   homophone, sound-alike, waiting) and how close it sounded (phonemes).
## - Log: every event in order, with latency on zaps.
## A zapped word is replaced by a new one that isn't a sound-alike of the
## others, the same rule the game spawner will use. A zapped word stays off
## screen for REZAP_COOLDOWN_MS, so a late repeat recognition can't hit it.

const LEVEL_INDEX := "res://data/wordlists/levels/index.json"
const LEVEL_DIR := "res://data/wordlists/levels/"
const N_WORDS := 5
const REZAP_COOLDOWN_MS := 2000  # same as the game spawner's REZAP_COOLDOWN
const HISTORY := 240  # level samples (~4 s at 60 fps)

const C_BG := Color(0.106, 0.122, 0.294)
const C_CARD := Color(0.16, 0.18, 0.40)
const C_TEXT := Color(0.95, 0.95, 1.0)
const C_DIM := Color(0.62, 0.65, 0.85)
const KIND_COLORS := {
	"exact": Color(0.30, 1.00, 0.60),
	"homophone": Color(0.30, 0.90, 1.00),
	"sound_alike": Color(1.00, 0.85, 0.30),
	"wait": Color(0.55, 0.65, 1.00),
	"zap": Color(1.00, 1.00, 1.00),
}

var listener: WordListener
var capture: AudioEffectCapture
var levels: Array = []  # index.json entries
var world: Dictionary = {}
var confusable := {}  # word -> {other: true}
var words: Array = []  # on-screen words, one per card
var cards: Array = []  # Dictionary per card: panel, word, kind, detail, bar
var level_hist := PackedFloat32Array()
var voice_hist := PackedByteArray()
var latencies: Array = []
var n_zaps := 0
var n_other := 0
var n_ignored := 0  # duplicate / stale word_heard, ignored by the game rule
var zapping := {}  # words mid-zap animation
var cooling := {}  # zapped word -> ticks_msec when it may come back
var t_start := 0
var feed_mic := true  # tests/viz_demo.gd turns this off and pushes clips itself

var preset_menu: OptionButton
var level_menu: OptionButton
var world_menu: OptionButton
var scope: Control
var lamp: Label
var hearing: Label
var card_row: HBoxContainer
var log_box: RichTextLabel
var stats: Label


func _ready() -> void:
	t_start = Time.get_ticks_msec()
	level_hist.resize(HISTORY)
	voice_hist.resize(HISTORY)
	_build_ui()
	_load_levels()
	_setup_mic()
	_start_listener()


# --- UI -----------------------------------------------------------------

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = C_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 24
	root.offset_top = 16
	root.offset_right = -24
	root.offset_bottom = -16
	root.add_theme_constant_override("separation", 12)
	add_child(root)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 12)
	root.add_child(top)
	var back := Button.new()
	back.text = "<"
	back.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/menu.tscn"))
	top.add_child(back)
	var title := _label("Word match", 26)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(title)
	level_menu = OptionButton.new()
	world_menu = OptionButton.new()
	preset_menu = OptionButton.new()
	for p in HeroSpeech.PRESETS:
		preset_menu.add_item(p)
	var shuffle := Button.new()
	shuffle.text = "New words"
	shuffle.pressed.connect(_new_words)
	for c in [level_menu, world_menu, preset_menu, shuffle]:
		top.add_child(c)
	level_menu.item_selected.connect(func(_i): _fill_worlds())
	world_menu.item_selected.connect(func(_i): _pick_world())
	preset_menu.item_selected.connect(func(_i): _start_listener())

	# Mic strip: lamp + scrolling level scope.
	var mic := HBoxContainer.new()
	mic.add_theme_constant_override("separation", 12)
	root.add_child(mic)
	lamp = _label("  MIC  ", 20)
	lamp.custom_minimum_size = Vector2(110, 56)
	lamp.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lamp.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	mic.add_child(lamp)
	scope = Control.new()
	scope.custom_minimum_size = Vector2(0, 56)
	scope.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scope.draw.connect(_draw_scope)
	mic.add_child(scope)

	hearing = _label("...", 34)
	hearing.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hearing.custom_minimum_size = Vector2(0, 48)
	root.add_child(hearing)

	card_row = HBoxContainer.new()
	card_row.add_theme_constant_override("separation", 12)
	card_row.custom_minimum_size = Vector2(0, 230)
	root.add_child(card_row)

	var legend := RichTextLabel.new()
	legend.bbcode_enabled = true
	legend.fit_content = true
	legend.scroll_active = false
	legend.add_theme_font_size_override("normal_font_size", 15)
	legend.text = "[color=#%s]exact[/color]   [color=#%s]homophone[/color]   [color=#%s]sound-alike[/color]   [color=#%s]waiting (could be a longer word)[/color]   bar = how close it sounded (phonemes)" % [
		KIND_COLORS["exact"].to_html(false), KIND_COLORS["homophone"].to_html(false),
		KIND_COLORS["sound_alike"].to_html(false), KIND_COLORS["wait"].to_html(false)]
	root.add_child(legend)

	log_box = RichTextLabel.new()
	log_box.bbcode_enabled = true
	log_box.scroll_following = true
	log_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	log_box.add_theme_font_size_override("normal_font_size", 15)
	log_box.add_theme_color_override("default_color", C_DIM)
	root.add_child(log_box)

	stats = _label("", 16)
	stats.add_theme_color_override("font_color", C_DIM)
	root.add_child(stats)


func _label(text: String, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", C_TEXT)
	return l


func _make_card(word: String) -> Dictionary:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.pivot_offset = Vector2(110, 115)
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_CARD
	sb.set_corner_radius_all(14)
	sb.set_border_width_all(4)
	sb.border_color = C_CARD
	panel.add_theme_stylebox_override("panel", sb)
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)
	var title := _label(word, 54)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	var kind := _label(" ", 18)
	kind.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(kind)
	var bar := ProgressBar.new()
	bar.max_value = 4
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 10)
	box.add_child(bar)
	var detail := _label(" ", 14)
	detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	detail.add_theme_color_override("font_color", C_DIM)
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(detail)
	return {"panel": panel, "style": sb, "name": title, "kind": kind, "bar": bar, "detail": detail}


func _set_card(i: int, kind: String, info: String, closeness: float) -> void:
	var c: Dictionary = cards[i]
	var col: Color = KIND_COLORS.get(kind, C_CARD)
	(c["style"] as StyleBoxFlat).border_color = col if kind != "" else C_CARD
	(c["name"] as Label).add_theme_color_override("font_color", col if kind != "" else C_TEXT)
	(c["kind"] as Label).text = kind.replace("_", "-") if kind != "" else " "
	(c["kind"] as Label).add_theme_color_override("font_color", col)
	(c["bar"] as ProgressBar).value = closeness
	(c["detail"] as Label).text = info if info != "" else " "


# --- Words ----------------------------------------------------------------

func _load_levels() -> void:
	var idx = JSON.parse_string(FileAccess.get_file_as_string(LEVEL_INDEX))
	levels = idx["levels"] if idx else []
	for l in levels:
		level_menu.add_item("%s %s" % [l["id"], l["name"]])
	level_menu.select(min(1, levels.size() - 1))  # L1 sight words by default
	_fill_worlds()


func _fill_worlds() -> void:
	var l: Dictionary = levels[level_menu.selected]
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(LEVEL_DIR + l["file"]))
	world_menu.clear()
	world_menu.set_meta("worlds", data["worlds"])
	for w in data["worlds"]:
		world_menu.add_item(w["name"])  # all Worlds open (design decision 5)
	world_menu.select(0)
	_pick_world()


func _pick_world() -> void:
	world = (world_menu.get_meta("worlds") as Array)[world_menu.selected]
	confusable.clear()
	for p in world.get("confusable", []):
		confusable.get_or_add(p[0], {})[p[1]] = true
		confusable.get_or_add(p[1], {})[p[0]] = true
	_new_words()


func _safe_pick(exclude: Array) -> String:
	# A word not on screen, not just zapped, and not a sound-alike of anything
	# on screen.
	var pool: Array = world["words"].duplicate()
	pool.shuffle()
	var now := Time.get_ticks_msec()
	for w in pool:
		if w in exclude or cooling.get(w, 0) > now:
			continue
		var clash := false
		for o in exclude:
			if confusable.get(w, {}).has(o):
				clash = true
				break
		if not clash:
			return w
	for w in pool:  # tiny word list: allow a sound-alike, never a just-zapped word
		if not (w in exclude or cooling.get(w, 0) > now):
			return w
	return pool[0]


func _new_words(fixed: Array = []) -> void:
	if world.is_empty() and fixed.is_empty():
		return
	words.clear()
	zapping.clear()
	for c in card_row.get_children():
		c.queue_free()
	cards.clear()
	for i in N_WORDS:
		var w: String = fixed[i] if i < fixed.size() else _safe_pick(words)
		words.append(w)
		var c := _make_card(w)
		card_row.add_child(c["panel"])
		cards.append(c)
	_push_words()
	_log("[color=#8890c0]words: %s[/color]" % ", ".join(words))


func _replace_word(i: int) -> void:
	var others := words.duplicate()
	others.remove_at(i)
	var w := _safe_pick(others + [words[i]])
	words[i] = w
	var old: Control = cards[i]["panel"]
	var c := _make_card(w)
	card_row.add_child(c["panel"])
	card_row.move_child(c["panel"], i)
	old.queue_free()
	cards[i] = c
	_push_words()


func _push_words() -> void:
	if listener and listener.is_loaded():
		listener.set_words(PackedStringArray(words))


# --- Audio ----------------------------------------------------------------

func _setup_mic() -> void:
	# Mic -> muted bus with a capture effect: raw samples, no playback.
	var bus := AudioServer.bus_count
	AudioServer.add_bus(bus)
	AudioServer.set_bus_name(bus, "MatchMic")
	AudioServer.set_bus_mute(bus, true)
	capture = AudioEffectCapture.new()
	capture.buffer_length = 0.5
	AudioServer.add_bus_effect(bus, capture)
	var mic := AudioStreamPlayer.new()
	mic.stream = AudioStreamMicrophone.new()
	mic.bus = "MatchMic"
	add_child(mic)
	mic.play()


func _start_listener() -> void:
	if listener:
		listener.queue_free()
		listener = null
	var preset := preset_menu.get_item_text(preset_menu.selected)
	hearing.text = "loading %s..." % preset
	await get_tree().process_frame
	var l := WordListener.new()
	add_child(l)
	var t0 := Time.get_ticks_msec()
	if not l.load_model(HeroSpeech.config_for(preset)):
		hearing.text = "could not load %s (models in %s?)" % [preset, HeroSpeech.models_root()]
		_log("[color=#ff8080]load failed: %s[/color]" % preset)
		return
	listener = l
	listener.voice_started.connect(_on_voice_started)
	listener.hypothesis.connect(_on_hypothesis)
	listener.word_heard.connect(_on_word_heard)
	listener.heard_other.connect(_on_heard_other)
	latencies.clear()
	n_zaps = 0
	n_other = 0
	hearing.text = "read a word out loud"
	_log("[color=#8890c0]%s loaded in %d ms[/color]" % [preset, Time.get_ticks_msec() - t0])
	_push_words()


func _process(_delta: float) -> void:
	if listener == null:
		return
	var n := capture.get_frames_available()
	if n > 0:
		var frames := capture.get_buffer(n)
		if feed_mic:
			listener.push_frames(frames, int(AudioServer.get_mix_rate()))
	var voice := listener.is_hearing_voice()
	level_hist = level_hist.slice(1)
	level_hist.append(listener.get_level())
	voice_hist = voice_hist.slice(1)
	voice_hist.append(1 if voice else 0)
	scope.queue_redraw()
	lamp.add_theme_color_override("font_color", KIND_COLORS["exact"] if voice else C_DIM)
	lamp.text = "VOICE" if voice else "  MIC  "


func _draw_scope() -> void:
	var s := scope.size
	scope.draw_rect(Rect2(Vector2.ZERO, s), Color(0, 0, 0, 0.25))
	var dx := s.x / HISTORY
	for i in HISTORY:
		var h: float = clampf(level_hist[i], 0.0, 1.0) * s.y
		var col := KIND_COLORS["exact"] if voice_hist[i] else C_DIM
		scope.draw_rect(Rect2(i * dx, s.y - h, maxf(dx - 1, 1), h), col)


# --- Listener events ------------------------------------------------------

func _on_voice_started() -> void:
	# Instant feedback (the game's "cannon charging" moment).
	hearing.add_theme_color_override("font_color", C_DIM)
	hearing.text = "..."
	_log("voice")


func _on_hypothesis(text: String, final: bool, detail: Array) -> void:
	hearing.text = "\"%s\"" % text
	hearing.add_theme_color_override("font_color", C_TEXT if final else C_DIM)
	var parts := []
	for d in detail:
		var i := words.find(d["word"])
		if i < 0:
			continue  # word changed since this hypothesis
		var dist: int = d["distance"]
		var closeness := 0.0 if dist < 0 else maxf(0.0, 4.0 - dist)
		var info := ""
		if d["token"] != "":
			info = "heard \"%s\"" % d["token"]
			if dist >= 0:
				info += "  (%d off)\n%s / %s" % [dist, d["word_phones"], d["token_phones"]]
		if d["kind"] in ["exact", "homophone"]:
			closeness = 4.0
		_set_card(i, d["kind"], info, closeness)
		if d["kind"] != "":
			parts.append("%s=%s" % [d["word"], d["kind"]])
	_log("%s \"%s\"%s" % ["[color=#ffffff]final[/color]" if final else "partial", text,
		("  -> " + ", ".join(parts)) if parts.size() else ""])


func _on_word_heard(word: String, heard: String, latency_ms: float) -> void:
	# Game rule: a duplicate recognition, or one for a word that is already
	# being zapped or has left the screen, has no effect. Words stay until read.
	var i := words.find(word)
	if i < 0 or zapping.has(word):
		n_ignored += 1
		_log("[color=#8890c0]ignored %s (already zapped)[/color]  heard \"%s\"" % [word.to_upper(), heard])
		_update_stats()
		return
	zapping[word] = true
	cooling[word] = Time.get_ticks_msec() + REZAP_COOLDOWN_MS
	n_zaps += 1
	latencies.append(latency_ms)
	_log("[color=#%s][b]ZAP %s[/b][/color]  heard \"%s\"  %d ms after voice stopped" % [
		KIND_COLORS["exact"].to_html(false), word.to_upper(), heard, latency_ms])
	_update_stats()
	var panel: Control = cards[i]["panel"]
	(cards[i]["kind"] as Label).text = "ZAP!  %d ms" % latency_ms
	var tw := create_tween()
	tw.tween_property(panel, "scale", Vector2(1.12, 1.12), 0.08)
	tw.tween_property(panel, "modulate:a", 0.0, 0.35)
	tw.tween_callback(func():
		zapping.erase(word)
		if word in words:
			_replace_word(words.find(word)))


func _on_heard_other(heard: String) -> void:
	n_other += 1
	_log("[color=#ffd060]no match[/color] \"%s\"  (try again!)" % heard)
	_update_stats()
	for i in cards.size():
		if (cards[i]["kind"] as Label).text.begins_with("ZAP"):
			continue
		var tw := create_tween()
		tw.tween_property(cards[i]["panel"], "position:x", cards[i]["panel"].position.x + 6, 0.05)
		tw.tween_property(cards[i]["panel"], "position:x", cards[i]["panel"].position.x, 0.08)


func _update_stats() -> void:
	var s := latencies.duplicate()
	s.sort()
	var med: float = s[s.size() / 2] if s.size() else 0.0
	var st: Dictionary = listener.get_stats() if listener else {}
	stats.text = "zaps %d   no-match %d   ignored dupes %d   median latency %d ms   compute %.1f%% of real time" % [
		n_zaps, n_other, n_ignored, med, 100.0 * float(st.get("rtf", 0.0))]


func _log(msg: String) -> void:
	var t := (Time.get_ticks_msec() - t_start) / 1000.0
	log_box.append_text("[color=#6870a0]%6.1f[/color]  %s\n" % [t, msg])
