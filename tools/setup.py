#!/usr/bin/env python3
"""Fetch everything Hero Reader needs but does not check in.

All third-party code, binaries, models and data are pinned in
third_party/manifest.json (URL + version/commit + sha256) and downloaded
here, so the repository only holds our own work.

  python tools/setup.py                      # runtime + recommended models + godot-cpp
  python tools/setup.py --with dataset godot # also Speech Commands and the Godot editor
  python tools/setup.py --with models-eval   # every model from the evaluation
  python tools/setup.py --venv               # also create stt-eval/.venv with requirements
  python tools/setup.py --build              # also compile the WordListener GDExtension
  python tools/setup.py --platform android   # fetch the Android runtime libs
  python tools/setup.py --list               # show components and status

Uses only the Python standard library (3.9+), works on Windows/macOS/Linux.
Downloads are cached in third_party/.cache; re-running skips what's present.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import tarfile
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "third_party" / "manifest.json"
CACHE = ROOT / "third_party" / ".cache"


def host_platform() -> str:
    s = platform.system()
    if s == "Windows":
        return "windows-x64"
    if s == "Darwin":
        return "macos"
    return "linux-x64"


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def download(url: str, want_sha: str | None) -> Path:
    CACHE.mkdir(parents=True, exist_ok=True)
    out = CACHE / url.rsplit("/", 1)[1]
    if not out.exists():
        tmp = out.with_suffix(out.suffix + ".part")
        print(f"  downloading {url}")
        req = urllib.request.Request(url, headers={"User-Agent": "hero-reader-setup"})
        with urllib.request.urlopen(req) as r, open(tmp, "wb") as f:
            total = int(r.headers.get("Content-Length") or 0)
            done = 0
            while True:
                chunk = r.read(1 << 20)
                if not chunk:
                    break
                f.write(chunk)
                done += len(chunk)
                if total and sys.stdout.isatty():
                    print(f"\r    {done >> 20} / {total >> 20} MB", end="", flush=True)
        if total and sys.stdout.isatty():
            print()
        tmp.rename(out)
    got = sha256(out)
    if want_sha and got != want_sha:
        out.unlink()
        sys.exit(f"  checksum mismatch for {url}\n    expected {want_sha}\n    got      {got}")
    if not want_sha:
        print(f"  (unpinned) sha256 {got}  {out.name}  <- add to third_party/manifest.json")
    return out


def extract(archive: Path, dest: Path, strip: int) -> None:
    """Extract archive into dest, dropping `strip` leading path components."""
    dest.mkdir(parents=True, exist_ok=True)

    def target(name: str) -> Path | None:
        parts = Path(name).parts
        parts = parts[1:] if parts and parts[0] == "." else parts
        if len(parts) <= strip:
            return None
        rel = Path(*parts[strip:])
        out = (dest / rel).resolve()
        if not str(out).startswith(str(dest.resolve())):
            raise RuntimeError(f"unsafe path in archive: {name}")
        return out

    if archive.suffix == ".zip":
        with zipfile.ZipFile(archive) as z:
            for info in z.infolist():
                out = target(info.filename)
                if out is None or info.is_dir():
                    continue
                out.parent.mkdir(parents=True, exist_ok=True)
                with z.open(info) as src, open(out, "wb") as dst:
                    shutil.copyfileobj(src, dst)
                mode = info.external_attr >> 16
                if mode & 0o111:
                    out.chmod(out.stat().st_mode | 0o755)
    else:
        with tarfile.open(archive) as t:
            for m in t.getmembers():
                out = target(m.name)
                if out is None:
                    continue
                if m.isdir():
                    out.mkdir(parents=True, exist_ok=True)
                elif m.isfile():
                    out.parent.mkdir(parents=True, exist_ok=True)
                    with t.extractfile(m) as src, open(out, "wb") as dst:
                        shutil.copyfileobj(src, dst)
                    if m.mode & 0o111:
                        out.chmod(0o755)


def git_checkout(url: str, ref: str, commit: str, dest: Path) -> None:
    if (dest / ".git").exists():
        head = subprocess.run(["git", "-C", str(dest), "rev-parse", "HEAD"],
                              capture_output=True, text=True).stdout.strip()
        if head == commit:
            print(f"  have {dest.relative_to(ROOT)} @ {commit[:10]}")
            return
        shutil.rmtree(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "-c", "advice.detachedHead=false", "clone", "--quiet", "--depth", "1", "--branch", ref, url, str(dest)], check=True)
    head = subprocess.run(["git", "-C", str(dest), "rev-parse", "HEAD"],
                          capture_output=True, text=True).stdout.strip()
    if head != commit:
        sys.exit(f"  {url}@{ref} is {head}, expected pinned {commit}")


def make_pron_dict(src: Path) -> None:
    """cmudict.dict -> godot/data/pron_dict.txt (first pronunciation, no stress)."""
    import re

    out = ROOT / "godot" / "data" / "pron_dict.txt"
    seen = set()
    lines = ["# Generated by tools/setup.py from the CMU Pronouncing Dictionary "
             "(BSD-2-Clause, https://github.com/cmusphinx/cmudict). Do not commit."]
    for line in src.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        word, *ph = line.split()
        if "(" in word or word in seen or not re.fullmatch(r"[a-z']+", word):
            continue  # keep the first pronunciation of plain words only
        seen.add(word)
        lines.append(word + " " + " ".join(re.sub(r"\d", "", p) for p in ph))
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"  wrote {out.relative_to(ROOT)} ({len(seen)} words)")


def install_files(src_root: Path, mapping: dict) -> None:
    for rel, dst in mapping.items():
        d = ROOT / dst
        d.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src_root / rel, d / Path(rel).name)
        print(f"  installed {Path(rel).name} -> {dst}")


def fetch(name: str, comp: dict, plat: str) -> None:
    print(f"[{name}]")
    if comp["type"] == "git":
        git_checkout(comp["url"], comp["ref"], comp["commit"], ROOT / comp["dest"])
        return
    spec = comp
    if "platforms" in comp:
        if plat not in comp["platforms"]:
            print(f"  no {plat} build listed; skipping")
            return
        spec = {**comp, **comp["platforms"][plat]}
    dest = ROOT / spec["dest"].format(platform=plat)
    if spec["type"] == "file":
        f = download(spec["url"], spec.get("sha256"))
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(f, dest)
    else:
        marker = dest / f".fetched-{Path(spec['url']).name}"
        if marker.exists():
            print(f"  have {dest.relative_to(ROOT)}")
        else:
            f = download(spec["url"], spec.get("sha256"))
            print(f"  extracting into {dest.relative_to(ROOT)}")
            extract(f, dest, spec.get("strip", 0))
            marker.write_text(spec["url"] + "\n")
    if spec.get("install"):
        install_files(dest, spec["install"])
    if spec.get("post") == "pron_dict":
        make_pron_dict(dest)


def make_venv() -> None:
    venv = ROOT / "stt-eval" / ".venv"
    print("[venv]")
    if not venv.exists():
        subprocess.run([sys.executable, "-m", "venv", str(venv)], check=True)
    py = venv / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
    subprocess.run([str(py), "-m", "pip", "install", "-q", "-r", str(ROOT / "stt-eval" / "requirements.txt")],
                   check=True)
    print(f"  ready: {py}")


def build(plat: str) -> None:
    print("[build WordListener]")
    scons_plat = {"linux-x64": "linux", "windows-x64": "windows", "macos": "macos", "android": "android"}[plat]
    env = dict(os.environ,
               SHERPA_ONNX_DIR=str(ROOT / "third_party" / "sherpa-onnx" / plat),
               GODOT_CPP_DIR=str(ROOT / "third_party" / "godot-cpp"))
    venv_py = ROOT / "stt-eval" / ".venv" / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
    py = str(venv_py) if venv_py.exists() else sys.executable  # --venv installs scons there
    if subprocess.run([py, "-c", "import SCons"], capture_output=True).returncode != 0:
        sys.exit("  scons not found: run with --venv, or pip install scons")
    args = [py, "-m", "SCons", f"platform={scons_plat}", "target=template_debug"]
    if plat == "android":
        args.append("arch=arm64")
    try:
        subprocess.run(args, cwd=ROOT / "native" / "hero_listen", env=env, check=True)
    except subprocess.CalledProcessError:
        sys.exit("  build failed (see native/hero_listen/README.md; Windows needs an MSVC x64 prompt)")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--with", dest="extra", nargs="*", default=[], help="extra groups to fetch")
    ap.add_argument("--only", nargs="*", help="fetch only these groups")
    ap.add_argument("--platform", default=host_platform(),
                    choices=["linux-x64", "windows-x64", "macos", "android"])
    ap.add_argument("--venv", action="store_true", help="create stt-eval/.venv with requirements")
    ap.add_argument("--build", action="store_true", help="compile the GDExtension afterwards")
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()

    m = json.loads(MANIFEST.read_text())
    groups = args.only if args.only is not None else m["default_groups"] + args.extra
    if args.list:
        for g, desc in m["groups"].items():
            print(f"{g:12} {'*' if g in m['default_groups'] else ' '} {desc}")
            for n, c in m["components"].items():
                if c["group"] == g:
                    print(f"    {n:24} {c.get('license', '')}")
        return
    for name, comp in m["components"].items():
        if comp["group"] in groups:
            fetch(name, comp, args.platform)
    if args.venv:
        make_venv()
    if args.build:
        build(args.platform)
    print("\nDone. Next: see HANDOFF.md (run the dev menu: godot --path godot).")


if __name__ == "__main__":
    main()
