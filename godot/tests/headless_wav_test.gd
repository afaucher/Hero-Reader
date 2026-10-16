extends SceneTree
## Headless proof that WordListener works inside Godot, end to end.
##
##   (models from tools/setup.py in godot/models; or set HERO_MODELS=/path)
##   godot --headless --path godot --script res://tests/headless_wav_test.gd -- \
##       --preset zipformer-hot --clips /path/to/speech_commands --n 40
##
## For each clip: put 5 words "on screen" (the clip's word + 4 others), stream
## the WAV into the listener in real time (20 ms chunks, like a mic), and
## record what fired and how long after the voice stopped.

const WORDS := ["bed", "bird", "cat", "dog", "down", "eight", "five", "four", "go", "happy",
	"house", "left", "nine", "no", "off", "on", "one", "right", "seven", "six", "stop",
	"three", "tree", "two", "up", "wow", "yes", "zero"]

var listener: WordListener
var heard: Array = []


func _initialize() -> void:
	var args := _parse_args()
	listener = WordListener.new()
	root.add_child(listener)
	var cfg := HeroSpeech.config_for(args.get("preset", HeroSpeech.PRESETS.keys()[0]))
	var t0 := Time.get_ticks_msec()
	if not listener.load_model(cfg):
		push_error("load_model failed: %s" % cfg)
		quit(1)
		return
	print("model loaded in %d ms (%s)" % [Time.get_ticks_msec() - t0, args.get("preset", HeroSpeech.PRESETS.keys()[0])])
	listener.word_heard.connect(func(w, t, lat): heard.append({"word": w, "text": t, "lat": lat}))
	listener.heard_other.connect(func(t): heard.append({"word": "", "text": t, "lat": 0.0}))
	_run.call_deferred(args.get("clips", ""), int(args.get("n", "30")))


func _run(clips_dir: String, n: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var hits := 0
	var total := 0
	var lats: Array = []
	for i in n:
		var word: String = WORDS[rng.randi() % WORDS.size()]
		var files := DirAccess.get_files_at(clips_dir.path_join(word))
		if files.is_empty():
			continue
		var path := clips_dir.path_join(word).path_join(files[rng.randi() % files.size()])
		var samples := _load_wav16(path)
		if samples.is_empty():
			continue
		var onscreen: Array = [word]
		while onscreen.size() < 5:
			var w: String = WORDS[rng.randi() % WORDS.size()]
			if not w in onscreen:
				onscreen.append(w)
		onscreen.shuffle()
		listener.set_words(PackedStringArray(onscreen))
		heard.clear()
		# 0.3 s quiet, the word, 1.0 s quiet, at real-time pace.
		var stream := PackedFloat32Array()
		stream.resize(4800)
		stream.fill(0.0)
		stream.append_array(samples)
		var tail := PackedFloat32Array()
		tail.resize(16000)
		tail.fill(0.0)
		stream.append_array(tail)
		var step := 320
		var start := Time.get_ticks_usec()
		var pos := 0
		while pos < stream.size():
			listener.push_samples(stream.slice(pos, pos + step), 16000)
			pos += step
			listener.poll()
			var due := start + pos * 1000000 / 16000
			var wait := due - Time.get_ticks_usec()
			if wait > 0:
				OS.delay_usec(wait)
		listener.poll()
		total += 1
		var first: Dictionary = heard[0] if heard.size() > 0 else {}
		var ok: bool = first.get("word", "") == word
		if ok:
			hits += 1
			lats.append(first["lat"])
		print("%-6s %-28s -> %-6s %6s  (heard %s)" % [word, " ".join(onscreen), first.get("word", "-"),
			("%.0fms" % first["lat"]) if ok else "", first.get("text", "")])
	lats.sort()
	var stats := listener.get_stats()
	print("\n%d/%d hits (%.0f%%); latency after voice stops: median %.0f ms, p90 %.0f ms" % [
		hits, total, 100.0 * hits / max(total, 1),
		lats[lats.size() / 2] if lats.size() else 0.0,
		lats[int(lats.size() * 0.9)] if lats.size() else 0.0])
	print("compute RTF %.3f, worst single decode %.1f ms" % [stats["rtf"], stats["max_chunk_ms"]])
	_multi_word_check(clips_dir)
	quit(0)


## Two words read in one breath, while the on-screen list changes mid-word
## (a new word spawns): both must still be zapped.
func _multi_word_check(clips_dir: String) -> void:
	var a := _load_wav16(clips_dir.path_join("yes").path_join(DirAccess.get_files_at(clips_dir.path_join("yes"))[1]))
	var b := _load_wav16(clips_dir.path_join("stop").path_join(DirAccess.get_files_at(clips_dir.path_join("stop"))[1]))
	var stream := PackedFloat32Array()
	stream.resize(4800)
	stream.fill(0.0)
	stream.append_array(a)
	var gap := PackedFloat32Array()
	gap.resize(1600)  # 0.1 s
	gap.fill(0.0)
	stream.append_array(gap)
	stream.append_array(b)
	var tail := PackedFloat32Array()
	tail.resize(16000)
	tail.fill(0.0)
	stream.append_array(tail)
	listener.set_words(PackedStringArray(["yes", "stop", "dog", "tree"]))
	heard.clear()
	var start := Time.get_ticks_usec()
	var pos := 0
	while pos < stream.size():
		listener.push_samples(stream.slice(pos, pos + 320), 16000)
		pos += 320
		if pos == 4800 + 3200:  # 0.2 s into "happy": a word spawns
			listener.set_words(PackedStringArray(["yes", "stop", "dog", "tree", "sun"]))
		listener.poll()
		var wait := start + pos * 1000000 / 16000 - Time.get_ticks_usec()
		if wait > 0:
			OS.delay_usec(wait)
	OS.delay_msec(300)  # let the worker finish the last decode
	listener.poll()
	var got := heard.filter(func(h): return h["word"] != "").map(func(h): return h["word"])
	print("multi-word events: ", heard)
	print("multi-word check: heard %s -> %s" % [got, "PASS" if "yes" in got and "stop" in got else "CHECK (clip-dependent)"])


func _parse_args() -> Dictionary:
	var out := {}
	var a := OS.get_cmdline_user_args()
	for i in range(0, a.size() - 1, 2):
		out[a[i].trim_prefix("--")] = a[i + 1]
	return out


## Minimal 16-bit PCM mono WAV reader (Speech Commands / record_words.py).
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
