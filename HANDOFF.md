# Handoff: next steps for a local session (with a mic and Godot)

The cloud session proved out the speech pipeline on recorded data and inside
headless Godot. What it could not do is the part that matters most: hear
**real voices through a real microphone**, especially kids. This file is the
checklist for a local Claude Code session (or a human) on the family PC.

Read `docs/stt-evaluation.md` first for the why. TL;DR:
- **Two co-finalists**, both presets in the game and both running through the
  `WordListener` GDExtension (`native/hero_listen`):
  - **`zipformer-hot`** (current default, hotword score 2): streaming. Led on the
    child-voice proxy and on real adult voice, and is half the size.
  - **`parakeet-110m-hot`**: NVIDIA Parakeet-TDT 110M behind a Silero VAD.
    Tightest latency and best in noise, but missed many short words on real voice.
- **Real kid recordings decide between them.** That is the main job of this handoff.

> **Default changed (2026-10-16, provisional until the kid recordings).** The game
> now loads `zipformer-hot` at hotword score 2 (first entry of `PRESETS` in
> `godot/addons/hero_listen/hero_speech.gd`), and the C++ matcher's sound-alike
> rule is "extra-only": a near miss counts only if it adds one sound after the
> same first sound ("cats" for "cat"), so "hat" and "that" no longer zap "cat".
> The game spawners also never bring back a word within 2 s of its zap, so a late
> repeat recognition can't hit a fresh copy. **To switch back:** move
> `parakeet-110m-hot` to the top of `PRESETS`. For the old, looser matching,
> add `"sound_alike": "any"` (or `"no-onset"`) to a preset. Word match lets you
> pick either preset from its menu. Until `stt-eval/matcher.py` flips its default
> too, pass `--sound-alike-mode extra-only` to `benchmark.py` to match the game.

## 1. Set up (Windows PC)

Nothing third-party is in the repo. `tools/setup.py` fetches it all from
`third_party/manifest.json`, with pinned versions and sha256 checksums.

1. Install Python 3.9+ and git.
2. Open an **"x64 Native Tools Command Prompt for VS"** (MSVC, for the build step) and run:
   ```
   python tools/setup.py --venv --build --with godot dataset
   ```
   This sets up the following:

   | What | Where |
   |---|---|
   | sherpa-onnx runtime DLLs | `godot/addons/hero_listen/bin/` |
   | Pronunciation dictionary (from CMUdict) | `godot/data/pron_dict.txt` |
   | Parakeet, Zipformer and Silero VAD models | `godot/models/` |
   | godot-cpp | `third_party/` |
   | Godot 4.7 | `third_party/godot/` |
   | Speech Commands (2.3 GB) | `third_party/data/` |
   | Python venv | `stt-eval/.venv` |
   | The compiled `WordListener` DLL | `godot/addons/hero_listen/bin/` |

   Drop `godot` if you already have Godot 4.7, and `dataset` if you only want real voices.
   `python tools/setup.py --list` shows every component and its licence.
3. Sanity check. This should print about 75–80% hits and roughly 300–400 ms latency:
   ```
   third_party\godot\Godot_v4.7-stable_win64_console.exe --headless --path godot --script res://tests/headless_wav_test.gd -- --clips third_party/data/speech_commands --n 40
   ```

## 2. Live test with the mic

Run the project (`godot --path godot`). The dev menu opens; choose **Speech test**.
Five words show. Read one, and it flashes "ZAP" with the latency since the voice stopped.
Try the presets in the drop-down.

For *why* it fired (or didn't), choose **Word match** instead. It shows the
mic level and the voice lamp, the model's live hypothesis (partials grey, finals
white), and per word card how that hypothesis matched (exact, homophone,
sound-alike, waiting) with phoneme distance. Words come from a real World, and
zapped words are replaced the way the spawner will do it. Without a mic,
`tools/make_tts_clips.ps1` renders Windows TTS clips and
`godot --path godot --script res://tests/viz_demo.gd -- --clips <dir>` plays them
into the scene and saves screenshots to `user://viz_demo`.

Things to note:
- Does it fire on the right word?
- Does a wrong word or a cough fire anything? It shouldn't.
- How does the latency *feel*?
- Room setup: a laptop mic at arm's length is the realistic case.

## 3. Record calibration voices

In the dev menu choose **Record voices**:
1. Click the age and gender, keep the `calibration` list, and press Start.
2. Words appear one at a time; recording is hands-free. After each list pass it
   reshuffles and loops, so let each reader do **2–3 rounds** (about 5–8 minutes).
3. The last few prompts each round are "other" sounds (um, a cough, "what's that
   word?"). They test that nothing fires on non-words.

Speakers available:

| Speaker | Why |
|---|---|
| 8f | closest to the target age (this is the number that matters) |
| 16f | teen voice |
| 42m | adult male |
| 44f | trained voice, gives the ideal-reader ceiling |
| Nora | if she's up for it: even one round is gold |

Recordings go to `%APPDATA%\Godot\app_userdata\Hero Reader\recordings\<age><gender>\<session>\`
with a `manifest.csv` and `session.json`. They stay on the PC and are never committed.

**Before a session with the kids:**
- Mic gain: after a test take, the recorder's stats line shows `last take -NN dB`. Aim
  for about -20 to -10 dB on normal speech. Below -30, turn up the gain dial (HyperX
  QuadCast S: on the bottom of the mic) or move closer; "a little loud" means lean back.
- The trigger ignores clicks, room hum and the first 0.3 s after a word appears, and
  only ends a take after 1 s of quiet. An "um" just before the word stays in the
  same take, and a slow "c... a... t" stays one take. If a take still goes wrong,
  press **R** right away (redo), or **S** to skip the word. **SPACE** pauses.
- If a reader goes off script (reads a different word, chats), pause, or exclude the
  session afterwards (below). Labels must match the audio, or the numbers are noise.

**After each session**, copy and benchmark. This is safe to run any number of times:
it never overwrites a take or a result. Redone takes move to `stt-eval/recordings-trash/`,
and each run gets its own folder under `stt-eval/results/calib/<speaker>/<session>/<time>/`
plus a row in `stt-eval/results/calib/runs.csv`:
```
python tools/collect_recordings.py --bench      # copy, check levels, benchmark new sessions
python tools/collect_recordings.py --report     # latest numbers per speaker
python tools/collect_recordings.py --exclude 8f/<session> "went off script"
```
`stt-eval/recordings/excluded.csv` lists sessions that stay on disk but are left out of
every benchmark. Two are excluded so far: the first low-gain adult take, and an 8f
session whose labels were shifted by one take under the old recorder trigger.

## 4. Benchmark the real voices

```
cd stt-eval
python benchmark.py --recordings recordings/8f --engines parakeet-110m-hot zipformer-hot whisper-base.en ^
    --hot-score 1.5 --beam 8 --sound-alike --trials 400 --onscreen 5 --out results/calib-8f
python benchmark.py --recordings recordings --engines parakeet-110m-hot --hot-score 1.5 --beam 8 --sound-alike --hard
```

Run it once per speaker folder, plus once over everything. Note that `--hot-score`
applies to every engine in a run. Use 3 for `zipformer-hot`, which means a separate run.

What to look for:
- **Hit %** per speaker, especially 8f and Nora.
- **Wrong-word %:** should stay near 0. A wrong zap is worse than a miss.
- **False-accept %** on the `_other` clips.
- **Latency p50/p90.**
- In `results/*/trials-*.csv`, the `text` column shows what the model heard on
  misses. That tells you whether to add homophones (`matcher.py` / `word_matcher.cpp`),
  tune `--hot-score`, or drop words that are unrecognizable in isolation
  (expect "a" and "I" to be bad).

## 5. Decide and tune

- If kid hit rate is under ~90%, the next levers, cheapest first:
  1. Raise `hotwords_score` (1.5 → 2.0) and recheck wrong-word % and false accepts.
  2. Lower `min_silence` (0.25 → 0.2) for speed, or raise it if kids pause mid-word.
  3. Use the game's control over which words share the screen: never show
     sound-alikes together at early levels (cat/hat, on/one, no/go).
  4. Score candidates directly (forced alignment against the 5 on-screen words)
     instead of transcribing; see "Next steps" in the evaluation.
- Update the tables in `docs/stt-evaluation.md` with the real-voice numbers.

## 6. Follow-up list

All the follow-ups so far, with where each can be done.

| # | Follow-up | Where | Status |
|---|---|---|---|
| 1 | Record calibration voices (8f, 16f, 42m, 44f, Nora) and benchmark them; settle Parakeet vs Zipformer | **local** (mic) | ready: recorder + benchmark |
| 2 | Tune hotword score (1.5 offline / 3 streaming) and VAD silence (0.2 s) on that data | **local** | after 1 |
| 3 | Candidate scoring: score each on-screen word against the audio (transducer forced alignment) instead of transcribing. This is the principled closed-set fix if hit rate is too low | local or cloud | not started; only if 1 shows < 90% |
| 4 | A/B the Vosk grammar mode (gdvosk). Its model host was blocked in the cloud sandbox | **local** | optional |
| 5 | Watch for the open child-speech model weights from DrivenData "On Top of Pasketti" (promised fall 2026); a kid-tuned Parakeet would drop in | anytime | watch |
| 6 | Android build of the extension (NDK) + `RECORD_AUDIO` permission + model download-on-first-run | local or CI | libs pinned (`--platform android`); NDK blocked in the cloud |
| 7 | iOS: build sherpa-onnx xcframework from source | Mac | later |
| 8 | CI (GitHub Actions) building the extension for Windows/Linux/Android so nobody needs a compiler | cloud | not started |
| 9 | Game loop: falling words, laser, shields, levels and Worlds from `docs/game-design.md` | **local** | first playable: Missile Command (below) |
| 10 | Art: expression variants per character, plus enemy and scenario sprites | cloud or local | style + 3 portraits done |
| 11 | Decisions only you can make: Nora's suit color and bangs (the 10 design questions are answered in `docs/game-design.md` §12; corgi is Rex for now) | you | partly done |
| 12 | Publish `docs/stt-evaluation.md` as a shareable web page | cloud | on request |

### Missile Command (first playable)

Dev menu → **Play: Missile Command** (`godot/scenes/game/`). It uses the real mic
through WordListener (default preset).
- **Start screen:** the parent picks the reading level, World, level and speed.
- **During play:** words fall at the §3.1 curve and spawn from the World's shuffle bag,
  with no duplicates and no `confusable` pairs on screen. `voice_started` charges the
  cannon, and `word_heard` fires a laser and a sparkle burst and adds +1 star.
- **Results:** Next level / Replay / Menu. When shields reach 0, the
  "Shields need a recharge!" panel shows Try again.

**House rule (2026-10-16), which overrides the design doc:** wrong, duplicate or
off-screen recognitions change nothing. A word leaves only when it is read. A word
that reaches the bottom costs 1 shield pip once, then hovers above its dome until
it is read, and its landing spot stays taken.

**Not done yet:** star word, sounds, Scenario resource/skins, the miss-beam animation,
progress saving.

**Dev aids:**
- Type a word and press Enter to zap it.
- Command-line options: `-- --autostart --no-mic --shot <png> --shot-after <s>`.

**Test:** `godot --headless --path godot --script res://tests/missile_command_test.gd`.

## 7. Other open threads

- **Art:** style A ("Cosmic Storybook" flat vector) is chosen, with likeness as close
  as possible.
  - Drafts: `godot/art/characters/*.svg` and `godot/art/cast_v2.png`.
  - Style guide: `godot/art/STYLE.md`.
  - Still open: Nora's suit color and her
    bang direction.
  - Reference photos must stay out of the repo (`art/reference/` is git-ignored).
- **Game design:** `docs/game-design.md`.
- **Leveled word lists:** `godot/data/wordlists/levels/`, generated by `build_levels.py`.
  They include per-World `confusable` pairs for the spawner.

## 8. Known issues and loose ends

| Issue | Detail | Suggested next step |
|---|---|---|
| **Multi-word check flaky after long runs** | `tests/headless_wav_test.gd` ends with a "two words in one breath" check. With the `parakeet-110m-hot` (VAD) preset it passed 3/3 after a 1-clip run, but once heard nothing after a 30-clip run. In the game, that would mean a missed word after a few minutes of play. Suspects: (a) the VAD lead-in ring buffer indexing (`history_start_` vs the VAD segment `start`) drifting once more than 10 s of audio has passed; (b) the test's fixed 300 ms wait before the final `poll()`. | Run `--n 30` several times and print the events. If it reproduces, log `seg->start`, `history_start_` and `history_.size()` in `process_vad()` (`native/hero_listen/src/word_listener.cpp`). |
| **Streaming partial-word "miss"** | `zipformer-hot` sometimes reports a fragment ("YE") as `heard_other` just before zapping "yes". | Keep the miss visual subtle, or ignore `heard_other` within ~300 ms of a zap. |
| **Moonshine results may be pessimistic** | Moonshine builds from before 2026-07-30 had a quantization bug (Tiny: 7.57% vs 4.83% LibriSpeech WER). The sherpa-onnx export we tested is dated 2026-02-27. | If Moonshine matters (smallest and fastest, MIT), re-test with a newer export. |
| **Kroko licence unclear** | The model archive points to a CC-BY-SA community licence; older wording said non-commercial only. It is evaluation-only here (group `models-eval`). | Don't ship it without a licence review. Same for NVIDIA Nemotron (NVIDIA Open Model License) and Parakeet v3 (conflicting statements). Parakeet-110M/0.6B-v2 are CC-BY-4.0: attribution is needed in the credits. |
| **`zipformer20m` produces no output** | Empty transcripts with int8 and fp32 weights alike. Not investigated. | Ignore unless a smaller streaming model is needed. |
| **Vosk / gdvosk not benchmarked** | Its model host was blocked in the cloud sandbox. Stated performance: small-en 40 MB, 9.85% LibriSpeech WER, true grammar mode, but no release since 2022. | Optional local A/B (follow-up #4). |
| **Windows / Android / iOS builds untested** | Only Linux was compiled and run. `tools/setup.py --platform windows-x64` / `android` fetch and install the pinned libraries, but the MSVC build, the Android NDK build and a real mic were never exercised. | First local task (section 1). Watch for `onnxruntime_providers_shared.dll`, which is listed as a Windows dependency. |
| **Latency numbers from contended runs** | The `results/final-*` accuracy runs ran three at a time, so their latency/RTF columns are inflated. | Use the sequential latency table in `docs/stt-evaluation.md`, or re-run on the PC. |
| **Child-voice numbers are a proxy** | `child` = adult audio pitched up 20%. No published child-speech WER exists for Parakeet-110M or the Zipformer. Small Whisper models are 2–7× worse on kids than on LibriSpeech (Fan et al. 2024). | The calibration recordings (section 3) replace this. |
| **Old commits contain `pron_dict.txt`** | Commits 3180ba2 and 27bfe06 still hold the 2.9 MB CMUdict-derived file (BSD-2, so redistribution is fine). It is now generated by `tools/setup.py`. | Optional: squash or rewrite the branch before merging if a clean history matters. |
| **Criteria-vs-stated-performance table not written** | The research on stated WER, latency and licences is summarized in this table and in `docs/stt-evaluation.md`. A one-table "target / stated / measured / pass" matrix was not added. | Add it to `docs/stt-evaluation.md` if useful. |

## 9. Mobile (later)

See the "Mobile" section in `docs/stt-evaluation.md`. Summary:
- Android arm64 is straightforward: sherpa-onnx ships the `.so` files, and you
  build the extension with the Android NDK.
- Plan for about 160 MB of model and runtime.
- Request the RECORD_AUDIO permission at runtime.
