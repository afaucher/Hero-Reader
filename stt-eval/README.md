# stt-eval: speech recognition benchmark for Hero Reader

The evaluation behind `docs/stt-evaluation.md`. The exact commands for every
result are in `docs/REPRODUCE.md`.

| File | What |
|---|---|
| `download_models.py` | fetch sherpa-onnx models (+ Speech Commands with `--speech-commands`) |
| `engines.py` | every engine/config behind one streaming interface (`make_engine("parakeet-110m-hot")`) |
| `matcher.py` | closed-set matcher: on-screen words, homophones, sound-alike (mirrors the C++ one) |
| `dataset.py` | Speech Commands + your own recordings, noise mixing, child-voice proxy |
| `benchmark.py` | accuracy + real-time latency simulation → `results/<out>/{summary,trials}-*.{md,json,csv}` |
| `rescore.py` | re-apply sound-alike matching to saved transcripts |
| `footprint.py` | memory / single-thread speed for mobile estimates |
| `live_mic.py` | terminal live-mic test (needs `sounddevice`) |
| `record_words.py` | terminal recorder (the Godot recorder scene is nicer) |

Quick start:

```sh
pip install -r requirements.txt
python download_models.py
python live_mic.py --engine parakeet-110m-hot            # talk to it
python benchmark.py --recordings recordings/8f --engines parakeet-110m-hot zipformer-hot --sound-alike
```
