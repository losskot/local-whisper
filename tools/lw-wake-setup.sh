#!/usr/bin/env bash
# Builds the wake-word daemon's Python environment.
#
# openWakeWord's default inference backend is tflite-runtime, which has NO macOS
# distribution at all ("No matching distribution found") — the failure looks like a
# broken install rather than an unsupported platform. onnxruntime is the backend that
# works here, so it is installed explicitly and lw-wake.py forces inference_framework
# ="onnx". Do not drop either half of that pairing.
#
# The venv lives beside the rest of the runtime state in the repo's gitignored state/:
# it is generated (~200 MB). `git clean -x` would delete it.
set -euo pipefail

STATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/state"
VENV="$STATE/wake-venv"

echo "==> creating venv at $VENV"
mkdir -p "$STATE"
python3 -m venv "$VENV"

echo "==> installing openwakeword + onnxruntime"
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet openwakeword onnxruntime

echo "==> downloading pretrained wake-word models (onnx)"
"$VENV/bin/python" - <<'PY'
import openwakeword.utils as u
u.download_models()
print("models downloaded")
PY

echo "==> verifying hey_mycroft loads on the onnx backend"
"$VENV/bin/python" - <<'PY'
import numpy as np
from openwakeword.model import Model
m = Model(wakeword_models=["hey_mycroft"], inference_framework="onnx")
m.predict(np.zeros(1280, dtype=np.int16))
print("OK — loaded:", list(m.models.keys()))
PY

echo
echo "done. Enable it from the local-whisper menu bar: Voice trigger."
