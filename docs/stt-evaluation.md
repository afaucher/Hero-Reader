# Speech-to-text for Hero Reader: evaluation and recommendation

*October 2026. Reproduce everything with `docs/REPRODUCE.md`. Next steps on a real PC are in `HANDOFF.md`.
Re-checked on the local PC in October 2026 (uncontended latency, Moonshine, Vosk grammar mode, kid-speech
weights, candidate scoring, matcher rules) and on the first real-mic voice; see "Local PC re-evaluation (2026-10)".
**Recommendation changed (provisional, pending kid recordings): `zipformer-hot` is now the default**, at
hotword score 2 with the "extra-only" sound-alike rule; see "Real voice: adult male, PC mic".*

## TL;DR

> **Update, 2026-10-16:** on the first real-microphone voice, an adult male, the
> Zipformer hit 95.5% against Parakeet's 80–85%, at equal wrong-word and false-accept
> rates. `zipformer-hot` is therefore the provisional default until the kid recordings
> are in. The bullets below are the original Speech Commands analysis. See "Real voice:
> adult male, PC mic".

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
| [gdvosk](https://github.com/Nihlus/gdvosk) | Vosk (Kaldi) | Small single-maintainer project, Godot 4.5+ | Real grammar mode (closed vocabulary) and streaming. But Vosk is dated (adult-trained, project barely active). Benchmarked locally in Oct 2026: grammar mode hits 94–96% but false-accepts 5–8% of off-screen words, at ~570 ms latency (see the local re-evaluation). A calibration candidate. |
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

## Local PC re-evaluation (2026-10)

These are the items the cloud session could not do, run on the family PC: a Ryzen 9
7950X3D (16 cores) on Windows 11, Python 3.14, sherpa-onnx 1.13.8, 2 inference threads,
with the machine otherwise idle (under 5% total CPU) and **one run at a time**. The
trials are the same seed-7 trials as the cloud runs, checked row by row. Commands are
in `REPRODUCE.md` §6 and the raw results in `stt-eval/results/local-*`.

| Engine | Condition | Hit % | Wrong word % | False accept % | Latency p50 / p90 |
|---|---|---:|---:|---:|---|
| **parakeet-110m-hot** (default; VAD 0.2 s, hot 1.5, beam 8, sound-alike) | clean | 80.7 | 0.3 | 0.0 | **320 / 389 ms** |
| | noise 10 dB | 75.7 | 1.4 | 1.4 | 391 / 537 ms |
| | child proxy | 74.7 | 1.0 | 2.7 | 339 / 396 ms |
| | clean, hard distractors | 79.4 | 2.7 | 0.0 | 321 / 394 ms |
| **zipformer-hot** (streaming; hot 3, beam 8, sound-alike) | clean | 81.8 | 0.3 | 0.0 | 371 / 662 ms |
| | noise 10 dB | 73.3 | 2.0 | 0.0 | 371 / 641 ms |
| | child proxy | 79.4 | 0.3 | 0.0 | 401 / 667 ms |
| | clean, hard distractors | 78.4 | 4.1 | 1.4 | 372 / 642 ms |
| **vosk-grammar** (Vosk small-en 0.15, grammar = on-screen words + `[unk]`, word confidence ≥ 0.9, endpoint 0.3 s) | clean | **96.3** | 0.7 | 5.4 | 572 / 702 ms |
| | noise 10 dB | **94.3** | 0.0 | 6.8 | 542 / 692 ms |
| | child proxy | **93.6** | 0.0 | 8.1 | 582 / 712 ms |
| | clean, hard distractors | 93.2 | 1.7 | 5.4 | 572 / 702 ms |
| | clean, endpoint 0.15 s | 96.3 | 0.7 | 5.4 | 442 / 562 ms |
| vosk (same model, open vocabulary + matcher) | clean / noise / child | 77.7 / 70.3 / 75.7 | 0.3–1.0 | 0–1.4 | 221–275 / 463–770 ms |
| parakeet-110m-score (prototype: candidate scoring, below) | clean | 87.2 | 1.4 | 8.1 | 351 / 425 ms |
| | noise 10 dB | 83.1 | 2.0 | 5.4 | 417 / 579 ms |
| | child proxy | 85.5 | 1.4 | 6.8 | 367 / 429 ms |

300 positive trials per row, of which 296 have usable audio, and 74 negative trials.
**One negative trial is 1.35 points of false accept**, so treat those columns as ±5
points. Pooled over the three conditions, false accepts were 3/222 for Parakeet, 0/222
for Zipformer, 15/222 for vosk-grammar and 15/222 for candidate scoring.

What each item showed:

1. **Uncontended latency:** Parakeet is 320/389 ms (it was 352/423 ms on the cloud
   container), and the Zipformer is 371/662 ms. The Zipformer's ~650 ms p90 tail is
   structural, not contention. RTF is 0.018 for Parakeet and 0.042 for the Zipformer.
   Accuracy reproduced to within ±1.1 points; 2–5 trials per run flip, from int8 kernel
   differences between the Xeon and the Ryzen.
2. **Moonshine re-test: no newer export exists.** The newest sherpa-onnx Moonshine
   assets in the `asr-models` release are still the 2026-02-27 ones we tested; we
   checked all 499 assets on 2026-10-16. Upstream's 2026-07-30 "improved quantization"
   (commit db54672c) re-quantized only its *streaming* English models. Those use a
   five-file layout that sherpa-onnx's `from_moonshine_v2` cannot load. Upstream's
   non-streaming tiny-en files are byte-identical to the export we tested, so our
   Moonshine numbers stand.
3. **Vosk grammar mode (HANDOFF #4)** is the surprise.
   - **Why it scores so high:** restricting Kaldi's decoder to the five on-screen
     words turns recognition into a forced choice. It hits 94–96% in every
     condition, including the child proxy, with ≤0.7% wrong words, against 75–82%
     for the finalists.
   - **Costs:**
     - **False accepts:** 5–8% of off-screen words are zapped as an on-screen word.
       Word confidence barely separates them; thresholds 0.85–1.0 give the same
       result on the seed-11 tuning trials.
     - **Latency:** 570/700 ms with the same 0.3 s endpoint as the Zipformer, and
       440/560 ms at 0.15 s.
     - **Firing early:** grammar-mode partial results are forced onto some on-screen
       word mid-utterance (60% false accepts in a smoke test), so only the
       endpointed result can be used.
     - **A second runtime:** it is Kaldi, not sherpa-onnx.
   - The open-vocabulary Vosk is no better than our finalists.
4. **Kid-speech weights (checked 2026-10-16): open, but not usable here yet.**
   - **What was released:** DrivenData published `drivendata/pasketti-word` on
     Hugging Face (2026-10-02), a Qwen3-ASR-1.7B full fine-tune with 17% WER on kids,
     4.1 GB, under the use-restricted bigcode-openrail-m licence. They also published
     `drivendata/pasketti-phonetic` (2026-10-06), a WavLM-Large CTC model that
     outputs IPA, not words.
   - **Winners' weights:** a few winners published their own, all Qwen3-ASR-1.7B,
     WavLM, or partial NeMo checkpoints without a complete `.nemo`.
   - **Why none was benchmarked:** none has a sherpa-onnx export. sherpa-onnx 1.13.8
     can load Qwen3-ASR, but only via an unverified third-party ONNX conversion. A
     1.7B LLM-decoder model is also far outside our latency and mobile budget. No
     kid-tuned Parakeet or Zipformer exists.
5. **Candidate scoring prototype** (`stt-eval/candidate_scoring.py`).
   - **How it works:** for each of the five words, the Parakeet transducer gives
     log P(word | audio), summed over TDT alignments, and the best word fires if it
     is close to the free transcript's score and clear of the runner-up.
   - **Tuning:** thresholds were tuned on seed 11 to the same ~5% false-accept level
     as vosk-grammar.
   - **Result:** it gains 4–11 points of hits over hotword + matcher (87/83/86%) at
     the cost of 5–8% false accepts and 1.4–2% wrong words. That is a clearly worse
     trade than Vosk's grammar at the same false-accept rate. At the finalists'
     ~1% false-accept level it gains little (seed-11 sweep in `tune_closed_set.py`).

### Follow-up: matcher strictness and Zipformer hotword strength

The live Godot test with Windows TTS clips (`godot/tests/tts_match_test.gd`) found two
kinds of false zap:
- **Onset swaps:** "what's that" zapped "cat", and "HAT" zapped "cat".
- **Made-up words from Zipformer at hotword score 3:** "BANANA THE", "um" heard as
  "OF THE", and second fires about 1.2 s after the first.

To measure both, `benchmark.py` now logs every recognizer event per trial. Partial
results only fire on exact matches, so recognition does not depend on the matcher, and
`replay_matcher.py` recomputes each trial's decision under any sound-alike rule. Its
"any" replay reproduces the benchmark's own numbers exactly. The rules compared:

- **exact:** homophones only.
- **any:** the current rule, one phoneme off.
- **no-onset:** the first sound must match.
- **extra-only:** only one added sound after the first, as in "cats" for "cat" or
  "true" for "two".

The new **stress set** combines three options:
- `--hard`: sound-alike distractors.
- `--hard-negatives`: the off-screen spoken word has its closest-sounding words on
  screen, which is the misread case.
- `--sight-words`: one of the, look, my, me, you, and, is, it, see, said is always on
  screen, so made-up function words can fire.

Results are in `results/local-events-*` and `results/local-stress-*`.

| Config | Rule | Hits clean / noise / child | Stress: wrong word | Stress: false accept | Fired twice (std / stress) | Latency p50 / p90 (clean) |
|---|---|---|---:|---:|---:|---|
| parakeet-110m-hot | exact | 79.4 / 73.3 / 70.6 | 2.4 | 1.4 | 0 / 0 | 327 / 400 ms |
| | any (current) | 80.7 / 75.7 / 74.7 | 2.7 | **6.8** | | |
| | no-onset | 79.7 / 75.3 / 73.3 | 2.7 | 2.7 | | |
| | extra-only | 79.4 / 74.3 / 72.3 | 2.7 | 1.4 | | |
| zipformer-hot, hot 3 | any | 81.8 / 73.3 / 79.4 | 3.4 | 6.8 | **5.9–8.4 / 8.6** | 376 / 667 ms |
| | extra-only | 79.4 / 69.3 / 76.7 | 3.4 | 5.4 | | |
| zipformer-hot, hot 2 | any | 81.1 / 74.0 / 78.4 | 2.4 | 5.4 | 3.0–8.4 / 3.8 | 421 / 706 ms |
| | extra-only | 78.4 / 69.9 / 75.3 | 2.4 | 2.7 | | |
| zipformer-hot, hot 1.5 | any | 81.1 / 73.0 / 77.4 | 2.0 | 5.4 | 2.2–5.9 / 2.4 | 456 / 702 ms |
| | extra-only | 78.4 / 68.9 / 74.0 | 2.0 | 2.7 | | |
| vosk-grammar | (any rule) | 96.3 / 94.3 / 93.6 | 1.4 | **16.2** | 0 / 0 | 573 / 703 ms |

These runs had about 7% background CPU from other work, so RTF is about 30% higher
than in the table above. Latency is within 10 ms for Parakeet, but Zipformer's rose
about 5–10%. Stress false accepts are out of 74 trials, so one trial is 1.35 points.

**What the game's own word lists say.** `replay_matcher.py --wordlists` checks every
pair among the 816 words in `godot/data/wordlists/levels`:

| Rule | Words for which some other game word is accepted | Accepted misreads per word | Examples |
|---|---:|---:|---|
| any (current) | 72% | 3.9 | bat→cat, at→cat, bag→big, dig→dog, bed→red |
| no-onset | 63% | 2.0 | cab→cat, can→cat, bag→big, rid→red |
| extra-only | 12% | 0.15 | sunny→sun, tube→two |

Conclusions:
- **(a) Sound-alike rule.**
  - **"any" accepts real misreads.** On the stress set it is where most false
    accepts come from: 6.8% for Parakeet, against 1.4% with exact matching.
  - **"no-onset" only half fixes it.** It still accepts vowel and final-sound swaps
    (big/bag, cat/cab), the commonest CVC decoding errors.
  - **"extra-only" does fix it.** On the word lists it drops accepted misreads from
    3.9 to 0.15 per word, and on the stress set it brings false accepts back to the
    exact-match level.
  - **Cost:** 1.3–2.4 points of hits for Parakeet and about 3 points for the
    Zipformer.
  - **Proposal:** make **extra-only the default ("strict") rule** and keep "any" as
    the parent-settings "friendly" option (section 5, item 6), in both
    `matcher.py` and `word_matcher.cpp`. The extra rule is a few lines in
    `matcher.py`: a non-zero distance must keep the first phoneme and be a single
    insertion.
  - **Kid recordings settle the cost.** `replay_matcher.py` rescores a calibration
    run under every rule without re-recognizing. Kids' articulation substitutions
    such as w/r and f/th are onset swaps too, so the cost may be higher on real kids.
- **(b) Zipformer hotword score.**
  - **What score 3 does:** the Zipformer re-fires after its endpoint in 6–9% of
    trials. Mostly it repeats the same word (77 of 80 at score 3), because a
    boosted decode of the trailing silence makes the word up again. A few fires
    land on a different word (GO|DOG, LEFT|ME), and those occur only at score 3.
  - **Score 2:** halves the double fires and removes the different-word ones, for
    about 1 point of hits and +45 ms p50.
  - **Score 1.5:** cuts double fires to about 2%, but costs +80 ms p50, for hit rates
    that are unchanged within noise.
  - **Parakeet behind the VAD never double-fired** (0 of 1,480 trials).
  - **Data limitation:** Speech Commands clips have no chatter, so "um → OF THE"
    style inventions show up only as 1–2 sight-word fires per 370 trials. The live
    TTS test is the better evidence there.
  - **Proposal:** run `zipformer-hot` at **score 2**, and have the game ignore a
    repeat of the word it just zapped within ~1.5 s.

*On Speech Commands alone, the recommendation after this follow-up was "unchanged":
Parakeet as the default, the Zipformer at hotword score 2, and sound-alike "extra-only".
The first real-mic voice, below, changed the default.*

**Vosk grammar mode is a third candidate for the kid calibration** (not adopted). It cut
misses from ~20% to ~5%. Adopting it means accepting zaps on off-screen words: 5–8% in
general, 16% when the off-screen word sounds like an on-screen one, and 9% on real voice
(below). It also means ~200 ms more latency and a second runtime. The calibration
benchmark already supports it: `--engines vosk-grammar`, from the Vosk venv.

### Real voice: adult male, PC mic (2026-10-16)

This is the first real-microphone data: session `adultm/20261016-134130`, recorded with
the Godot recorder on a HyperX QuadCast S. It covers 2 rounds of the calibration list,
which is 77 words and 157 clips, plus 20 `_other` clips (um, coughs, "what's that
word?"). Each clip is used once as a positive.

The run had 5 words on screen and 120 negatives: 100 words that were not on screen,
plus the 20 `_other` clips. The earlier low-gain session is left out. Commands are in
`REPRODUCE.md` §6, and results in `results/local-calib-adultm-s2-*`. Hit / wrong word /
false accept % are given under the current ("any") and the proposed ("extra-only")
sound-alike rule.

| Config | Normal screens: any | Normal: extra-only | Hard distractors: extra-only | Fired twice | Latency p50 / p90 |
|---|---|---|---|---:|---|
| parakeet-110m-hot, hot 1.5 | 80.3 / 1.9 / 2.5 | 79.0 / 1.3 / 0.8 | 80.9 / 3.2 / 1.7 | 0 | 309 / 364 ms |
| parakeet-110m-hot, hot 2 | 84.7 / 1.9 / 2.5 | 83.4 / 1.3 / 0.8 | 83.4 / 3.8 / 2.5 | 0 | 310 / 363 ms |
| parakeet-0.6b-hot, hot 1.5 | 80.9 / 3.8 / 7.5 | 77.7 / 3.2 / 6.7 | 72.0 / 10.2 / 14.2 | 0.7 | 379 / 435 ms |
| **zipformer-hot, hot 3** | 96.2 / 1.3 / 4.2 | **96.2 / 0.6 / 0.8** | 89.8 / 5.1 / 1.7 | 9.0 | 273 / 622 ms |
| **zipformer-hot, hot 2** | 95.5 / 0.6 / 4.2 | **95.5 / 0.6 / 0.8** | 90.4 / 3.8 / 1.7 | 10.5 | 327 / 637 ms |
| zipformer-hot, hot 1.5 | 96.2 / 0.6 / 4.2 | 95.5 / 0.6 / 0.8 | 89.8 / 3.8 / 1.7 | 6.9 | 387 / 646 ms |
| vosk-grammar | 98.7 / 0.0 / 9.2 | (same) | 91.7 / 0.0 / 9.2 | 0 | 533 / 663 ms |

What it shows:
- **On a real voice the Zipformer is far better than Parakeet: 95–96% hits vs
  80–85%.** One clip is 0.64 points, so the gap is 18–25 clips.
  - **Parakeet's misses** are mostly empty transcripts for short words (bug, dig, the,
    but, hat, all). The rest are near-word guesses biased to common words and questions:
    want→"What?", run→"When?", sun→"Son.", log→"Lock.".
  - **Not the VAD's fault:** decoding the whole clip without the VAD gives the same
    ~77%.
  - **The larger Parakeet 0.6B is worse.**
  - **This matches the child proxy,** which the Zipformer also led (79 vs 74%), so it
    is now two independent signals against one (Speech Commands).
- **"extra-only" is confirmed.** It cuts false accepts from 4.2% to 0.8% for the
  Zipformer and from 2.5% to 0.8% for Parakeet, at no hit cost for the Zipformer.
  - **Hard screens:** extra-only *raises* Zipformer hits (86.6→89.8%), because "any"
    let a sound-alike distractor fire first.
  - **The one remaining false accept** is the `_other` prompt "I don't know", heard as
    "know", a homophone of an on-screen "no".
- **Hotword score barely matters for the Zipformer on this voice:** 95.5–96.2% at
  1.5 / 2 / 3. Lower scores cost latency: 273 → 327 → 387 ms p50.
  - **Score 2** had fewer wrong words on hard screens (3.8 vs 5.1%), and on Speech
    Commands it removed the different-word double fires.
- **Double fires (7–10%) are all same-word repeats on this data,** so the game's
  dedupe (ignore a repeat of the just-zapped word for ~1.5 s) removes them.
- **The Zipformer's latency tail** (p90 ~630 ms) is unchanged; its median (273–327 ms)
  is better than Parakeet's.

**Recommendation: changed to `zipformer-hot` as the default preset (provisional until
the kid recordings), with hotword score 2, the "extra-only" sound-alike rule and a
~1.5 s same-word dedupe in the game.**
- **Why:** on the first real-mic voice it hit 95.5% against Parakeet's 80–85%, with the
  same 0.6% wrong words and 0.8% false accepts. It also led on the child proxy.
- **What it gives up:**
  - a longer latency tail (p90 ~630 vs ~360 ms);
  - more double fires, which the dedupe handles;
  - about 2 points in 10 dB noise on Speech Commands.
- **What stays:** `parakeet-110m-hot` remains a preset. This is one adult speaker, so
  the 8f and 6f recordings decide whether it sticks; if kids reverse it, switch back.

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
   - **closed-set decoding:** Vosk grammar mode (94–96% hits on this data, 5–8% false
     accepts) is already a benchmark engine. Parakeet candidate scoring
     (`stt-eval/candidate_scoring.py`) was a weaker trade in the local re-evaluation;
   - **watch the DrivenData "On Top of Pasketti" kids-ASR models.** As of 2026-10-16 the
     open weights are Qwen3-ASR-1.7B and WavLM models without sherpa-onnx exports. A
     child-fine-tuned Parakeet or Zipformer would drop straight into this pipeline.
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
