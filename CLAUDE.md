# Hero Reader: notes for Claude sessions

An early-reader game for kids 6+ in Godot 4.7. The child reads a falling word
aloud and it gets zapped. Speech recognition runs on-device through our
`WordListener` GDExtension, which wraps sherpa-onnx.

**Start with `HANDOFF.md`** (current task list), then `docs/stt-evaluation.md`
(model choice and why) and `docs/game-design.md`.

## What may be checked in

Only our own work: code, docs, word lists, our SVG art, benchmark summaries.

**Never commit:**
- **Third-party code, binaries, models or datasets.** Pin them in
  `third_party/manifest.json` (URL + version/commit + sha256) and fetch them with
  `tools/setup.py`. Generated files such as `godot/data/pron_dict.txt` (built from
  CMUdict) are covered by this rule too.
- **Voice recordings of family members**, kids especially. They live in Godot's
  `user://recordings` or `stt-eval/recordings/`, both git-ignored.
- **Reference photos** of real people (`art/reference/` is ignored).
- **Build outputs:** `godot/.godot/`, `godot/addons/hero_listen/bin/*`, `*.o`/`*.os`.

Check `git status` before committing; `.gitignore` covers these paths.

## Setup

```sh
python tools/setup.py --venv --build       # runtime libs, recommended models, godot-cpp, venv, extension
python tools/setup.py --with dataset godot # optional: Speech Commands test set, Godot editor
python tools/setup.py --list               # what's pinned, by group, with licences
```

On Windows, run `--build` from an "x64 Native Tools Command Prompt for VS"
(MSVC). Models land in `godot/models/`, which both Godot (`res://models`) and
`stt-eval` (default `STT_MODELS`) read.

## Common commands

```sh
godot --path godot                                    # dev menu: Speech test / Record voices
godot --headless --path godot --script res://tests/headless_wav_test.gd -- \
      --clips third_party/data/speech_commands --n 40 # end-to-end check in Godot
godot --headless --path godot --script res://tests/recorder_test.gd -- third_party/data/speech_commands
cd stt-eval && .venv/bin/python benchmark.py --engines parakeet-110m-hot zipformer-hot \
      --hot-score 1.5 --beam 8 --sound-alike --trials 300  # see docs/REPRODUCE.md
```

After changing `native/hero_listen/src`, rebuild with `python tools/setup.py --only --build`
and rerun the headless test.

## Conventions

- **Keep the matchers in step.** The C++ matcher (`native/hero_listen/src/word_matcher.cpp`)
  and the Python one (`stt-eval/matcher.py`) must behave the same; change both together.
- **Model presets** have the same names in `godot/addons/hero_listen/hero_speech.gd` and
  `stt-eval/engines.py`.
- **Feedback is always positive** ("try again", never "you lose"). Art follows
  `godot/art/STYLE.md`.
