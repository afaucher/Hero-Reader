#!/usr/bin/env python3
"""Build the leveled word lists for Hero Reader.

Usage:  python3 build_levels.py            # check + write JSON
        python3 build_levels.py --check    # check only, write nothing

Pure Python 3 stdlib. Reads ../../pron_dict.txt (relative to this file) and
writes one JSON file per reading level next to this script, plus index.json.

Each level file:
  {"id", "name", "grade", "description", "source",
   "worlds": [{"id", "name", "words": [...], "confusable": [[w1, w2], ...]}]}

Checks (the build fails if any of them fails):
  * every word is lowercase a-z only and at least 2 letters (no "a" / "I")
  * no duplicate words within a level (repeats across levels are fine)
  * every word exists in pron_dict.txt
  * every World has 25-40 words
  * every World has a set of >= MIN_SAFE_SET words that are pairwise
    NOT confusable, so the spawner can always fill the screen safely

"confusable" lists every pair in a World whose pronunciations are within one
phoneme of each other. Plain phoneme edit distance <= 1 catches cat/hat,
cat/cap, no/go, tree/three, pig/big. On top of that the distance is weighted:
swapping two sound-alike phonemes (p/b, t/d, m/n, short i/e, ah/aa...) costs
0.5 and inserting or dropping a glide (w, y, h) costs 0.5, so near misses
like on/one (AA N vs W AH N) and bat/pad also count. Homophones (to/two)
have distance 0 and are always flagged. The game should never show two words
from the same pair on screen at the same time.
"""

import json
import os
import re
import sys
from itertools import combinations

HERE = os.path.dirname(os.path.abspath(__file__))
DICT_PATH = os.path.normpath(os.path.join(HERE, "..", "..", "pron_dict.txt"))

MIN_WORLD = 25
MAX_WORLD = 40
MIN_SAFE_SET = 5          # max words on screen at once in the hardest level
CONFUSABLE_THRESHOLD = 1.0

# Extra pairs the speech evaluation found confusing even if the dictionary
# distance says otherwise. Only applied when both words are in the same World.
MANUAL_CONFUSABLE = [
    ("on", "one"),
    ("cat", "cap"),
    ("tree", "three"),
    ("no", "go"),
]

SOURCES = {
    "dolch": "Dolch sight words (1936, public domain)",
    "fry": "Fry Instant Words (public domain frequency list)",
    "phonics": "standard decodable phonics patterns (CVC, blends, digraphs, CVCe, vowel teams, r-controlled)",
    "nouns": "Dolch picture nouns and common kid-friendly nouns",
}

# --------------------------------------------------------------------------
# Word content. Edit here, then re-run the script.
# --------------------------------------------------------------------------

LEVELS = [
    {
        "id": "L0",
        "file": "l0-letter-sounds-cvc.json",
        "name": "Letter Sounds & CVC",
        "grade": "Pre-K to K (phonics)",
        "description": "Short-vowel consonant-vowel-consonant words, one vowel per World, "
                       "grouped by word family. Every word can be sounded out letter by letter.",
        "source": SOURCES["phonics"],
        "worlds": [
            ("short-a", "Short a", """
                cat bat hat mat rat sat pat
                can fan man pan ran van tan
                cap map nap tap lap
                bag rag tag wag
                jam ham ram yam
                dad sad pad bad had
                cab lab wax
            """),
            ("short-i", "Short i", """
                big pig dig wig fig
                sit hit kit fit bit pit
                pin win fin tin bin
                lip hip dip zip rip sip tip
                mix fix six
                kid lid hid rid
                him rim
            """),
            ("short-o", "Short o", """
                dog hog log fog jog
                hot pot dot cot lot got not
                mop top hop pop cop
                box fox ox
                rod nod pod
                job cob bop jot
                mom rock sock lock dock
            """),
            ("short-u", "Short u", """
                bug hug mug rug jug dug tug
                cup pup up
                bun fun run sun
                but cut hut nut
                bud mud
                tub rub cub sub
                gum hum yum sum
                bus buzz duck luck
            """),
            ("short-e", "Short e", """
                bed red fed led wed
                pet wet net jet get let met set vet
                hen pen ten men den
                leg peg beg
                web yes yet
                neck deck peck
                bell tell well yell
            """),
        ],
    },
    {
        "id": "L1",
        "file": "l1-prek-sight-cvc.json",
        "name": "First Sight Words",
        "grade": "Pre-K",
        "description": "The Dolch pre-primer sight words (minus the one-letter words a and I), "
                       "mixed with short-vowel CVC words and easy picture nouns.",
        "source": SOURCES["dolch"] + "; " + SOURCES["phonics"] + "; " + SOURCES["nouns"],
        "worlds": [
            ("look-and-see", "Look and See", """
                the see look go up my me you
                cat hat bat mat dog log pig wig sun bug hug mug
                hen pen ten bed cup pup box fox map cap egg duck
            """),
            ("run-and-jump", "Run and Jump", """
                run jump play can big red and we
                man fan van pan sit hit kit pin fin hop top mop
                hot pot nut hut cut jet net wet web leg bag tag
            """),
            ("come-and-help", "Come and Help", """
                come help here where said not for is
                dig fig mix fix zip lip dip hip
                rug jug bun fun gum tub cub mud
                rock sock lock jam ham yam dad yes
            """),
            ("funny-friends", "Funny Little Friends", """
                funny little yellow blue away find make down
                ball bird boat car cow doll fish frog toy tree cake bell
                hill milk nest ring rain seed snow song star kite bike bee
            """),
            ("one-two-three", "One, Two, Three", """
                one two three to in it four five nine six
                sat rat pat nap tap lap win tin bin lid kid
                dot lot job bus rub hum pet men den well tell
            """),
        ],
    },
    {
        "id": "L2",
        "file": "l2-kindergarten.json",
        "name": "Kindergarten",
        "grade": "K",
        "description": "Dolch primer sight words, words with blends (st, fl, cr...), "
                       "digraphs (sh, ch, th, ck), ng/nk endings, and everyday nouns.",
        "source": SOURCES["dolch"] + "; " + SOURCES["phonics"] + "; " + SOURCES["nouns"],
        "worlds": [
            ("blends", "Blend Blast", """
                all am are at ate be black brown but came did do eat
                stop step spin spot swim snap slip sled flag flat frog
                crab drum drip grab grin trip clap clip plan plum
            """),
            ("sh-ch-th", "Sh, Ch, Th", """
                four get good have he into like must new no now on our
                ship shop shell fish dish wish chip chop chin chick much lunch
                bath path moth thin thick kick neck pack duck
            """),
            ("end-blends", "Ending Blends", """
                out please pretty ran ride saw say she so soon that there they
                hand sand land pond best nest rest vest lamp camp milk gift
                desk tent belt jump bump list fast last
            """),
            ("ng-nk", "Ring and Sing", """
                this too under want was well went what white who will with yes
                ring sing king wing long song hang pink sink wink think thank honk
                bell hill doll fill kiss miss puff
            """),
            ("everyday-things", "Everyday Things", """
                apple baby ball bear bird boat boy bread cake car chair coat
                corn cow door egg farm feet game girl grass head home horse
                house rabbit rain seed sheep shoe snow table toy tree window water
            """),
        ],
    },
    {
        "id": "L3",
        "file": "l3-grade1.json",
        "name": "Grade 1",
        "grade": "1",
        "description": "Dolch grade 1 sight words and Fry first-100 words, with magic-e (CVCe), "
                       "vowel-team and bossy-r phonics words.",
        "source": SOURCES["dolch"] + "; " + SOURCES["fry"] + "; " + SOURCES["phonics"],
        "worlds": [
            ("magic-e-a", "Magic E: a", """
                after again an any as ask by could every fly from give had has
                cake game name same gate late plate cave wave save lake snake
                shake face race tape grape skate
            """),
            ("magic-e-i", "Magic E: i", """
                her him his how just know let live may of old once open over
                bike hike kite bite five dive hive line mine nine pine fine
                ride hide side wide slide smile time
            """),
            ("magic-e-o-u", "Magic E: o and u", """
                put round some stop take thank them then think walk were when giving
                home bone cone hope rope nose rose note joke stone smoke broke globe
                cube cute mule tube flute huge use
            """),
            ("vowel-teams", "Vowel Teams", """
                rain train paint tail mail snail play stay tray
                green sleep sheep feet teeth queen wheel
                leaf beach team seat clean dream
                boat coat goat road soap toad float
                snow grow show slow
            """),
            ("bossy-r", "Bossy R", """
                car star park farm barn yard shark jar arm dark start
                bird girl shirt first dirt third
                corn horn fork storm short sport porch
                fur turn burn surf curl fern
            """),
            ("fry-power", "Power Words", """
                about each which their there would people number water word write
                been call made part other many these those because does goes
                where very your find long look more most only also
            """),
        ],
    },
    {
        "id": "L4",
        "file": "l4-grade2.json",
        "name": "Grade 2",
        "grade": "2",
        "description": "Dolch grade 2 sight words, Fry 101-200 words, and grade-2 phonics: "
                       "igh/oo, ou/ow, oi/oy, soft c and g, compound and two-syllable words.",
        "source": SOURCES["dolch"] + "; " + SOURCES["fry"] + "; " + SOURCES["phonics"],
        "worlds": [
            ("igh-oo", "Night and Moon", """
                always around because before best both buy call cold does fast found
                gave goes green many off pull read right
                light night bright high sky try
                moon spoon zoo boot food pool roof
            """),
            ("ou-ow", "Clouds and Crowns", """
                sing sit sleep tell their these those upon us use very wash which
                why wish work would write your first five been made its or
                cloud house mouse mouth owl town clown crown flower
            """),
            ("fry-101-200", "Big Idea Words", """
                place year thing great through sentence mean same follow show also
                small large even another such turn need land different move kind
                picture change spell air animal point page letter answer study
                learn should world still
            """),
            ("oi-oy-compound", "Coins and Cowboys", """
                coin join soil boil foil noise voice choice boy toy joy enjoy
                sunset rainbow cupcake backpack popcorn starfish snowman sandbox
                bedtime football baseball goldfish sailboat cowboy homework
                city nice rice mice cage giant
            """),
            ("two-syllables", "Two-Beat Words", """
                rabbit kitten puppy garden button basket pencil napkin picnic muffin
                magnet tiger zebra pizza robot planet rocket music paper happy
                sunny silly jelly cookie apple turtle purple orange yellow pillow
                wagon lemon melon seven
            """),
        ],
    },
    {
        "id": "L5",
        "file": "l5-grade3.json",
        "name": "Grade 3",
        "grade": "3",
        "description": "Dolch grade 3 sight words, Fry 201-300 words, and longer content words: "
                       "space, nature and animals, prefixes and suffixes.",
        "source": SOURCES["dolch"] + "; " + SOURCES["fry"] + "; " + SOURCES["phonics"],
        "worlds": [
            ("dolch-g3", "Bring It Together", """
                about better bring carry clean done draw drink eight fall far full
                grow hold keep kind laugh light never only
                high every near food between below country plant school father
                earth thought story along
            """),
            ("fry-201-300-a", "Mountain Path", """
                myself own pick seven shall show small start today together try warm
                something seem next hard example begin often group important until
                children began took river second idea enough really almost above
            """),
            ("fry-201-300-b", "Story Time", """
                sometimes mountain young talk family leave without hear book left
                few while add last head under side feet watch face list song
                city paper close eye might life later mile state
            """),
            ("space", "Space Words", """
                planet comet rocket orbit galaxy astronaut gravity telescope meteor
                moon crater satellite launch alien spaceship asteroid universe
                sunlight shuttle helmet oxygen explore mission signal robot laser
                engine captain crew cosmic eclipse journey distance
            """),
            ("prefix-suffix", "Word Builders", """
                unlock untie undo unpack replay retell reuse rewrite helpful careful
                playful thankful colorful quickly slowly softly loudly kindness
                darkness teacher painter farmer swimmer runner sleepy windy cloudy
                rainy snowy biggest tallest fastest
            """),
            ("nature-animals", "Wild Places", """
                forest ocean desert island valley meadow jungle waterfall volcano
                rainbow weather season autumn winter summer spring
                dolphin penguin elephant giraffe octopus turtle butterfly squirrel
                kangaroo hamster parrot eagle beaver
            """),
        ],
    },
]

# --------------------------------------------------------------------------
# Pronunciation helpers
# --------------------------------------------------------------------------

SIMILAR_PAIRS = [
    # consonants: voicing pairs, nasals, th/f
    ("P", "B"), ("T", "D"), ("K", "G"), ("F", "V"), ("TH", "DH"), ("S", "Z"),
    ("SH", "ZH"), ("CH", "JH"), ("M", "N"), ("N", "NG"), ("F", "TH"), ("V", "DH"),
    ("S", "SH"), ("CH", "SH"),
    # neighbouring vowels
    ("IH", "EH"), ("EH", "AE"), ("AE", "AH"), ("AH", "AA"), ("AA", "AO"),
    ("IH", "IY"), ("UH", "UW"), ("AO", "OW"), ("AH", "UH"), ("EH", "EY"),
]
SIMILAR = {frozenset(p) for p in SIMILAR_PAIRS}
GLIDES = {"W", "Y", "HH"}


def load_dict(path):
    pron = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            if not line.strip() or line.startswith("#"):
                continue
            parts = line.split()
            word = parts[0]
            if word not in pron:
                pron[word] = tuple(parts[1:])
    return pron


def sub_cost(a, b):
    if a == b:
        return 0.0
    if frozenset((a, b)) in SIMILAR:
        return 0.5
    return 1.0


def indel_cost(p):
    return 0.5 if p in GLIDES else 1.0


def phone_distance(a, b):
    """Weighted Levenshtein distance between two phoneme sequences."""
    n, m = len(a), len(b)
    prev = [0.0] * (m + 1)
    for j in range(1, m + 1):
        prev[j] = prev[j - 1] + indel_cost(b[j - 1])
    for i in range(1, n + 1):
        cur = [prev[0] + indel_cost(a[i - 1])] + [0.0] * m
        for j in range(1, m + 1):
            cur[j] = min(prev[j] + indel_cost(a[i - 1]),
                         cur[j - 1] + indel_cost(b[j - 1]),
                         prev[j - 1] + sub_cost(a[i - 1], b[j - 1]))
        prev = cur
    return prev[m]


def plain_distance(a, b):
    n, m = len(a), len(b)
    prev = list(range(m + 1))
    for i in range(1, n + 1):
        cur = [i] + [0] * m
        for j in range(1, m + 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] != b[j - 1]))
        prev = cur
    return prev[m]


def confusable_pairs(words, pron):
    manual = {frozenset(p) for p in MANUAL_CONFUSABLE}
    pairs = []
    plain = 0
    for w1, w2 in combinations(words, 2):
        d = phone_distance(pron[w1], pron[w2])
        if d <= CONFUSABLE_THRESHOLD or frozenset((w1, w2)) in manual:
            pairs.append([w1, w2])
            if plain_distance(pron[w1], pron[w2]) <= 1:
                plain += 1
    return pairs, plain


def greedy_safe_set(words, pairs):
    """Size of a greedy independent set in the confusability graph."""
    nbrs = {w: set() for w in words}
    for a, b in pairs:
        nbrs[a].add(b)
        nbrs[b].add(a)
    chosen, blocked = [], set()
    for w in sorted(words, key=lambda w: len(nbrs[w])):
        if w not in blocked:
            chosen.append(w)
            blocked |= nbrs[w] | {w}
    return len(chosen)


# --------------------------------------------------------------------------
# Build
# --------------------------------------------------------------------------

def main():
    check_only = "--check" in sys.argv
    pron = load_dict(DICT_PATH)
    print(f"Loaded {len(pron)} pronunciations from {os.path.relpath(DICT_PATH, HERE)}")

    errors = []
    index = []
    total_words = 0
    total_pairs = 0
    total_plain = 0
    outputs = []

    for level in LEVELS:
        seen = {}
        worlds_out = []
        print(f"\n{level['id']} {level['name']} ({level['grade']})")
        for wid, wname, text in level["worlds"]:
            words = text.split()
            tag = f"{level['id']}/{wid}"
            for w in words:
                if not re.fullmatch(r"[a-z]{2,}", w):
                    errors.append(f"{tag}: '{w}' must be lowercase a-z, 2+ letters")
                if w not in pron:
                    errors.append(f"{tag}: '{w}' is not in pron_dict.txt")
                if w in seen:
                    errors.append(f"{tag}: '{w}' duplicates a word in {seen[w]}")
                seen.setdefault(w, tag)
            if not MIN_WORLD <= len(words) <= MAX_WORLD:
                errors.append(f"{tag}: {len(words)} words (want {MIN_WORLD}-{MAX_WORLD})")
            known = [w for w in words if w in pron]
            pairs, plain = confusable_pairs(known, pron)
            safe = greedy_safe_set(known, pairs)
            if safe < MIN_SAFE_SET:
                errors.append(f"{tag}: only {safe} mutually non-confusable words (need {MIN_SAFE_SET})")
            total_pairs += len(pairs)
            total_plain += plain
            print(f"  {wid:16s} {len(words):3d} words  {len(pairs):3d} confusable pairs"
                  f" ({plain} at plain distance <=1)  safe set {safe}")
            worlds_out.append({
                "id": f"{level['id'].lower()}-{wid}",
                "name": wname,
                "words": words,
                "confusable": pairs,
            })
        n = len(seen)
        total_words += n
        print(f"  total: {n} words in {len(worlds_out)} Worlds")
        doc = {
            "id": level["id"],
            "name": level["name"],
            "grade": level["grade"],
            "description": level["description"],
            "source": level["source"],
            "worlds": worlds_out,
        }
        outputs.append((level["file"], doc))
        index.append({"id": level["id"], "name": level["name"], "grade": level["grade"],
                      "file": level["file"], "worlds": len(worlds_out), "words": n})

    print(f"\nAll levels: {total_words} words, {total_pairs} confusable pairs "
          f"({total_plain} at plain phoneme distance <=1)")

    if errors:
        print(f"\nFAILED: {len(errors)} problem(s)")
        for e in errors:
            print("  " + e)
        sys.exit(1)

    print("All checks passed: lowercase, no 1-letter words, no in-level duplicates, "
          "every word in pron_dict.txt, World sizes OK, safe sets OK.")
    if check_only:
        return
    for fname, doc in outputs:
        with open(os.path.join(HERE, fname), "w", encoding="utf-8") as f:
            json.dump(doc, f, indent=1)
            f.write("\n")
    with open(os.path.join(HERE, "index.json"), "w", encoding="utf-8") as f:
        json.dump({"levels": index}, f, indent=1)
        f.write("\n")
    print(f"Wrote {len(outputs)} level files + index.json to {HERE}")


if __name__ == "__main__":
    main()
