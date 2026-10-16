extends RefCounted
## Picks the next word for a World (docs/game-design.md §4): a shuffle bag, never
## a word that is already on screen, never a sound-alike of one ("confusable"
## pairs), never a word zapped in the last REZAP_COOLDOWN seconds, and for
## L0-L2 preferably not the same first two letters.

## The recognizer can report a word again ~1.5 s after it was zapped (trailing
## silence re-decoded). A fresh copy must not be on screen to catch that echo.
const REZAP_COOLDOWN := 2.0

var words: Array = []
var cooling := {}  # word -> seconds until it may spawn again
var confusable := {}  # word -> {other: true}
var soft_prefix := false
var bag: Array = []
var used: Array = []
var reached_base := {}  # word -> times it landed, re-practised first on refill


func setup(world: Dictionary, soft_prefix_rule: bool) -> void:
	words.clear()
	for w in world.get("words", []):
		words.append(str(w))
	confusable.clear()
	for p in world.get("confusable", []):
		confusable.get_or_add(p[0], {})[p[1]] = true
		confusable.get_or_add(p[1], {})[p[0]] = true
	soft_prefix = soft_prefix_rule
	used.clear()
	reached_base.clear()
	cooling.clear()
	bag = words.duplicate()
	bag.shuffle()


func clashes(w: String, on_screen: Array) -> bool:
	if w in on_screen:
		return true
	var c: Dictionary = confusable.get(w, {})
	for o in on_screen:
		if c.has(o):
			return true
	return false


## The next word that may join `on_screen`, or "" if none can right now.
func next_word(on_screen: Array) -> String:
	if bag.is_empty():
		_refill()
	var i := _first_ok(bag, on_screen, soft_prefix)
	if i < 0 and soft_prefix:
		i = _first_ok(bag, on_screen, false)
	if i < 0 and not used.is_empty():
		# Everything left in the bag clashes with what's on screen: refill early
		# rather than stall (a landed word may stay a long time).
		_refill()
		i = _first_ok(bag, on_screen, false)
	if i < 0:
		return ""
	var w: String = bag[i]
	bag.remove_at(i)
	used.append(w)
	return w


func note_reached_base(w: String) -> void:
	reached_base[w] = reached_base.get(w, 0) + 1


func note_zapped(w: String) -> void:
	cooling[w] = REZAP_COOLDOWN


func is_cooling(w: String) -> bool:
	return cooling.has(w)


## Game time passes (the game's tick calls this).
func cool(delta: float) -> void:
	for w in cooling.keys():
		cooling[w] -= delta
		if cooling[w] <= 0.0:
			cooling.erase(w)


func _first_ok(pool: Array, on_screen: Array, prefix_rule: bool) -> int:
	for i in pool.size():
		var w: String = pool[i]
		if cooling.has(w) or clashes(w, on_screen):
			continue
		if prefix_rule and on_screen.any(func(o): return o.left(2) == w.left(2)):
			continue
		return i
	return -1


func _refill() -> void:
	# Words that reached the base come first (useful re-practice), then the rest.
	var again := used.duplicate()
	again.shuffle()
	again.sort_custom(func(a, b): return reached_base.get(a, 0) > reached_base.get(b, 0))
	bag.append_array(again)
	used.clear()
