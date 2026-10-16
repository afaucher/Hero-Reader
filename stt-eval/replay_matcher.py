"""Replay saved recognizer events under each sound-alike rule (no re-recognition).

benchmark.py logs every event a trial produced (`events` column: text, final,
ms after the end of the word). Partial results only ever fire on exact
matches, so recognition does not depend on the matcher, and the decision under
any matcher rule can be recomputed exactly from that log.

  python replay_matcher.py results/local-events-*/trials-*.csv
  python replay_matcher.py --wordlists     # misreads each rule accepts in the game's word lists

Rules: "exact" (homophones only), "any" (original sound-alike), "no-onset"
(first sound must match), "extra-only" (only one added sound after the first).
"""

from __future__ import annotations

import argparse
import csv
import glob
import json
from collections import defaultdict
from pathlib import Path

import matcher

MODES = ["exact", "any", "no-onset", "extra-only"]


def set_mode(mode: str):
    matcher.SOUND_ALIKE = mode != "exact"
    matcher.SOUND_ALIKE_MODE = "any" if mode == "exact" else mode


def replay(paths):
    rows = [r for p in paths for r in csv.DictReader(open(p, encoding="utf-8"))]
    if rows and "events" not in rows[0]:
        raise SystemExit("these trials have no `events` column; re-run benchmark.py")
    print("| engine | cond | rule | hit % | wrong word % | false accept % | fired twice % |")
    print("|---|---|---|---:|---:|---:|---:|")
    groups = defaultdict(list)
    for r in rows:
        groups[(r["engine"], r["condition"])].append(r)
    for (eng, cond), rs in groups.items():
        for mode in MODES:
            set_mode(mode)
            hit = wrong = fa = twice = pos = neg = 0
            for r in rs:
                m = matcher.WordMatcher(r["onscreen"].split())
                fired = [x.word for t, final, _ in json.loads(r["events"])
                         if (x := m.match(t, final=final))]
                twice += len(fired) > 1
                if r["positive"] == "True":
                    pos += 1
                    hit += bool(fired) and fired[0] == r["word"]
                    wrong += bool(fired) and fired[0] != r["word"]
                else:
                    neg += 1
                    fa += bool(fired)
            print(f"| {eng} | {cond} | {mode} | {100 * hit / pos:.1f} | {100 * wrong / pos:.1f} | "
                  f"{100 * fa / max(neg, 1):.1f} | {100 * twice / len(rs):.1f} |")


def wordlists():
    """For each game word, which other game words would the rule accept for it?"""
    levels = Path(__file__).resolve().parent.parent / "godot" / "data" / "wordlists" / "levels"
    worlds = [(f.stem, wd["words"]) for f in sorted(levels.glob("l*.json"))
              for wd in json.loads(f.read_text(encoding="utf-8"))["worlds"]]
    universe = sorted({w for _, ws in worlds for w in ws})  # plausible things a child says
    targets = sorted({w for _, ws in worlds for w in ws})
    print(f"{len(targets)} game words; misread = another game word the rule accepts for it\n")
    print("| rule | words with 1+ accepted misread | accepted misreads per word | examples |")
    print("|---|---:|---:|---|")
    for mode in MODES[1:]:
        set_mode(mode)
        acc = {}
        for w in targets:
            m = matcher.WordMatcher([w])
            acc[w] = [u for u in universe
                      if matcher.canon(u) != matcher.canon(w) and m.match(u, final=True)]
        n = sum(bool(v) for v in acc.values())
        ex = ", ".join(f"{u}->{w}" for w in ("cat", "big", "dog", "sun", "red", "two") for u in acc.get(w, [])[:2])
        print(f"| {mode} | {n} ({100 * n / len(targets):.0f}%) | "
              f"{sum(map(len, acc.values())) / len(targets):.2f} | {ex} |")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("trials", nargs="*")
    ap.add_argument("--wordlists", action="store_true")
    a = ap.parse_args()
    if a.wordlists:
        wordlists()
    if a.trials:
        replay([p for pat in a.trials for p in glob.glob(pat)])


if __name__ == "__main__":
    main()
