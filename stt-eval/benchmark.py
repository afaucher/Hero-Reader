"""Closed-set word-reading benchmark: accuracy + end-of-speech latency.

Each trial mimics one moment of gameplay:

  * N words are "on screen" (the target plus N-1 distractors);
  * the engine hears 0.4 s of room tone, one spoken word, then 1.2 s of room
    tone, delivered in 20 ms chunks like a game's mic buffer;
  * we record which on-screen word (if any) the engine fires on, and when.

Negative trials play a word that is NOT on screen; the right outcome there is
to fire on nothing (that's the "child says a different word" / chatter case).

Latency is simulated in real time: chunk i arrives at its audio timestamp,
starts processing when both it has arrived and chunk i-1 is finished, and an
event's time is when its chunk finished processing. Reported latency is that
time minus the end of the spoken word (negative = fired before the child
finished the word, which streaming models can do).

Usage:
  python benchmark.py --engines zipformer whisper-tiny.en --trials 300
  python benchmark.py --recordings recordings/ --engines zipformer-hot
"""

from __future__ import annotations

import argparse
import csv
import json
import random
import statistics
import sys
import time
from pathlib import Path

import numpy as np

import dataset as ds
import matcher
from engines import ENGINES, MODELS_DIR, SAMPLE_RATE, make_engine

CHUNK = int(0.02 * SAMPLE_RATE)
LEAD_S, TRAIL_S = 0.4, 1.2


def build_stream(clip_audio, cond, noises, rng):
    x = clip_audio
    if cond.get("child"):
        x = ds.child_proxy(x)
    s0, s1 = ds.speech_bounds(x)
    # Trim the clip's own silence so every trial has the same lead/trail.
    pad = 0.05
    a, b = max(0, int((s0 - pad) * SAMPLE_RATE)), min(len(x), int((s1 + pad) * SAMPLE_RATE))
    word = x[a:b]
    peak = np.abs(word).max() + 1e-9
    word = word * (0.5 / peak)  # normalise level, like an AGC'd mic
    lead = np.zeros(int(LEAD_S * SAMPLE_RATE), np.float32)
    trail = np.zeros(int(TRAIL_S * SAMPLE_RATE), np.float32)
    audio = np.concatenate([lead, word, trail]).astype(np.float32)
    speech_start = LEAD_S + (s0 - a / SAMPLE_RATE)
    speech_end = LEAD_S + (s1 - a / SAMPLE_RATE)
    if cond.get("snr") is not None and noises:
        audio = ds.mix_noise(audio, rng.choice(noises), cond["snr"], rng)
    else:  # faint room tone so VADs/endpointers see realistic input
        audio = audio + np.float32(1e-3) * np.asarray(
            np.random.default_rng(rng.randrange(1 << 30)).standard_normal(len(audio)), np.float32)
    return audio, speech_start, speech_end


def run_trial(engine, audio, onscreen):
    sess = engine.session(onscreen)
    done_at = 0.0
    compute = 0.0
    first = None
    texts = []
    n = len(audio)
    for i in range(0, n + CHUNK, CHUNK):
        chunk = audio[i : i + CHUNK]
        arrive = min(i + CHUNK, n) / SAMPLE_RATE
        t0 = time.perf_counter()
        evs = sess.feed(chunk) if len(chunk) else sess.flush()
        dt = time.perf_counter() - t0
        compute += dt
        done_at = max(done_at, arrive) + dt
        for ev in evs:
            texts.append(ev.text)
            if first is None and ev.match is not None:
                first = (ev, done_at)
        if not len(chunk):
            break
    return first, texts, compute


CONDITIONS = {
    "clean": {},
    "noise10": {"snr": 10},
    "child": {"child": True},
}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--engines", nargs="+", default=["zipformer"], help=f"any of: {' '.join(ENGINES)}")
    ap.add_argument("--speech-commands", default="data/speech_commands")
    ap.add_argument("--recordings", help="folder from record_words.py (overrides Speech Commands)")
    ap.add_argument("--conditions", nargs="+", default=["clean"], choices=list(CONDITIONS))
    ap.add_argument("--trials", type=int, default=200, help="positive trials per condition")
    ap.add_argument("--negatives", type=float, default=0.25, help="extra negative trials, as a fraction")
    ap.add_argument("--onscreen", type=int, default=5, help="words on screen per trial")
    ap.add_argument("--hard", action="store_true", help="pick sound-alike / look-alike distractors")
    ap.add_argument("--threads", type=int, default=2)
    ap.add_argument("--silence", type=float, default=0.25, help="VAD hang-over for offline models (s)")
    ap.add_argument("--trailing", type=float, default=0.3, help="endpoint silence for streaming models (s)")
    ap.add_argument("--hot-score", type=float, default=2.0, help="hotword boost (\"-hot\" engines)")
    ap.add_argument("--beam", type=int, default=4, help="beam width (\"-hot\" engines)")
    ap.add_argument("--sound-alike", action="store_true",
                    help="also accept on-screen words within one phoneme (game default)")
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--out", default="results")
    args = ap.parse_args()

    matcher.SOUND_ALIKE = args.sound_alike
    root = Path(args.speech_commands)
    clips = ds.recordings(Path(args.recordings)) if args.recordings else ds.speech_commands(root)
    noises = ds.background_noise(root)
    # "_other" recordings (um, coughs, "what's that word") are never on screen:
    # they're only used as negative trials, where nothing should fire.
    other_clips = [c for c in clips if c.word.startswith("_")]
    clips = [c for c in clips if not c.word.startswith("_")]
    vocab = sorted({c.word for c in clips})
    if len(vocab) < args.onscreen + 1:
        sys.exit(f"need at least {args.onscreen + 1} distinct words, found {vocab}")
    print(f"{len(clips)} clips, {len(vocab)} words, models in {MODELS_DIR}", file=sys.stderr)

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    tag = time.strftime("%Y%m%d-%H%M%S")
    rows, summary = [], []

    for name in args.engines:
        t_load = time.perf_counter()
        eng = make_engine(name, threads=args.threads, silence=args.silence, trailing=args.trailing,
                          hot_score=args.hot_score, beam=args.beam)
        t_load = time.perf_counter() - t_load
        for cname in args.conditions:
            cond = CONDITIONS[cname]
            rng = random.Random(args.seed)  # same trials for every engine
            n_neg = int(args.trials * args.negatives)
            plan = [(True, c) for c in rng.sample(clips, min(args.trials, len(clips)))]
            plan += [(False, c) for c in rng.sample(clips, min(n_neg, len(clips)))]
            plan += [(False, c) for c in other_clips]
            stats = dict(hit=0, wrong=0, none=0, pos=0, neg=0, false_accept=0)
            lats, audio_s, compute_s = [], 0.0, 0.0
            for k, (positive, clip) in enumerate(plan):
                try:
                    audio, s_start, s_end = build_stream(ds.load_wav(clip.path), cond, noises, rng)
                except ValueError:  # silent clip in the dataset; skip it
                    continue
                if positive:
                    others = ds.distractors(clip.word, vocab, args.onscreen - 1, args.hard, rng)
                    onscreen = others + [clip.word]
                else:
                    onscreen = rng.sample([w for w in vocab if w != clip.word], args.onscreen)
                rng.shuffle(onscreen)
                first, texts, compute = run_trial(eng, audio, onscreen)
                audio_s += len(audio) / SAMPLE_RATE
                compute_s += compute
                fired = first[0].match.word if first else None
                lat = (first[1] - s_end) if first else None
                if positive:
                    stats["pos"] += 1
                    if fired == clip.word:
                        stats["hit"] += 1
                        lats.append(lat)
                        outcome = "hit"
                    elif fired:
                        stats["wrong"] += 1
                        outcome = "wrong"
                    else:
                        stats["none"] += 1
                        outcome = "none"
                else:
                    stats["neg"] += 1
                    outcome = "false_accept" if fired else "rejected"
                    stats["false_accept"] += bool(fired)
                rows.append(dict(engine=name, condition=cname, positive=positive, word=clip.word,
                                 speaker=clip.speaker, onscreen=" ".join(onscreen), fired=fired or "",
                                 outcome=outcome, latency_ms=None if lat is None else round(lat * 1000),
                                 speech_ms=round((s_end - s_start) * 1000),
                                 text=" | ".join(texts), file=str(clip.path)))
                if (k + 1) % 50 == 0:
                    print(f"  {name}/{cname}: {k + 1}/{len(plan)}", file=sys.stderr)
            pos = max(stats["pos"], 1)
            lat_ms = sorted(l * 1000 for l in lats)
            s = dict(
                engine=name, condition=cname, trials=stats["pos"], negatives=stats["neg"],
                hit_pct=100 * stats["hit"] / pos, wrong_word_pct=100 * stats["wrong"] / pos,
                no_fire_pct=100 * stats["none"] / pos,
                false_accept_pct=100 * stats["false_accept"] / max(stats["neg"], 1),
                latency_p50_ms=statistics.median(lat_ms) if lat_ms else None,
                latency_p90_ms=float(np.percentile(lat_ms, 90)) if lat_ms else None,
                early_fire_pct=100 * sum(l < 0 for l in lat_ms) / max(len(lat_ms), 1),
                rtf=compute_s / audio_s, load_s=t_load,
            )
            summary.append(s)
            print(fmt_row(s), file=sys.stderr)

    with open(out / f"trials-{tag}.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)
    (out / f"summary-{tag}.json").write_text(json.dumps(dict(args=vars(args), summary=summary), indent=2))
    table = markdown(summary, args)
    (out / f"summary-{tag}.md").write_text(table)
    print(table)


def fmt_row(s):
    lat = "-" if s["latency_p50_ms"] is None else f"{s['latency_p50_ms']:.0f}/{s['latency_p90_ms']:.0f}ms"
    return (f"{s['engine']:>16} {s['condition']:>8} hit {s['hit_pct']:5.1f}% wrong {s['wrong_word_pct']:4.1f}% "
            f"none {s['no_fire_pct']:4.1f}% FA {s['false_accept_pct']:4.1f}% lat p50/p90 {lat} RTF {s['rtf']:.3f}")


def markdown(summary, args):
    hdr = ("| engine | cond | hit % | wrong word % | no fire % | false accept % | "
           "latency p50 | latency p90 | fired before word end % | RTF |\n"
           "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|\n")
    body = ""
    for s in summary:
        p50 = "-" if s["latency_p50_ms"] is None else f"{s['latency_p50_ms']:.0f} ms"
        p90 = "-" if s["latency_p90_ms"] is None else f"{s['latency_p90_ms']:.0f} ms"
        body += (f"| {s['engine']} | {s['condition']} | {s['hit_pct']:.1f} | {s['wrong_word_pct']:.1f} | "
                 f"{s['no_fire_pct']:.1f} | {s['false_accept_pct']:.1f} | {p50} | {p90} | "
                 f"{s['early_fire_pct']:.0f} | {s['rtf']:.3f} |\n")
    note = (f"\n{args.trials} positive trials per row, {args.onscreen} words on screen"
            f"{' (hard distractors)' if args.hard else ''}, {args.threads} threads, "
            f"VAD hang-over {args.silence}s, streaming endpoint {args.trailing}s, "
            f"hotword score {args.hot_score}, beam {args.beam}"
            f"{', sound-alike matching' if args.sound_alike else ''}.\n")
    return hdr + body + note


if __name__ == "__main__":
    main()
