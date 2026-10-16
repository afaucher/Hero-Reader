extends SceneTree
## Headless end-to-end check with Windows text-to-speech clips: no microphone,
## no Speech Commands dataset.
##
##   powershell -ExecutionPolicy Bypass -File tools/make_tts_clips.ps1
##   godot --headless --path godot --script res://tests/tts_match_test.gd -- \
##       --clips <abs dir, default godot/tests/tts_clips> [--preset zipformer-hot]
##
## Clip names (from make_tts_clips.ps1): word_<w>.wav (must zap <w>),
## other_<x>.wav (non-target speech: nothing may fire), multi_<a>_<b>.wav
## (several words in one breath: each must fire).
## For each clip, 5 words go "on screen" (targets + others that don't sound
## like them), the clip is streamed in real time (20 ms chunks, 0.5 s silence
## either side), and word_heard / heard_other / voice_started / hypothesis
## are recorded. Exit 0 if hit rate >= 70% and nothing wrong was zapped.

const WORDS := ["cat", "hat", "dog", "sun", "red", "big", "run", "go", "no", "two", "see", "the"]
## Never put these on screen next to each other: the test is about hearing
## the right word, not about choosing between rhymes.
const SOUND_ALIKE := [["cat", "hat"], ["sun", "run"], ["go", "no", "two"]]
const DEFAULT_PRESETS := ["parakeet-110m-hot", "zipformer-hot"]
const RATE := 16000
const STEP := 320  # 20 ms
const PAD := 8000  # 0.5 s silence before and after
const MIN_HIT_RATE := 0.7

var listener: WordListener
var words_heard: Array = []   # {word, text, lat}
var others: Array = []        # heard_other texts
var hyps: Array = []          # {text, final, detail}
var voice_starts := 0
var has_hyp := false


func _initialize() -> void:
	_run.call_deferred(_parse_args())


func _run(args: Dictionary) -> void:
	var clips_dir: String = args.get("clips", ProjectSettings.globalize_path("res://tests/tts_clips"))
	var clips := _list_clips(clips_dir)
	if clips.is_empty():
		push_error("no clips in %s (run tools/make_tts_clips.ps1)" % clips_dir)
		quit(1)
		return
	var presets: Array = [args["preset"]] if args.has("preset") else DEFAULT_PRESETS
	var ok := true
	var summaries: Array = []
	for preset in presets:
		var s := _run_preset(preset, clips)
		if s.is_empty():
			ok = false
			continue
		summaries.append(s)
		ok = ok and s["pass"]
	print("\n==== summary ====")
	for s in summaries:
		print("%-18s hits %d/%d (%.0f%%)  wrong %d  false accepts %d/%d  median latency %.0f ms  RTF %.3f  -> %s" % [
			s["preset"], s["hits"], s["targets"], 100.0 * s["hits"] / max(s["targets"], 1), s["wrong"],
			s["false_accepts"], s["non_targets"], s["median_lat"], s["rtf"], "PASS" if s["pass"] else "FAIL"])
	quit(0 if ok else 1)


func _run_preset(preset: String, clips: Array) -> Dictionary:
	if listener:
		listener.queue_free()
		listener = null
	listener = WordListener.new()
	root.add_child(listener)
	var t0 := Time.get_ticks_msec()
	if not listener.load_model(HeroSpeech.config_for(preset)):
		push_error("load_model failed for %s" % preset)
		return {}
	print("\n==== %s (model loaded in %d ms) ====" % [preset, Time.get_ticks_msec() - t0])
	listener.word_heard.connect(func(w, t, lat): words_heard.append({"word": w, "text": t, "lat": lat}))
	listener.heard_other.connect(func(t): others.append(t))
	listener.voice_started.connect(func(): voice_starts += 1)
	has_hyp = listener.has_signal("hypothesis")
	if has_hyp:
		# connect() by name: the script must still parse with an older DLL.
		listener.connect("hypothesis", func(text, final, detail): hyps.append({"text": text, "final": final, "detail": detail}))
	else:
		print("WARNING: WordListener has no 'hypothesis' signal (old DLL?); hypotheses not shown")

	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var hits := 0
	var targets := 0
	var wrong := 0
	var false_accepts := 0
	var non_targets := 0
	var lats: Array = []
	for clip in clips:
		var samples := _load_wav16(clip["path"])
		if samples.is_empty():
			print("skip unreadable %s" % clip["path"])
			continue
		var expected: Array = clip["expected"]
		var onscreen := _pick_onscreen(expected, rng)
		_stream(samples, onscreen)

		var fired: Array = words_heard.map(func(h): return h["word"])
		var bad: Array = fired.filter(func(w): return not w in expected)
		var status: String
		var lat_txt := ""
		if expected.is_empty():
			non_targets += 1
			status = "ok" if fired.is_empty() else "FALSE"
			if not fired.is_empty():
				false_accepts += 1
		else:
			targets += 1
			var all_heard := expected.all(func(w): return w in fired)
			if not bad.is_empty():
				status = "WRONG"
				wrong += 1
			elif all_heard:
				status = "hit"
				hits += 1
			else:
				status = "miss"
			for h in words_heard:
				if h["word"] in expected:
					lats.append(h["lat"])
					lat_txt += "%.0fms " % h["lat"]
		var label: String = clip["label"]
		print("%-12s [%s] %-5s %s fired=%s%s%s" % [label, " ".join(onscreen), status, lat_txt,
			fired, (" other=%s" % [others]) if not others.is_empty() else "", "" if voice_starts > 0 else " (no voice_started)"])
		if has_hyp:
			print("    hyp: %s" % _hyp_summary())
			var shown: Array = []
			for w in expected + bad:
				if not w in shown:
					shown.append(w)
					print("    %s%s: %s" % ["" if w in expected else "zapped ", w, _detail_for(w)])

	lats.sort()
	var median: float = lats[lats.size() / 2] if lats.size() else 0.0
	var stats := listener.get_stats()
	var rate: float = float(hits) / max(targets, 1)
	var passed: bool = rate >= MIN_HIT_RATE and wrong == 0 and false_accepts == 0
	print("%s: hits %d/%d (%.0f%%), wrong %d, false accepts %d/%d, median latency %.0f ms, RTF %.3f" % [
		preset, hits, targets, 100.0 * rate, wrong, false_accepts, non_targets, median, stats["rtf"]])
	return {"preset": preset, "hits": hits, "targets": targets, "wrong": wrong,
		"false_accepts": false_accepts, "non_targets": non_targets, "median_lat": median,
		"rtf": stats["rtf"], "pass": passed}


## 0.5 s silence, the clip, 0.5 s silence, at real-time pace; then flush and
## give the worker time to finish.
func _stream(samples: PackedFloat32Array, onscreen: Array) -> void:
	listener.reset()
	listener.set_words(PackedStringArray(onscreen))
	OS.delay_msec(50)
	listener.poll()
	words_heard.clear()
	others.clear()
	hyps.clear()
	voice_starts = 0

	var stream := PackedFloat32Array()
	stream.resize(PAD)
	stream.fill(0.0)
	stream.append_array(samples)
	var tail := PackedFloat32Array()
	tail.resize(PAD)
	tail.fill(0.0)
	stream.append_array(tail)
	var start := Time.get_ticks_usec()
	var pos := 0
	while pos < stream.size():
		listener.push_samples(stream.slice(pos, pos + STEP), RATE)
		pos += STEP
		listener.poll()
		var wait := start + pos * 1000000 / RATE - Time.get_ticks_usec()
		if wait > 0:
			OS.delay_usec(wait)
	listener.flush()
	for i in 25:  # 0.5 s
		OS.delay_msec(20)
		listener.poll()


func _pick_onscreen(expected: Array, rng: RandomNumberGenerator) -> Array:
	var avoid: Array = expected.duplicate()
	for w in expected:
		for g in SOUND_ALIKE:
			if w in g:
				avoid.append_array(g)
	var out: Array = expected.duplicate()
	var pool: Array = WORDS.filter(func(w): return not w in avoid)
	while out.size() < 5 and not pool.is_empty():
		var w: String = pool[rng.randi() % pool.size()]
		pool.erase(w)
		out.append(w)
		for g in SOUND_ALIKE:  # don't put two rhymes on screen together either
			if w in g:
				pool = pool.filter(func(p): return not p in g)
	# Same order every run, target not always first.
	var shuffled: Array = []
	while not out.is_empty():
		shuffled.append(out.pop_at(rng.randi() % out.size()))
	return shuffled


## Partials (consecutive duplicates dropped) then finals.
func _hyp_summary() -> String:
	var parts: Array = []
	var finals: Array = []
	for h in hyps:
		var t := '"%s"' % h["text"]
		if h["final"]:
			finals.append(t)
		elif parts.is_empty() or parts[-1] != t:
			parts.append(t)
	return "%s | final %s" % [" ".join(parts) if not parts.is_empty() else "-", " ".join(finals) if not finals.is_empty() else "-"]


## Match detail for one on-screen word: from the last final hypothesis that
## matched it, else the last final, else the last partial.
func _detail_for(word: String) -> String:
	var src: Dictionary = {}
	var matched: Dictionary = {}
	for h in hyps:
		if h["final"] or src.is_empty() or not src["final"]:
			src = h
		if h["final"]:
			for d in h["detail"]:
				if d.get("word", "") == word and d.get("kind", "") != "":
					matched = h
	if not matched.is_empty():
		src = matched
	if src.is_empty():
		return "no hypothesis"
	for d in src["detail"]:
		if d.get("word", "") == word:
			return "kind=%s token=%s distance=%d phones %s ~ %s%s" % [
				d.get("kind", "") if d.get("kind", "") != "" else "none", d.get("token", ""), d.get("distance", -1),
				d.get("word_phones", ""), d.get("token_phones", ""), "" if src["final"] else " (partial)"]
	return "not in detail"


## word_<w>.wav, other_<x>.wav, multi_<a>_<b>.wav
func _list_clips(dir: String) -> Array:
	var out: Array = []
	var files := Array(DirAccess.get_files_at(dir))
	files.sort_custom(func(a, b): return _order(a) < _order(b))
	for f in files:
		if not f.ends_with(".wav"):
			continue
		var stem: String = f.get_basename()
		var kind := stem.get_slice("_", 0)
		var rest := stem.substr(kind.length() + 1)
		var expected: Array = []
		if kind == "word":
			expected = [rest]
		elif kind == "multi":
			expected = Array(rest.split("_"))
		elif kind != "other":
			continue
		out.append({"path": dir.path_join(f), "expected": expected,
			"label": rest.replace("_", " ") if kind != "other" else "(%s)" % rest.replace("_", " ")})
	return out


func _order(f: String) -> String:
	return ("0" if f.begins_with("word_") else "1" if f.begins_with("multi_") else "2") + f


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
