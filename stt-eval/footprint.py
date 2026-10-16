"""Mobile-oriented footprint of one engine: memory, load time, 1-thread speed.

  python footprint.py parakeet-110m-hot --threads 1

Run each engine in its own process (peak memory is per process). Phones are
roughly 1.5-3x slower per core than a desktop, so a word that takes 40 ms of
single-thread compute here is ~60-120 ms on a mid-range phone.
"""

from __future__ import annotations

import argparse
import json
import resource
import statistics
import time
from pathlib import Path

import numpy as np

import dataset as ds
from engines import SAMPLE_RATE, make_engine


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("engine")
    ap.add_argument("--threads", type=int, default=1)
    ap.add_argument("--n", type=int, default=60)
    ap.add_argument("--speech-commands",
                    default=str(Path(__file__).resolve().parent.parent / "third_party" / "data" / "speech_commands"))
    args = ap.parse_args()

    rss0 = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024
    t0 = time.perf_counter()
    eng = make_engine(args.engine, threads=args.threads, hot_score=1.5 if "parakeet" in args.engine else 3.0,
                      beam=8)
    load_s = time.perf_counter() - t0
    clips = ds.speech_commands(Path(args.speech_commands))[: args.n * 3 : 3]
    per_word, total_audio, total_compute = [], 0.0, 0.0
    for c in clips:
        x = ds.load_wav(c.path)
        audio = np.concatenate([np.zeros(6400, np.float32), x, np.zeros(19200, np.float32)])
        sess = eng.session([c.word, "cat", "dog", "sun", "red"])
        worst = 0.0
        for i in range(0, len(audio), 320):
            t = time.perf_counter()
            sess.feed(audio[i : i + 320])
            dt = time.perf_counter() - t
            worst = max(worst, dt)
            total_compute += dt
        t = time.perf_counter()
        sess.flush()
        total_compute += time.perf_counter() - t
        total_audio += len(audio) / SAMPLE_RATE
        per_word.append(worst * 1000)
    out = dict(
        engine=args.engine, threads=args.threads, load_s=round(load_s, 2),
        peak_rss_mb=round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024),
        python_baseline_mb=round(rss0),
        rtf=round(total_compute / total_audio, 4),
        worst_chunk_ms_p50=round(statistics.median(per_word), 1),
        worst_chunk_ms_max=round(max(per_word), 1),
    )
    print(json.dumps(out))


if __name__ == "__main__":
    main()
