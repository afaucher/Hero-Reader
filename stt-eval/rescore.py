"""Re-score saved benchmark transcripts with a sound-alike matcher.

The default matcher only accepts an exact (or homophone) word. Here, when
nothing matches exactly, the heard word is compared to each on-screen word by
pronunciation (CMU dictionary phonemes) and accepted if it is within
`--max-dist` phoneme edits of exactly one on-screen word, e.g. TRUE -> two
(T R UW vs T UW). This trades a little strictness for far fewer "I said it
right but nothing happened" moments.

  python rescore.py results/clean/trials-*.csv
"""

from __future__ import annotations

import argparse
import csv
import re
from collections import defaultdict

import cmudict

from matcher import canon, tokenize

CMU = cmudict.dict()


def phones(word: str) -> list[str] | None:
    p = CMU.get(word.lower())
    return [re.sub(r"\d", "", x) for x in p[0]] if p else None


def edit(a, b) -> int:
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def sound_match(text: str, onscreen: list[str], max_dist: int) -> str | None:
    by_canon = {canon(w): w for w in onscreen}
    toks = tokenize(text)
    for t in toks:
        if canon(t) in by_canon:
            return by_canon[canon(t)]
    best = []
    for t in toks:
        pt = phones(t)
        if not pt:
            continue
        for w in onscreen:
            pw = phones(w)
            if not pw:
                continue
            d = edit(pt, pw)
            # never fuzz 1-2 phoneme words by more than... nothing: "go"/"no".
            limit = 0 if len(pw) <= 2 else max_dist
            if len(pw) == 2 and len(pt) == 3 and d == 1:
                limit = 1  # allow an extra sound only ("TRUE" for "two")
            if d <= limit:
                best.append((d, w))
    if not best:
        return None
    best.sort()
    if len(best) > 1 and best[0][0] == best[1][0] and best[0][1] != best[1][1]:
        return None  # ambiguous between two on-screen words
    return best[0][1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv", nargs="+")
    ap.add_argument("--max-dist", type=int, default=1)
    args = ap.parse_args()
    agg = defaultdict(lambda: defaultdict(int))
    for path in args.csv:
        for r in csv.DictReader(open(path)):
            key = (r["engine"], r["condition"])
            a = agg[key]
            onscreen = r["onscreen"].split()
            positive = r["positive"] == "True"
            fired = r["fired"] or None
            if not fired:
                for t in r["text"].split(" | "):
                    fired = sound_match(t, onscreen, args.max_dist)
                    if fired:
                        break
            if positive:
                a["pos"] += 1
                a["hit"] += fired == r["word"]
                a["wrong"] += bool(fired) and fired != r["word"]
            else:
                a["neg"] += 1
                a["fa"] += bool(fired)
    print("| engine | cond | hit % | wrong word % | no fire % | false accept % |")
    print("|---|---|---:|---:|---:|---:|")
    for (e, c), a in agg.items():
        pos = max(a["pos"], 1)
        print(f"| {e} | {c} | {100 * a['hit'] / pos:.1f} | {100 * a['wrong'] / pos:.1f} | "
              f"{100 * (pos - a['hit'] - a['wrong']) / pos:.1f} | {100 * a['fa'] / max(a['neg'], 1):.1f} |")


if __name__ == "__main__":
    main()
