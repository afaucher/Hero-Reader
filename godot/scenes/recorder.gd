extends Control
## Calibration recorder: build a test set of real voices reading game words.
##
## 1. Click the reader's age and gender, pick a word list, press Start.
## 2. Words appear one at a time in random order. Recording is hands-free:
##    it starts when the reader speaks (keeping a little audio from just
##    before) and stops after a short silence, then the next word appears.
## 3. When the list runs out it reshuffles and loops, so every word collects
##    several takes. Stop whenever you like.
##
## Keys: SPACE pause/resume, R redo the last take, S skip a word, ESC finish.
##
## Output (same mic path as the game, saved as 16 kHz mono WAV):
##   user://recordings/<age><gender>/<session>/<word>__r<round>.wav
##   .../manifest.csv  one row per take (word, round, time, length, level...)
##   .../session.json  age, gender, mic device, mix rate, word list
## stt-eval/benchmark.py --recordings <folder> reads these directly.

const SAMPLE_RATE := 16000
const PREROLL_S := 0.35
const TAIL_SILENCE_S := 0.6
const MAX_TAKE_S := 4.0
const NEXT_WORD_DELAY_S := 0.6
const AGES := ["4", "5", "6", "7", "8", "9", "10", "11", "12", "13-17", "adult"]
const GENDERS := {"F": "f", "M": "m", "Other": "x"}

enum State { SETUP, WAITING, RECORDING, PAUSED, BETWEEN, DONE }

var state := State.SETUP
var age := ""
var gender := ""
var words: Array = []
var queue: Array = []
var round_no := 0
var current := ""
var session_dir := ""
var takes := 0
var last_take_path := ""
var last_take_word := ""

var capture: AudioEffectCapture
var mic_rate := 44100.0
var resample_pos := 0.0
var ring := PackedFloat32Array()  # recent 16 kHz audio for pre-roll
var take := PackedFloat32Array()
var take_started_ms := 0
var quiet_s := 0.0
var noise_floor := 1e-5
var peak := 0.0

@onready var setup_box: VBoxContainer = $VBox/Setup
@onready var age_row: HBoxContainer = $VBox/Setup/Ages
@onready var gender_row: HBoxContainer = $VBox/Setup/Genders
@onready var list_menu: OptionButton = $VBox/Setup/ListRow/List
@onready var start_button: Button = $VBox/Setup/Start
@onready var word_label: Label = $VBox/Word
@onready var meter: ProgressBar = $VBox/Meter
@onready var info: Label = $VBox/Info
@onready var stats: Label = $VBox/Stats


func _ready() -> void:
	var age_group := ButtonGroup.new()
	for a in AGES:
		var b := _toggle_button(a, age_group)
		b.pressed.connect(func(): age = a.replace("-", "to"); _refresh_setup())
		age_row.add_child(b)
	var gender_group := ButtonGroup.new()
	for g in GENDERS:
		var b := _toggle_button(g, gender_group)
		b.pressed.connect(func(): gender = GENDERS[g]; _refresh_setup())
		gender_row.add_child(b)
	for f in DirAccess.get_files_at("res://data/wordlists"):
		if f.ends_with(".json"):
			list_menu.add_item(f.get_basename())
			if f.get_basename() == "calibration":
				list_menu.select(list_menu.item_count - 1)
	start_button.pressed.connect(_start_session)
	_refresh_setup()
	_setup_mic()
	word_label.text = ""
	info.text = "Click the reader's age and gender, then Start."


func _toggle_button(text: String, group: ButtonGroup) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.button_group = group
	b.custom_minimum_size = Vector2(72, 56)
	b.add_theme_font_size_override("font_size", 24)
	return b


func _refresh_setup() -> void:
	start_button.disabled = age == "" or gender == ""
	start_button.text = "Start recording" if not start_button.disabled else "Pick age and gender"


func _setup_mic() -> void:
	var bus := AudioServer.bus_count
	AudioServer.add_bus(bus)
	AudioServer.set_bus_name(bus, "RecMic")
	AudioServer.set_bus_mute(bus, true)
	capture = AudioEffectCapture.new()
	capture.buffer_length = 1.0
	AudioServer.add_bus_effect(bus, capture)
	var mic := AudioStreamPlayer.new()
	mic.stream = AudioStreamMicrophone.new()
	mic.bus = "RecMic"
	add_child(mic)
	mic.play()
	mic_rate = AudioServer.get_mix_rate()


func _start_session() -> void:
	var list_id := list_menu.get_item_text(list_menu.selected)
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/wordlists/%s.json" % list_id))
	words = data["words"].filter(func(w): return true)
	for o in data.get("others", []):
		words.append("_other:" + o)
	var stamp := Time.get_datetime_string_from_system().replace(":", "").replace("-", "").replace("T", "-")
	session_dir = "user://recordings/%s%s/%s" % [age, gender, stamp]
	DirAccess.make_dir_recursive_absolute(session_dir)
	var meta := {
		"age": age, "gender": gender, "word_list": list_id, "started": Time.get_datetime_string_from_system(),
		"input_device": AudioServer.input_device, "mix_rate": mic_rate, "sample_rate": SAMPLE_RATE,
		"os": OS.get_name(), "godot": Engine.get_version_info()["string"],
	}
	FileAccess.open(session_dir + "/session.json", FileAccess.WRITE).store_string(JSON.stringify(meta, "  "))
	FileAccess.open(session_dir + "/manifest.csv", FileAccess.WRITE).store_line(
		"file,word,round,take_started,duration_s,peak,kind")
	setup_box.visible = false
	_next_word()


func _next_word() -> void:
	if queue.is_empty():
		round_no += 1
		queue = words.duplicate()
		queue.shuffle()
	current = queue.pop_front()
	if current.begins_with("_other:"):
		word_label.text = current.trim_prefix("_other:")
		word_label.modulate = Color(0.7, 0.85, 1.0)
		info.text = "Not a game word - just say or do this naturally."
	else:
		word_label.text = current
		word_label.modulate = Color.WHITE
		info.text = "Read the word out loud."
	_update_stats()
	state = State.WAITING


func _process(_delta: float) -> void:
	var n := capture.get_frames_available()
	if n == 0 or state == State.SETUP:
		return
	handle_block(_to_16k(capture.get_buffer(n)))


## One block of 16 kHz mono audio (public so tests can feed WAV data).
func handle_block(block: PackedFloat32Array) -> void:
	var e := 0.0
	for x in block:
		e += x * x
	e /= max(1, block.size())
	meter.value = clampf(sqrt(e) * 800.0, 0.0, 100.0)
	var voiced: bool = e > maxf(noise_floor * 10.0, 2e-6)
	match state:
		State.WAITING:
			if not voiced:
				noise_floor = lerpf(noise_floor, e, 0.05)
			ring.append_array(block)
			var keep := int(PREROLL_S * SAMPLE_RATE)
			if ring.size() > keep:
				ring = ring.slice(ring.size() - keep)
			if voiced:
				take = ring.duplicate()
				take_started_ms = Time.get_ticks_msec()
				quiet_s = 0.0
				peak = 0.0
				state = State.RECORDING
				word_label.modulate = Color(1.0, 0.55, 0.5)
		State.RECORDING:
			take.append_array(block)
			for x in block:
				peak = maxf(peak, absf(x))
			quiet_s = 0.0 if voiced else quiet_s + float(block.size()) / SAMPLE_RATE
			if quiet_s >= TAIL_SILENCE_S or take.size() >= MAX_TAKE_S * SAMPLE_RATE:
				_save_take()
		_:
			pass


func _to_16k(frames: PackedVector2Array) -> PackedFloat32Array:
	# Linear-interpolation downsample to 16 kHz mono.
	var out := PackedFloat32Array()
	var step := mic_rate / SAMPLE_RATE
	while resample_pos < frames.size() - 1:
		var i := int(resample_pos)
		var t := resample_pos - i
		out.append(lerpf(0.5 * (frames[i].x + frames[i].y), 0.5 * (frames[i + 1].x + frames[i + 1].y), t))
		resample_pos += step
	resample_pos = maxf(0.0, resample_pos - frames.size())
	return out


func _save_take() -> void:
	var is_other := current.begins_with("_other:")
	var name := "_other" if is_other else current.validate_filename()
	var path := "%s/%s__r%d.wav" % [session_dir, name, round_no]
	var k := 2
	while FileAccess.file_exists(path):
		path = "%s/%s__r%d_%d.wav" % [session_dir, name, round_no, k]
		k += 1
	_write_wav(path, take)
	var dur := float(take.size()) / SAMPLE_RATE
	var f := FileAccess.open(session_dir + "/manifest.csv", FileAccess.READ_WRITE)
	f.seek_end()
	f.store_line("%s,%s,%d,%s,%.2f,%.3f,%s" % [path.get_file(), "\"%s\"" % current.trim_prefix("_other:"),
		round_no, Time.get_datetime_string_from_system(), dur, peak, "other" if is_other else "word"])
	f.close()
	last_take_path = path
	last_take_word = current
	takes += 1
	ring = PackedFloat32Array()
	word_label.modulate = Color(0.4, 1.0, 0.6)
	info.text = "Got it!"
	state = State.BETWEEN
	get_tree().create_timer(NEXT_WORD_DELAY_S).timeout.connect(func():
		if state == State.BETWEEN:
			_next_word())


func _unhandled_input(event: InputEvent) -> void:
	if state == State.SETUP or not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_SPACE:
			if state == State.PAUSED:
				_next_word()
			elif state in [State.WAITING, State.BETWEEN]:
				queue.push_front(current)
				state = State.PAUSED
				word_label.text = "paused"
				info.text = "SPACE to carry on, ESC to finish."
		KEY_R:
			if last_take_path != "" and state in [State.WAITING, State.BETWEEN]:
				DirAccess.remove_absolute(last_take_path)
				_mark_redo(last_take_path.get_file())
				queue.push_front(current)
				queue.push_front(last_take_word)
				last_take_path = ""
				takes -= 1
				_next_word()
		KEY_S:
			if state in [State.WAITING, State.BETWEEN]:
				_next_word()
		KEY_ESCAPE:
			_finish()


func _mark_redo(file: String) -> void:
	var f := FileAccess.open(session_dir + "/manifest.csv", FileAccess.READ_WRITE)
	f.seek_end()
	f.store_line("%s,,,%s,,,deleted" % [file, Time.get_datetime_string_from_system()])
	f.close()


func _finish() -> void:
	state = State.DONE
	word_label.text = "Thank you!"
	word_label.modulate = Color(1.0, 0.85, 0.3)
	info.text = "%d takes saved to %s" % [takes, ProjectSettings.globalize_path(session_dir)] if session_dir != "" else ""


func _update_stats() -> void:
	stats.text = "round %d  |  %d takes this session  |  SPACE pause  R redo  S skip  ESC finish" % [round_no, takes]


static func _write_wav(path: String, samples: PackedFloat32Array) -> void:
	var pcm := PackedByteArray()
	pcm.resize(samples.size() * 2)
	for i in samples.size():
		pcm.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer("RIFF".to_ascii_buffer())
	f.store_32(36 + pcm.size())
	f.store_buffer("WAVEfmt ".to_ascii_buffer())
	f.store_32(16)
	f.store_16(1)
	f.store_16(1)
	f.store_32(SAMPLE_RATE)
	f.store_32(SAMPLE_RATE * 2)
	f.store_16(2)
	f.store_16(16)
	f.store_buffer("data".to_ascii_buffer())
	f.store_32(pcm.size())
	f.store_buffer(pcm)
	f.close()
