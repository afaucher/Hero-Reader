extends SceneTree
## Headless scenario test of the calibration recorder's start/stop trigger:
## proves every saved take holds the word that was on screen when it was
## recorded (no label shifted onto the next prompt).
##
##   godot --headless --path godot --script res://tests/recorder_test.gd [-- --clips <dir>]
##
## --clips defaults to godot/tests/tts_clips (word_<w>.wav, other_<x>.wav from
## tools/make_tts_clips.ps1). Each scenario prompts a known word, then feeds the
## recorder synthetic audio (clips + silence / noise) through handle_block() in
## 20 ms blocks, faster than real time. Whenever a take is saved the next prompt
## (a decoy word) goes up at once, so audio that spills past a take lands in a
## take with the wrong label and fails the test. Every saved take is played to
## a WordListener (parakeet-110m-hot): the word it hears must equal the label in
## manifest.csv. Writes only to user://test_recordings and deletes it after.
## Exit 0 only if every scenario passes.

const RATE := 16000
const BLOCK := 320  # 20 ms
const PRESET := "parakeet-110m-hot"
const WORDS := ["cat", "hat", "dog", "sun", "red", "big", "run", "go", "no", "two", "see", "the"]
const DECOY := "hat"  # the "next" prompt; must never be heard in a take
const ROOM_DB := -70.0  # background room tone between sounds
const TEST_ROOT := "user://test_recordings"

var rec
var clips_dir := ""
var rng := RandomNumberGenerator.new()
var pos := 0  # samples fed in the current scenario
var events: Array = []  # takes in the current scenario: {start, end, label, file, voiced, saved}
var cur_start := -1
var listener: WordListener
var heard: Array = []
var others: Array = []
var finals: Array = []  # final hypothesis texts
var last_text := ""


func _initialize() -> void:
	rng.seed = 11
	_run.call_deferred(_parse_args())


func _run(args: Dictionary) -> void:
	clips_dir = args.get("clips", ProjectSettings.globalize_path("res://tests/tts_clips"))
	if not FileAccess.file_exists(clips_dir.path_join("word_cat.wav")):
		push_error("no clips in %s (run: powershell -ExecutionPolicy Bypass -File tools/make_tts_clips.ps1)" % clips_dir)
		quit(1)
		return
	listener = WordListener.new()
	root.add_child(listener)
	if not listener.load_model(HeroSpeech.config_for(PRESET)):
		push_error("load_model failed for %s" % PRESET)
		quit(1)
		return
	listener.word_heard.connect(func(w, _t, _lat): heard.append(w))
	listener.heard_other.connect(func(t): others.append(t))
	if listener.has_signal("hypothesis"):
		listener.connect("hypothesis", func(text, final, _d):
			if final and text != "":
				finals.append(text))

	rec = load("res://scenes/recorder.tscn").instantiate()
	if args.has("recorder"):  # try a modified recorder script without editing the real one
		rec.set_script(load(args["recorder"]))
	root.add_child(rec)
	await process_frame
	rec.set_process(false)  # no microphone: we feed audio ourselves
	rec.recordings_root = TEST_ROOT  # never touch the family's user://recordings
	rec.age = "8"
	rec.gender = "f"
	rec._start_session()
	if not rec.session_dir.begins_with(TEST_ROOT):
		push_error("session went to %s, refusing to continue" % rec.session_dir)
		quit(1)
		return
	rec.words = WORDS.duplicate()
	rec.queue = []
	rec.round_no = 1

	var results: Array = []
	results.append(_scenario_clean("cat"))
	results.append(_scenario_click("dog"))
	results.append(_scenario_um("sun"))
	results.append(_scenario_sounded_out("big"))
	results.append(_scenario_hum("red"))
	results.append(_scenario_back_to_back("go", "see"))
	results.append(_scenario_quiet("run"))

	# Verify every take against the manifest and the recogniser.
	var manifest := _read_manifest()
	var all_ok := true
	print("")
	for r in results:
		for t in r["takes"]:
			if not t["saved"]:
				continue
			var label: String = manifest.get(t["file"], "?")
			t["manifest"] = label
			t["heard"] = _recognise(rec.session_dir.path_join(t["file"]))
			t["text"] = last_text
			if label != t["label"]:
				r["why"].append("manifest says %s for %s, recorder said %s" % [label, t["file"], t["label"]])
			if t["heard"] != [label]:
				r["why"].append("ASR heard %s in take labelled %s" % [t["heard"], label])
		var ok: bool = r["why"].is_empty()
		all_ok = all_ok and ok
		var saved: Array = r["takes"].filter(func(t): return t["saved"])
		var dropped: Array = r["takes"].filter(func(t): return not t["saved"])
		print("%s %-14s takes=%d labels=%s heard=%s%s" % ["PASS" if ok else "FAIL", r["name"], saved.size(),
			saved.map(func(t): return t.get("manifest", t["label"])), saved.map(func(t): return t.get("heard", [])),
			(" dropped=%d" % dropped.size()) if dropped.size() else ""])
		for t in r["takes"]:
			print("      %s %.2f-%.2f s  voiced %.2f s  %s%s" % ["take" if t["saved"] else "drop", t["start"] / float(RATE),
				t["end"] / float(RATE), t["voiced"], t["label"], ("  asr text \"%s\"" % t["text"]) if t.has("text") else ""])
		for w in r["why"]:
			print("      why: %s" % w)

	_cleanup()
	rec.free()
	listener.free()
	print("\n%s" % ("ALL PASS" if all_ok else "SOME FAILED"))
	quit(0 if all_ok else 1)


# ---- scenarios -------------------------------------------------------------

func _scenario_clean(word: String) -> Dictionary:
	_prompt(word)
	_feed(_room(0.6))
	var span := _feed(_clip("word_" + word))
	_feed(_room(1.5))
	return _expect("clean", [[word, span]])


func _scenario_click(word: String) -> Dictionary:
	_prompt(word)
	_feed(_room(0.6))
	_feed(_noise(0.03, -20.0))
	_feed(_room(0.8))
	var span := _feed(_clip("word_" + word))
	_feed(_room(1.5))
	return _expect("click", [[word, span]])


func _scenario_um(word: String) -> Dictionary:
	_prompt(word)
	_feed(_room(0.6))
	_feed(_clip("other_um"))
	_feed(_room(0.4))
	var span := _feed(_clip("word_" + word))
	_feed(_room(1.5))
	return _expect("um-then-word", [[word, span]])


func _scenario_sounded_out(word: String) -> Dictionary:
	_prompt(word)
	_feed(_room(0.6))
	var c := _clip("word_" + word)
	# Split at the quietest 10 ms in the middle third (between two sounds,
	# e.g. "ca... t"), as a child sounding the word out would.
	var mid := c.size() / 2
	var best := INF
	for i in range(c.size() / 3, 2 * c.size() / 3 - 160, 80):
		var e := 0.0
		for k in 160:
			e += c[i + k] * c[i + k]
		if e < best:
			best = e
			mid = i + 80
	var a := _feed(c.slice(0, mid))
	_feed(_room(0.5))
	var b := _feed(c.slice(mid))
	_feed(_room(1.5))
	return _expect("sounded-out", [[word, [a[0], b[1]]]])


func _scenario_hum(word: String) -> Dictionary:
	_prompt(word)
	_feed(_noise(3.0, -60.0))
	return _expect("room-hum", [])


func _scenario_back_to_back(first: String, second: String) -> Dictionary:
	_prompt(first, second)
	_feed(_room(0.6))
	var span_a := _feed(_clip("word_" + first))
	# Silence until the first take is saved; _feed then puts `second` up at
	# once, and the reader starts it 0.2 s later.
	var limit := pos + 5 * RATE
	while rec.current == first and pos < limit:
		_feed(_room(BLOCK / float(RATE)))
	_feed(_room(0.2))
	var span_b := _feed(_clip("word_" + second))
	_feed(_room(1.5))
	return _expect("back-to-back", [[first, span_a], [second, span_b]])


func _scenario_quiet(word: String) -> Dictionary:
	_prompt(word)
	_feed(_room(0.6))
	var c := _clip("word_" + word)
	var pk := 0.0
	for x in c:
		pk = maxf(pk, absf(x))
	var g := pow(10.0, -35.0 / 20.0) / pk
	for i in c.size():
		c[i] *= g
	var span := _feed(c)
	_feed(_room(1.5))
	var r := _expect("quiet-reader", [[word, span]])
	if not r["why"].is_empty():
		# What the recorder's voice gate saw in the word.
		var total := 0
		var run := 0
		var longest := 0
		var loudest := 0.0
		for b in range(0, c.size(), BLOCK):
			var e := 0.0
			for x in c.slice(b, b + BLOCK):
				e += x * x
			e /= BLOCK
			loudest = maxf(loudest, e)
			run = run + 1 if e > rec.MIN_VOICE_ENERGY else 0
			total += 1 if e > rec.MIN_VOICE_ENERGY else 0
			longest = maxi(longest, run)
		r["why"].append("word at -35 dBFS peak: loudest 20 ms block %.1f dBFS RMS; %.2f s above MIN_VOICE_ENERGY (%.1f dBFS), longest run %.2f s (START_VOICED_S %.2f, MIN_VOICED_S %.2f)" % [
			10.0 * log(loudest) / log(10.0), total * 0.02, 10.0 * log(rec.MIN_VOICE_ENERGY) / log(10.0),
			longest * 0.02, rec.START_VOICED_S, rec.MIN_VOICED_S])
	return r


# ---- driving the recorder --------------------------------------------------

## Put `word` on screen; when its take is saved, `next` (default the decoy)
## goes up straight away.
func _prompt(word: String, next: String = DECOY) -> void:
	pos = 0
	events = []
	cur_start = -1
	rec.queue = [word, next, DECOY, DECOY]
	rec._next_word()


## Feed samples in 20 ms blocks; returns [start, end) of what was fed.
func _feed(samples: PackedFloat32Array) -> Array:
	var start := pos
	var i := 0
	while i < samples.size():
		var block := samples.slice(i, i + BLOCK)
		var before: int = rec.state
		var word: String = rec.current
		rec.handle_block(block)
		i += block.size()
		pos += block.size()
		if before == rec.State.WAITING and rec.state == rec.State.RECORDING:
			cur_start = pos - rec.take.size()
		elif before == rec.State.RECORDING and rec.state == rec.State.BETWEEN:
			events.append({"start": pos - rec.take.size(), "end": pos, "label": word,
				"file": rec.last_take_path.get_file(), "voiced": rec.voiced_total_s, "saved": true})
			rec._next_word()  # skip the between-words timer
		elif before == rec.State.RECORDING and rec.state == rec.State.WAITING:
			events.append({"start": cur_start, "end": pos, "label": word, "file": "",
				"voiced": rec.voiced_total_s, "saved": false})
	return [start, pos]


## Check takes against the expected [word, [start, end]] list.
func _expect(name: String, expected: Array) -> Dictionary:
	var why: Array = []
	if rec.state == rec.State.RECORDING:
		why.append("still recording at end of scenario (take started at %.2f s)" % (cur_start / float(RATE)))
	var saved: Array = events.filter(func(t): return t["saved"])
	if saved.size() != expected.size():
		why.append("expected %d take(s), got %d" % [expected.size(), saved.size()])
	for e in expected:
		var w: String = e[0]
		var span: Array = e[1]
		var inside: Array = saved.filter(func(t): return t["start"] <= span[0] and t["end"] >= span[1])
		if inside.is_empty():
			why.append("'%s' (%.2f-%.2f s) not wholly inside any saved take" % [w, span[0] / float(RATE), span[1] / float(RATE)])
		elif inside[0]["label"] != w:
			why.append("'%s' landed in a take labelled %s" % [w, inside[0]["label"]])
	return {"name": name, "takes": events.duplicate(), "why": why}


# ---- audio -----------------------------------------------------------------

## Word clip trimmed to its voiced part with 60 ms either side.
func _clip(stem: String) -> PackedFloat32Array:
	var s := _load_wav16(clips_dir.path_join(stem + ".wav"))
	var first := -1
	var last := -1
	for b in range(0, s.size(), BLOCK):
		var e := 0.0
		var blk := s.slice(b, b + BLOCK)
		for x in blk:
			e += x * x
		if e / max(1, blk.size()) > 1e-5:
			if first < 0:
				first = b
			last = b + blk.size()
	if first < 0:
		return s
	var pad := int(0.06 * RATE)
	var out := s.slice(maxi(0, first - pad), mini(s.size(), last + pad))
	var room := _room(out.size() / float(RATE))
	for i in out.size():
		out[i] += room[i]
	return out


func _room(seconds: float) -> PackedFloat32Array:
	return _noise(seconds, ROOM_DB)


## White noise with the given RMS in dBFS.
func _noise(seconds: float, rms_db: float) -> PackedFloat32Array:
	var n := int(round(seconds * RATE))
	var out := PackedFloat32Array()
	out.resize(n)
	var amp := pow(10.0, rms_db / 20.0) * sqrt(3.0)  # uniform [-a, a] has RMS a/sqrt(3)
	for i in n:
		out[i] = rng.randf_range(-amp, amp)
	return out


# ---- verification ----------------------------------------------------------

## Words the recogniser hears in a WAV (all game words on screen).
## Very quiet takes are raised to a -6 dBFS peak first: this checks what is
## in the take, not how sensitive the recogniser is.
func _recognise(path: String) -> Array:
	var s := _load_wav16(path)
	var pk := 0.0
	for x in s:
		pk = maxf(pk, absf(x))
	if pk > 0.0 and pk < 0.1:
		var g := 0.5 / pk
		for i in s.size():
			s[i] *= g
	listener.reset()
	listener.set_words(PackedStringArray(WORDS))
	OS.delay_msec(50)
	listener.poll()
	heard.clear()
	others.clear()
	finals.clear()
	var pad := PackedFloat32Array()
	pad.resize(RATE / 2)
	pad.fill(0.0)
	var stream := pad.duplicate()
	stream.append_array(s)
	stream.append_array(pad)
	var t0 := Time.get_ticks_usec()
	var p := 0
	while p < stream.size():
		listener.push_samples(stream.slice(p, p + BLOCK), RATE)
		p += BLOCK
		listener.poll()
		var wait := t0 + p * 1000000 / RATE - Time.get_ticks_usec()
		if wait > 0:
			OS.delay_usec(wait)
	listener.flush()
	for i in 25:
		OS.delay_msec(20)
		listener.poll()
	var out: Array = []
	for w in heard:
		if not w in out:
			out.append(w)
	last_text = " | ".join(finals)
	return out


## file -> word from manifest.csv (deleted rows ignored).
func _read_manifest() -> Dictionary:
	var out := {}
	var lines := FileAccess.get_file_as_string(rec.session_dir + "/manifest.csv").split("\n")
	for i in range(1, lines.size()):
		var cols := lines[i].strip_edges().split(",")
		if cols.size() >= 7 and cols[6] != "deleted":
			out[cols[0]] = cols[1].trim_prefix("\"").trim_suffix("\"")
	return out


func _cleanup() -> void:
	var dir: String = rec.session_dir
	if not dir.begins_with(TEST_ROOT + "/"):
		return
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)
	# Remove the now-empty <age><gender> folder and the test root if empty.
	for d in [dir.get_base_dir(), TEST_ROOT]:
		if DirAccess.get_files_at(d).is_empty() and DirAccess.get_directories_at(d).is_empty():
			DirAccess.remove_absolute(d)


func _parse_args() -> Dictionary:
	var out := {}
	var a := OS.get_cmdline_user_args()
	for i in range(0, a.size() - 1, 2):
		out[a[i].trim_prefix("--")] = a[i + 1]
	return out


## Minimal 16-bit PCM mono WAV reader.
static func _load_wav16(path: String) -> PackedFloat32Array:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PackedFloat32Array()
	f.seek(12)
	var out := PackedFloat32Array()
	while f.get_position() + 8 <= f.get_length():
		var id := f.get_buffer(4).get_string_from_ascii()
		var size := f.get_32()
		if id == "data":
			var pcm := f.get_buffer(size)
			out.resize(size / 2)
			for i in out.size():
				out[i] = pcm.decode_s16(i * 2) / 32768.0
			break
		f.seek(f.get_position() + size + (size & 1))
	return out
