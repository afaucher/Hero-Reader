# Speech-to-text for Hero Reader: evaluation and recommendation

*October 2026. Reproduce everything with `docs/REPRODUCE.md`. Next steps on a real PC are in `HANDOFF.md`.*

## TL;DR

- **Use [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) inside Godot through our own small
  GDExtension (`WordListener`, in `native/hero_listen`).** It is MIT/Apache, active, and runs
  fully offline. It ships prebuilt Windows, Linux, macOS and Android libraries, and one
  runtime runs every model we tested.
- **Default model: NVIDIA Parakeet-TDT 110M (int8)** with this setup:
  - a Silero VAD with 250 ms of lead-in;
  - per-utterance hotword boosting toward the on-screen words (score 1.5, beam 8);
  - a closed-set matcher with homophones and sound-alike tolerance.
- **Co-finalist: the streaming Zipformer (2023-06-26, int8)** with hotwords. It ties
  Parakeet on clean audio (81.4%) and did *better* on the child-voice proxy (79% vs 74%)
  with zero false accepts. It is worse in noise (73% vs 76%), has a longer latency
  tail (p90 about 670 ms vs 420 ms), and is half the size (68 MB).
  **The calibration recordings (real kids) should pick between these two.** Both are
  presets in the game, switchable at runtime.
- **Recognition is a closed-set problem, not dictation.** We only ever ask "which of
  these ~5 words, if any?". That makes **wrong-word zaps rare (about 0.3%)** as long as
  sound-alike words aren't on screen together. The failure mode is a *miss*, and the
  game design already makes misses free.
- **Measured on 10,598 crowd-sourced one-word recordings** (Speech Commands: noisy,
  often muffled or truncated, mostly adults):

  | Condition | Hit rate | Wrong word | False accepts |
  |---|---|---|---|
  | Clean | **81%** | 0.3% | 0% |
  | 10 dB noise | 76% | 1.4% | 1.4% |
  | Crude child-voice proxy | 74% | 0.7% | 2.7% |

  About 8% of these clips are missed by *every* model, so on clear speech from a
  close mic expect noticeably higher. **The real number to get is Nora's, and the 8f's,
  through the PC mic.** `HANDOFF.md` has the recorder and steps.
- **Latency from end of word to zap:** **about 350 ms median, 420 ms p90** at 0.2 s VAD
  silence, and about 290/360 ms at 0.15 s with no accuracy loss on this data.
  - Inside Godot, measured end to end: 310–390 ms median.
  - Compute is 3.5% of one 2.1 GHz core.
  - The game should still give *instant* feedback when a voice is detected
    (`voice_started`), such as the cannon charging, so the remaining delay feels like
    the laser's travel time.
- **Mobile is feasible.** Android arm64 needs about 160 MB (model + runtime), about
  230 MB of RAM, and about 90 ms of single-thread compute per word on this CPU
  (around 150–250 ms on a mid-range phone). iOS needs a source build of sherpa-onnx.

## 1. The problem, precisely

| Requirement | What it means for speech recognition |
|---|---|
| Kid reads a word on screen; it gets blasted | Closed vocabulary: 2–8 known words at a time, changing constantly |
| "High accuracy" | Never zap the *wrong* word. Rarely miss a correctly read word, ideally under 10%. |
| "Extremely low latency" | Under ~400 ms from end of word to zap; instant "I hear you" feedback |
| Local, PC first; then mobile? | Fully offline, CPU only, embeddable in Godot on Windows (then Android/iOS) |
| Age 6+ | Child voices, slow reading, sounding-out ("c… a… t… cat"), chatter |

## 2. Options considered

### Godot plugins that exist today

These are from the Oct 2026 survey (sources at the end). We couldn't open every page
directly, so treat the details as approximate.

| Plugin | Engine | State | Fit |
|---|---|---|---|
| [godot-whisper](https://github.com/appsinacup/godot-whisper) | whisper.cpp | Active, Godot 4.3+, Win/Linux/macOS/Android prebuilt, MIT | No grammar/vocabulary constraint exposed; not truly streaming; open issues on short words and hallucinating on silence. Whisper was also weaker and slower in our tests. |
| [gdvosk](https://github.com/Nihlus/gdvosk) | Vosk (Kaldi) | Small single-maintainer project, Godot 4.5+ | Real grammar mode (closed vocabulary) and streaming. But Vosk is dated (adult-trained, project barely active), and changing the word list means re-creating the recognizer. Not benchmarked: the Vosk model host was blocked from the cloud sandbox. Worth a local A/B if curious. |
| sherpa-onnx | ONNX Runtime | No maintained Godot ASR plugin | Best engine fit (below). We wrote the ~600-line GDExtension ourselves. |

### Why sherpa-onnx

- **One runtime, every modern small model:** streaming Zipformer and NeMo transducers,
  Parakeet, Whisper, Moonshine v1/v2, a keyword spotter, and Silero VAD.
- **Per-utterance hotwords:** it can bias decoding toward exactly the words on screen,
  changing every utterance.
- **A plain C API with prebuilt libraries** for Windows, Linux, macOS and Android, plus
  build scripts for iOS.
- **Very active:** v1.13.8, Sep 2026.

### Models benchmarked (all int8 unless noted)

- **Streaming (partial results while speaking):**
  - Zipformer en 2023-06-26 (68 MB)
  - Zipformer 20M
  - Kroko 2025-08 (fp32)
  - NeMo FastConformer 80 ms
  - the GigaSpeech keyword spotter (KWS)
- **Offline behind a VAD:**
  - Whisper tiny.en / base.en
  - Moonshine tiny/base, v1 and v2 (2026)
  - Parakeet-TDT 110M and 0.6B v2

## 3. Method (short)

There are 300 positive trials per configuration plus 75 negative ones (the word is
*not* on screen). Each trial has 5 words on screen and streams 0.4 s of room tone,
the word, then 1.2 s of tail in 20 ms chunks.

The latency clock is simulated in real time, compute included. Latency is measured
from the end of the spoken word (energy-detected) to the zap.

Conditions:
- **clean**
- **noise10:** 10 dB SNR room noise
- **child:** pitch and formants raised about 20%. This is crude; real kids differ in
  much more than pitch.

Details and exact commands are in `REPRODUCE.md`.

## 4. Results

### Round 1: every model, default settings (clean)

| Engine | Hit % | Wrong % | No fire % | + sound-alike hit % | Latency p50 / p90 | RTF* |
|---|---:|---:|---:|---:|---|---:|
| zipformer (streaming) | 74.0 | 0.3 | 25.7 | 78.0 | 493 / 704 ms | 0.077 |
| kroko (streaming, fp32) | 77.7 | 0.0 | 22.3 | 80.1 | 670 / 1331 ms | 0.068 |
| nemo80 (streaming) | 77.7 | 0.0 | 22.3 | 81.4 | 540 / 867 ms | 0.43 |
| kws (keyword spotter) | 38.5 | 0.3 | 61.1 | 38.5 | 331 / 539 ms | 0.034 |
| whisper-tiny.en | 65.5 | 0.0 | 34.5 | 70.3 | 421 / 512 ms | 0.053 |
| whisper-base.en | 66.9 | 0.0 | 33.1 | 73.0 | 464 / 552 ms | 0.074 |
| moonshine-tiny / base (v1) | 25.3 / 52.0 | 0 | | 28.4 / 58.4 | ~330 ms | 0.013 / 0.024 |
| moonshine2-tiny / base (2026) | 49.0 / 50.0 | 0 | | 59.8 / 57.4 | ~340 ms | 0.016 / 0.021 |
| parakeet-110m | 64.5 | 0.0 | 35.5 | 68.2 | 361 / 432 ms | 0.025 |
| parakeet-0.6b | 64.2 | 0.0 | 35.8 | 69.3 | 459 / 545 ms | 0.070 |
| zipformer20m | 0.3 | | | | | broken in harness |

*RTF is the real-time factor: compute time ÷ audio time, on 2 threads of a 2.1 GHz Xeon.
Hotword variants are omitted from this table because hotwords were silently ineffective
in round 1 (fixed below).

What we learned:
- **Wrong-word zaps are about 0% for every engine.** Closed-set matching is safe.
  Errors are misses.
- **VAD + offline models were *faster* than streaming models.** Streaming transducers
  wait for right-context before committing to the last word.
- **The keyword spotter is too strict** at default thresholds. Moonshine is fast but
  weak on isolated words.
- **Kroko holds its final word until more audio or end of input arrives**, giving a
  ~1.3 s p90. That is disqualifying for a reaction game.

### Fixes that mattered

| Fix | Effect |
|---|---|
| **VAD lead-in**: Silero triggers after a word starts, which clipped the first consonant. We keep a ring buffer and add 250 ms of lead-in. | Parakeet 64.5→70.6%, Whisper-base 66.9→75.7%, Moonshine2-tiny 49→62% |
| **Working hotwords**: beam 4→8, and give the generated BPE vocab −1 per piece so hotwords aren't spelled letter by letter | Zipformer 74→78%, Kroko 77→85%, Parakeet 70.6→79.4% (at score 1.5) |
| **Sound-alike matching**: if no exact match, accept the on-screen word within 1 phoneme (CMU dict). 1–2 phoneme words only tolerate an *extra* sound, and ties never fire. | +2 to +6 points; under 1% extra wrong words |
| **Hotword strength**: 1.0 / 1.5 / 3 / 6 for Parakeet | 75.3 / **79.4** / 79.7 / 22.6% hits, and wrong words 0.3 / **0.0** / 6.8 / 76.7%. **Too much boost makes it hallucinate on-screen words**: 1.5 for offline, 3 for streaming. |

### Final configurations

All three conditions use 300 + 75 trials. Latency is from sequential runs (see note).

| Config | Condition | Hit % | Wrong % | No fire % | False accept % |
|---|---|---:|---:|---:|---:|
| **parakeet-110m-hot** (VAD 0.2 s, lead-in 0.25 s, hot 1.5, beam 8, sound-alike) | clean | **81.1** | 0.3 | 18.6 | 0.0 |
| | noise 10 dB | 75.7 | 1.4 | 23.0 | 1.4 |
| | child proxy | 73.6 | 0.7 | 25.7 | 2.7 |
| | clean, **hard** distractors | 79.4 | **2.7** | 17.9 | 0.0 |
| **zipformer-hot** (streaming, hot 3, beam 8, sound-alike) | clean | **81.4** | 0.3 | 18.2 | 0.0 |
| | noise 10 dB | 73.3 | 2.0 | 24.7 | 0.0 |
| | child proxy | **79.1** | 0.3 | 20.6 | 0.0 |
| | clean, **hard** distractors | 77.4 | **3.7** | 18.9 | 1.4 |
| whisper-base.en (VAD + lead-in, no hotwords) | clean / noise / child | 75.7 / 68.2 / 69.9 | 0.3 | | 0 |
| nemo80 streaming (no hotwords possible) | clean / noise / child | 77.7 / 70.3 / 74.0 | 0–0.3 | | 0 |

**Latency, sequential runs, 2 threads, end of word → zap:**

| Config | p50 | p90 |
|---|---:|---:|
| parakeet-110m-hot, VAD silence 0.25 s | 384 ms | 460 ms |
| parakeet-110m-hot, VAD silence **0.20 s** (default) | **352 ms** | **423 ms** |
| parakeet-110m-hot, VAD silence 0.15 s | 286 ms | 360 ms |
| zipformer-hot (streaming) | 385 ms | 652–671 ms |
| whisper-base.en | 467 ms | 597 ms |
| nemo80 | 521 ms | 840 ms |

The three VAD settings had identical accuracy (81.1%) on this data. Kids who pause
inside a word ("sounding out") may favor 0.2 s or more; their partial sounds just
produce a harmless "miss" first.

> Note: the final-config accuracy runs ran three at a time on the 4-core container, so
> *their* latency/RTF columns (in `results/final-*`) are inflated by contention
> (Parakeet RTF 0.10 vs 0.035 alone). The latency table above uses the
> sequential runs.

### Inside Godot (end to end)

Run via `godot/tests/headless_wav_test.gd`: real Speech Commands WAVs streamed in
real time into the `WordListener` node with 5 words on screen. Latency here is
measured from the extension's own voice tracker.

| Preset | Hits | Latency p50 / p90 | Compute (RTF) |
|---|---|---|---|
| parakeet-110m-hot | 83% (25/30) and 80% (48/60) | 312–388 / 458–552 ms | 0.073–0.078 |
| zipformer-hot | 80% (24/30) and 70% (28/40, before hotword fix) | 288–341 / 613–646 ms | 0.08–0.12 |

Also verified in Godot:
- two words read in one breath are both zapped, even when the on-screen list changes mid-word;
- the calibration recorder writes correct 16 kHz WAVs, rounds and a manifest;
- the speech test, recorder and menu scenes run without script errors.

### How to read these numbers

- **The dataset is hard on purpose.** Speech Commands was crowd-sourced through
  browsers; many clips are quiet, clipped at 1 s or mumbled.
  - 23 of 300 test clips (8%) were missed by all five strong models.
  - On the in-Godot runs, most misses were words like "wow"→"well" or "house"→"host".
  - A child reading carefully into a decent mic is a different situation. It could be
    better (clear speech) or worse (child acoustics).
- **The child proxy is crude.** Parakeet and Zipformer lost 5–8 points on it; Kroko
  and nemo80 lost less than 4. Real child speech is known to be much harder for ASR.
  In published benchmarks, zero-shot WER on kids' read speech is 10–20% for the best
  models, and worse for younger kids (sources below).
- **Closed-set helps a lot.** We aren't computing WER; we only need the right one of
  five words. With hotwords and sound-alike matching, most "almost right"
  transcriptions still land on the right word.

## 5. Design implications for the game

1. **Never put sound-alikes on screen together** at early levels (cat/hat/cap, on/one,
   no/go, tree/three). Hard distractors raised wrong-word zaps from 0.3% to 2.7–3.7%.
   The leveled word lists precompute `confusable` pairs per World so the spawner can
   avoid them.
2. **Avoid single-letter words** ("a", "I") as targets; they're unreliable in isolation.
3. **Instant feedback beats raw latency.** Use `voice_started` to charge the cannon or
   light Nora's headset immediately; the zap lands about 0.3 s later.
4. **Misses are the common error, so make them free and friendly.** This matches the
   design ("try again", no penalty). A non-match (`heard_other`) should look gentle,
   because partial sounds while sounding out can trigger one just before the real zap.
5. **Several words in one breath all count** (implemented).
6. **Expose "strict / friendly" matching in parent settings.** Friendly mode accepts
   within one sound ("cap" for "cat"), which also accepts real misreads.
7. **Keep fall speeds generous.** With about 0.35 s recognition plus reading time, a word
   should be readable for several seconds even at top speed.

## 6. Mobile

| | Android (arm64) | iOS |
|---|---|---|
| Runtime | sherpa-onnx ships `libsherpa-onnx-c-api.so` (4.5 MB) + `libonnxruntime.so` (22 MB) | Build `sherpa-onnx.xcframework` + onnxruntime from source (`build-ios.sh`); not in the v1.13.8 release assets |
| Extension | Same C++; build godot-cpp + extension with the Android NDK (`platform=android arch=arm64`) | Static GDExtension (`.xcframework`), Godot iOS export |
| Models | Parakeet-110M int8 131 MB, or Zipformer 68 MB. Copied from the package to `user://` on first run (already handled by `HeroSpeech`). Consider Play Asset Delivery or download-on-first-run to keep the base APK small. | Same; App Store on-demand resources |
| Mic | `RECORD_AUDIO` permission in the export preset + `OS.request_permissions()` at runtime | `NSMicrophoneUsageDescription` |
| Memory | about 230 MB for Parakeet (331 MB process minus 106 MB Python baseline), about 135 MB for Zipformer | same |
| Speed | Parakeet: **RTF 0.041 on 1 thread** here, about 90 ms of compute per word. A mid-range phone core is ~1.5–3× slower, so ~150–250 ms on top of VAD silence. Zipformer: 1-thread RTF 0.08, about 25 ms per 20 ms chunk worst case, so it keeps up in real time with headroom. | A-series chips are faster than this Xeon per core |

**Verdict:** Android is a moderate porting task with no new research needed.
- Budget about 160 MB of downloads and 250 MB of RAM.
- To shrink it, Zipformer (68 MB) is the lighter choice on phones, at similar accuracy
  and a longer latency tail.
- Moonshine v2 tiny (43 MB, fastest) is too inaccurate on isolated words today
  (62% hits even with lead-in).
- We could not compile the Android build in the cloud sandbox (the Android NDK download
  host was blocked), so it is untested.

## 7. Choices: where to start

| Decision | Default (why) | Alternatives (when) |
|---|---|---|
| Engine runtime | **sherpa-onnx via `WordListener`** (all models, hotwords, prebuilt libraries, mobile) | godot-whisper (no vocab constraint, slower); gdvosk (true grammar mode, worth an A/B on kids) |
| Model | **Parakeet-TDT 110M + VAD** for now (tightest latency, best in noise) | **Zipformer streaming**: if it wins on the kid calibration data (it led on the child proxy), or for a smaller mobile download. Whisper-base: no hotwords, slower. |
| VAD silence | **0.2 s** | 0.15 s for speed if kids don't pause mid-word; 0.25–0.3 s for slow sounders |
| Hotword strength | **1.5 offline / 3 streaming** | Raise only if wrong-word % stays ~0 on calibration data |
| Matching | **Exact + homophones + sound-alike (friendly)** | Strict (exact + homophones) for older readers |
| Platform | **Windows PC first** | Android next (section 6); iOS after |

## 8. Next steps

1. **Calibrate on real voices** (8f, 16f, 42m, 44f, and Nora if possible) with the
   Godot recorder; see `HANDOFF.md`. This replaces the child proxy with the truth and
   settles Parakeet vs Zipformer.
2. If kid hit rate is under 90%, try these, cheapest first:
   - tune the hotword score and VAD silence on the calibration data;
   - **candidate scoring:** instead of transcribing, score each of the 5 on-screen words
     against the audio (forced alignment / transducer log-likelihood) and pick the best
     above a threshold. This is the principled closed-set solution;
   - **watch the April 2026 DrivenData "On Top of Pasketti" kids-ASR winners.** Open
     weights are promised for fall 2026. A child-fine-tuned Parakeet would drop
     straight into this pipeline.
3. Port to Android once the PC game loop exists.

## Sources (Oct 2026 survey)

- sherpa-onnx: https://github.com/k2-fsa/sherpa-onnx (models: releases `asr-models`, `kws-models`)
- godot-whisper: https://github.com/appsinacup/godot-whisper
- gdvosk: https://github.com/Nihlus/gdvosk
- Moonshine v2 (streaming encoder, Feb 2026): arXiv 2602.12241; https://github.com/moonshine-ai/moonshine
- Child ASR benchmark (Fan et al., Interspeech 2024; Canary/Parakeet beat Whisper zero-shot on MyST/OGI): https://arxiv.org/abs/2406.10507
- Kid-Whisper fine-tunes: https://github.com/ahmedadelattia/whisperKids
- DrivenData "On Top of Pasketti" children's ASR challenge (2026): https://drivendata.co/blog/on-top-of-pasketti-winners
- Speech Commands v0.02 (Warden 2018), CC-BY 4.0
