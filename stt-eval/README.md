# stt-eval: speech recognition benchmark for Hero Reader

The evaluation behind `docs/stt-evaluation.md`. The exact commands for every
result are in `docs/REPRODUCE.md`.

| File | What |
|---|---|
| `engines.py` | every engine/config behind one streaming interface (`make_engine("parakeet-110m-hot")`); `vosk` / `vosk-grammar` need the separate Vosk venv (`docs/REPRODUCE.md` §6) |
| `matcher.py` | closed-set matcher: on-screen words, homophones, sound-alike (mirrors the C++ one) |
| `dataset.py` | Speech Commands + your own recordings, noise mixing, child-voice proxy |
| `benchmark.py` | accuracy + real-time latency simulation → `results/<out>/{summary,trials}-*.{md,json,csv}` |
| `rescore.py` | re-apply sound-alike matching to saved transcripts |
| `candidate_scoring.py` | prototype: score each on-screen word with Parakeet's TDT log-likelihood (engine `parakeet-110m-score`; needs onnxruntime, Vosk venv) |
| `tune_closed_set.py` | picks the vosk-grammar / candidate-scoring thresholds on seed 11 |
| `replay_matcher.py` | re-decides saved trials under each sound-alike rule (exact / any / no-onset / extra-only); `--wordlists` counts the misreads each rule accepts among the game's words |
| `footprint.py` | memory / single-thread speed for mobile estimates |
| `live_mic.py` | terminal live-mic test (needs `sounddevice`) |
| `record_words.py` | terminal recorder (the Godot recorder scene is nicer) |

Models and data are not in the repo. `python tools/setup.py --venv` (from the repo
root) fetches them into `godot/models/` and creates `.venv` here. Add
`--with models-eval dataset` for every evaluated model and the Speech Commands set.

Quick start:

```sh
python live_mic.py --engine parakeet-110m-hot            # talk to it
python benchmark.py --recordings recordings/8f --engines parakeet-110m-hot zipformer-hot --sound-alike
```
