"""Map raw ASR text onto the closed set of words currently on screen.

The game never needs open dictation: at any moment only a handful of words
are on screen, so the job is "which of these N words (if any) was just read?".
This module turns a (possibly partial) transcript into that decision.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

# Sound-alike matching (same rules as the game's C++ matcher). Set from
# benchmark.py --sound-alike; needs godot/data/pron_dict.txt (tools/setup.py).
SOUND_ALIKE = False
PRON_DICT = Path(__file__).parent.parent / "godot" / "data" / "pron_dict.txt"
_PRON: dict[str, list[str]] = {}


def _pron() -> dict[str, list[str]]:
    if not _PRON and PRON_DICT.exists():
        for line in PRON_DICT.read_text().splitlines():
            if line and not line.startswith("#"):
                w, *ph = line.split()
                _PRON[w] = ph
    return _PRON

# Words a child can read correctly but an ASR model may spell differently.
# Each group is treated as equivalent when matching.
HOMOPHONES = [
    {"to", "two", "too", "2"},
    {"for", "four", "4"},
    {"one", "won", "1"},
    {"no", "know"},
    {"right", "write"},
    {"eight", "ate", "8"},
    {"there", "their", "they're"},
    {"see", "sea", "c"},
    {"be", "bee", "b"},
    {"I", "eye", "i"},
    {"you", "u"},
    {"are", "r"},
    {"why", "y"},
    {"by", "buy", "bye"},
    {"here", "hear"},
    {"red", "read"},
    {"blue", "blew"},
    {"new", "knew"},
    {"so", "sew"},
    {"sun", "son"},
    {"meet", "meat"},
    {"not", "knot"},
    {"oh", "o"},
    {"okay", "ok"},
    {"zero", "0"},
    {"three", "3"},
    {"five", "5"},
    {"six", "6"},
    {"seven", "7"},
    {"nine", "9"},
    {"ten", "10"},
]

_CANON: dict[str, str] = {}
for group in HOMOPHONES:
    rep = sorted(group)[0].lower()
    for w in group:
        _CANON[w.lower()] = rep

_TOKEN_RE = re.compile(r"[a-z0-9']+")


def canon(word: str) -> str:
    w = word.lower().strip("'")
    return _CANON.get(w, w)


def tokenize(text: str) -> list[str]:
    return _TOKEN_RE.findall(text.lower().replace("▁", " "))


def _edit_distance(a: str, b: str) -> int:
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


@dataclass
class Match:
    word: str  # the on-screen word that matched (original spelling)
    heard: str  # the ASR token that produced the match
    kind: str  # "exact" | "fuzzy"


class WordMatcher:
    """Closed-set matcher for the words currently on screen."""

    def __init__(self, onscreen: list[str], fuzzy: bool = False):
        self.onscreen = list(onscreen)
        self.by_canon = {canon(w): w for w in onscreen}
        self.fuzzy = fuzzy or SOUND_ALIKE

    def _prefix_ambiguous(self, tok: str) -> bool:
        """True if tok could still grow into a *different* on-screen word."""
        c = canon(tok)
        return any(o != c and o.startswith(c) for o in self.by_canon)

    def match(self, text: str, final: bool) -> Match | None:
        """Return the first on-screen word found in `text`.

        For partial (non-final) hypotheses the last token may still be growing
        ("on" -> "one"), so it is only accepted if no other on-screen word
        starts with it.
        """
        toks = tokenize(text)
        for i, tok in enumerate(toks):
            c = canon(tok)
            if c in self.by_canon:
                is_last = i == len(toks) - 1
                if final or not is_last or not self._prefix_ambiguous(tok):
                    return Match(self.by_canon[c], tok, "exact")
        if final and self.fuzzy and toks:
            return self._fuzzy(toks)
        return None

    def _fuzzy(self, toks: list[str]) -> Match | None:
        """Accept the on-screen word within one phoneme of a heard word.

        1-2 phoneme words only tolerate one *extra* sound ("true" for "two"),
        never a substitution ("go" must not become "no"). Ties -> no match.
        """
        pron = _pron()
        best_d, best, tie = 99, None, False
        for tok in toks:
            pt = pron.get(tok)
            if not pt:
                continue
            for w in self.onscreen:
                pw = pron.get(w.lower())
                if not pw:
                    continue
                d = _edit_distance(pt, pw)
                limit = 0 if len(pw) <= 2 else 1
                if len(pw) == 2 and len(pt) == 3 and d == 1:
                    limit = 1
                if d > limit:
                    continue
                if d < best_d:
                    best_d, best, tie = d, Match(w, tok, "fuzzy"), False
                elif d == best_d and best and w != best.word:
                    tie = True
        return None if tie else best
