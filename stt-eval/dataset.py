"""Test audio for the benchmark.

Two sources:

* Google Speech Commands v0.02 (CC-BY 4.0): ~11k one-second recordings of 35
  single words by ~2,600 different (mostly adult) speakers. Many of them are
  early sight words (go, no, on, up, yes, down, stop, one, two, cat, dog...).
* Your own recordings, made with record_words.py, stored as
  recordings/<speaker>/<word>__<n>.wav. This is how we validate on an actual
  6-year-old's voice, which is the number that really matters.
"""

from __future__ import annotations

import random
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy.signal import resample_poly

SR = 16000
# Proper names in Speech Commands; not reading-game words.
SKIP_WORDS = {"marvin", "sheila", "_background_noise_"}


@dataclass
class Clip:
    word: str
    path: Path
    speaker: str


def load_wav(path: Path) -> np.ndarray:
    x, sr = sf.read(str(path), dtype="float32", always_2d=True)
    x = x.mean(axis=1)
    if sr != SR:
        g = np.gcd(sr, SR)
        x = resample_poly(x, SR // g, sr // g).astype(np.float32)
    return x


def speech_commands(root: Path, split: str = "testing") -> list[Clip]:
    root = Path(root)
    lst = root / f"{split}_list.txt"
    names = lst.read_text().split() if lst.exists() else [
        str(p.relative_to(root)) for p in root.glob("*/*.wav")]
    clips = []
    for rel in names:
        word = rel.split("/")[0]
        if word in SKIP_WORDS:
            continue
        clips.append(Clip(word, root / rel, Path(rel).name.split("_")[0]))
    return clips


def recordings(root: Path) -> list[Clip]:
    """Recorder output: <root>/<age><gender>/<session>/<word>__r<round>.wav.

    The speaker label is the first folder under root (e.g. "8f"), so you can
    point --recordings at the top folder, one speaker, or one session.
    """
    root = Path(root)
    clips = []
    for p in sorted(root.glob("**/*.wav")):
        word = p.stem.split("__")[0].lower()
        rel = p.relative_to(root).parts
        clips.append(Clip(word, p, rel[0] if len(rel) > 1 else root.name))
    return clips


def background_noise(root: Path) -> list[np.ndarray]:
    d = Path(root) / "_background_noise_"
    return [load_wav(p) for p in sorted(d.glob("*.wav"))] if d.exists() else []


def speech_bounds(x: np.ndarray) -> tuple[float, float]:
    """Start/end (seconds) of the spoken word, from 10 ms frame energy.

    A frame counts as speech if it is within 40 dB of the loudest frame and
    at least 9 dB above the clip's noise floor, so quiet word endings
    ("-ppy", "-s") are kept but background hiss isn't.
    """
    hop = SR // 100
    n = len(x) // hop
    if n == 0:
        return 0.0, len(x) / SR
    e = (x[: n * hop].reshape(n, hop) ** 2).mean(axis=1) + 1e-12
    db = 10 * np.log10(e)
    floor = np.percentile(db, 10)
    thr = max(db.max() - 40, floor + 9)
    on = np.where(db > thr)[0]
    if len(on) < 5:  # < 50 ms above the floor: silent / broken clip
        raise ValueError("no speech found")
    return on[0] * hop / SR, (on[-1] + 1) * hop / SR


def child_proxy(x: np.ndarray) -> np.ndarray:
    """Crude child-voice stand-in: shift pitch and formants up ~20%.

    Children have higher F0 and formants (shorter vocal tract). Playing adult
    speech back 1.2x faster raises both; it also speeds speech up, which real
    children don't do, so treat this as a stress test, not a child corpus.
    """
    return resample_poly(x, 5, 6).astype(np.float32)


def mix_noise(x: np.ndarray, noise: np.ndarray, snr_db: float, rng: random.Random) -> np.ndarray:
    if len(noise) < len(x):
        noise = np.tile(noise, len(x) // len(noise) + 1)
    start = rng.randrange(0, len(noise) - len(x) + 1)
    n = noise[start : start + len(x)]
    ps = (x**2).mean() + 1e-12
    pn = (n**2).mean() + 1e-12
    return (x + n * np.sqrt(ps / pn / 10 ** (snr_db / 10))).astype(np.float32)


def spelling_distance(a: str, b: str) -> int:
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


# Pairs that sound alike even though they are spelled differently.
SOUND_ALIKE = [("tree", "three"), ("bed", "bird"), ("no", "go"), ("off", "up"),
               ("four", "forward"), ("dog", "down"), ("five", "nine"), ("on", "one"),
               ("left", "learn"), ("follow", "four"), ("six", "seven"), ("cat", "bed"),
               ("yes", "six"), ("two", "zero"), ("wow", "house")]


def distractors(target: str, vocab: list[str], k: int, hard: bool, rng: random.Random) -> list[str]:
    pool = [w for w in vocab if w != target]
    if not hard:
        return rng.sample(pool, k)
    similar = {b for a, b in SOUND_ALIKE if a == target} | {a for a, b in SOUND_ALIKE if b == target}
    ranked = sorted(pool, key=lambda w: (w not in similar, spelling_distance(target, w), rng.random()))
    return ranked[:k]
