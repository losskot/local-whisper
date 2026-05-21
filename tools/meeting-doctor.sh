#!/usr/bin/env bash
# meeting-doctor.sh — one-shot diagnostic snapshot for meeting mode.
# Run when meeting mode is hanging or behaving oddly. Dumps:
#   - Hammerspoon-side meeting state (via hs CLI)
#   - Current system default output + available audio devices
#   - Running whisper-cli / ffmpeg processes
#   - meeting_chunks/ directory contents
#   - Tail of meeting-related log lines
set -u

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
hr()    { printf '%s\n' "────────────────────────────────────────────────────────────────"; }
TMPDIR_REAL=$(getconf DARWIN_USER_TEMP_DIR)
LOG="${TMPDIR_REAL}whisper-dictate/whisper-dictate.log"
CHUNK_DIR="${TMPDIR_REAL}whisper-dictate/meeting_chunks"
HELPER="$HOME/.local-whisper/bin/aggregate-audio"
HS_CLI="/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs"

bold "Hammerspoon meeting state"
hr
if [[ -x "$HS_CLI" ]]; then
    "$HS_CLI" -c 'meetingDoctor()' 2>/dev/null \
        || echo "(hs CLI returned nothing — is the 'hs' command line tool installed via Hammerspoon Preferences?)"
else
    echo "(Hammerspoon hs CLI not found at $HS_CLI)"
fi
echo

bold "Audio devices"
hr
if [[ -x "$HELPER" ]]; then
    echo "default output: $("$HELPER" default-uid 2>/dev/null || echo '(unavailable)')"
    echo "available outputs:"
    "$HELPER" list 2>/dev/null | sed 's/^/  /' || echo "  (helper failed)"
else
    echo "(audio helper not built at $HELPER — meeting mode wasn't enabled at install)"
fi
echo

bold "Running processes"
hr
PS=$(ps -A -o pid,etime,command 2>/dev/null | grep -E "whisper-cli|ffmpeg" | grep -v grep || true)
if [[ -z "$PS" ]]; then
    echo "(none)"
else
    echo "$PS"
fi
echo

bold "Chunks directory"
hr
if [[ -d "$CHUNK_DIR" ]]; then
    ls -la "$CHUNK_DIR" | sed 's/^/  /'
else
    echo "(no chunks dir — meeting hasn't run)"
fi
echo

bold "Recent meeting log (last 40 meeting: lines)"
hr
if [[ -f "$LOG" ]]; then
    grep -E "meeting:" "$LOG" | tail -40
else
    echo "(log not found at $LOG)"
fi
