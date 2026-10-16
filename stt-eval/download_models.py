"""Download the speech models (and optionally the test dataset).

  python download_models.py                 # recommended models only
  python download_models.py --all           # every model in the evaluation
  python download_models.py --speech-commands   # + 2.3 GB test dataset

Models come from the sherpa-onnx GitHub releases; the dataset is Google
Speech Commands v0.02 (CC-BY 4.0).
"""

from __future__ import annotations

import argparse
import shutil
import tarfile
import urllib.request
from pathlib import Path

HERE = Path(__file__).parent
REL = "https://github.com/k2-fsa/sherpa-onnx/releases/download"

RECOMMENDED = [
    "asr-models/sherpa-onnx-streaming-zipformer-en-2023-06-26.tar.bz2",
    "asr-models/sherpa-onnx-nemo-parakeet_tdt_transducer_110m-en-36000-int8.tar.bz2",
    "asr-models/sherpa-onnx-moonshine-tiny-en-quantized-2026-02-27.tar.bz2",
    "asr-models/silero_vad.onnx",
]
EXTRA = [
    "asr-models/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17.tar.bz2",
    "asr-models/sherpa-onnx-streaming-zipformer-en-kroko-2025-08-06.tar.bz2",
    "asr-models/sherpa-onnx-nemo-streaming-fast-conformer-transducer-en-80ms-int8.tar.bz2",
    "kws-models/sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01.tar.bz2",
    "asr-models/sherpa-onnx-whisper-tiny.en.tar.bz2",
    "asr-models/sherpa-onnx-whisper-base.en.tar.bz2",
    "asr-models/sherpa-onnx-moonshine-tiny-en-int8.tar.bz2",
    "asr-models/sherpa-onnx-moonshine-base-en-int8.tar.bz2",
    "asr-models/sherpa-onnx-moonshine-base-en-quantized-2026-02-27.tar.bz2",
    "asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2",
]
SPEECH_COMMANDS = "https://storage.googleapis.com/download.tensorflow.org/data/speech_commands_v0.02.tar.gz"


def fetch(url: str, dest_dir: Path) -> None:
    name = url.rsplit("/", 1)[1]
    stem = name.removesuffix(".tar.bz2").removesuffix(".tar.gz")
    if (dest_dir / stem).exists() or (dest_dir / name).exists() and not name.endswith(("bz2", "gz")):
        print(f"have {stem}")
        return
    dest_dir.mkdir(parents=True, exist_ok=True)
    tmp = dest_dir / (name + ".part")
    print(f"downloading {url}")
    with urllib.request.urlopen(url) as r, open(tmp, "wb") as f:
        shutil.copyfileobj(r, f)
    if name.endswith((".tar.bz2", ".tar.gz")):
        target = dest_dir if name.endswith(".bz2") else dest_dir / stem
        with tarfile.open(tmp) as t:
            t.extractall(target, filter="data")
        tmp.unlink()
    else:
        tmp.rename(dest_dir / name)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--speech-commands", action="store_true")
    ap.add_argument("--models-dir", default=str(HERE / "models"))
    args = ap.parse_args()
    for rel in RECOMMENDED + (EXTRA if args.all else []):
        fetch(f"{REL}/{rel}", Path(args.models_dir))
    if args.speech_commands:
        fetch(SPEECH_COMMANDS, HERE / "data")
        src = HERE / "data" / "speech_commands_v0.02"
        if src.exists():
            src.rename(HERE / "data" / "speech_commands")


if __name__ == "__main__":
    main()
