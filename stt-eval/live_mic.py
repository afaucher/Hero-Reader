"""Live microphone test: read the words on screen, see what fires and how fast.

  python live_mic.py --engine parakeet-110m-hot --list dolch-preprimer

Shows N random words from a word list. Say one; when the engine matches it
you get "ZAP" plus the latency from the moment your voice stopped (negative =
fired while you were still saying it). A word that's heard but not on screen
prints a gentle "miss". Press Ctrl+C to quit; a summary is printed.

Latency here is measured with a simple energy-based voice tracker, so it is
an estimate (+/- 20 ms) but good enough to compare engines on real speech.
"""

from __future__ import annotations

import argparse
import json
import queue
import random
import statistics
import sys
import time
from pathlib import Path

import numpy as np

from engines import ENGINES, SAMPLE_RATE, make_engine

WORDLISTS = Path(__file__).parent.parent / "godot" / "data" / "wordlists"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--engine", default="parakeet-110m-hot", choices=ENGINES)
    ap.add_argument("--list", default="dolch-preprimer", help="word list id in godot/data/wordlists")
    ap.add_argument("--onscreen", type=int, default=5)
    ap.add_argument("--threads", type=int, default=2)
    ap.add_argument("--device", default=None, help="sounddevice input device (name or index)")
    args = ap.parse_args()

    import sounddevice as sd  # imported here so the benchmark doesn't need it

    words = json.loads((WORDLISTS / f"{args.list}.json").read_text())["words"]
    words = [w for w in words if len(w) > 1]  # "a"/"I" alone aren't reliably recognisable
    print(f"loading {args.engine}...", flush=True)
    import matcher
    matcher.SOUND_ALIKE = True
    eng = make_engine(args.engine, threads=args.threads, hot_score=1.5 if "parakeet" in args.engine else 3.0,
                      beam=8)

    chunk = int(0.02 * SAMPLE_RATE)
    q: queue.Queue = queue.Queue()

    def cb(indata, frames, t, status):
        q.put((indata[:, 0].copy(), time.perf_counter()))

    def new_screen():
        on = random.sample(words, args.onscreen)
        print("\n   " + "    ".join(w.upper() for w in on) + "\n", flush=True)
        return on, eng.session(on)

    onscreen, sess = new_screen()
    floor, last_voice = 1e-4, 0.0
    lats, zaps, misses = [], 0, 0
    try:
        with sd.InputStream(samplerate=SAMPLE_RATE, channels=1, dtype="float32",
                            blocksize=chunk, device=args.device, callback=cb):
            print("listening... (Ctrl+C to stop)")
            while True:
                x, t_arrive = q.get()
                e = float((x**2).mean())
                floor = min(floor * 1.002, e) if e < floor * 4 else floor * 1.0005
                if e > max(floor * 8, 1e-6):
                    last_voice = t_arrive
                for ev in sess.feed(x):
                    now = time.perf_counter()
                    if ev.match:
                        lat = (now - last_voice) * 1000
                        lats.append(lat)
                        zaps += 1
                        print(f"  ZAP  {ev.match.word.upper():<10} {lat:+5.0f} ms   (heard: {ev.text!r})")
                        onscreen, sess = new_screen()
                    else:
                        misses += 1
                        print(f"  miss            (heard: {ev.text!r}) - try again!")
    except KeyboardInterrupt:
        pass
    if lats:
        print(f"\n{zaps} zaps, {misses} misses; latency median {statistics.median(lats):.0f} ms, "
              f"max {max(lats):.0f} ms")


if __name__ == "__main__":
    sys.exit(main())
