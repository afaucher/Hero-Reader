#!/usr/bin/env python3
"""Collect calibration recordings from Godot and benchmark them, losing nothing.

The in-game recorder (dev menu > Record voices) saves takes under Godot's
user data folder. This script:

1. Copies every session into stt-eval/recordings/<speaker>/<session>/ (git-ignored).
   It is safe to run any number of times, even while a session is still being
   recorded:
   - new files are copied, identical files are skipped;
   - a file that changed (a redone take) or that the recorder deleted (R = redo)
     is moved to stt-eval/recordings-trash/ with a timestamp, never overwritten
     or removed;
   - the source is never modified.
2. Checks each session: takes per round, levels (peak dBFS), exact-zero samples
   (mic gain too low), clipping, and manifest rows vs files on disk.
3. With --bench, benchmarks every new or changed session, and each speaker's
   sessions combined, with both finalist presets, normal and --hard. Each run
   gets its own folder:
       stt-eval/results/calib/<speaker>/<session or _all>/<run time>/<engine>[-hard]/
   One row per run is appended to stt-eval/results/calib/runs.csv. Older runs
   are kept, so results from different days can be compared.

  python tools/collect_recordings.py                # copy + check
  python tools/collect_recordings.py --bench        # ... and benchmark what changed
  python tools/collect_recordings.py --bench --all  # re-benchmark everything
  python tools/collect_recordings.py --bench --jobs 4  # faster (latency columns get noisier)
  python tools/collect_recordings.py --exclude 8f/20261016-134952 "labels shifted by one"
  python tools/collect_recordings.py --report       # latest results per speaker, excluded sessions left out

A session whose labels can't be trusted (the reader went off script, the
recorder mis-triggered) is listed in stt-eval/recordings/excluded.csv: it is
still copied and kept, but never benchmarked, and --report hides its rows.

Uses only the standard library; benchmarks run with stt-eval/.venv.
Recordings of family members must never be committed (see CLAUDE.md).
"""

from __future__ import annotations

import argparse
import array
import csv
import hashlib
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
import time
import wave
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EVAL = ROOT / "stt-eval"
DST = EVAL / "recordings"
TRASH = EVAL / "recordings-trash"
STAGE = EVAL / "recordings-stage"  # combined per-speaker sets during a run (git-ignored)
RESULTS = EVAL / "results" / "calib"
RUNS_CSV = RESULTS / "runs.csv"
EXCLUDED = DST / "excluded.csv"

# Same settings as the game presets (docs/stt-evaluation.md, "Final configurations").
PRESETS = {
    "parakeet-110m-hot": ["--hot-score", "1.5"],
    "zipformer-hot": ["--hot-score", "3"],
}
COMMON = ["--beam", "8", "--sound-alike", "--trials", "400", "--onscreen", "5"]
RUN_FIELDS = ["run_time", "git_commit", "speaker", "scope", "n_word_clips", "n_other_clips",
              "manifest_sha", "engine", "hard", "hit_pct", "wrong_word_pct", "no_fire_pct",
              "false_accept_pct", "latency_p50_ms", "latency_p90_ms", "double_fire_pct",
              "rtf", "out_dir"]


def godot_recordings() -> Path:
    if sys.platform == "win32":
        base = Path(os.environ["APPDATA"]) / "Godot"
    elif sys.platform == "darwin":
        base = Path.home() / "Library" / "Application Support" / "Godot"
    else:
        base = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share")) / "godot"
    return base / "app_userdata" / "Hero Reader" / "recordings"


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def stamp() -> str:
    return time.strftime("%Y%m%d-%H%M%S")


# --- 1. copy ---------------------------------------------------------------

def deleted_in_manifest(manifest: Path) -> set[str]:
    if not manifest.exists():
        return set()
    with manifest.open(encoding="utf-8", newline="") as f:
        return {r["file"] for r in csv.DictReader(f) if r.get("kind") == "deleted"}


def to_trash(path: Path, speaker: str, session: str, why: str) -> Path:
    dest = TRASH / speaker / session / f"{path.stem}.{why}-{stamp()}{path.suffix}"
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(path), dest)
    return dest


def collect_session(src: Path, speaker: str, session: str) -> dict:
    dst = DST / speaker / session
    dst.mkdir(parents=True, exist_ok=True)
    n = dict(new=0, same=0, replaced=0, trashed=0)
    src_files = {p.name: p for p in src.iterdir() if p.is_file()}
    for name, p in sorted(src_files.items()):
        d = dst / name
        if not d.exists():
            shutil.copy2(p, d)
            n["new"] += 1
        elif sha(p) == sha(d):
            n["same"] += 1
        elif p.suffix == ".wav":
            # A redone take reused the name: keep the old audio in the trash.
            to_trash(d, speaker, session, "replaced")
            shutil.copy2(p, d)
            n["replaced"] += 1
        else:
            # manifest.csv / session.json: the recorder only appends, so the
            # source is the newer, longer version.
            if d.stat().st_size > p.stat().st_size:
                print(f"  ! {speaker}/{session}/{name}: copy here is larger than the source; kept both")
                to_trash(d, speaker, session, "larger")
            shutil.copy2(p, d)
    # Takes the recorder deleted (R = redo) leave the benchmark set, into the trash.
    for name in deleted_in_manifest(src / "manifest.csv"):
        d = dst / name
        if d.exists() and name not in src_files:
            to_trash(d, speaker, session, "redo")
            n["trashed"] += 1
    for d in dst.glob("*.wav"):
        if d.name not in src_files:
            print(f"  ! {speaker}/{session}/{d.name}: not in the Godot folder any more; kept")
    return n


# --- 2. check --------------------------------------------------------------

def wav_stats(path: Path) -> tuple[float, float, int, float]:
    """(peak, fraction of exact-zero samples, clipped samples, seconds)."""
    with wave.open(str(path)) as w:
        if w.getsampwidth() != 2:
            return 0.0, 0.0, 0, 0.0
        a = array.array("h", w.readframes(w.getnframes()))
        sr = w.getframerate()
    if not a:
        return 0.0, 1.0, 0, 0.0
    peak = max(max(a), -min(a)) / 32768.0
    zeros = a.count(0) / len(a)
    clipped = sum(1 for x in a if x >= 32766 or x <= -32767)
    return peak, zeros, clipped, len(a) / sr


def check_session(dst: Path) -> dict:
    rows = []
    if (dst / "manifest.csv").exists():
        with (dst / "manifest.csv").open(encoding="utf-8", newline="") as f:
            rows = list(csv.DictReader(f))
    deleted = {r["file"] for r in rows if r.get("kind") == "deleted"}
    # Replay the manifest in order: a redo deletes a take and may reuse its file
    # name, so the last row for a name describes the file on disk.
    by_file: dict[str, dict] = {}
    for r in rows:
        if r.get("kind") == "deleted":
            by_file.pop(r["file"], None)
        elif r.get("kind") in ("word", "other"):
            by_file[r["file"]] = r
    live = list(by_file.values())
    missing = [f for f in by_file if not (dst / f).exists() and f not in deleted]
    wavs = sorted(dst.glob("*.wav"))
    unlisted = [p.name for p in wavs if p.name not in by_file]
    peaks, zeros, clipped_takes, quiet = [], [], [], []
    for p in wavs:
        pk, z, c, _ = wav_stats(p)
        peaks.append(pk)
        zeros.append(z)
        if c:
            clipped_takes.append(p.name)
        if pk < 0.03:
            quiet.append(p.name)
    rounds = sorted({r["round"] for r in live if r.get("round")})
    med = sorted(peaks)[len(peaks) // 2] if peaks else 0.0
    q = dict(
        words=sum(1 for r in by_file.values() if r["kind"] == "word"),
        others=sum(1 for r in by_file.values() if r["kind"] == "other"),
        rounds=len(rounds),
        redos=len(deleted),
        peak_dbfs_median=round(20 * math.log10(med), 1) if med > 0 else None,
        zero_pct=round(100 * sum(zeros) / len(zeros), 1) if zeros else None,
        clipped_takes=len(clipped_takes),
        quiet_takes=len(quiet),
        missing_files=missing,
        unlisted_files=unlisted,
    )
    warn = []
    if q["zero_pct"] and q["zero_pct"] > 20:
        warn.append(f"{q['zero_pct']}% exact-zero samples: mic gain far too low")
    if q["peak_dbfs_median"] is not None and q["peak_dbfs_median"] < -30:
        warn.append(f"median peak {q['peak_dbfs_median']} dBFS: quiet, raise gain or move closer")
    if clipped_takes:
        warn.append(f"{len(clipped_takes)} clipped takes: lower gain a little")
    if missing:
        warn.append(f"{len(missing)} manifest rows without a file")
    if unlisted:
        warn.append(f"{len(unlisted)} files not in the manifest")
    q["warnings"] = warn
    return q


# --- exclusions --------------------------------------------------------------

def excluded() -> dict[str, str]:
    """speaker/session -> reason."""
    if not EXCLUDED.exists():
        return {}
    with EXCLUDED.open(encoding="utf-8", newline="") as f:
        return {r["session"]: r["reason"] for r in csv.DictReader(f)}


def add_exclusion(session: str, reason: str) -> None:
    if not (DST / session).is_dir():
        sys.exit(f"no session {DST / session}")
    new = not EXCLUDED.exists()
    with EXCLUDED.open("a", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        if new:
            w.writerow(["session", "reason", "excluded_on"])
        w.writerow([session, reason, time.strftime("%Y-%m-%d")])
    print(f"excluded {session}: {reason}")


# --- 3. benchmark ------------------------------------------------------------

def manifest_sha(dirs: list[Path]) -> str:
    h = hashlib.sha256()
    for d in sorted(dirs):
        m = d / "manifest.csv"
        if m.exists():
            h.update(m.read_bytes())
    return h.hexdigest()[:16]


def already_benchmarked() -> set[tuple[str, str, str]]:
    if not RUNS_CSV.exists():
        return set()
    with RUNS_CSV.open(encoding="utf-8", newline="") as f:
        return {(r["speaker"], r["scope"], r["manifest_sha"]) for r in csv.DictReader(f)}


def venv_python() -> str:
    for p in (EVAL / ".venv" / "Scripts" / "python.exe", EVAL / ".venv" / "bin" / "python"):
        if p.exists():
            return str(p)
    sys.exit("stt-eval/.venv not found: run python tools/setup.py --venv")


def git_commit() -> str:
    try:
        return subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--short", "HEAD"],
                              capture_output=True, text=True).stdout.strip()
    except OSError:
        return ""


def bench_one(job: dict) -> list[dict]:
    out = job["out"]
    out.mkdir(parents=True, exist_ok=False)  # a fresh folder per run: nothing is overwritten
    (out / "sessions.txt").write_text("\n".join(job["sessions"]) + "\n", encoding="utf-8")
    cmd = [venv_python(), "benchmark.py", "--recordings", str(job["recordings"]),
           "--engines", job["engine"], *PRESETS[job["engine"]], *COMMON, "--out", str(out)]
    if job["hard"]:
        cmd.append("--hard")
    r = subprocess.run(cmd, cwd=EVAL, capture_output=True, text=True)
    log = (r.stdout + r.stderr).replace(str(ROOT) + os.sep, "").replace(str(ROOT), ".")
    (out / "log.txt").write_text(log, encoding="utf-8")
    if r.returncode != 0:
        print(f"  ! benchmark failed ({job['speaker']}/{job['scope']} {job['engine']}): see {out / 'log.txt'}")
        return []
    rows = []
    for sj in sorted(out.glob("summary-*.json")):
        for s in json.loads(sj.read_text())["summary"]:
            rows.append({
                "run_time": job["run_time"], "git_commit": job["commit"],
                "speaker": job["speaker"], "scope": job["scope"],
                "n_word_clips": job["n_words"], "n_other_clips": job["n_others"],
                "manifest_sha": job["sha"], "engine": s["engine"], "hard": int(job["hard"]),
                **{k: round(s[k], 1) if isinstance(s[k], float) else s[k] for k in
                   ["hit_pct", "wrong_word_pct", "no_fire_pct", "false_accept_pct",
                    "latency_p50_ms", "latency_p90_ms", "double_fire_pct"]},
                "rtf": round(s["rtf"], 3),
                "out_dir": str(out.relative_to(EVAL)).replace("\\", "/"),
            })
    return rows


def append_runs(rows: list[dict]) -> None:
    RUNS_CSV.parent.mkdir(parents=True, exist_ok=True)
    new = not RUNS_CSV.exists()
    with RUNS_CSV.open("a", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=RUN_FIELDS)
        if new:
            w.writeheader()
        w.writerows(rows)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--src", type=Path, default=godot_recordings(), help="Godot recordings folder")
    ap.add_argument("--bench", action="store_true", help="benchmark new or changed sessions")
    ap.add_argument("--all", action="store_true", help="with --bench: re-run everything")
    ap.add_argument("--speaker", nargs="+", help="only these speakers (e.g. 8f 6f)")
    ap.add_argument("--jobs", type=int, default=1,
                    help="benchmarks at once (default 1: parallel runs inflate the latency columns)")
    ap.add_argument("--exclude", nargs=2, metavar=("SPEAKER/SESSION", "REASON"),
                    help="never benchmark this session (it stays on disk)")
    ap.add_argument("--report", action="store_true", help="latest results per speaker and scope")
    args = ap.parse_args()

    if args.exclude:
        add_exclusion(args.exclude[0], args.exclude[1])
        return
    if args.report:
        report()
        return

    if not args.src.exists():
        sys.exit(f"no recordings at {args.src}")
    print(f"from {args.src}\n  to {DST}\n")
    sessions = []  # (speaker, session, dst dir, quality)
    for spk_dir in sorted(p for p in args.src.iterdir() if p.is_dir()):
        if args.speaker and spk_dir.name not in args.speaker:
            continue
        for ses_dir in sorted(p for p in spk_dir.iterdir() if p.is_dir()):
            n = collect_session(ses_dir, spk_dir.name, ses_dir.name)
            dst = DST / spk_dir.name / ses_dir.name
            q = check_session(dst)
            sessions.append((spk_dir.name, ses_dir.name, dst, q))
            print(f"{spk_dir.name:>6}/{ses_dir.name}  {q['words']:3d} words  {q['others']:2d} other  "
                  f"rounds {q['rounds']}  redos {q['redos']}  peak {q['peak_dbfs_median']} dBFS  "
                  f"zeros {q['zero_pct']}%  clipped {q['clipped_takes']}  "
                  f"[copied {n['new']}, unchanged {n['same']}, replaced {n['replaced']}, to trash {n['trashed']}]")
            for wmsg in q["warnings"]:
                print(f"        ! {wmsg}")
            why = excluded().get(f"{spk_dir.name}/{ses_dir.name}")
            if why:
                print(f"        (excluded from benchmarks: {why})")
    if not args.bench:
        print("\nCopied and checked. Add --bench to benchmark.")
        return

    run_time = stamp()
    commit = git_commit()
    done = set() if args.all else already_benchmarked()
    jobs = []
    by_speaker: dict[str, list] = {}
    for spk, ses, dst, q in sessions:
        by_speaker.setdefault(spk, []).append((ses, dst, q))
    skip = excluded()
    # Combined sets are staged inside the repo (git-ignored), so result paths stay repo-relative.
    STAGE.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix="run-", dir=STAGE))
    for spk, items in by_speaker.items():
        items = [it for it in items if f"{spk}/{it[0]}" not in skip and it[2]["words"] >= 12]
        scopes = [(ses, dst, [dst], q["words"], q["others"]) for ses, dst, q in items]
        if len(items) > 1:  # every usable session of this speaker together
            combined = stage / spk
            for ses, dst, _ in items:
                shutil.copytree(dst, combined / ses)
            scopes.append(("_all", combined, [d for _, d, _ in items],
                           sum(q["words"] for *_, q in items), sum(q["others"] for *_, q in items)))
        for scope, rec_dir, dirs, n_words, n_others in scopes:
            msha = manifest_sha(dirs)
            if (spk, scope, msha) in done:
                continue
            for engine in PRESETS:
                for hard in (False, True):
                    jobs.append(dict(speaker=spk, scope=scope, recordings=rec_dir, engine=engine, hard=hard,
                                     sessions=[f"{spk}/{d.name}" for d in dirs],
                                     sha=msha, n_words=n_words, n_others=n_others, run_time=run_time,
                                     commit=commit,
                                     out=RESULTS / spk / scope / run_time / (engine + ("-hard" if hard else ""))))
    if not jobs:
        shutil.rmtree(stage, ignore_errors=True)
        print("\nNothing new to benchmark (use --all to re-run).")
        return
    print(f"\n{len(jobs)} benchmark runs, {args.jobs} at a time...")
    try:
        with ThreadPoolExecutor(max_workers=args.jobs) as ex:
            results = list(ex.map(bench_one, jobs))
    finally:
        shutil.rmtree(stage, ignore_errors=True)
    rows = [r for rs in results for r in rs]
    append_runs(rows)
    print(f"\n{'speaker':>7} {'scope':>16} {'engine':>18} hard   hit  wrong   FA  p50/p90 ms   2x")
    for r in rows:
        print(f"{r['speaker']:>7} {r['scope']:>16} {r['engine']:>18} {r['hard']:>4} {r['hit_pct']:5.1f} "
              f"{r['wrong_word_pct']:6.1f} {r['false_accept_pct']:4.1f}  {r['latency_p50_ms']:4.0f}/"
              f"{r['latency_p90_ms']:<4.0f}  {r['double_fire_pct']:4.1f}")
    print(f"\nAppended {len(rows)} rows to {RUNS_CSV.relative_to(ROOT)}")


def report() -> None:
    if not RUNS_CSV.exists():
        sys.exit("no runs yet: python tools/collect_recordings.py --bench")
    skip = excluded()
    with RUNS_CSV.open(encoding="utf-8", newline="") as f:
        rows = list(csv.DictReader(f))
    latest: dict[tuple, dict] = {}
    for r in rows:  # runs.csv is in time order, so the last row per key wins
        if f"{r['speaker']}/{r['scope']}" in skip:
            continue
        sessions_file = EVAL / r["out_dir"] / "sessions.txt"
        listed = sessions_file.read_text().split() if sessions_file.exists() else []
        if r["scope"] == "_all" and (not listed or any(s in skip for s in listed)):
            continue  # a combined run that included a session excluded later
        latest[(r["speaker"], r["scope"], r["engine"], r["hard"])] = r
    print(f"{'speaker':>7} {'scope':>16} {'engine':>18} hard  words   hit  wrong    FA  p50/p90 ms    2x  run")
    for k in sorted(latest):
        r = latest[k]
        print(f"{r['speaker']:>7} {r['scope']:>16} {r['engine']:>18} {r['hard']:>4} {r['n_word_clips']:>6} "
              f"{float(r['hit_pct']):5.1f} {float(r['wrong_word_pct']):6.1f} {float(r['false_accept_pct']):5.1f}  "
              f"{float(r['latency_p50_ms']):4.0f}/{float(r['latency_p90_ms']):<4.0f}  "
              f"{float(r['double_fire_pct']):4.1f}  {r['run_time']}")
    if skip:
        print("\nexcluded: " + "; ".join(f"{k} ({v})" for k, v in skip.items()))


if __name__ == "__main__":
    main()
