extends SceneTree
## Headless check of the recorder: feed real WAV words through a session and
## verify takes, rounds and the manifest are written correctly.
##   godot --headless --path godot --script res://tests/recorder_test.gd -- <dir with wavs>

func _initialize() -> void:
	var rec = load("res://scenes/recorder.tscn").instantiate()
	root.add_child(rec)
	_run.call_deferred(rec, OS.get_cmdline_user_args()[0])


func _run(rec, clips: String) -> void:
	await process_frame
	rec.age = "8"
	rec.gender = "f"
	rec.words = ["cat", "dog", "go"]
	rec._start_session()
	rec.words = ["cat", "dog", "go"]  # small list so it loops quickly
	rec.queue = []
	rec.round_no = 0
	rec._next_word()
	var silence := PackedFloat32Array()
	silence.resize(320)
	silence.fill(0.0)
	for i in 6:  # two full rounds
		var word: String = rec.current
		var wav: PackedFloat32Array = load("res://tests/headless_wav_test.gd")._load_wav16(clips.path_join(word).path_join(DirAccess.get_files_at(clips.path_join(word))[i]))
		for k in 30:
			rec.handle_block(silence)  # room tone; learns the noise floor
		for k in range(0, wav.size(), 320):
			rec.handle_block(wav.slice(k, k + 320))
		for k in 60:
			rec.handle_block(silence)
		# skip the between-words timer
		if rec.state == rec.State.BETWEEN:
			rec._next_word()
	var files := DirAccess.get_files_at(rec.session_dir)
	print("session: ", ProjectSettings.globalize_path(rec.session_dir))
	print("files: ", files)
	print(FileAccess.get_file_as_string(rec.session_dir + "/manifest.csv"))
	quit(0 if rec.takes == 6 else 1)
