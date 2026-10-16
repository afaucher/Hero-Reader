"""Record a personal test set (e.g. your child reading words) for benchmark.py.

  python record_words.py --speaker nora --list dolch-preprimer --count 40

For each prompt: press Enter, read the word, recording stops automatically
after a short silence (or after 3 s). Press 's' + Enter to skip a word,
'r' + Enter to redo the last one, 'q' + Enter to quit. Files are written as

  recordings/<speaker>/<word>__<n>.wav   (16 kHz mono)

Then: python benchmark.py --recordings recordings --engines nemo80-hot ...

Recordings of your kids stay on your machine: recordings/ is git-ignored.
"""

from __future__ import annotations

import argparse
import json
import random
from pathlib import Path

import numpy as np
import soundfile as sf

SR = 16000
WORDLISTS = Path(__file__).parent.parent / "godot" / "data" / "wordlists"


def record(sd, device, max_s=3.0, tail_s=0.6):
    """Record until voice then `tail_s` of quiet, or max_s."""
    block = SR // 50
    frames, heard, quiet = [], False, 0
    floor = None
    with sd.InputStream(samplerate=SR, channels=1, dtype="float32", blocksize=block, device=device) as st:
        for _ in range(int(max_s * 50)):
            x, _ = st.read(block)
            x = x[:, 0].copy()
            frames.append(x)
            e = float((x**2).mean())
            floor = e if floor is None else min(floor, e) if len(frames) < 10 else floor
            if e > max(floor * 10, 1e-6):
                heard, quiet = True, 0
            elif heard:
                quiet += 1
                if quiet >= tail_s * 50:
                    break
    return np.concatenate(frames), heard


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--speaker", required=True)
    ap.add_argument("--list", default="dolch-preprimer")
    ap.add_argument("--count", type=int, default=40)
    ap.add_argument("--out", default="recordings")
    ap.add_argument("--device", default=None)
    args = ap.parse_args()
    import sounddevice as sd

    words = json.loads((WORDLISTS / f"{args.list}.json").read_text())["words"]
    random.shuffle(words)
    out = Path(args.out) / args.speaker
    out.mkdir(parents=True, exist_ok=True)
    i, last = 0, None
    while i < min(args.count, len(words)):
        w = words[i]
        cmd = input(f"[{i + 1}/{args.count}]  read:   {w.upper():<12} (Enter) ").strip().lower()
        if cmd == "q":
            break
        if cmd == "s":
            i += 1
            continue
        if cmd == "r" and last:
            last.unlink(missing_ok=True)
            i -= 1
            continue
        audio, heard = record(sd, args.device)
        if not heard:
            print("   didn't hear anything, let's try that one again")
            continue
        n = len(list(out.glob(f"{w}__*.wav")))
        last = out / f"{w}__{n}.wav"
        sf.write(last, audio, SR)
        print(f"   saved {last}")
        i += 1


if __name__ == "__main__":
    main()
