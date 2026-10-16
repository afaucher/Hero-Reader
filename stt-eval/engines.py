"""Speech engine adapters with one common, streaming-shaped interface.

Every engine is driven the way the game will drive it: audio arrives in small
chunks (default 20 ms, like a Godot AudioEffectCapture buffer) and the engine
may emit a decision at any point. That lets the benchmark measure latency the
way a child experiences it: from the moment they stop saying the word to the
moment the laser fires.

All engines run on sherpa-onnx (https://github.com/k2-fsa/sherpa-onnx), which
has a C API, prebuilt Windows/Linux/macOS libraries and a C#/.NET package,
so whichever model wins can be embedded in Godot without Python.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import sherpa_onnx

from matcher import Match, WordMatcher

SAMPLE_RATE = 16000
# Same folder the Godot project uses (filled by tools/setup.py).
MODELS_DIR = Path(os.environ.get("STT_MODELS", Path(__file__).resolve().parent.parent / "godot" / "models"))


@dataclass
class Event:
    match: Match | None  # None = speech was heard but matched nothing on screen
    text: str  # raw ASR text that produced the decision
    final: bool  # True if decided at end-of-utterance, False if from a partial


class Session:
    """One 'screen' worth of listening: fixed set of on-screen words."""

    def feed(self, samples: np.ndarray) -> list[Event]:
        raise NotImplementedError

    def flush(self) -> list[Event]:
        return []


class Engine:
    name = "base"
    streaming = False

    def session(self, onscreen: list[str]) -> Session:
        raise NotImplementedError


def _p(model_dir: str, name: str) -> str:
    path = MODELS_DIR / model_dir / name
    if not path.exists():
        raise FileNotFoundError(f"{path} (run: python tools/setup.py --with models-eval)")
    return str(path)


# ---------------------------------------------------------------------------
# Streaming transducers: emit partial hypotheses every ~chunk, so a word can be
# matched while (or right as) the child is still saying it.
# ---------------------------------------------------------------------------


class StreamingSession(Session):
    def __init__(self, eng: "StreamingEngine", onscreen: list[str]):
        self.eng = eng
        self.matcher = WordMatcher(onscreen, fuzzy=eng.fuzzy)
        hot = eng.hotwords_for(onscreen) if eng.hotwords else None
        self.stream = eng.rec.create_stream(hotwords=hot) if hot else eng.rec.create_stream()
        self.fired = False  # one decision per utterance
        self.last_text = ""

    def _final(self) -> list[Event]:
        text = self.eng.rec.get_result(self.stream).strip()
        events = []
        if not self.fired and text:
            events.append(Event(self.matcher.match(text, final=True), text, True))
        self.eng.rec.reset(self.stream)
        self.fired = False
        self.last_text = ""
        return events

    def feed(self, samples):
        rec, s = self.eng.rec, self.stream
        s.accept_waveform(SAMPLE_RATE, samples)
        events = []
        while rec.is_ready(s):
            rec.decode_stream(s)
        text = rec.get_result(s).strip()
        if text != self.last_text:
            self.last_text = text
            if not self.fired:
                m = self.matcher.match(text, final=False)
                if m:
                    self.fired = True
                    events.append(Event(m, text, False))
        if rec.is_endpoint(s):
            events += self._final()
        return events

    def flush(self):
        tail = np.zeros(int(0.6 * SAMPLE_RATE), dtype=np.float32)
        self.stream.accept_waveform(SAMPLE_RATE, tail)
        self.stream.input_finished()
        while self.eng.rec.is_ready(self.stream):
            self.eng.rec.decode_stream(self.stream)
        return self._final()


class StreamingEngine(Engine):
    streaming = True

    def __init__(self, name, model_dir, encoder, decoder, joiner, tokens="tokens.txt",
                 model_type="", hotwords=False, fuzzy=False,
                 num_threads=2, trailing_silence=0.3, hotwords_score=2.0, beam=4):
        self.name = name
        self.fuzzy = fuzzy
        self.hotwords = hotwords
        self.tokens = _p(model_dir, tokens)
        self.vocab = Vocab(self.tokens)
        bpe = dict(modeling_unit="bpe", bpe_vocab=self.vocab.bpe_vocab_file()) if hotwords else {}
        self.rec = sherpa_onnx.OnlineRecognizer.from_transducer(
            **bpe,
            tokens=self.tokens,
            encoder=_p(model_dir, encoder),
            decoder=_p(model_dir, decoder),
            joiner=_p(model_dir, joiner),
            num_threads=num_threads,
            sample_rate=SAMPLE_RATE,
            model_type=model_type,
            decoding_method="modified_beam_search" if hotwords else "greedy_search",
            max_active_paths=beam,
            hotwords_score=hotwords_score,
            enable_endpoint_detection=True,
            rule1_min_trailing_silence=2.4,
            rule2_min_trailing_silence=trailing_silence,
            rule3_min_utterance_length=20,
        )

    def hotwords_for(self, words):
        return self.vocab.hotwords(words)

    def session(self, onscreen):
        return StreamingSession(self, onscreen)


class Vocab:
    """Greedy longest-match tokenizer over a model's tokens.txt.

    Good enough to express a single word as model tokens for hotword boosting
    or keyword spotting, without needing the model's sentencepiece file.
    """

    def __init__(self, tokens_path: str):
        self.path = tokens_path
        self.ordered = [line.split()[0] for line in open(tokens_path, encoding="utf-8")
                        if line.strip()]
        self.tokens = set(self.ordered)
        self.upper = _tokens_are_upper(tokens_path)
        self.maxlen = max(len(t) for t in self.tokens)

    def encode(self, word: str) -> list[str]:
        s = "\u2581" + (word.upper() if self.upper else word.lower())
        out, i = [], 0
        while i < len(s):
            for j in range(min(len(s), i + self.maxlen), i, -1):
                if s[i:j] in self.tokens:
                    out.append(s[i:j])
                    i = j
                    break
            else:
                raise ValueError(f"cannot tokenize {word!r} with this model")
        return out

    def hotwords(self, words: list[str]) -> str:
        """Hotwords string for sherpa-onnx with modeling_unit="bpe"."""
        return "/".join(w.upper() if self.upper else w.lower() for w in words)

    def bpe_vocab_file(self) -> str:
        """sherpa-onnx wants a sentencepiece-style vocab to encode hotwords.

        Every piece scores -1 so segmentation prefers the fewest, longest
        pieces, which is how the model itself spells common words. (Equal
        scores make it spell hotwords letter by letter, which never matches.)
        """
        out = Path(self.path).with_name("_hotwords_bpe.vocab")
        out.write_text("".join(f"{t}\t-1\n" for t in self.ordered))
        return str(out)


def _tokens_are_upper(tokens_path: str) -> bool:
    letters = "".join(line.split()[0] for line in open(tokens_path, encoding="utf-8")
                      if line.strip())
    letters = [c for c in letters if c.isalpha() and c.isascii()]
    return sum(c.isupper() for c in letters) > len(letters) / 2


# ---------------------------------------------------------------------------
# Keyword spotter: the on-screen words *are* the grammar. Nothing else can be
# recognized, which suits a closed vocabulary but needs a threshold to reject
# off-screen words and noise.
# ---------------------------------------------------------------------------


class KwsSession(Session):
    def __init__(self, eng: "KwsEngine", onscreen):
        self.eng = eng
        self.matcher = WordMatcher(onscreen)
        kw = "/".join(f"{' '.join(eng.vocab.encode(w))} @{w}" for w in onscreen)
        self.stream = eng.kws.create_stream(keywords=kw)

    def feed(self, samples):
        kws, s = self.eng.kws, self.stream
        s.accept_waveform(SAMPLE_RATE, samples)
        events = []
        while kws.is_ready(s):
            kws.decode_stream(s)
            r = kws.get_result(s)
            if r:
                kws.reset_stream(s)
                events.append(Event(self.matcher.match(r, final=True), r, False))
        return events

    def flush(self):
        return self.feed(np.zeros(int(0.6 * SAMPLE_RATE), dtype=np.float32))


class KwsEngine(Engine):
    streaming = True

    def __init__(self, name, model_dir, encoder, decoder, joiner, threshold=0.25,
                 score=1.0, num_threads=2):  # noqa: D107
        self.name = name
        self.model_dir = model_dir
        self.tokens = _p(model_dir, "tokens.txt")
        self.vocab = Vocab(self.tokens)
        # The C++ side insists on a keywords file; real keywords come per stream.
        dummy = MODELS_DIR / model_dir / "_default_keywords.txt"
        if not dummy.exists():
            dummy.write_text(" ".join(self.vocab.encode("hello")) + " @hello\n")
        self.kws = sherpa_onnx.KeywordSpotter(
            tokens=self.tokens,
            encoder=_p(model_dir, encoder),
            decoder=_p(model_dir, decoder),
            joiner=_p(model_dir, joiner),
            keywords_file=str(dummy),
            num_threads=num_threads,
            keywords_threshold=threshold,
            keywords_score=score,
            num_trailing_blanks=1,
        )

    def session(self, onscreen):
        return KwsSession(self, onscreen)


# ---------------------------------------------------------------------------
# Non-streaming models (Whisper, Moonshine, Parakeet) behind Silero VAD: wait
# for the child to stop talking, then transcribe the whole utterance at once.
# Latency = VAD silence hang-over + inference time.
# ---------------------------------------------------------------------------


class VadSession(Session):
    def __init__(self, eng: "VadOfflineEngine", onscreen):
        self.eng = eng
        self.matcher = WordMatcher(onscreen, fuzzy=eng.fuzzy)
        self.vad = sherpa_onnx.VoiceActivityDetector(eng.vad_config, buffer_size_in_seconds=30)
        self.buf = np.zeros(0, dtype=np.float32)
        # Everything fed so far (a real game keeps a ring buffer of a few
        # seconds), so segments can be re-cut with lead-in the VAD dropped.
        self.history = np.zeros(0, dtype=np.float32)

    def _drain(self):
        events = []
        while not self.vad.empty():
            front = self.vad.front
            seg = np.asarray(front.samples, dtype=np.float32)
            if self.eng.preroll > 0:
                a = max(0, front.start - int(self.eng.preroll * SAMPLE_RATE))
                seg = self.history[a : front.start + len(seg)]
            self.vad.pop()
            text = self.eng.transcribe(seg, self.matcher.onscreen)
            if text:
                events.append(Event(self.matcher.match(text, final=True), text, True))
        return events

    def feed(self, samples):
        # Silero wants whole 512-sample windows.
        self.buf = np.concatenate([self.buf, samples])
        self.history = np.concatenate([self.history, samples])
        n = len(self.buf) // 512 * 512
        if n:
            self.vad.accept_waveform(self.buf[:n])
            self.buf = self.buf[n:]
        return self._drain()

    def flush(self):
        self.vad.flush()
        return self._drain()


class VadOfflineEngine(Engine):
    streaming = False

    def __init__(self, name, make_recognizer, min_silence=0.25, fuzzy=False, tokens=None,
                 preroll=0.25):
        self.name = name
        self.preroll = preroll  # seconds of audio kept before the VAD's start
        self.fuzzy = fuzzy
        self.rec = make_recognizer()
        # tokens set => transducer decoded with beam search + on-screen hotwords
        self.vocab = Vocab(tokens) if tokens else None
        cfg = sherpa_onnx.VadModelConfig()
        cfg.silero_vad.model = str(MODELS_DIR / "silero_vad.onnx")
        cfg.silero_vad.min_silence_duration = min_silence
        cfg.silero_vad.min_speech_duration = 0.1
        cfg.silero_vad.threshold = 0.5
        cfg.silero_vad.window_size = 512
        cfg.sample_rate = SAMPLE_RATE
        cfg.num_threads = 1
        self.vad_config = cfg

    def transcribe(self, samples: np.ndarray, onscreen: list[str]) -> str:
        # Pad short segments; most offline models are trained on >=1 s audio.
        pad = np.zeros(int(0.3 * SAMPLE_RATE), dtype=np.float32)
        if self.vocab:
            s = self.rec.create_stream(hotwords=self.vocab.hotwords(onscreen))
        else:
            s = self.rec.create_stream()
        s.accept_waveform(SAMPLE_RATE, np.concatenate([pad, samples, pad]))
        self.rec.decode_stream(s)
        return s.result.text.strip()

    def session(self, onscreen):
        return VadSession(self, onscreen)


# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------

ZIP = "sherpa-onnx-streaming-zipformer-en-2023-06-26"
ZIP_SUFFIX = "epoch-99-avg-1-chunk-16-left-128.int8.onnx"
ZIP20 = "sherpa-onnx-streaming-zipformer-en-20M-2023-02-17"
KROKO = "sherpa-onnx-streaming-zipformer-en-kroko-2025-08-06"
NEMO80 = "sherpa-onnx-nemo-streaming-fast-conformer-transducer-en-80ms-int8"
KWS = "sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01"


def _whisper(size, threads):
    d = f"sherpa-onnx-whisper-{size}"
    return lambda: sherpa_onnx.OfflineRecognizer.from_whisper(
        encoder=_p(d, f"{size}-encoder.int8.onnx"),
        decoder=_p(d, f"{size}-decoder.int8.onnx"),
        tokens=_p(d, f"{size}-tokens.txt"),
        num_threads=threads,
    )


def _moonshine_v2(size, threads):
    d = f"sherpa-onnx-moonshine-{size}-en-quantized-2026-02-27"
    return lambda: sherpa_onnx.OfflineRecognizer.from_moonshine_v2(
        encoder=_p(d, "encoder_model.ort"),
        decoder=_p(d, "decoder_model_merged.ort"),
        tokens=_p(d, "tokens.txt"),
        num_threads=threads,
    )


def _moonshine_v1(size, threads):
    d = f"sherpa-onnx-moonshine-{size}-en-int8"
    return lambda: sherpa_onnx.OfflineRecognizer.from_moonshine(
        preprocessor=_p(d, "preprocess.onnx"),
        encoder=_p(d, "encode.int8.onnx"),
        uncached_decoder=_p(d, "uncached_decode.int8.onnx"),
        cached_decoder=_p(d, "cached_decode.int8.onnx"),
        tokens=_p(d, "tokens.txt"),
        num_threads=threads,
    )


def _nemo_offline(d, threads, hot=False, score=2.0, beam=4):
    bpe = dict(modeling_unit="bpe", bpe_vocab=Vocab(_p(d, "tokens.txt")).bpe_vocab_file()) if hot else {}
    return lambda: sherpa_onnx.OfflineRecognizer.from_transducer(
        **bpe,
        encoder=_p(d, "encoder.int8.onnx"),
        decoder=_p(d, "decoder.int8.onnx"),
        joiner=_p(d, "joiner.int8.onnx"),
        tokens=_p(d, "tokens.txt"),
        model_type="nemo_transducer",
        num_threads=threads,
        decoding_method="modified_beam_search" if hot else "greedy_search",
        max_active_paths=beam,
        hotwords_score=score,
    )


PARAKEET = {"parakeet-110m": "sherpa-onnx-nemo-parakeet_tdt_transducer_110m-en-36000-int8",
            "parakeet-0.6b": "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8"}


def make_engine(name: str, threads: int = 2, silence: float = 0.25,
                trailing: float = 0.3, hot_score: float = 2.0, beam: int = 4) -> Engine:
    """Build an engine by short name. See ENGINES for the list."""
    hot = dict(hotwords_score=hot_score, beam=beam)
    z = lambda part: f"{part}-{ZIP_SUFFIX}"  # noqa: E731
    if name == "zipformer":
        return StreamingEngine(name, ZIP, z("encoder"), z("decoder"), z("joiner"),
                               num_threads=threads, trailing_silence=trailing)
    if name == "zipformer-hot":
        return StreamingEngine(name, ZIP, z("encoder"), z("decoder"), z("joiner"),
                               hotwords=True, num_threads=threads, trailing_silence=trailing,
                               **hot)
    if name == "zipformer20m":
        return StreamingEngine(name, ZIP20, "encoder-epoch-99-avg-1.int8.onnx",
                               "decoder-epoch-99-avg-1.int8.onnx",
                               "joiner-epoch-99-avg-1.int8.onnx",
                               num_threads=threads, trailing_silence=trailing)
    if name in ("kroko", "kroko-hot"):
        return StreamingEngine(name, KROKO, "encoder.onnx", "decoder.onnx", "joiner.onnx",
                               hotwords=name.endswith("hot"), num_threads=threads,
                               trailing_silence=trailing, **hot)
    if name == "nemo80":  # NeMo streaming models only support greedy search
        return StreamingEngine(name, NEMO80, "encoder.int8.onnx", "decoder.int8.onnx",
                               "joiner.int8.onnx", model_type="nemo_transducer",
                               num_threads=threads, trailing_silence=trailing)
    if name == "kws":
        return KwsEngine(name, KWS, "encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx",
                         "decoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx",
                         "joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx",
                         num_threads=threads)
    if name.startswith("whisper-"):
        return VadOfflineEngine(name, _whisper(name.split("-", 1)[1], threads), silence)
    if name.startswith("moonshine2-"):
        return VadOfflineEngine(name, _moonshine_v2(name.split("-", 1)[1], threads), silence)
    if name.startswith("moonshine-"):
        return VadOfflineEngine(name, _moonshine_v1(name.split("-", 1)[1], threads), silence)
    if name.removesuffix("-hot") in PARAKEET:
        d = PARAKEET[name.removesuffix("-hot")]
        hot = name.endswith("-hot")
        return VadOfflineEngine(name, _nemo_offline(d, threads, hot, hot_score, beam), silence,
                                tokens=_p(d, "tokens.txt") if hot else None)
    raise ValueError(f"unknown engine {name!r}; choose from {ENGINES}")


ENGINES = [
    "zipformer", "zipformer-hot", "zipformer20m", "kroko", "kroko-hot", "nemo80",
    "kws",
    "whisper-tiny.en", "whisper-base.en", "whisper-small.en",
    "moonshine-tiny", "moonshine-base", "moonshine2-tiny", "moonshine2-base",
    "parakeet-110m", "parakeet-110m-hot", "parakeet-0.6b", "parakeet-0.6b-hot",
]
