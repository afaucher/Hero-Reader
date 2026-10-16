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
python tools/setup.py --venv --with models-eval dataset   # ~1.8 GB of models + 2.3 GB dataset
. stt-eval/.venv/bin/activate                              # Windows: stt-eval\.venv\Scripts\activate
```

- **Models** come from the sherpa-onnx GitHub releases (`asr-models`, `kws-models` tags).
  Exact URLs and sha256 pins are in `third_party/manifest.json`. They unpack to
  `godot/models/`, which `stt-eval` uses by default (override with `STT_MODELS`).
- **Pronunciation dictionary:** the CMU Pronouncing Dictionary at a pinned commit,
  converted to `godot/data/pron_dict.txt` by `tools/setup.py`.
- **Test audio** is Google Speech Commands v0.02, unpacked to `third_party/data/speech_commands` (CC-BY 4.0), using the official
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
python tools/setup.py --build --with godot   # runtime libs + godot-cpp + compile WordListener + Godot 4.7
G=third_party/godot/Godot_v4.7-stable_linux.x86_64
$G --headless --path godot --import
# end-to-end: real WAVs streamed in real time into WordListener, 5 words on screen
$G --headless --path godot --script res://tests/headless_wav_test.gd -- \
  --preset parakeet-110m-hot --clips $PWD/third_party/data/speech_commands --n 60
# recorder: simulated session (2 rounds) -> WAVs + manifest
$G --headless --path godot --script res://tests/recorder_test.gd -- $PWD/third_party/data/speech_commands
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
6. **Hotword runs crashed on Windows** with `UnicodeEncodeError`. The generated
   `_hotwords_bpe.vocab` holds "▁" pieces, and Python before 3.15 writes text in the
   ANSI code page by default. `engines.py` and `benchmark.py` now write UTF-8 explicitly.

## 6. Local PC re-evaluation (October 2026)

| | |
|---|---|
| Machine | AMD Ryzen 9 7950X3D (16 cores / 32 threads), Windows 11, otherwise idle (< 5% CPU during runs) |
| Python | 3.14.2; `stt-eval/.venv` with sherpa-onnx 1.13.8, numpy 2.5, scipy 1.18 |
| Vosk venv | separate, so `stt-eval/.venv` keeps its pins: `third_party/venv-vosk` with vosk 0.3.45, onnxruntime 1.31, sherpa-onnx 1.13.8 |
| Threads | 2 per sherpa-onnx engine; Vosk is single-threaded |

Every run below ran alone, one after another, so latency and RTF are uncontended.

```sh
python tools/setup.py --only dataset models-eval   # adds vosk-model-small-en-us-0.15 (pinned)
python -m venv third_party/venv-vosk                # git-ignored; Windows: third_party\venv-vosk\Scripts\python
third_party/venv-vosk/bin/pip install vosk==0.3.45 sherpa-onnx==1.13.8 numpy scipy soundfile onnxruntime
cd stt-eval
PY=.venv/bin/python; VPY=../third_party/venv-vosk/bin/python   # Scripts\python.exe on Windows

# 1. finalists, uncontended
$PY benchmark.py --engines parakeet-110m-hot --hot-score 1.5 --beam 8 --sound-alike --silence 0.2 \
  --trials 300 --conditions clean noise10 child --out results/local-final-parakeet
$PY benchmark.py --engines zipformer-hot --hot-score 3 --beam 8 --sound-alike \
  --trials 300 --conditions clean noise10 child --out results/local-final-zipformer
$PY benchmark.py --engines parakeet-110m-hot --hot-score 1.5 --beam 8 --sound-alike --silence 0.2 --hard \
  --trials 300 --out results/local-hard-parakeet
$PY benchmark.py --engines zipformer-hot --hot-score 3 --beam 8 --sound-alike --hard \
  --trials 300 --out results/local-hard-zipformer

# 2. Vosk: grammar mode (on-screen words + [unk]) and open vocabulary
$VPY benchmark.py --engines vosk-grammar vosk --sound-alike --trials 300 \
  --conditions clean noise10 child --out results/local-vosk
$VPY benchmark.py --engines vosk-grammar --sound-alike --hard --trials 300 --out results/local-hard-vosk
$VPY benchmark.py --engines vosk-grammar --sound-alike --trailing 0.15 --trials 300 --out results/local-vosk-trailing0.15

# 3. candidate scoring prototype (Parakeet TDT log-likelihood of each on-screen word)
$VPY candidate_scoring.py --check 150      # numpy frontend vs sherpa-onnx: 117/150 identical, rest mostly punctuation
$VPY candidate_scoring.py --engines parakeet-110m-score --sound-alike --silence 0.2 --trials 300 \
  --conditions clean noise10 child --out results/local-score-parakeet

# thresholds for vosk-grammar (min_conf 0.9) and candidate scoring (reject 6, margin 3),
# picked on seed 11 so the seed-7 results above are not tuned on themselves
$VPY tune_closed_set.py vosk-grammar
$VPY tune_closed_set.py parakeet-110m-score

# 4. follow-up: matcher rules and Zipformer hotword strength (events logged per trial)
$PY benchmark.py --engines parakeet-110m-hot --hot-score 1.5 --beam 8 --sound-alike --silence 0.2   --trials 300 --conditions clean noise10 child --out results/local-events-parakeet
for h in 3 2 1.5; do $PY benchmark.py --engines zipformer-hot --hot-score $h --beam 8 --sound-alike   --trials 300 --conditions clean noise10 child --out results/local-events-zipformer-hot$h; done
STRESS="--trials 300 --hard --hard-negatives --sight-words the look my me you and is it see said"
$PY benchmark.py --engines parakeet-110m-hot --hot-score 1.5 --beam 8 --sound-alike --silence 0.2 $STRESS   --out results/local-stress-parakeet
for h in 3 2 1.5; do $PY benchmark.py --engines zipformer-hot --hot-score $h --beam 8 --sound-alike $STRESS   --out results/local-stress-zipformer-hot$h; done
$VPY benchmark.py --engines vosk-grammar --sound-alike $STRESS --out results/local-stress-vosk-grammar
$PY replay_matcher.py "results/local-events-*/trials-*.csv" "results/local-stress-*/trials-*.csv"
$PY replay_matcher.py --wordlists          # misreads each rule accepts among the game's words

# 5. real voice: adult male session (git-ignored recordings in stt-eval/recordings/adultm/)
REC="--recordings recordings/adultm/20261016-134130 --trials 400 --onscreen 5 --sound-alike"
O=results/local-calib-adultm-s2
for H in "" "--hard"; do S=${H:+-hard}
  $PY benchmark.py $REC $H --engines parakeet-110m-hot --hot-score 1.5 --beam 8 --silence 0.2 --out $O-parakeet-hot1.5$S
  $PY benchmark.py $REC $H --engines parakeet-110m-hot --hot-score 2 --beam 8 --silence 0.2 --out $O-parakeet-hot2$S
  $PY benchmark.py $REC $H --engines parakeet-0.6b-hot --hot-score 1.5 --beam 8 --silence 0.2 --out $O-parakeet0.6b-hot1.5$S
  for h in 3 2 1.5; do $PY benchmark.py $REC $H --engines zipformer-hot --hot-score $h --beam 8 --out $O-zipformer-hot$h$S; done
  $VPY benchmark.py $REC $H --engines vosk-grammar --out $O-vosk-grammar$S
done
$PY replay_matcher.py "$O-*/trials-*.csv"  # per-rule numbers in the real-voice table
```

Notes:
- **Replaying matcher rules:** `--sight-words`, `--hard-negatives` and the `events`
  column do not change the default trials. The stress options draw from their own
  random stream, which was checked row by row. The follow-up runs had about 7%
  background CPU load from other work, so their RTF is about 30% higher.
- **Vosk endpointing:** the vosk 0.3.45 Python API reads endpointing only from
  `conf/model.conf`. `VoskEngine` makes a copy of the model (`…-rule2-<s>`, under
  `godot/models`) with `rule2.min-trailing-silence` set to `--trailing`, the same
  value the sherpa streaming engines use.
- **Vosk grammar mode** decides on the endpointed result only. Its partial results
  are forced onto an on-screen word mid-utterance.
- **Same trials as the cloud runs:** the `local-final-*` and `local-hard-*` trials
  match the cloud `final-*` runs row for row (word, speaker, on-screen set). They differ
  in 0–5 outcomes per run because the int8 kernels differ between the CPUs.
- **Moonshine and kid-speech models:** no new model was pinned. No newer sherpa-onnx
  Moonshine export exists, and the Pasketti kid-speech weights have no sherpa-onnx
  export (status as of 2026-10-16 in `docs/stt-evaluation.md`).
