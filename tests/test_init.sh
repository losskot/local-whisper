#!/usr/bin/env bash
# test_init.sh — structural and behavioral tests for hammerspoon/init.lua
#
# Runs tests/test_init.lua through the Hammerspoon `hs` CLI, since this stack has
# no standalone Lua interpreter. Requires Hammerspoon to be running.
#
# Usage:
#   ./tests/test_init.sh                 # test the repo's init.lua
#   ./tests/test_init.sh path/to/init.lua  # test a specific file
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

TARGET="${1:-$REPO_DIR/hammerspoon/init.lua}"
# hs runs as the Hammerspoon process, so paths must be absolute.
TARGET="$(cd "$(dirname "$TARGET")" && pwd)/$(basename "$TARGET")"

HS_BIN="$(command -v hs || echo /Applications/Hammerspoon.app/Contents/Frameworks/hs/hs)"
if [[ ! -x "$HS_BIN" ]]; then
    echo -e "${RED}Error: the 'hs' CLI was not found.${NC}"
    echo "Enable it from the Hammerspoon console: hs.ipc.cliInstall()"
    exit 1
fi

if ! pgrep -x Hammerspoon >/dev/null 2>&1; then
    echo -e "${RED}Error: Hammerspoon is not running.${NC}"
    echo "These tests execute Lua through Hammerspoon's runtime. Start Hammerspoon and retry."
    exit 1
fi

OUT="$(mktemp -t lw_test_init)"
trap 'rm -f "$OUT"' EXIT

echo -e "${BOLD}local-whisper init.lua test suite${NC}"
echo -e "Target: ${BOLD}${TARGET#"$REPO_DIR"/}${NC}"
echo ""

# hs evaluates in the running Hammerspoon process and does not inherit this shell's
# environment, so pass the paths as globals rather than env vars.
# Run in background: hs often hangs on IPC cleanup after the Lua completes. We wait
# for the DONE sentinel the test suite writes, then kill hs ourselves.
"$HS_BIN" -c "_G.LW_TARGET='$TARGET'; _G.LW_OUT='$OUT'; dofile('$SCRIPT_DIR/test_init.lua')" \
    >/dev/null 2>&1 &
HS_PID=$!

DEADLINE=120  # seconds
ELAPSED=0
while [[ $ELAPSED -lt $DEADLINE ]]; do
    sleep 0.2
    ELAPSED=$(( ELAPSED + 1 ))
    if grep -q $'^DONE\t' "$OUT" 2>/dev/null; then
        break
    fi
done

kill "$HS_PID" 2>/dev/null || true
wait "$HS_PID" 2>/dev/null || true

if [[ $ELAPSED -ge $DEADLINE ]]; then
    echo -e "${RED}Error: test suite timed out after ${DEADLINE}s.${NC}"
    echo "Check that $SCRIPT_DIR/test_init.lua loads cleanly."
    exit 1
fi

if [[ ! -s "$OUT" ]]; then
    echo -e "${RED}Error: the test suite produced no output.${NC}"
    echo "Check that $SCRIPT_DIR/test_init.lua loads cleanly."
    exit 1
fi

PASS=0
FAIL=0
while IFS=$'\t' read -r status name detail; do
    [[ -z "$status" ]] && continue
    [[ "$status" == "DONE" ]] && continue
    if [[ "$status" == "PASS" ]]; then
        PASS=$((PASS + 1))
        echo -e "  ${GREEN}PASS${NC}  $name"
    else
        FAIL=$((FAIL + 1))
        echo -e "  ${RED}FAIL${NC}  $name"
        [[ -n "$detail" ]] && echo -e "        ${YELLOW}$detail${NC}"
    fi
done < "$OUT"

TOTAL=$((PASS + FAIL))
echo ""
if [[ $FAIL -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}All $TOTAL checks passed.${NC}"
    exit 0
else
    echo -e "${RED}${BOLD}$FAIL of $TOTAL checks failed.${NC}"
    exit 1
fi
