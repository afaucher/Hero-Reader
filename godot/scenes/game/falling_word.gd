extends Node2D
## One falling word: a cream word plate with a meteor trail. It moves in a
## straight line from its lane at the top to its landing spot over `fall_time`,
## then hovers there, still readable, until it is read.

enum { FALLING, LANDED, ZAPPED }

const FONT_SIZE := 44
const PLATE_H := 66.0
const TRAIL := 220.0
const NAVY := Color("141836")
const CREAM := Color("FFF4DC")
const ORANGE := Color("FF7A45")
const GOLD := Color("FFC93C")

var word := ""
var start := Vector2.ZERO
var target := Vector2.ZERO
var lane := 0
var slot := 0
var fall_time := 10.0
var progress := 0.0  # 0 at spawn, 1 on landing
var state := FALLING
var age := 0.0
var plate_w := 0.0
var _font: Font
var _plate := StyleBoxFlat.new()


func setup(w: String, from: Vector2, to: Vector2, seconds: float, start_progress: float = 0.0) -> void:
	word = w
	start = from
	target = to
	fall_time = seconds
	progress = clampf(start_progress, 0.0, 1.0)
	position = start.lerp(target, progress)
	_font = ThemeDB.fallback_font
	plate_w = _font.get_string_size(word, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x + 44.0
	_plate.bg_color = CREAM
	_plate.set_corner_radius_all(18)
	_plate.set_border_width_all(5)
	_plate.border_color = NAVY


## Advance by `delta` seconds. Returns true on the frame the word lands.
func advance(delta: float) -> bool:
	age += delta
	var landed_now := false
	if state == FALLING:
		progress = minf(1.0, progress + delta / fall_time)
		position = start.lerp(target, progress)
		if progress >= 1.0:
			state = LANDED
			landed_now = true
	elif state == LANDED:
		position = target + Vector2(0, sin(age * 2.2) * 4.0)
	queue_redraw()
	return landed_now


## Read correctly: pop and disappear (the caller adds the sparkle burst).
func zap() -> void:
	state = ZAPPED
	var tw := create_tween()
	tw.tween_property(self, "scale", Vector2(1.18, 1.18), 0.08)
	tw.tween_property(self, "modulate:a", 0.0, 0.22)
	tw.tween_callback(queue_free)


## Level over: drift up and fade out.
func float_away() -> void:
	state = ZAPPED
	var tw := create_tween().set_parallel()
	tw.tween_property(self, "position:y", position.y - 160.0, 1.2).set_ease(Tween.EASE_IN)
	tw.tween_property(self, "modulate:a", 0.0, 1.2)
	tw.chain().tween_callback(queue_free)


func _draw() -> void:
	if _font == null:
		return
	var top := Vector2(0, -PLATE_H / 2.0)
	if state == FALLING:
		var dir := (target - start).normalized()
		var length := minf(TRAIL, start.distance_to(position))
		if length > 4.0:
			var pts := PackedVector2Array()
			var cols := PackedColorArray()
			for i in 9:
				var f := i / 8.0
				pts.append(top - dir * length * (1.0 - f))
				cols.append(Color(ORANGE, 0.55 * f))
			draw_polyline_colors(pts, cols, 10.0, true)
		draw_circle(top, 13.0, ORANGE)
		draw_circle(top, 13.0, NAVY, false, 3.0, true)
		draw_circle(top + Vector2(-4, -4), 4.0, GOLD)
	elif state == LANDED:
		# Waiting to be read: a soft pulsing glow, never alarming.
		var glow := 0.25 + 0.15 * sin(age * 3.0)
		var halo := Rect2(-plate_w / 2.0 - 8, -PLATE_H / 2.0 - 8, plate_w + 16, PLATE_H + 16)
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(ORANGE, glow)
		sb.set_corner_radius_all(24)
		draw_style_box(sb, halo)
	var r := Rect2(-plate_w / 2.0, -PLATE_H / 2.0, plate_w, PLATE_H)
	draw_style_box(_plate, r)
	var text_w := _font.get_string_size(word, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x
	var asc := _font.get_ascent(FONT_SIZE)
	var desc := _font.get_descent(FONT_SIZE)
	var baseline := -PLATE_H / 2.0 + (PLATE_H - asc - desc) / 2.0 + asc
	draw_string(_font, Vector2(-text_w / 2.0, baseline), word, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, NAVY)
