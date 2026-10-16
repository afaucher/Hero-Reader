# Reproducing the speech evaluation

Every number in `docs/stt-evaluation.md` comes from the commands below. Raw
per-trial results (what each model heard, latency, on-screen words) are in
`stt-eval/results/*/trials-*.csv`; summaries are next to them.

## Environment used

| | |
|---|---|
| Machine | cloud Linux container, 4 vCPU Intel Xeon @ 2.1 GHz, 16 GB RAM, no GPU |
| Python | 3.13, `sherpa-onnx 1.13.8`, numpy 2.5, scipy 1.18, soundfile 0.14, cmudict 1.1.3 |
| Godot | 4.7-stable (Linux x86_64), headless |
| godot-cpp | tag `godot-4.5-stable` (an extension built against 4.5 loads in 4.5+) |
| sherpa-onnx native | v1.13.8 prebuilt shared libraries (GitHub releases) |
| Threads | 2 inference threads per engine unless noted |

A desktop PC is typically 1.5–3× faster per core than this container, so expect
lower RTF and slightly lower latency there. Accuracy does not depend on speed.

## 1. Data and models

```sh
cd stt-eval
python -m venv .venv && . .venv/bin/activate      # Windows: .venv\Scripts\activate
pip install -r requirements.txt
python download_models.py --all --speech-commands   # ~1.5 GB of models + 2.3 GB dataset
```

- **Models** come from the sherpa-onnx GitHub releases (`asr-models`, `kws-models` tags).
  The exact archive names are in `download_models.py`.
- **Test audio** is Google Speech Commands v0.02 (CC-BY 4.0), using the official
  `testing_list.txt` split: 10,598 clips, 33 words, about 2,600 mostly adult speakers.
  The proper names "marvin" and "sheila" are excluded.

## 2. What one trial is

`benchmark.py` simulates one moment of gameplay per trial:
- **Screen:** 5 words are on screen, the spoken word plus 4 random distractors (`--hard`
  picks sound-alike or look-alike distractors instead).
- **Audio:** 0.4 s of room tone, the word (trimmed and level-normalized), then 1.2 s of
  room tone. It is streamed in 20 ms chunks, like a game's mic buffer.
- **Real-time clock:** a chunk arrives at its audio timestamp. Its processing starts
  when it has arrived *and* the previous chunk is done, and an event's time is when
  its chunk finished processing.
- **Latency** is that event time minus the end of the spoken word, using an energy
  detector with a noise-floor-aware threshold. Expect ±20–40 ms of error.
- **Outcome:** the first on-screen word the engine fires on is the decision.
  - **hit:** it fired on the right word.
  - **wrong word:** it fired on a different on-screen word.
  - **no fire:** nothing fired.
- **Negative trials:** 25% extra trials play a word that is *not* on screen (plus any
  `_other` recordings). Firing on anything there is a **false accept**.
- **Conditions:**
  - `clean`
  - `noise10`: Speech Commands background noise mixed at 10 dB SNR
  - `child`: a crude child-voice proxy. The audio is resampled ×1.2, raising pitch and
    formants about 20%. It is a stress test, not a substitute for kids.
- **Determinism:** the same seed (7) gives every engine the same trials.

## 3. Commands behind each results folder

```sh
cd stt-eval
# results/clean: all 17 engine configs, default settings (beam 4, hotword score 2)
python benchmark.py --engines zipformer zipformer-hot zipformer20m kroko kroko-hot nemo80 kws \
  whisper-tiny.en whisper-base.en moonshine-tiny moonshine-base moonshine2-tiny moonshine2-base \
  parakeet-110m parakeet-110m-hot parakeet-0.6b parakeet-0.6b-hot --trials 300 --conditions clean --out results/clean

# sound-alike matching applied to those saved transcripts (no re-recognition)
python rescore.py results/clean/trials-*.csv

# results/finalists-streaming: hotwords fixed (beam 8, score 3)
python benchmark.py --engines zipformer-hot kroko-hot --trials 300 --beam 8 --hot-score 3 \
  --conditions clean noise10 child --out results/finalists-streaming

# results/finalists-offline: offline models with VAD lead-in (pre-roll 0.25 s)
python benchmark.py --engines parakeet-110m whisper-base.en nemo80 --trials 300 \
  --conditions clean noise10 child --out results/finalists-offline

# hotword strength sweep for the offline transducer (scratch runs, numbers in the evaluation)
python benchmark.py --engines parakeet-110m-hot --trials 300 --beam 8 --hot-score {1.0,1.5,3,6}

# results/final-*: the recommended configurations
python benchmark.py --engines parakeet-110m-hot --hot-score 1.5 --beam 8 --sound-alike --silence 0.2 \
  --trials 300 --conditions clean noise10 child --out results/final-parakeet
python benchmark.py --engines zipformer-hot --hot-score 3 --beam 8 --sound-alike \
  --trials 300 --conditions clean noise10 child --out results/final-zipformer
python benchmark.py --engines parakeet-110m-hot --hot-score 1.5 --beam 8 --sound-alike --silence 0.2 --hard \
  --trials 300 --out results/final-hard-parakeet
python benchmark.py --engines zipformer-hot --hot-score 3 --beam 8 --sound-alike --hard \
  --trials 300 --out results/final-hard-zipformer
for s in 0.15 0.2; do python benchmark.py --engines parakeet-110m-hot --hot-score 1.5 --beam 8 \
  --sound-alike --silence $s --trials 300 --out results/final-silence$s; done

# mobile-oriented footprint (single thread, own process each)
for e in parakeet-110m-hot zipformer-hot moonshine2-tiny whisper-tiny.en; do python footprint.py $e --threads 1; done
```

Two final runs (`final-parakeet` and `final-zipformer`) ran in parallel with a
third on the 4-core container. Their RTF and latency carry a little contention
compared with the sequential runs; accuracy is unaffected.

## 4. Inside Godot

```sh
# build the extension (Linux shown; see native/hero_listen/README.md for others)
git clone --depth 1 --branch godot-4.5-stable https://github.com/godotengine/godot-cpp deps/godot-cpp
curl -LO https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.8/sherpa-onnx-v1.13.8-linux-x64-shared.tar.bz2
tar xjf sherpa-onnx-v1.13.8-linux-x64-shared.tar.bz2 && mv sherpa-onnx-v1.13.8-linux-x64-shared deps/sherpa-onnx
(cd native/hero_listen && SHERPA_ONNX_DIR=../../deps/sherpa-onnx GODOT_CPP_DIR=../../deps/godot-cpp \
   scons platform=linux target=template_debug)
cp deps/sherpa-onnx/lib/libsherpa-onnx-c-api.so deps/sherpa-onnx/lib/libonnxruntime.so godot/addons/hero_listen/bin/

godot --headless --path godot --import
# end-to-end: real WAVs streamed in real time into WordListener, 5 words on screen
HERO_MODELS=$PWD/stt-eval/models godot --headless --path godot --script res://tests/headless_wav_test.gd -- \
  --preset parakeet-110m-hot --clips $PWD/stt-eval/data/speech_commands --n 60
# recorder: simulated session (2 rounds) -> WAVs + manifest
godot --headless --path godot --script res://tests/recorder_test.gd -- $PWD/stt-eval/data/speech_commands
```

## 5. Bugs found along the way

These are worth knowing if you change the code.

1. **Hotwords silently did nothing at first.** There were two causes:
   - With beam 4, the boosted word was rarely in the beam. Use beam 8.
   - The generated `bpe.vocab` gave every token the same score, so sherpa-onnx spelled
     hotwords letter by letter ("▁L E F T"), which never matches the model's own
     "▁LEFT". Every token now scores −1, which prefers the fewest pieces.

   Verify with a huge boost (score 30) on a misheard clip: the boosted word must appear.
2. **VAD clipped word onsets.** Silero only reports speech after it starts, so offline
   models never heard the first consonant. Keeping a ring buffer and adding 250 ms of
   lead-in raised accuracy 6–13 points (Parakeet 64.5→70.6%, Whisper-base 66.9→75.7%,
   Moonshine v2 tiny 49→62%).
3. **End-of-word detection** at −25 dB cut quiet word endings ("hap-py"). It is now
   −40 dB re peak and +9 dB above the noise floor.
4. **Kroko's latency tail** (p90 about 1.3 s) is structural. It holds its last token
   until more audio or end of input arrives, so it is excluded despite its good accuracy.
5. **`zipformer20m`** outputs nothing in this harness, with int8 or fp32 weights alike.
   It was not investigated further.
