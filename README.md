# Hero Reader

An early-reader game for ages 6 and up. Words float down the screen, and
**reading one out loud blasts it** with a laser from your base. Commander
Aaron hands out the missions; Hero Nora (and her corgi co-pilot) save the
day by reading.

- **Levels and worlds:** 90-second levels with escalating speed. 4–5 levels
  share a vocabulary and make up a World; finishing a World unlocks the next,
  with new words.
- **Scenarios** reuse the same mechanic: Space Invaders, Missile Command, and more.
- **Never a "you lose":** a wrong word is a visible miss with no penalty, and
  running out of HP means "try again!".
- **Word lists** are selectable by reading level (CVC phonics, then Dolch pre-primer → grade 3, then nouns).

## Status

The first milestone was proving that **on-device speech recognition is accurate
and fast enough**. It is done and documented:
- `docs/stt-evaluation.md`: which models were tested, how, the results, and
  the mobile outlook.
- `HANDOFF.md`: next steps on a real PC with a microphone (live test, recording
  calibration voices, benchmarking real kids).

## Start here

Setup: `python tools/setup.py --venv --build` fetches every pinned third-party
piece (models, runtime, godot-cpp) and builds the speech extension. Nothing
third-party is checked in. Details are in `CLAUDE.md`.

| If you want to… | Read |
|---|---|
| Know which speech model we picked and why (and the alternatives) | `docs/stt-evaluation.md`, especially §7 "Choices: where to start" |
| Reproduce every number | `docs/REPRODUCE.md` |
| Continue on a PC with a mic: live test, record family voices, benchmark them | `HANDOFF.md` |
| See the game design: levels, Worlds, spawning rules, feedback, scenarios | `docs/game-design.md` |
| Use or build the Godot speech node | `native/hero_listen/README.md` |
| Match the art style | `godot/art/STYLE.md` |

## Layout

| Path | What |
|---|---|
| `godot/` | Godot 4.7 project: dev menu, speech test scene, calibration recorder, art, word lists |
| `godot/addons/hero_listen/` | `WordListener` extension manifest and `HeroSpeech` model presets |
| `native/hero_listen/` | C++ source for the GDExtension (sherpa-onnx C API) |
| `stt-eval/` | Python benchmark: engines, matcher, real-time latency simulation, results |
| `godot/art/` | "Cosmic Storybook" art style guide and character SVGs |
| `godot/data/wordlists/levels/` | 6 reading levels × 5–6 Worlds (1,047 words) with confusable pairs; `build_levels.py` regenerates them |
| `docs/` | evaluation, reproduction steps, game design |
| `third_party/manifest.json` | pinned URLs, versions and checksums of everything we download (`tools/setup.py`) |
