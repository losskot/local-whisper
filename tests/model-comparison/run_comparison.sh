#!/usr/bin/env bash
# Runs whisper-cli for each session × each model, writes results to results/raw/.
# Usage: ./run_comparison.sh
# Reads tmp/segments.json (produced by build_segments.py).

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
WHISPER="$HOME/whisper.cpp/build/bin/whisper-cli"
MODELS=(
    "$HOME/whisper.cpp/models/ggml-large-v3-turbo-q5_0.bin"
    "$HOME/whisper.cpp/models/ggml-large-v3.bin"
)
MODEL_NAMES=("large-v3-turbo-q5_0" "large-v3")
SEGMENTS_JSON="$DIR/tmp/segments.json"
RAW_DIR="$DIR/results/raw"

mkdir -p "$RAW_DIR"

# Verify models exist
for m in "${MODELS[@]}"; do
    if [ ! -f "$m" ]; then
        echo "ERROR: model not found: $m"
        exit 1
    fi
done

sessions=$(python3 -c "import json; d=json.load(open('$SEGMENTS_JSON')); print('\n'.join(d.keys()))")

for session in $sessions; do
    seg_list=$(python3 -c "
import json
d=json.load(open('$SEGMENTS_JSON'))
for s in d.get('$session', []):
    print(s)
")
    if [ -z "$seg_list" ]; then
        echo "[$session] no segments, skipping"
        continue
    fi

    for model_idx in 0 1; do
        model="${MODELS[$model_idx]}"
        model_name="${MODEL_NAMES[$model_idx]}"
        out_file="$RAW_DIR/${session}__${model_name}.txt"
        time_file="$RAW_DIR/${session}__${model_name}.time"

        if [ -f "$out_file" ]; then
            echo "[$session][$model_name] already done, skipping"
            continue
        fi

        echo "[$session][$model_name] starting..."
        start_ts=$(date +%s%N)
        full_text=""

        while IFS= read -r seg_wav; do
            [ -z "$seg_wav" ] && continue
            seg_text=$("$WHISPER" -m "$model" -f "$seg_wav" -l auto -nt 2>/dev/null || true)
            seg_text=$(echo "$seg_text" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -s ' ')
            if [ -n "$seg_text" ]; then
                full_text="${full_text}${seg_text} "
            fi
        done <<< "$seg_list"

        end_ts=$(date +%s%N)
        elapsed_ms=$(( (end_ts - start_ts) / 1000000 ))

        # trim trailing space
        full_text="${full_text% }"
        echo "$full_text" > "$out_file"
        echo "$elapsed_ms" > "$time_file"
        echo "[$session][$model_name] done — ${elapsed_ms}ms"
    done
done

echo ""
echo "All done. Results in $RAW_DIR"
