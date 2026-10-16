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

1. Install Godot **4.7** and Python 3.11+.
2. Install the Python tools and download the models and dataset:
   ```
   cd stt-eval
   python -m venv .venv && .venv\Scripts\activate
   pip install -r requirements.txt scons
   python download_models.py            # ~250 MB into stt-eval/models
   python download_models.py --speech-commands   # optional, 2.3 GB public test set
   ```
3. Build the extension for Windows. Follow `native/hero_listen/README.md`
   (MSVC, `platform=windows`) and copy the two sherpa-onnx DLLs into
   `godot/addons/hero_listen/bin/`.
4. Point Godot at the models: set `HERO_MODELS` to the absolute path of
   `stt-eval/models`, or copy that folder to `godot/models` (both are git-ignored).
5. Sanity check. This should print about 75–80% hits and roughly 300–400 ms latency:
   ```
   godot --headless --path godot --script res://tests/headless_wav_test.gd -- --clips stt-eval/data/speech_commands --n 40
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

## 6. Other open threads

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

## 7. Mobile (later)

See the "Mobile" section in `docs/stt-evaluation.md`. Summary:
- Android arm64 is straightforward: sherpa-onnx ships the `.so` files, and you
  build the extension with the Android NDK.
- Plan for about 160 MB of model and runtime.
- Request the RECORD_AUDIO permission at runtime.
