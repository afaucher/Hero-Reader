# hero_listen: GDExtension for on-device word recognition

`WordListener` is a Godot node that listens for the words currently on screen.
It wraps the [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) C API
(v1.13.8), runs recognition on a worker thread, and emits signals on the main thread.

```gdscript
var listener := WordListener.new()
add_child(listener)
listener.load_model(HeroSpeech.config_for("parakeet-110m-hot"))
listener.set_words(["cat", "dog", "sun"])          # whatever is on screen now
listener.word_heard.connect(func(word, heard, latency_ms): blast(word))
listener.heard_other.connect(func(heard): show_miss())  # no penalty, "try again"
listener.voice_started.connect(func(): charge_laser())  # instant feedback
# each frame: listener.push_frames(capture.get_buffer(n), AudioServer.get_mix_rate())
```

See `godot/scenes/stt_test.gd` for the full microphone setup.

## Build

You need:
- Python 3 with `scons`
- a C++17 compiler
- godot-cpp at tag `godot-4.5-stable`
- the sherpa-onnx shared release for your platform

The easy way is `python tools/setup.py --build`. It fetches the pinned
godot-cpp and sherpa-onnx (see `third_party/manifest.json`), copies the runtime
libraries into `godot/addons/hero_listen/bin/`, and runs:

```sh
cd native/hero_listen
SHERPA_ONNX_DIR=../../third_party/sherpa-onnx/<platform> GODOT_CPP_DIR=../../third_party/godot-cpp \
  scons platform=<linux|windows|macos|android> target=template_debug
```

The library lands in `godot/addons/hero_listen/bin/`, next to the sherpa-onnx
runtime libraries. They are listed under `[dependencies]` in
`hero_listen.gdextension`, so Godot packages them on export.
`--platform android` fetches the arm64 libraries; the Android build itself also
needs the NDK.

| Platform | sherpa-onnx archive | Copy into `bin/` |
|---|---|---|
| Linux x86_64 | `sherpa-onnx-v1.13.8-linux-x64-shared.tar.bz2` | `lib/libsherpa-onnx-c-api.so`, `lib/libonnxruntime.so` |
| Windows x86_64 | `sherpa-onnx-v1.13.8-win-x64-shared-MD-Release.tar.bz2` (MSVC) | `sherpa-onnx-c-api.dll`, `onnxruntime.dll`, `onnxruntime_providers_shared.dll` (link against `sherpa-onnx-c-api.lib`) |
| macOS | `sherpa-onnx-v1.13.8-osx-universal2-shared.tar.bz2` | `libsherpa-onnx-c-api.dylib`, `libonnxruntime.dylib` |
| Android arm64 | `sherpa-onnx-v1.13.8-android.tar.bz2` | `jniLibs/arm64-v8a/*.so` into `bin/android/arm64-v8a/` |
| iOS | build `sherpa-onnx.xcframework` with `build-ios.sh` from the sherpa-onnx repo | a static GDExtension, see "Mobile" in `docs/stt-evaluation.md` |

For Windows with MSVC, run the commands from a "x64 Native Tools" prompt with
`platform=windows`. The SConstruct links `sherpa-onnx-c-api`, which MSVC
resolves to the `.lib` import library.

## Model files

sherpa-onnx opens models by filesystem path. `HeroSpeech.config_for()`
handles this for you:
- **Editor:** files are used where they are (`res://models`, filled by `tools/setup.py`, or the `HERO_MODELS` env var).
- **Exported builds, including mobile:** files are copied out of the package to
  `user://models` once.

Hotword boosting writes a small `_hotwords_bpe.vocab` next to the model's
`tokens.txt`, so that folder must be writable. `user://` always is.

## Config keys (`load_model`)

| key | meaning | default |
|---|---|---|
| `kind` | `"streaming"` (zipformer / NeMo transducer) or `"vad_offline"` (Silero VAD + offline model) | `streaming` |
| `family` | vad_offline only: `transducer` (Parakeet), `moonshine_v2`, `whisper` | `transducer` |
| `encoder`, `decoder`, `joiner`, `tokens` | model files (absolute paths) | |
| `model_type` | `""` or `"nemo_transducer"` | |
| `hotwords` | bias decoding toward the on-screen words (transducers only) | `false` |
| `hotwords_score`, `beam` | hotword boost / beam width | 3.0 streaming, 1.5 offline / 8 |
| `vad_model`, `min_silence`, `preroll` | Silero VAD file, hang-over seconds, lead-in seconds | `0.25`, `0.25` |
| `pron_dict` | CMU-style dictionary enabling sound-alike matches (`godot/data/pron_dict.txt`) | off |
| `threads` | inference threads | 2 |
