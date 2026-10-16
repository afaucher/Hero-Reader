"""Pick the reject thresholds of the closed-set deciders on seed 11.

The benchmark reports seed 7, so thresholds are chosen on different trials
(same clips pool, same conditions, 300 + 75 per condition). Prints hit /
wrong-word / false-accept % per condition for a grid of thresholds.

  python tune_closed_set.py vosk-grammar          # vosk venv
  python tune_closed_set.py parakeet-110m-score   # vosk venv (needs onnxruntime)
"""

from __future__ import annotations

import json
import random
import sys
from pathlib import Path

import benchmark as bm
import dataset as ds
import engines
import matcher

ROOT = Path(__file__).resolve().parent.parent / "third_party" / "data" / "speech_commands"
CONDS = ["clean", "noise10", "child"]


def trials(eng, record):
    clips = ds.speech_commands(ROOT)
    noises = ds.background_noise(ROOT)
    vocab = sorted({c.word for c in clips})
    rows = []
    for cname in CONDS:
        rng = random.Random(11)
        plan = [(True, c) for c in rng.sample(clips, 300)] + [(False, c) for c in rng.sample(clips, 75)]
        for pos, clip in plan:
            try:
                audio, _, _ = bm.build_stream(ds.load_wav(clip.path), bm.CONDITIONS[cname], noises, rng)
            except ValueError:
                continue
            if pos:
                onscreen = ds.distractors(clip.word, vocab, 4, False, rng) + [clip.word]
            else:
                onscreen = rng.sample([w for w in vocab if w != clip.word], 5)
            rng.shuffle(onscreen)
            record.clear()
            bm.run_trial(eng, audio, onscreen)
            rows.append(dict(cond=cname, pos=pos, word=clip.word, segs=list(record)))
        print(f"{cname} done", file=sys.stderr)
    return rows


def report(rows, grid, decide):
    for params in grid:
        out = []
        for cname in CONDS:
            r = [x for x in rows if x["cond"] == cname]
            p, n = [x for x in r if x["pos"]], [x for x in r if not x["pos"]]
            first = lambda x: next((d for s in x["segs"] if (d := decide(s, *params))), None)  # noqa: E731
            hit = sum(first(x) == x["word"] for x in p) / len(p)
            wrong = sum(first(x) not in (None, x["word"]) for x in p) / len(p)
            fa = sum(first(x) is not None for x in n) / len(n)
            out.append(f"{cname} {100 * hit:.1f}/{100 * wrong:.1f}/{100 * fa:.1f}")
        print(f"{params}: hit/wrong/FA " + " | ".join(out))


def main():
    matcher.SOUND_ALIKE = True
    name = sys.argv[1]
    record = []
    if name == "vosk-grammar":
        eng = engines.make_engine(name)
        eng.min_conf = 0.0
        orig = engines.VoskSession._text

        def spy(self, js, key):
            if key == "text":
                record.append([w for w in json.loads(js).get("result", []) if w["word"] != "[unk]"])
            return orig(self, js, key)

        engines.VoskSession._text = spy
        rows = trials(eng, record)

        def decide(seg, thr):
            return seg[0]["word"] if seg and seg[0]["conf"] >= thr else None

        report(rows, [(t,) for t in (0, 0.5, 0.7, 0.8, 0.85, 0.9, 0.95, 1.0)], decide)
    elif name == "parakeet-110m-score":
        import candidate_scoring  # noqa: F401  (registers the engine)
        eng = engines.make_engine(name, silence=0.2)
        orig = eng.scorer.decide

        def spy(audio, onscreen):
            r = orig(audio, onscreen)
            record.append(dict(scores=r[2], free_ll=r[3]))
            return r

        eng.scorer.decide = spy
        rows = trials(eng, record)

        def decide(seg, reject, margin):
            (b, w), second = seg["scores"][0], seg["scores"][1][0]
            return w if b - max(seg["free_ll"], b) > -reject and b - second > margin else None

        report(rows, [(r, m) for r in (2, 3, 4, 6, 8, 12) for m in (0, 0.5, 1, 2, 3)], decide)
    else:
        sys.exit("usage: tune_closed_set.py vosk-grammar|parakeet-110m-score")


if __name__ == "__main__":
    main()
