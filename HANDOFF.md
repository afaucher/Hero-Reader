# Handoff: next steps for a local session (with a mic and Godot)

The cloud session proved out the speech pipeline on recorded data and inside
headless Godot. What it could not do is the part that matters most: hear
**real voices through a real microphone**, especially kids. This file is the
checklist for a local Claude Code session (or a human) on the family PC.

Read `docs/stt-evaluation.md` first for the why. TL;DR:
- **Two co-finalists**, both presets in the game and both running through the
  `WordListener` GDExtension (`native/hero_listen`):
  - **`parakeet-110m-hot`** (current default): NVIDIA Parakeet-TDT 110M behind a
    Silero VAD. Tightest latency and best in noise.
  - **`zipformer-hot`**: streaming. Led on the child-voice proxy and is half the size.
- **Real kid recordings decide between them.** That is the main job of this handoff.

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
| Nora (6f) | if she's up for it: even one round is gold |

Recordings go to `%APPDATA%\Godot\app_userdata\Hero Reader\recordings\<age><gender>\<session>\`
with a `manifest.csv` and `session.json`. They stay on the PC: copy them to
`stt-eval/recordings/` (git-ignored) and never commit them.

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
| 9 | Game loop: falling words, laser, shields, levels and Worlds from `docs/game-design.md` | **local** | next big task |
| 10 | Art: expression variants per character, plus enemy and scenario sprites | cloud or local | style + 3 portraits done |
| 11 | Decisions only you can make: corgi's name, Nora's suit color and bangs, the 10 questions at the end of `docs/game-design.md` | you | open |
| 12 | Publish `docs/stt-evaluation.md` as a shareable web page | cloud | on request |

## 7. Other open threads

- **Art:** style A ("Cosmic Storybook" flat vector) is chosen, with likeness as close
  as possible.
  - Drafts: `godot/art/characters/*.svg` and `godot/art/cast_v2.png`.
  - Style guide: `godot/art/STYLE.md`.
  - Still open: the corgi's name (maybe Nora picks), Nora's suit color, and her
    bang direction.
  - Reference photos must stay out of the repo (`art/reference/` is git-ignored).
- **Game design:** `docs/game-design.md`.
- **Leveled word lists:** `godot/data/wordlists/levels/`, generated by `build_levels.py`.
  They include per-World `confusable` pairs for the spawner.

## 8. Mobile (later)

See the "Mobile" section in `docs/stt-evaluation.md`. Summary:
- Android arm64 is straightforward: sherpa-onnx ships the `.so` files, and you
  build the extension with the Android NDK.
- Plan for about 160 MB of model and runtime.
- Request the RECORD_AUDIO permission at runtime.
