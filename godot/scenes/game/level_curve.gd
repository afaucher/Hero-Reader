extends RefCounted
## The level curve from docs/game-design.md §3.1, in one place so it can be tuned.

const LEVEL_SECONDS := 90.0
const TOP_UP_EMPTY := 1.5  # screen empty this long -> spawn now
const MIN_SPAWN_GAP := 2.5  # top-up never spawns faster than this

## Per level 1..5: fall time top->base (s), spawn interval (s), max words on screen.
const LEVELS := [
	{"fall": 14.0, "interval": 5.0, "max": 3},
	{"fall": 12.5, "interval": 4.5, "max": 3},
	{"fall": 11.0, "interval": 4.0, "max": 4},
	{"fall": 9.5, "interval": 3.5, "max": 4},
	{"fall": 8.0, "interval": 3.0, "max": 5},
]

## Reading-level pace factor (index into levels/index.json: 0 = L0, 1 = L1, ...).
const PACE := {0: 1.25, 1: 1.15}

## Parent speed setting.
const SPEEDS := {"Relaxed": 1.5, "Normal": 1.0, "Zoomy": 0.85}


static func fall_time(level: int, reading_idx: int, speed: String) -> float:
	var t: float = LEVELS[level - 1]["fall"] * PACE.get(reading_idx, 1.0) * SPEEDS.get(speed, 1.0)
	return maxf(t, 7.0 if speed == "Zoomy" else 8.0)


static func spawn_interval(level: int) -> float:
	return LEVELS[level - 1]["interval"]


static func max_on_screen(level: int) -> int:
	return LEVELS[level - 1]["max"]
