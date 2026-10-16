extends Node2D
## Short-lived effects: a laser beam, a sparkle burst (a word read) and a
## small fizzle (speech that matched nothing). Each frees itself when done.

const TEAL := Color("2EC4B6")
const CREAM := Color("FFF4DC")
const GOLD := Color("FFC93C")

var kind := ""
var life := 0.0
var duration := 0.5
var beam_to := Vector2.ZERO  # laser end, local
var parts: Array = []  # {p, v, size, col}


static func laser(from: Vector2, to: Vector2) -> Node2D:
	var fx = load("res://scenes/game/fx.gd").new()
	fx.kind = "laser"
	fx.duration = 0.28
	fx.position = from
	fx.beam_to = to - from
	return fx


static func burst(at: Vector2, n: int = 14) -> Node2D:
	var fx = load("res://scenes/game/fx.gd").new()
	fx.kind = "burst"
	fx.duration = 0.75
	fx.position = at
	for i in n:
		var a := TAU * i / n + randf_range(-0.2, 0.2)
		fx.parts.append({"p": Vector2.ZERO, "v": Vector2.from_angle(a) * randf_range(140, 300),
			"size": randf_range(7, 14), "col": [GOLD, CREAM, TEAL][i % 3]})
	return fx


static func fizzle(at: Vector2) -> Node2D:
	var fx = load("res://scenes/game/fx.gd").new()
	fx.kind = "fizzle"
	fx.duration = 0.6
	fx.position = at
	for i in 6:
		fx.parts.append({"p": Vector2.ZERO, "v": Vector2(randf_range(-50, 50), randf_range(-110, -60)),
			"size": randf_range(4, 7), "col": CREAM})
	return fx


func _process(delta: float) -> void:
	life += delta
	if life >= duration:
		queue_free()
		return
	for p in parts:
		p["p"] += p["v"] * delta
		p["v"] *= 0.92
	queue_redraw()


func _draw() -> void:
	var fade := 1.0 - life / duration
	if kind == "laser":
		draw_line(Vector2.ZERO, beam_to, Color(TEAL, 0.5 * fade), 22.0 * fade + 4.0, true)
		draw_line(Vector2.ZERO, beam_to, Color(CREAM, fade), 5.0, true)
		draw_circle(beam_to, 26.0 * fade + 6.0, Color(TEAL, 0.6 * fade))
		return
	for p in parts:
		_star(p["p"], p["size"] * (0.6 + 0.4 * fade), Color(p["col"], fade))


func _star(c: Vector2, r: float, col: Color) -> void:
	# 4-point sparkle (STYLE.md: the only sharp shapes are stars and sparkles).
	var pts := PackedVector2Array()
	for i in 8:
		var rr := r if i % 2 == 0 else r * 0.35
		pts.append(c + Vector2.from_angle(PI / 4.0 * i - PI / 2.0) * rr)
	draw_colored_polygon(pts, col)
