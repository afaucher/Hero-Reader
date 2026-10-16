"""Prototype: closed-set *candidate scoring* with Parakeet-TDT 110M.

Instead of transcribing and then matching text, score each on-screen word
against the audio: log P(word tokens | audio) under the transducer, summed
over all TDT alignments (forward algorithm). The best-scoring word wins if

  * it explains the audio nearly as well as the model's own free transcript
    (score - free_score > -REJECT; that rejects off-screen words and chatter), and
  * it beats the runner-up on-screen word by MARGIN (that rejects ties).

It reuses the benchmark harness unchanged (same VAD + 250 ms lead-in, same
trials, same latency clock), as engine "parakeet-110m-score". The decision is
returned as text, so the normal matcher maps it to the on-screen word.

Needs onnxruntime, which is not in stt-eval/.venv (sherpa-onnx is pinned
there); run it from the separate venv described in docs/REPRODUCE.md:

  python candidate_scoring.py --check 200            # frontend sanity check
  python candidate_scoring.py --engines parakeet-110m-score --trials 300 \
      --silence 0.2 --conditions clean noise10 child --out results/local-score-parakeet
"""

from __future__ import annotations

import os
import sys

import numpy as np
import onnxruntime as ort

import engines
from engines import MODELS_DIR, SAMPLE_RATE, Vocab, VadOfflineEngine

D = MODELS_DIR / engines.PARAKEET["parakeet-110m"]
DURATIONS = [0, 1, 2, 3, 4]
REJECT = float(os.environ.get("SCORE_REJECT", 6.0))  # nats below the free transcript
MARGIN = float(os.environ.get("SCORE_MARGIN", 3.0))  # nats over the runner-up
# (tuned on seed 11 to a ~5% false-accept rate, like vosk-grammar; the benchmark uses seed 7)


# --- NeMo AudioToMelSpectrogramPreprocessor (per_feature, 80 mels, slaney) ---

def _hz_to_mel(f):
    f = np.asarray(f, dtype=np.float64)
    mel = f / (200.0 / 3)
    log = f >= 1000.0
    return np.where(log, 15.0 + np.log(np.maximum(f, 1e-10) / 1000.0) / (np.log(6.4) / 27.0), mel)


def _mel_to_hz(m):
    m = np.asarray(m, dtype=np.float64)
    f = m * (200.0 / 3)
    log = m >= 15.0
    return np.where(log, 1000.0 * np.exp((np.log(6.4) / 27.0) * (m - 15.0)), f)


def _mel_fb(sr=16000, n_fft=512, n_mels=80):
    fft_f = np.linspace(0, sr / 2, 1 + n_fft // 2)
    mel_f = _mel_to_hz(np.linspace(_hz_to_mel(0), _hz_to_mel(sr / 2), n_mels + 2))
    fdiff = np.diff(mel_f)
    ramps = mel_f[:, None] - fft_f[None, :]
    lower = -ramps[:-2] / fdiff[:-1, None]
    upper = ramps[2:] / fdiff[1:, None]
    w = np.maximum(0, np.minimum(lower, upper))
    return w * (2.0 / (mel_f[2:] - mel_f[:-2]))[:, None]


MEL = _mel_fb().astype(np.float32)
WIN = np.zeros(512, np.float32)
WIN[56:456] = np.hanning(402)[1:-1].astype(np.float32)  # torch.hann_window(400, periodic=False)


def features(x: np.ndarray) -> np.ndarray:
    x = np.concatenate([x[:1], x[1:] - 0.97 * x[:-1]]).astype(np.float32)
    x = np.pad(x, 256)  # torch.stft(center=True), zero padding
    n = 1 + (len(x) - 512) // 160
    frames = np.lib.stride_tricks.as_strided(x, (n, 512), (x.strides[0] * 160, x.strides[0]))
    spec = np.abs(np.fft.rfft(frames * WIN, axis=1)) ** 2
    m = np.log(spec @ MEL.T + 2.0 ** -24).T  # (80, n)
    mean = m.mean(axis=1, keepdims=True)
    std = np.sqrt(((m - mean) ** 2).sum(axis=1, keepdims=True) / max(n - 1, 1)) + 1e-5
    return ((m - mean) / std).astype(np.float32)


def _logsoftmax(a, axis=-1):
    a = a - a.max(axis=axis, keepdims=True)
    return a - np.log(np.exp(a).sum(axis=axis, keepdims=True))


class TdtScorer:
    def __init__(self, threads=2):
        so = ort.SessionOptions()
        so.intra_op_num_threads = threads
        so.inter_op_num_threads = 1
        mk = lambda f: ort.InferenceSession(str(D / f), so, providers=["CPUExecutionProvider"])  # noqa: E731
        self.enc, self.dec, self.join = mk("encoder.int8.onnx"), mk("decoder.int8.onnx"), mk("joiner.int8.onnx")
        self.vocab = Vocab(str(D / "tokens.txt"))
        self.ids = {t: i for i, t in enumerate(self.vocab.ordered)}
        self.blank = len(self.vocab.ordered) - 1
        self._dec_cache: dict[tuple, tuple] = {}

    def encode(self, audio):
        f = features(audio)[None]
        out, _ = self.enc.run(None, {"audio_signal": f, "length": np.array([f.shape[2]], np.int64)})
        return out  # (1, 512, T)

    def _decoder(self, prefix: tuple):
        """Prediction-net output after feeding `prefix` (blank as start symbol)."""
        if prefix in self._dec_cache:
            return self._dec_cache[prefix]
        if prefix:
            _, h, c = self._decoder(prefix[:-1])
            tok = prefix[-1]
        else:
            h = c = np.zeros((1, 1, 640), np.float32)
            tok = self.blank
        o, _, h2, c2 = self.dec.run(None, {"targets": np.array([[tok]], np.int32),
                                           "target_length": np.array([1], np.int32),
                                           "states.1": h, "onnx::LSTM_3": c})
        self._dec_cache[prefix] = (o[:, :, :1], h2, c2)
        return self._dec_cache[prefix]

    def joint(self, enc, ys):
        dec = np.concatenate([self._decoder(tuple(ys[:u]))[0] for u in range(len(ys) + 1)], axis=2)
        logits = self.join.run(None, {"encoder_outputs": enc, "decoder_outputs": dec})[0][0]  # (T, U+1, 1030)
        return _logsoftmax(logits[..., : self.blank + 1]), _logsoftmax(logits[..., self.blank + 1:])

    def loglik(self, enc, ys: list[int]) -> float:
        """log P(ys | audio), summed over TDT alignments."""
        tok, dur = self.joint(enc, ys)
        T, U = enc.shape[2], len(ys)
        alpha = np.full((T + 1, U + 1), -np.inf)
        alpha[0, 0] = 0.0
        for t in range(T):
            for u in range(U + 1):
                a = alpha[t, u]
                if a == -np.inf:
                    continue
                for k, d in enumerate(DURATIONS):
                    if d > 0 and t + d <= T:  # blank
                        alpha[t + d, u] = np.logaddexp(alpha[t + d, u], a + tok[t, u, self.blank] + dur[t, u, k])
                    if u < U and t + d < T:  # label (the final step out is always a blank)
                        alpha[t + d, u + 1] = np.logaddexp(alpha[t + d, u + 1],
                                                           a + tok[t, u, ys[u]] + dur[t, u, k])
        return float(alpha[T, U])

    def greedy(self, enc) -> list[int]:
        T = enc.shape[2]
        ys, t, sym = [], 0, 0
        while t < T:
            dec = self._decoder(tuple(ys))[0]
            lg = self.join.run(None, {"encoder_outputs": enc[:, :, t:t + 1], "decoder_outputs": dec})[0][0, 0, 0]
            k = int(lg[: self.blank + 1].argmax())
            d = DURATIONS[int(lg[self.blank + 1:].argmax())]
            if k != self.blank:
                ys.append(k)
                sym += 1
            if d == 0 and (k == self.blank or sym >= 5):
                d = 1
            if d:
                sym = 0
            t += d
        return ys

    def text(self, ys) -> str:
        return "".join(self.vocab.ordered[i] for i in ys).replace("▁", " ").strip()

    def _ids(self, s: str) -> list[int]:
        """Greedy longest-match over the model's (case-sensitive) pieces."""
        out, i = [], 0
        while i < len(s):
            for j in range(min(len(s), i + self.vocab.maxlen), i, -1):
                if s[i:j] in self.ids:
                    out.append(self.ids[s[i:j]])
                    i = j
                    break
            else:
                raise ValueError(s)
        return out

    def word_score(self, enc, w: str) -> float:
        """The model writes "Yes." as often as "yes": sum over case and end punctuation."""
        w = w.lower()
        variants = {"▁" + v + p for v in (w, w.capitalize()) for p in ("", ".", "?", "!")}
        return float(np.logaddexp.reduce([self.loglik(enc, self._ids(v)) for v in variants]))

    def decide(self, audio, onscreen):
        self._dec_cache = {}
        enc = self.encode(audio)
        free = self.greedy(enc)
        free_ll = self.loglik(enc, free) if free else -np.inf
        scores = sorted(((self.word_score(enc, w), w) for w in onscreen), reverse=True)
        (best, w), second = scores[0], scores[1][0] if len(scores) > 1 else -np.inf
        ok = best - max(free_ll, best) > -REJECT and best - second > MARGIN
        return (w if ok else ""), self.text(free), scores, free_ll


class ScoringEngine(VadOfflineEngine):
    """Same VAD + lead-in as parakeet-110m-hot; decision by candidate scoring."""

    def __init__(self, name, threads=2, silence=0.25):
        self.scorer = TdtScorer(threads)
        super().__init__(name, lambda: None, silence)

    def transcribe(self, samples, onscreen):
        pad = np.zeros(int(0.3 * SAMPLE_RATE), dtype=np.float32)
        word, free, *_ = self.scorer.decide(np.concatenate([pad, samples, pad]), onscreen)
        # A word is fired via the matcher; otherwise report what was heard (a miss).
        return word or (f"~{free}" if free else "")


def _make(name, threads=2, silence=0.25, **kw):
    if name == "parakeet-110m-score":
        return ScoringEngine(name, threads, silence)
    return _orig_make(name, threads=threads, silence=silence, **kw)


_orig_make = engines.make_engine
engines.make_engine = _make
engines.ENGINES.append("parakeet-110m-score")


def check(n):
    """Greedy-decode n clips with this frontend; compare with sherpa-onnx's greedy text."""
    import random

    import dataset as ds
    root = MODELS_DIR.parent.parent / "third_party" / "data" / "speech_commands"
    clips = random.Random(1).sample(ds.speech_commands(root), n)
    sc = TdtScorer()
    rec = engines._nemo_offline(str(D.name), 2)()
    agree = 0
    for c in clips:
        x = ds.load_wav(c.path)
        s = rec.create_stream()
        s.accept_waveform(SAMPLE_RATE, x)
        rec.decode_stream(s)
        ref = s.result.text.strip().lower()
        sc._dec_cache = {}
        got = sc.text(sc.greedy(sc.encode(x))).lower()
        agree += ref == got
        if ref != got:
            print(f"  {c.word}: sherpa {ref!r} vs ours {got!r}")
    print(f"frontend check: {agree}/{n} greedy transcripts identical to sherpa-onnx")


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "--check":
        check(int(sys.argv[2]))
    else:
        import benchmark  # picks up the patched make_engine
        benchmark.main()
