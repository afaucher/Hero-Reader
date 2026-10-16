# Hero Reader: Game Design

A read-aloud arcade game for early readers (age 6+). Words drift toward Hero Nora's
base. When she reads a word out loud, the base zaps it. The scenario changes (space
invaders, meteors, undersea...), but the mechanic stays the same: **read a word on the
screen to stop it**.

Related docs: `docs/stt-evaluation.md` (speech engine findings), `godot/art/STYLE.md`
(the "Cosmic Storybook" art style), `godot/data/wordlists/levels/` (leveled word lists).

---

## 1. Pillars

1. **Reading is the only button.** Every action in a level is reading a word aloud.
   The game never asks for a word that isn't on screen.
2. **Never punish trying.** A wrong word or a mumble is a harmless *Miss*. Running out
   of shields means "Let's try again", never "You lose". There is no game-over screen.
3. **Readable first, flashy second.** Words are big, high-contrast and on screen for
   at least 8 seconds. Effects never cover a word the child is reading.
4. **Same words, faster pace.** A World keeps one vocabulary for all its levels, so
   the child gets fluent with those words while the speed goes up.
5. **One mechanic, many skins.** Scenarios are data-driven, so a new theme is new art
   plus a config file, not new game code.
6. **Feel instant.** The cannon starts charging as soon as a voice is heard, which hides
   the 300-400 ms recognition delay.

## 2. Core loop

```
word spawns at top ──► drifts down ──► child reads it aloud
                                        │
            ┌───────────────────────────┼─────────────────────────┐
     matches an on-screen word   speech that matches nothing     silence
            │                           │                         │
         ZAP (hit)               MISS: laser visibly misses,   word reaches the base:
       +1 star, word               no penalty                  -1 shield pip,
       flies to word jar                                       word comes back later
```

Each level is 90 seconds. Read words to earn stars. Survive the timer and the level is
complete. Complete every level in a World and the next World unlocks.

Moment to moment:
1. `voice_started` → the cannon glows and hums, and Nora's headset light blinks.
2. `word_heard(word, text, latency_ms)` → the beam fires at that word, and the word bursts
   into stars.
3. `heard_other(text)`, or no result within 1.5 s of `voice_started` → **Miss**: the
   beam fires into empty space next to the nearest word.
4. A word touches the base line → a soft bump, one shield pip dims, and the word puffs away.

The recognizer runs as a closed set. On every spawn, zap or base hit, call
`WordListener.set_words(<words currently on screen>)`.

## 3. Structure: reading level → World → level

```
Reading Level (L0..L5, picked in the menu)
 └─ World 1..N (4-6 per reading level, one fixed vocabulary of 25-40 words)
     └─ Level 1..5 (90 s each, same vocabulary, faster each time)
```

### 3.1 Level curve (per World)

| Level | Fall time, top→base | Spawn interval | Max words on screen | Nominal spawns / 90 s |
|---|---|---|---|---|
| 1 Warm-up | 14.0 s | 5.0 s | 3 | 18 |
| 2 | 12.5 s | 4.5 s | 3 | 20 |
| 3 | 11.0 s | 4.0 s | 4 | 23 |
| 4 | 9.5 s | 3.5 s | 4 | 26 |
| 5 Finale | 8.0 s | 3.0 s | 5 | 30 |

- Speed is expressed as **fall time**, not px/s, so it doesn't depend on resolution.
  Speed = playfield height / fall time.
- **Reading-level pace factor** multiplies fall time: L0 ×1.25, L1 ×1.15, L2 and up ×1.0.
  Pre-readers sound words out, and the fastest word still stays on screen for 10 s.
- **Parent speed setting** multiplies fall time again: Relaxed ×1.5, Normal ×1.0,
  Zoomy ×0.85. The floor is 8 s, and Zoomy never drops below 7 s.
- **Top-up rule:** if the screen has been empty for 1.5 s, spawn now instead of waiting
  for the timer. This keeps fast readers busy. The spawn rate is capped at 1 per 2.5 s.
- **First 3 seconds:** one word, already a third of the way down, so the level starts
  with something to read.
- **Last 10 s of Level 5:** "Big Finale". A large carrier (mothership, giant meteor...)
  holds three words in turn, and each one read knocks off a piece. It can't damage the
  base, it's just a fun ending. When the timer ends, any words still on screen float
  away. The level is complete.

### 3.2 Shields (HP)

- Shields: **5 pips**, full at the start of every level.
- A word that reaches the base costs **1 pip**. Nothing else costs pips. Misses, wrong
  words and noise are always free.
- Getting pips back:
  - **Streak:** 5 zaps in a row (no base hits in between) restores 1 pip.
  - **Star word:** once per level, at about 45 s, a gold-glowing word appears. Reading it
    restores 1 pip and gives 3 stars. It follows normal spawn rules.
  - Pips never go above 5.
- **Shields reach 0:** the action stops gently with a "Shields need a recharge!" panel:
  - It shows what went well: "You read **14** words!" plus any new words read.
  - Buttons: **Try again** (big, default), **Slower speed** (shown after 2 tries on the
    same level; it applies Relaxed to this level only), and **Map**.
  - Stars and word stats from the attempt are still saved. Effort counts.
- **Auto-assist:** after 3 recharges on the same level, the next try quietly uses
  ×1.25 fall time and a streak threshold of 3 (instead of 5) to refill pips. The
  parent report notes it; the child never sees a label.

### 3.3 Completion and unlocks

- **Level complete:** the 90 s timer runs out with at least 1 shield pip left. There is
  no score threshold.
- **World complete:** all 5 levels of the World are complete. The next World in the
  same reading level unlocks, with new vocabulary. Completed levels can be replayed
  any time ("practice run").
- **Reading level complete:** every World in it is complete. A "Graduation" scene with
  Commander Aaron plays and suggests the next reading level. Parents can lock the
  reading level, so the suggestion only shows if allowed.
- Levels inside a World unlock in order. Worlds inside a reading level unlock in order.
  All reading levels are selectable from the start, and the menu marks one as
  recommended.
- The timer is shown as a progress bar that fills up (a fuel gauge, or the sun crossing
  the sky), not a number counting down.

## 4. Word spawning rules (closed set)

Data: `godot/data/wordlists/levels/<level>.json`. Each World has `words` and
`confusable` (pairs that must never be on screen together). Build the lists with
`build_levels.py`, which checks every word against `pron_dict.txt`.

When the spawner needs a word, it:
1. Draws from the current World's shuffle bag. The bag is filled with all of the World's
   words at level start.
2. Skips any word that:
   - is already on screen,
   - forms a pair in `confusable` with any on-screen word (for example cat/hat, no/go,
     tree/three, on/one, to/two),
   - *soft rule, L0-L2 only:* starts with the same two letters as an on-screen word
     (visual look-alikes such as `bat`/`bag`). It is dropped if it would leave no
     candidate.
3. Takes the first word that passes and removes it from the bag. **No word repeats within
   a level** until the bag is empty.
4. If the bag is empty, refills it with the words already used, putting first the words
   that reached the base (useful re-practice), then the rest.
5. If no word passes, waits 0.5 s and tries again. In simulation this never happened,
   because every World has at least 7 mutually non-confusable words.
6. Places the word in one of 5 lanes. It never shares a lane with a word that is still
   in the top 40% of the screen, and its label never overlaps another.

Other rules:
- No single-letter words (`a`, `I` are unreliable in isolation). This is enforced in
  the data.
- Homographs (`read`, `live`, `close`) are allowed. The matcher accepts either
  pronunciation because it matches text.
- The star word is drawn from the World's words that reached the base most often
  earlier in the session (or at random if none have).

### 4.1 How many words a World needs

- Nominal spawns per 90 s level: 90 / interval = **18, 20, 23, 26, 30** (Levels 1-5).
- With the top-up rule, a very fast reader can push the rate up to the 2.5 s cap:
  90 / 2.5 = **36** spawns at most.
- Requirement: World size ≥ nominal spawns of the hardest level (30). Ideally it's
  ≥ the fast-reader cap (36), so a word almost never repeats.
- The lists use **29-36 words per World** (Grade 3 "Wild Places" has 29 long words,
  which are read more slowly). Levels 1-4 never repeat. Level 5 repeats only after the
  bag is empty.
- A simulation of the spawner (300 runs per level, 25% of words reaching the base) found
  **zero stalls**. Words repeated only in Level 5 of the densest L0 Worlds, in 3-10% of
  runs, with 1 repeat each.
- Across a World, the child sees each word about 4-5 times (5 levels × ~25 spawns / ~32
  words). That repetition is intended, because it builds fluency.

## 5. Feedback design

Rule: **feedback for success is big, feedback for anything else is small and kind.**
No red X's, no buzzers, no sad faces (see STYLE.md: expressions are always positive).

| Event | Visual | Audio | Character |
|---|---|---|---|
| Voice detected (`voice_started`) | The cannon charges with a teal glow growing over 0.3 s. A mic ring pulses. | Rising hum | Nora: "concentrating" pose |
| **Hit** (`word_heard`) | A beam hits the word, which pops into stars. The word's letters fly into the "word jar" in the corner. +1 star. | Bright zap + chime. Pitch rises with streak. | Nora cheers. The corgi barks happily (on 1 hit in 4). |
| **Miss** (speech, no match) | The beam fires and visibly misses: it passes beside the nearest word, which wobbles "phew!" Small fizzle sparkle. | Soft whoosh | Corgi: "So close! Try again!" (at most once every 8 s) |
| Word reaches base | The word bumps the shield, which flickers. One pip dims. The word puffs into a cloud and is re-queued. If the setting is on, the voice says the word ("That word was *ship*"). | Gentle "boing" | Corgi: "We've got this!" |
| Streak of 5 | A shield pip refills with a sparkle. | Power-up jingle | Corgi: "Five in a row!" |
| Level complete | Words float away, then confetti. A tally counts up: words read, stars, new words. | Fanfare | Commander Aaron: congratulations line |
| Shields at 0 | Play freezes softly into the "recharge" panel (see 3.2). | Calm "power-down" | Corgi: "Let's try again together!" |
| World complete | Badge plus a new map location. Nora does a cheering pose. | Big fanfare | Aaron + corgi |

Celebrating effort:
- Every word read is kept in a **word jar / collection**. Seeing it grow is a reward
  that doesn't depend on winning.
- Personal bests ("Most words in one mission: 22!"), never comparisons with others.
- **No 1-3 star grading of a level** (that implies failing). Stars are only counted up.
- Miss attempts count as "brave tries" in the parent report, never shown as failures.

Latency handling: the hit must follow end of speech within about 400 ms. The charge
animation starts on `voice_started`, so most of the delay feels like wind-up.

## 6. Menus and reading-level selection

```
Title ─► Who's playing? (profile pick, skipped if one profile)
      ─► Main menu:  [ PLAY ]   [ Word Jar ]   [ Settings ]   [ Grown-ups (gated) ]
PLAY  ─► Choose your reading level (6 big cards)
      ─► World map for that level (Worlds 1..N, later ones locked)
      ─► Level picker (5 nodes, later ones locked)
      ─► Mission briefing (Commander Aaron, 1-2 lines, tap to skip)
      ─► Mic check (first mission each session: "Say GO to launch!")
      ─► Play (90 s) ─► Results ─► Next level / Map
```

The reading-level cards look like this. Each card shows three sample words in the
game font, so a parent can pick by eye:

| Card | Shows | Grade |
|---|---|---|
| L0 Letter Sounds & CVC | cat · pig · sun | Pre-K/K phonics |
| L1 First Sight Words | the · look · jump | Pre-K |
| L2 Kindergarten | stop · fish · they | K |
| L3 Grade 1 | cake · train · because | 1 |
| L4 Grade 2 | night · cloud · picture | 2 |
| L5 Grade 3 | together · planet · thankful | 3 |

- The last level played is pre-selected and marked "Recommended".
- Optional **quick check** (a parent can start it from Grown-ups): 3 words from each
  level, one at a time, no timer. The highest level with 3/3 read recommends that level.
- Changing reading level keeps the progress of every level.

First launch also includes:
1. Aaron greets Nora.
2. The corgi is introduced and Nora names it (see 8).
3. A mic permission prompt.
4. A tutorial mission: one word, no shields, it waits until the word is read.

## 7. Scenario framework ("skins")

A scenario is a Godot `Resource` (`Scenario.tres`) that the level scene loads. Game
logic never references scenario art directly.

| Field | Purpose |
|---|---|
| `id`, `title` | e.g. `star_patrol`, "Star Patrol" |
| `background` | PackedScene (parallax layers) |
| `carrier` | PackedScene with a `WordLabel` node and `hit()`, `miss_nearby()`, `reach_base()` animations |
| `base` | PackedScene with a `fire_at(pos, hit: bool)` method and shield pip display |
| `projectile` | Beam/projectile scene; `hit: bool` decides whether it lands on the carrier or flies wide |
| `motion` | `straight_down`, `diagonal` (missile command), `sway`, `zigzag` |
| `shield_icon`, `music`, `sfx` | Assets |
| `briefings` | Mission lines for Commander Aaron (fallback: generic lines) |

Scenarios are assigned to Worlds by index (World 1 is always Star Patrol, the rest
rotate) or picked by the player once unlocked. Violence stays gentle: things get
tickled, repaired, caught, bubbled or sent home, never destroyed with gore.

| Scenario | Word carrier | Base | "Laser / zap" | Hit | Miss |
|---|---|---|---|---|---|
| **Star Patrol** (Space Invaders) | Cute alien saucer holding a word sign | Nora's cannon ship at the bottom, shield bubble | Teal laser beam | Saucer pops into stars, alien parachutes home waving | Beam zips past the saucer, alien does a "phew" wobble |
| **Meteor Shield** (Missile Command) | Space rock falling diagonally, trailing the word | 3 moon-base domes; pips are the dome lights | Interceptor flies up and bursts into a sparkle cloud | Rock crumbles into glitter | Burst pops in empty sky beside the rock |
| **Bubble Reef** (undersea) | Jellyfish drifting down, swaying | Coral reef and the corgi's submarine | Bubble beam | Jellyfish wrapped in a bubble floats up, smiling | Bubbles stream past and pop |
| **Volcano Valley** (dinosaurs) | Glowing lava pebble bouncing down the slope | Dino nest with eggs | Baby pterodactyl's water splash | Pebble cools into a gem | Splash lands in the grass |
| **Snow Fort** | Snowball arcing toward the fort | Snow fort with flags | The corgi catches it in a giant mitten | Snowball turns into a snowflake burst | Mitten snaps shut on air, snowball sails past |
| **Picnic Rescue** | Grumpy rain cloud drifting down | Picnic blanket; pips are sandwiches | Sunbeam | Cloud turns into a rainbow | Sunbeam lands beside the cloud |
| **Goal Keeper** | Soccer ball kicked toward the goal (curving) | Goal and net | Corgi goalkeeper dive | Ball caught, crowd cheers | Corgi dives, playfully misses, rolls over |
| **Robot Repair** | Wobbly broken robot rolling down a ramp | Workshop door | Repair ray | Robot fixed, it dances off | Ray sparks on the floor |

## 8. Characters and voice lines

- **Commander Aaron:** the mission giver. Warm, confident, brief. He speaks in briefings,
  results, and Graduation, never during play.
- **Hero Nora:** the reader. Her animations mirror the child: concentrating while
  speaking, cheering on hits, "hmm" after a miss.
- **Corgi co-pilot (orange):** the encouragement voice during play. Name TBD. Proposed:
  let the child pick from read-aloud options on first launch: *Biscuit, Comet, Rocket,
  Nugget, Sparky, Waffles, Cosmo, Pickles*. Lines use `{corgi}` and `{hero}` placeholders.

Line rules: at most 8 words, present tense, positive, no sarcasm, never mention losing.
Every line has a caption. Rate limit: at most 1 corgi line every 8 s.

**Commander Aaron: briefings** (one per level, chosen per scenario):
- "Hero {hero}, words are falling! Ready to read?"
- "Your reading powers the laser. Let's go!"
- "Same words, faster speed. You know these!"
- "Read the words to protect the base."
- "Meteors ahead! Your voice is our shield."
- "Big finale today. I believe in you, hero!"
- (result) "Mission complete! You read like a star."
- (World complete) "A whole World saved! On to the next one."
- (Graduation) "You're ready for harder words, hero!"

**Corgi: in play**
- Hit: "Woof! Got it!", "Zap-tastic!", "You read it!", "Nice reading!"
- Streak: "Five in a row!", "You're on fire... I mean, on *sparkle*!"
- Miss: "So close! Try again!", "Almost! Say it again!", "Ooh, nearly!"
- Base hit: "We've got this!", "Shields are okay. Keep going!"
- Low shields: "Take a breath. Pick one word."
- Recharge (0 shields): "Let's try again together!", "Great try! Want another go?"
- Level complete: "We did it! Best co-pilot team!"

## 9. Accessibility and settings

Child-facing (Settings):
- **Font:** the default is a beginning-reader font with single-story *a* and *g*
  (Andika, SIL OFL, or Lexend). A **dyslexia-friendly option** uses OpenDyslexic (OFL).
  Atkinson Hyperlegible is the high-legibility alternative.
- **Text size:** word plates are at least 56 px high at 1080p, with a slider from ×1.0 to
  ×1.6. Wide letter spacing (+5%). Words always use cream plates (`#FFF4DC`) with navy
  text (`#141836`), contrast > 12:1.
- **Color-blind safe:** meaning never depends on color alone. Hit, miss and base hit
  differ in motion, shape and sound. Shield pips are shapes that empty out, not
  red/green. The star word gets a sparkle outline as well as gold color.
- **Reduced motion:** no screen shake, fewer particles, no parallax.
- **Volume:** separate sliders for music, effects and voice. Captions are always on for
  voice lines.

Grown-ups area (gated by a hold-for-3-seconds button plus a simple sum):
- **Speed:** Relaxed / Normal / Zoomy (3.1), plus a **Practice mode** where words stop
  just above the base and wait.
- **Pronunciation matching:**
  - *Friendly* (default): sound-alike matching on, hotword boost 1.5, preset
    `parakeet-110m-hot`. Close attempts count.
  - *Strict*: sound-alike off, lower hotword boost. For children working on specific
    sounds.
- **Say missed words aloud:** on/off (default on for L0-L1).
- **Tap a word to hear it:** off by default. Tapping never zaps.
- **Tap-to-zap fallback**, for speech or mic problems. Stats are marked as tapped, not
  read.
- **Session limit:** for example 3 levels, then "Great job! Time for a break."
- **Reading level lock**, profiles, reset progress, export CSV.
- **Mic test:** shows the live level meter and the last heard text.

## 10. Progress data (parent/teacher)

Stored locally in `user://profiles/<id>/progress.json`. No audio is stored in game
mode, nothing leaves the device, and there are no accounts.

Per word, per profile:
- `shown`, `zapped`, `reached_base`, `miss_attempts_while_on_screen`
- `read_time_ms`, median and last: time from the word becoming fully visible to the zap.
  This is the reading fluency signal.
- `asr_latency_ms`, median: end of speech to zap, from `word_heard`. This is the system
  health signal.
- `first_seen`, `first_zapped`, `last_seen`
- `mastered`: zapped in ≥ 3 sessions on ≥ 2 different days, with median read time
  < 2.5 s and no base hits in the last 5 showings.

Per level attempt:
- date/time, reading level, World, level, scenario
- speed setting, matching mode, auto-assist on/off
- duration, words spawned, zapped, reached base, misses, star word read, streaks
- completed or recharged, shields left

Parent dashboard:
- Words mastered (count and list), with a "tricky words" list (most base hits, or slowest
  read time).
- A reading speed trend per World.
- Minutes played per day.
- Microphone health: miss rate and latency. A high miss rate suggests checking the room
  or mic, not the child.

Teacher export: CSV per word and per attempt.

## 11. Godot implementation notes

- `LevelRunner` (scene) owns the timer, shields, the spawner and the `WordListener` node,
  and emits gameplay signals. Scenario scenes only listen and animate.
- `LevelCurve` resource holds the table in 3.1 so it can be tuned without code.
- `WordSpawner` loads the World's `words` and `confusable` into a `Dictionary` of
  `word -> PackedStringArray` neighbors. It implements section 4.
- After every spawn, zap and base hit, call `listener.set_words(on_screen_words)`.
  Debounce it to once per frame.
- Miss detection: on `voice_started`, start a 1.5 s timer. `word_heard` cancels it.
  `heard_other` or the timeout triggers the Miss animation.
- Word lists: `godot/data/wordlists/levels/index.json` lists the reading levels.
  Edit `build_levels.py`, then run `python3 build_levels.py`. The build fails if a word
  is missing from `pron_dict.txt`, is duplicated within a level, or is a single letter.

## 12. Decisions (2026-10-16)

The ten open questions, answered:

| # | Question | Decision |
|---|---|---|
| 1 | Corgi's name | **Rex** for now; can still change later. |
| 2 | World-to-scenario mapping | **Fixed, then free:** the first play of a World uses its fixed scenario; replays may use any unlocked scenario. |
| 3 | Level 5 Big Finale | **Dropped.** All 5 levels of a World are the same apart from speed. |
| 4 | Saying the word after a base hit | **Skipped for now.** No word playback; revisit later (offline TTS or recordings). |
| 5 | Unlocks | **All open:** every World of a reading level is playable from the start. |
| 6 | Levels per World | **5 everywhere**, pre-K included. |
| 7 | L0 grouping | **One vowel per World** (current); the spawner keeps sound-alikes apart. |
| 8 | Placement quick check | **Parent picks** the reading level; no placement test. |
| 9 | Two-player / sibling mode | **Out of scope.** |
| 10 | Reward economy | **Pure tally:** stars just count up and buy nothing. |
| 11 | Misreads and duplicate recognitions | **No effect.** A wrong word, an off-list word, or a repeat recognition of a word already zapped changes nothing. A word leaves the screen only when it is read correctly; words stay until they are gotten. |

Earlier sections may still describe the Big Finale, sequential unlocks or star
purchases; this table overrides them.
