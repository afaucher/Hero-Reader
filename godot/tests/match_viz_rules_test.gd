extends SceneTree
## Game rule in the Word match scene: duplicate or stale word_heard events
## change nothing; a word leaves only when it is read.
##   godot --headless --path godot --script res://tests/match_viz_rules_test.gd


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var viz: Control = load("res://scenes/match_viz.tscn").instantiate()
	viz.feed_mic = false
	root.add_child(viz)
	await process_frame
	viz._new_words(["cat", "dog", "red", "big", "sun"])
	var fails := []

	viz._on_word_heard("cat", "cat", 300.0)
	viz._on_word_heard("cat", "cat cat", 900.0)  # duplicate while zapping
	viz._on_word_heard("fox", "fox", 300.0)  # not on screen
	viz._on_heard_other("banana")  # off-list word
	if viz.n_zaps != 1 or viz.n_ignored != 2:
		fails.append("zaps=%d ignored=%d, want 1 and 2" % [viz.n_zaps, viz.n_ignored])
	for w in ["dog", "red", "big", "sun"]:
		if not w in viz.words:
			fails.append("%s left the screen without being read" % w)

	for i in 60:  # let the zap animation finish and the card be replaced
		await process_frame
	if "cat" in viz.words:
		fails.append("cat was not replaced after its zap")
	if viz.words.size() != 5:
		fails.append("expected 5 words on screen, got %d" % viz.words.size())
	viz._on_word_heard("cat", "cat", 300.0)  # late duplicate after replacement
	if viz.n_zaps != 1:
		fails.append("late duplicate zapped something")

	# A just-zapped word stays off screen for the cooldown, so a late repeat
	# can't hit a fresh copy. 7 words, 5 on screen: after cat and dog are
	# zapped, dog's replacement must be the one spare word, never cat.
	viz.world = {"words": ["cat", "dog", "red", "big", "sun", "fox", "hen"]}
	viz.confusable.clear()
	viz.cooling.clear()
	viz._new_words(["cat", "dog", "red", "big", "sun"])
	viz._on_word_heard("cat", "cat", 300.0)
	viz._on_word_heard("dog", "dog", 300.0)
	await create_timer(0.8).timeout  # zap animation (~0.45 s), well inside the cooldown
	if viz.n_zaps != 3:
		fails.append("zaps=%d after cat and dog, want 3" % viz.n_zaps)
	if "cat" in viz.words:
		fails.append("cat came back within %d ms of its zap" % viz.REZAP_COOLDOWN_MS)
	if viz.words.size() != 5 or "dog" in viz.words:
		fails.append("dog not replaced: %s" % [viz.words])

	for f in fails:
		printerr("FAIL: ", f)
	print("PASS" if fails.is_empty() else "FAIL")
	quit(0 if fails.is_empty() else 1)
