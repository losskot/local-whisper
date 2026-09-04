#!/usr/bin/env bash
# lw-wake-score.sh — score every pretrained wake word against your own voice.
#
# Which wake word suits a given voice is not something the code can decide, and it is not
# something you can tell by ear either: the model matches sound, and a word that feels close
# can score zero rather than "slightly too low". This records you saying the candidates and
# prints what the model actually made of each one.
#
# Deliberately does NOT transcribe what you said. A transcript is text -- whisper normalises
# whatever it hears into the nearest familiar word -- so it says nothing about the sounds you
# produced. The wake model's own score is the measurement.
#
# Usage: ./tools/lw-wake-score.sh [seconds]     (default 30)
#
# Say each candidate a few times, with a pause between them, then read the table.
set -euo pipefail

SECS="${1:-30}"
VENV="$HOME/.local-whisper/wake-venv"
REC="$HOME/.local-whisper/bin/lw-record"
RAW="$(mktemp -t lw-wake-score).raw"
MIC="$(cat "$HOME/.local-whisper/mic" 2>/dev/null || true)"

[ -x "$VENV/bin/python" ] || { echo "run tools/lw-wake-setup.sh first"; exit 1; }

trap 'rm -f "$RAW"' EXIT

echo "Recording ${SECS}s. Say each of: \"hey mycroft\", \"hey jarvis\", \"hey rhasspy\""
echo "a few times each, pausing between them."
echo
# shellcheck disable=SC2086
"$REC" - 0.08 16000 ${MIC:+"$MIC"} > "$RAW" 2>/dev/null &
REC_PID=$!
sleep "$SECS"
kill -INT "$REC_PID" 2>/dev/null || true
wait "$REC_PID" 2>/dev/null || true
echo "Scoring..."
echo

"$VENV/bin/python" - "$RAW" <<'PY'
import sys
import numpy as np
from openwakeword.model import Model

raw = open(sys.argv[1], "rb").read()
FRAME = 2560
print(f"{'word':<14}{'peak':>8}{'frames >=0.95':>16}   verdict")
print("-" * 58)
for word in ("hey_mycroft", "hey_jarvis", "hey_rhasspy"):
    model = Model(wakeword_models=[word], inference_framework="onnx")
    scores = []
    for i in range(0, len(raw) - FRAME, FRAME):
        frame = np.frombuffer(raw[i:i + FRAME], dtype=np.int16)
        scores.append(float(model.predict(frame).get(word, 0.0)))
    peak = max(scores) if scores else 0.0
    over = sum(1 for s in scores if s >= 0.95)
    # A single frame over the line is a coin flip in a real room; a solid detection holds
    # for several frames in a row.
    verdict = "solid" if over >= 5 else "marginal" if over >= 1 else "not recognised"
    print(f"{word.replace('_', ' '):<14}{peak:>8.3f}{over:>16}   {verdict}")
print()
print("Pick a 'solid' word. Switch it from the menu bar: Wake word.")
PY
