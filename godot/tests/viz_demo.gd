extends SceneTree
## Plays recorded clips into the Word match scene instead of the mic and saves
## a screenshot after each one: a mic-free look at the match visualization.
## Needs a window (not --headless) so the screen renders.
##
##   godot --path godot --script res://tests/viz_demo.gd -- \
##         --clips <dir with word_*.wav / other_*.wav> [--preset zipformer-hot] [--out <dir>]
##
## Clips are 16 kHz mono 16-bit WAVs, e.g. from tools/make_tts_clips.ps1.

const WORDS := ["cat", "dog", "red", "big", "sun"]
const PLAY := ["word_dog", "other_banana", "word_hat", "word_red", "multi_cat_dog"]


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := {"clips": "", "preset": "", "out": ProjectSettings.globalize_path("user://viz_demo")}
	var a := OS.get_cmdline_user_args()
	for i in range(0, a.size() - 1, 2):
		args[a[i].trim_prefix("--")] = a[i + 1]
	DirAccess.make_dir_recursive_absolute(args["out"])

	var viz: Control = load("res://scenes/match_viz.tscn").instantiate()
	viz.feed_mic = false
	root.add_child(viz)
	await process_frame
	if args["preset"] != "":
		for i in viz.preset_menu.item_count:
			if viz.preset_menu.get_item_text(i) == args["preset"]:
				viz.preset_menu.select(i)
				viz._start_listener()
	for _i in 600:
		if viz.listener != null:
			break
		await process_frame
	if viz.listener == null:
		printerr("model did not load")
		quit(1)
		return
	viz._new_words(WORDS)
	await _silence(viz, 0.5)

	for name in PLAY:
		var path: String = args["clips"].path_join(name + ".wav")
		if not FileAccess.file_exists(path):
			print("skip (missing): ", path)
			continue
		var samples := _load_wav16(path)
		await _silence(viz, 0.3)
		await _feed(viz, samples)
		await _silence(viz, 0.9)
		var png: String = args["out"].path_join(name + ".png")
		root.get_texture().get_image().save_png(png)
		print("%-16s hearing=%s  -> %s" % [name, viz.hearing.text, png])
		viz._new_words(WORDS)  # same five words for every clip
	print(viz.log_box.get_parsed_text())
	quit(0)


# Real-time push in 20 ms steps, like the mic would deliver.
func _feed(viz: Control, samples: PackedFloat32Array) -> void:
	var step := 320
	var t0 := Time.get_ticks_usec()
	var pos := 0
	while pos < samples.size():
		var due := int((Time.get_ticks_usec() - t0) / 1e6 * 16000)
		if due > pos:
			var end := mini(due, samples.size())
			for p in range(pos, end, step):
				viz.listener.push_samples(samples.slice(p, mini(p + step, end)), 16000)
			pos = end
		await process_frame


func _silence(viz: Control, seconds: float) -> void:
	var z := PackedFloat32Array()
	z.resize(int(seconds * 16000))
	await _feed(viz, z)


static func _load_wav16(path: String) -> PackedFloat32Array:
	# Minimal RIFF reader: finds the "data" chunk, 16-bit PCM mono.
	var b := FileAccess.get_file_as_bytes(path)
	var out := PackedFloat32Array()
	var i := 12
	while i + 8 <= b.size():
		var id := b.slice(i, i + 4).get_string_from_ascii()
		var n := b.decode_u32(i + 4)
		if id == "data":
			out.resize(n / 2)
			for k in n / 2:
				out[k] = b.decode_s16(i + 8 + 2 * k) / 32768.0
			return out
		i += 8 + n + (n & 1)
	return out
