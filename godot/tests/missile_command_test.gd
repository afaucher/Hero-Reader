extends SceneTree
## Headless smoke test for the Missile Command scene (no mic, no model):
## injects recognizer events and checks the house rules.
##
##   godot --headless --path godot --script res://tests/missile_command_test.gd

var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	print("%s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		failures += 1


func _run() -> void:
	var game: Control = load("res://scenes/game/missile_command.tscn").instantiate()
	game.use_mic = false
	game.auto_spawn = false
	root.add_child(game)
	await process_frame

	# L1, World 1, level 1.
	game.reading_idx = 1
	game._load_worlds()
	game.world_idx = 0
	game.level_num = 1
	game.start_level()
	game.set_process(false)  # the test drives the clock itself
	_check(game.playing and game.active.is_empty(), "level starts, nothing on screen")

	_check(game.spawn_word("cat"), "spawn cat")
	_check(game.spawn_word("dog"), "spawn dog")
	_check(not game.spawn_word("cat"), "same word never twice on screen")
	_check(Array(game.listened) == ["cat", "dog"], "listener gets the on-screen words")
	game.tick(1.0)

	# A correct word is removed.
	game._on_word_heard("cat", "cat", 320.0)
	_check(not game.active.has("cat"), "read word leaves the screen")
	_check(game.stars == 1 and game.words_read == ["cat"], "+1 star")
	_check(Array(game.listened) == ["dog"], "listener no longer hears cat")

	# Duplicate, off-screen and wrong words change nothing.
	var before := _state(game)
	game._on_word_heard("cat", "cat", 300.0)  # duplicate recognition
	game._on_word_heard("zebra", "zebra", 300.0)  # never on screen
	game._on_heard_other("um banana")  # matched nothing
	game._on_voice_started()  # a cough
	_check(_state(game) == before, "duplicate / off-screen / wrong word: no effect")

	# A just-zapped word can't come back while a late echo of it may arrive.
	_check(not game.spawn_word("cat"), "zapped word not respawned within the cooldown")
	game.tick(game.spawner.REZAP_COOLDOWN + 0.1)
	_check(game.spawn_word("cat"), "zapped word can come back after the cooldown")
	game._on_word_heard("cat", "cat", 300.0)

	# A word that reaches the bottom stays until read.
	var dog = game.active["dog"]
	for i in 200:  # 20 s, more than the 16.1 s L1 fall time
		game.tick(0.1)
	_check(game.active.has("dog") and dog.state == dog.LANDED, "landed word still on screen")
	_check(game.shields == game.SHIELD_MAX - 1, "landing costs one shield pip")
	for i in 200:
		game.tick(0.1)
	_check(game.active.has("dog") and game.shields == game.SHIELD_MAX - 1, "it keeps waiting, no more drain")
	_check("dog" in Array(game.listened), "landed word can still be read")
	game._on_word_heard("dog", "dog", 300.0)
	_check(not game.active.has("dog") and game.stars == 3, "landed word read -> gone")

	# Timer runs out -> results.
	for i in 600:
		game.tick(0.1)
	_check(not game.playing and game.result_panel.visible, "level ends at 90 s with results")
	game._on_word_heard("dog", "dog", 300.0)
	_check(game.stars == 3, "events after the level do nothing")

	# Auto-spawn over a whole level 5: never a duplicate or a sound-alike pair.
	game.auto_spawn = true
	game.level_num = 5
	game.start_level()
	var bad := 0
	var spawned := {}
	var max_seen := 0
	var zapped_at := {}  # word -> game time of its zap
	var early := 0
	for i in 900:
		game.tick(0.1)
		var on: Array = game.active.keys()
		max_seen = maxi(max_seen, on.size())
		for w in on:
			spawned[w] = true
			if zapped_at.has(w) and i * 0.1 - zapped_at[w] < game.spawner.REZAP_COOLDOWN:
				early += 1
			zapped_at.erase(w)
			for o in on:
				if o != w and game.spawner.clashes(w, [o]):
					bad += 1
		# Read the oldest word now and then, like a child would.
		if i % 55 == 0 and on.size():
			game._on_word_heard(on[0], on[0], 300.0)
			zapped_at[on[0]] = i * 0.1
	_check(bad == 0, "no sound-alikes on screen together")
	_check(early == 0, "no word respawned within %.0f s of its zap" % game.spawner.REZAP_COOLDOWN)
	_check(max_seen >= 3 and max_seen <= game.LevelCurve.max_on_screen(5), "on-screen cap %d (saw %d)" % [game.LevelCurve.max_on_screen(5), max_seen])
	_check(spawned.size() >= 10, "spawner keeps words coming (%d different)" % spawned.size())

	# Shields at 0 -> gentle recharge panel, not a game over.
	game.auto_spawn = false
	game.level_num = 1
	game.start_level()
	for w in ["the", "see", "look", "go", "up"]:
		game.spawn_word(w)
	for i in 200:
		game.tick(0.1)
	_check(not game.playing and game.shields == 0 and game.result_panel.visible, "5 landings -> recharge panel")

	print("missile_command_test: %s" % ("PASS" if failures == 0 else "%d FAILED" % failures))
	quit(1 if failures else 0)


func _state(game) -> Array:
	return [game.active.keys(), game.stars, game.shields, game.streak, game.words_read.duplicate(),
		Array(game.listened), game.playing]
