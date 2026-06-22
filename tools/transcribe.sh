#!/usr/bin/env bash
# transcribe.sh — batch audio/video transcription using whisper.cpp large-v3-turbo
#
# Usage:
#   ./transcribe.sh [OPTIONS] FILE|DIR [FILE|DIR ...]
#
# Options:
#   -m MODEL    Model path or name (default: large-v3-turbo-q5_0)
#   -l LANG     Language code, e.g. en, ru, auto (default: auto)
#   -f FORMAT   Output format: txt, srt, vtt, json, csv, lrc (default: txt)
#   -o DIR      Output directory (default: same dir as each input file)
#   -t N        Threads (default: auto-detect)
#   -T           Translate to English
#   -p PROMPT   Initial prompt string
#   -n           No timestamps in txt output
#   -r           Recurse into directories
#   -h           Show this help

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[0;33m'
BLU='\033[0;34m'; BLD='\033[1m'; RST='\033[0m'

log()  { echo -e "${BLU}[transcribe]${RST} $*"; }
ok()   { echo -e "${GRN}[ok]${RST} $*"; }
warn() { echo -e "${YLW}[warn]${RST} $*"; }
err()  { echo -e "${RED}[error]${RST} $*" >&2; }

usage() {
    cat <<'EOF'
Usage: transcribe.sh [OPTIONS] FILE|DIR [FILE|DIR ...]

Options:
  -m MODEL    Model path or name (default: large-v3-turbo-q5_0)
  -l LANG     Language code, e.g. en, ru, auto (default: auto)
  -f FORMAT   Output format: txt, srt, vtt, json, csv, lrc (default: txt)
  -o DIR      Output directory (default: same dir as each input file)
  -t N        Threads (default: auto-detect)
  -T          Translate to English
  -p PROMPT   Initial prompt string
  -n          No timestamps in txt output
  -r          Recurse into directories
  -h          Show this help

Supported audio/video formats:
  Native (no conversion): flac, mp3, ogg, wav
  Via ffmpeg: mp4, m4a, aac, webm, mkv, avi, mov, wma, opus, aiff, amr,
              3gp, ts, mts, flv, vob, caf, au, wv, ape, ra, rm, mxf, ...

Examples:
  transcribe.sh interview.mp4
  transcribe.sh -l ru -f srt podcast.m4a
  transcribe.sh -r -o ./transcripts ./recordings/
  transcribe.sh -T -l fr talk.webm        # translate French → English
EOF
    exit 0
}

# ── Default config ────────────────────────────────────────────────────────────
WHISPER_BIN="${HOME}/whisper.cpp/build/bin/whisper-cli"
MODELS_DIR="${HOME}/whisper.cpp/models"
DEFAULT_MODEL="large-v3-turbo-q5_0"

MODEL_ARG=""          # filled by -m; resolved later
LANG="auto"
FORMAT="txt"
OUT_DIR=""
THREADS=""
TRANSLATE=false
PROMPT=""
NO_TIMESTAMPS=false
RECURSE=false

# ── Supported formats ─────────────────────────────────────────────────────────
# whisper-cli handles these natively (no ffmpeg conversion needed)
NATIVE_EXTS="flac mp3 ogg wav"

# Everything else is converted via ffmpeg to 16 kHz mono WAV
EXTRA_EXTS="
  mp4 m4a m4b m4p aac
  webm mkv mka mks
  avi mov wmv wma asf
  opus oga spx
  aiff aif aifc
  amr awb
  3gp 3g2
  ts mts m2ts m2t
  mp2 mp1
  ac3 eac3 dts dtshd
  flv f4v f4a f4b
  vob mpg mpeg m2v m1v
  caf au snd
  wv ape tak tta
  ra rm rmvb
  mxf gxf
  dv
  mid midi
  gsm
  nut
  roq
"

# ── Parse flags ───────────────────────────────────────────────────────────────
while getopts ":m:l:f:o:t:Tp:nrh" opt; do
    case $opt in
        m) MODEL_ARG="$OPTARG" ;;
        l) LANG="$OPTARG" ;;
        f) FORMAT="$OPTARG" ;;
        o) OUT_DIR="$OPTARG" ;;
        t) THREADS="$OPTARG" ;;
        T) TRANSLATE=true ;;
        p) PROMPT="$OPTARG" ;;
        n) NO_TIMESTAMPS=true ;;
        r) RECURSE=true ;;
        h) usage ;;
        :) err "Option -$OPTARG requires an argument."; exit 1 ;;
        \?) err "Unknown option: -$OPTARG"; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

[[ $# -eq 0 ]] && { usage; }

# ── Resolve model path ────────────────────────────────────────────────────────
resolve_model() {
    local m="$1"
    # Absolute path given
    [[ "$m" == /* ]] && { echo "$m"; return; }
    # Filename inside models dir
    [[ -f "${MODELS_DIR}/${m}" ]]          && { echo "${MODELS_DIR}/${m}"; return; }
    # Short name → ggml-<name>.bin
    [[ -f "${MODELS_DIR}/ggml-${m}.bin" ]] && { echo "${MODELS_DIR}/ggml-${m}.bin"; return; }
    echo ""
}

MODEL_PATH=$(resolve_model "${MODEL_ARG:-$DEFAULT_MODEL}")
if [[ -z "$MODEL_PATH" || ! -f "$MODEL_PATH" ]]; then
    err "Model not found: '${MODEL_ARG:-$DEFAULT_MODEL}'"
    err "Available models in ${MODELS_DIR}:"
    ls "${MODELS_DIR}"/ggml-*.bin 2>/dev/null | sed "s|${MODELS_DIR}/ggml-||;s|\.bin||" | sed 's/^/  /'
    exit 1
fi

# ── Check dependencies ────────────────────────────────────────────────────────
if [[ ! -x "$WHISPER_BIN" ]]; then
    err "whisper-cli not found or not executable: $WHISPER_BIN"
    exit 1
fi

FFMPEG_BIN=""
for f in /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg ffmpeg; do
    if command -v "$f" &>/dev/null; then FFMPEG_BIN="$f"; break; fi
done
if [[ -z "$FFMPEG_BIN" ]]; then
    warn "ffmpeg not found — only native formats (flac, mp3, ogg, wav) will be supported."
fi

# ── Auto-detect thread count ──────────────────────────────────────────────────
if [[ -z "$THREADS" ]]; then
    THREADS=$(sysctl -n hw.logicalcpu 2>/dev/null || nproc 2>/dev/null || echo 4)
fi

# ── Extension lookup (bash 3.2-compatible, no associative arrays) ────────────
ext_type() {
    # Returns: native, ffmpeg, or empty string (unsupported)
    local e="$1"
    case " $NATIVE_EXTS " in
        *" $e "*) echo native; return ;;
    esac
    if [[ -n "$FFMPEG_BIN" ]]; then
        case " $EXTRA_EXTS " in
            *" $e "*) echo ffmpeg; return ;;
        esac
    fi
    echo ""
}

# ── Collect input files ───────────────────────────────────────────────────────
collect_files() {
    local path="$1"
    if [[ -f "$path" ]]; then
        echo "$path"
    elif [[ -d "$path" ]]; then
        if $RECURSE; then
            find "$path" -type f | sort
        else
            find "$path" -maxdepth 1 -type f | sort
        fi
    else
        err "Not a file or directory: $path"
    fi
}

ALL_FILES=()
for arg in "$@"; do
    while IFS= read -r f; do
        [[ -n "$f" ]] && ALL_FILES+=("$f")
    done < <(collect_files "$arg")
done

# Filter to supported formats only
QUEUE=()
SKIPPED=0
for f in "${ALL_FILES[@]}"; do
    ext="${f##*.}"
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    if [[ -n "$(ext_type "$ext")" ]]; then
        QUEUE+=("$f")
    else
        warn "Skipping unsupported format: $f"
        (( SKIPPED++ )) || true
    fi
done

TOTAL=${#QUEUE[@]}
if [[ $TOTAL -eq 0 ]]; then
    err "No supported audio/video files found."
    exit 1
fi

log "Model  : $(basename "$MODEL_PATH")"
log "Lang   : $LANG"
log "Format : $FORMAT"
log "Threads: $THREADS"
log "Files  : $TOTAL"
[[ $SKIPPED -gt 0 ]] && warn "$SKIPPED file(s) skipped (unsupported format)"
echo

# ── Temp dir for WAV conversions ──────────────────────────────────────────────
TMPWORK=$(mktemp -d)
trap 'rm -rf "$TMPWORK"' EXIT

# ── Format flags for whisper-cli ──────────────────────────────────────────────
format_flag() {
    case "$1" in
        txt)  echo "--output-txt" ;;
        srt)  echo "--output-srt" ;;
        vtt)  echo "--output-vtt" ;;
        json) echo "--output-json" ;;
        csv)  echo "--output-csv" ;;
        lrc)  echo "--output-lrc" ;;
        *)    err "Unknown format: $1"; exit 1 ;;
    esac
}
FMT_FLAG=$(format_flag "$FORMAT")

# ── Extension that whisper appends to the output-file base ────────────────────
format_ext() {
    case "$1" in
        txt)  echo "txt" ;;
        srt)  echo "srt" ;;
        vtt)  echo "vtt" ;;
        json) echo "json" ;;
        csv)  echo "csv" ;;
        lrc)  echo "lrc" ;;
    esac
}
FMT_EXT=$(format_ext "$FORMAT")

# ── Process each file ─────────────────────────────────────────────────────────
DONE=0; FAILED=0

for input_file in "${QUEUE[@]}"; do
    (( DONE++ )) || true
    filename="$(basename "$input_file")"
    stem="${filename%.*}"
    ext="${filename##*.}"; ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

    # Determine output path
    if [[ -n "$OUT_DIR" ]]; then
        mkdir -p "$OUT_DIR"
        out_base="${OUT_DIR}/${stem}"
    else
        out_base="$(dirname "$input_file")/${stem}"
    fi

    printf "${BLD}[%d/%d]${RST} %s\n" "$DONE" "$TOTAL" "$filename"

    # Convert to WAV if needed
    audio_file="$input_file"
    if [[ "$(ext_type "$ext")" == "ffmpeg" ]]; then
        wav_tmp="${TMPWORK}/$(printf '%06d' "$DONE").wav"
        log "  Converting via ffmpeg → WAV 16 kHz mono…"
        if ! "$FFMPEG_BIN" -hide_banner -loglevel error \
            -i "$input_file" \
            -ar 16000 -ac 1 -c:a pcm_s16le \
            -y "$wav_tmp" 2>&1; then
            err "  ffmpeg conversion failed — skipping."
            (( FAILED++ )) || true
            continue
        fi
        audio_file="$wav_tmp"
    fi

    # Build whisper-cli command
    cmd=(
        "$WHISPER_BIN"
        --model      "$MODEL_PATH"
        --language   "$LANG"
        --threads    "$THREADS"
        --output-file "$out_base"
        $FMT_FLAG
    )
    $NO_TIMESTAMPS && cmd+=(--no-timestamps)
    $TRANSLATE     && cmd+=(--translate)
    [[ -n "$PROMPT" ]] && cmd+=(--prompt "$PROMPT")
    cmd+=("$audio_file")

    if "${cmd[@]}" 2>&1 | grep -v "^$"; then
        ok "  → ${out_base}.${FMT_EXT}"
    else
        err "  whisper-cli failed for: $filename"
        (( FAILED++ )) || true
    fi
    echo
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "${BLD}Done.${RST} Processed: $((DONE - FAILED))/$TOTAL  |  Failed: $FAILED"
[[ $FAILED -gt 0 ]] && exit 1 || exit 0
