extends Control
## Microphone proof-of-concept: five words, read one, watch it get zapped.
##
## Shows the model's latency (from when your voice stopped to the zap) for
## each word, so you can try it with your reader and compare presets.

const WORDLIST := "res://data/wordlists/dolch-preprimer.json"

var listener: WordListener
var capture: AudioEffectCapture
var words: Array = []
var pool: Array = []
var word_labels: Array[Label] = []
var lat_history: Array = []

@onready var row: HBoxContainer = $VBox/Words
@onready var status: Label = $VBox/Status
@onready var stats: Label = $VBox/Stats
@onready var meter: ProgressBar = $VBox/Meter
@onready var preset_menu: OptionButton = $VBox/Top/Preset


func _ready() -> void:
	pool = _load_words()
	for p in HeroSpeech.PRESETS:
		preset_menu.add_item(p)
	preset_menu.item_selected.connect(func(_i): _start_listener())
	_setup_mic()
	_start_listener()


func _setup_mic() -> void:
	# Route the microphone into a muted bus with a capture effect, so we can
	# read raw samples without playing the child's voice back.
	var bus := AudioServer.bus_count
	AudioServer.add_bus(bus)
	AudioServer.set_bus_name(bus, "Mic")
	AudioServer.set_bus_mute(bus, true)
	capture = AudioEffectCapture.new()
	capture.buffer_length = 0.5
	AudioServer.add_bus_effect(bus, capture)
	var mic := AudioStreamPlayer.new()
	mic.stream = AudioStreamMicrophone.new()
	mic.bus = "Mic"
	add_child(mic)
	mic.play()


func _start_listener() -> void:
	if listener:
		listener.queue_free()
	listener = WordListener.new()
	add_child(listener)
	var preset := preset_menu.get_item_text(preset_menu.selected)
	status.text = "Loading %s..." % preset
	await get_tree().process_frame
	var t0 := Time.get_ticks_msec()
	if not listener.load_model(HeroSpeech.config_for(preset)):
		status.text = "Could not load %s - are the models in %s?" % [preset, HeroSpeech.models_root()]
		return
	status.text = "Ready! (model loaded in %d ms) Read a word out loud." % (Time.get_ticks_msec() - t0)
	listener.word_heard.connect(_on_word_heard)
	listener.heard_other.connect(_on_heard_other)
	lat_history.clear()
	_new_words()


func _process(_delta: float) -> void:
	if capture == null or listener == null:
		return
	var n := capture.get_frames_available()
	if n > 0:
		listener.push_frames(capture.get_buffer(n), int(AudioServer.get_mix_rate()))
	meter.value = listener.get_level() * 100.0


func _new_words() -> void:
	words = []
	var shuffled := pool.duplicate()
	shuffled.shuffle()
	words = shuffled.slice(0, 5)
	for c in row.get_children():
		c.queue_free()
	word_labels.clear()
	for w in words:
		var l := Label.new()
		l.text = w
		l.add_theme_font_size_override("font_size", 64)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		row.add_child(l)
		word_labels.append(l)
	listener.set_words(PackedStringArray(words))


func _on_word_heard(word: String, heard: String, latency_ms: float) -> void:
	var i := words.find(word)
	if i >= 0:
		var l := word_labels[i]
		l.modulate = Color(0.3, 1.0, 0.6)
		var tw := create_tween()
		tw.tween_property(l, "scale", Vector2(1.3, 1.3), 0.08)
		tw.tween_property(l, "modulate:a", 0.0, 0.25)
	lat_history.append(latency_ms)
	var sorted := lat_history.duplicate()
	sorted.sort()
	status.text = "ZAP!  %s   (%.0f ms after you stopped talking)" % [word.to_upper(), latency_ms]
	stats.text = "heard: \"%s\"   |   median latency %.0f ms over %d words" % [
		heard, sorted[sorted.size() / 2], sorted.size()]
	get_tree().create_timer(0.6).timeout.connect(_new_words)


func _on_heard_other(heard: String) -> void:
	# Never a penalty: just a gentle nudge.
	status.text = "Ooh, close! Try again  (heard \"%s\")" % heard


func _load_words() -> Array:
	var f := FileAccess.open(WORDLIST, FileAccess.READ)
	if f == null:
		return ["cat", "dog", "sun", "red", "big", "run", "fun", "hat", "pig", "map"]
	var data: Dictionary = JSON.parse_string(f.get_as_text())
	return data["words"].filter(func(w): return w.length() > 1)
