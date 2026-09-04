#!/bin/sh
# lw-wake-run.sh — runs capture -> wake-word detector as one unit that dies on one signal.
#
# hs.task:terminate() signals only the process Hammerspoon spawned, so a bare
# `sh -c "recorder | detector"` would leave both halves orphaned — and an orphaned recorder
# holds the microphone open, which is the one thing this feature must never do once the
# screen is off.
#
# One kill is enough for both: lw-record terminates itself when a stdout write fails
# (reader gone) and lw-wake exits on stdin EOF (writer gone), so signalling either end
# takes the other with it.
#
# Usage: lw-wake-run.sh <lw-record> <micUID|""> <python> <lw-wake.py> <log> <model> <threshold>
set -u

REC="$1"; MIC="$2"; PY="$3"; WAKE="$4"; LOG="$5"; MODEL="$6"; THRESH="$7"

if [ -n "$MIC" ]; then
    "$REC" - 0.08 16000 "$MIC" 2>>"$LOG" \
        | "$PY" "$WAKE" --log "$LOG" --model "$MODEL" --threshold "$THRESH" &
else
    "$REC" - 0.08 16000 2>>"$LOG" \
        | "$PY" "$WAKE" --log "$LOG" --model "$MODEL" --threshold "$THRESH" &
fi
CHILD=$!

trap 'kill $CHILD 2>/dev/null' TERM INT HUP
wait $CHILD
