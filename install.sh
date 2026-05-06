#!/usr/bin/env bash
# install.sh — local-whisper installer
# Sets up everything needed for hold-to-dictate on macOS with whisper.cpp
# Architecture: Hammerspoon-only (no Karabiner, no bash scripts at runtime)
set -euo pipefail

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${BLUE}[*]${NC} $*"; }
ok()    { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[x]${NC} $*"; }

# ─── Detect script location (repo root) ─────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ─── Configurable paths ─────────────────────────────────────────────────────
WHISPER_CPP_DIR="$HOME/whisper.cpp"
WHISPER_MODEL="medium"
HAMMERSPOON_DIR="$HOME/.hammerspoon"

# ─── Preflight ───────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}local-whisper installer${NC}"
echo -e "Hold a key → speak → release → text at cursor"
echo ""

# Check macOS
if [[ "$(uname)" != "Darwin" ]]; then
    error "This tool is macOS-only."
    exit 1
fi

# Check Apple Silicon
ARCH=$(uname -m)
if [[ "$ARCH" == "arm64" ]]; then
    ok "Apple Silicon detected ($ARCH)"
else
    warn "Intel Mac detected ($ARCH) — will work but transcription will be slower"
fi

# Check Homebrew
if ! command -v brew &>/dev/null; then
    error "Homebrew not found. Install it first: https://brew.sh"
    exit 1
fi
ok "Homebrew found"

# ─── Step 1: Brew dependencies ──────────────────────────────────────────────
echo ""
info "Step 1/6: Installing dependencies via Homebrew..."

BREW_FORMULAE=(ffmpeg cmake git)
for formula in "${BREW_FORMULAE[@]}"; do
    if brew list "$formula" &>/dev/null; then
        ok "$formula already installed"
    else
        info "Installing $formula..."
        brew install "$formula"
        ok "$formula installed"
    fi
done

if brew list --cask hammerspoon &>/dev/null; then
    ok "hammerspoon already installed"
else
    info "Installing hammerspoon..."
    brew install --cask hammerspoon
    ok "hammerspoon installed"
fi

# ─── Step 2: Build whisper.cpp ───────────────────────────────────────────────
echo ""
info "Step 2/6: Building whisper.cpp..."

if [[ -x "$WHISPER_CPP_DIR/build/bin/whisper-cli" ]]; then
    ok "whisper-cli already built at $WHISPER_CPP_DIR/build/bin/whisper-cli"
else
    if [[ ! -d "$WHISPER_CPP_DIR" ]]; then
        info "Cloning whisper.cpp..."
        git clone https://github.com/ggml-org/whisper.cpp "$WHISPER_CPP_DIR"
    else
        ok "whisper.cpp repo already at $WHISPER_CPP_DIR"
    fi

    info "Building with cmake (this may take a few minutes)..."
    cd "$WHISPER_CPP_DIR"
    cmake -B build
    cmake --build build -j --config Release
    cd "$SCRIPT_DIR"

    if [[ -x "$WHISPER_CPP_DIR/build/bin/whisper-cli" ]]; then
        ok "whisper-cli built successfully"
    else
        error "Build failed — check output above"
        exit 1
    fi
fi

# ─── Step 3: Download models ────────────────────────────────────────────────
echo ""
info "Step 3/6: Downloading whisper models..."

MODEL_FILE="$WHISPER_CPP_DIR/models/ggml-${WHISPER_MODEL}.bin"
if [[ -f "$MODEL_FILE" ]]; then
    ok "Model already downloaded: ggml-${WHISPER_MODEL}.bin"
else
    info "Downloading ggml-${WHISPER_MODEL}.bin (~1.5 GB)..."
    cd "$WHISPER_CPP_DIR"
    bash ./models/download-ggml-model.sh "$WHISPER_MODEL"
    cd "$SCRIPT_DIR"

    if [[ -f "$MODEL_FILE" ]]; then
        ok "Model downloaded"
    else
        error "Model download failed"
        exit 1
    fi
fi

# Also download tiny model for faster live preview (~75 MB)
TINY_MODEL="$WHISPER_CPP_DIR/models/ggml-tiny.bin"
if [[ -f "$TINY_MODEL" ]]; then
    ok "Tiny model already downloaded (used for fast live preview)"
else
    info "Downloading ggml-tiny.bin for faster live preview (~75 MB)..."
    cd "$WHISPER_CPP_DIR"
    bash ./models/download-ggml-model.sh tiny
    cd "$SCRIPT_DIR"

    if [[ -f "$TINY_MODEL" ]]; then
        ok "Tiny model downloaded"
    else
        warn "Tiny model download failed — live preview will use main model (slower but works)"
    fi
fi

# ─── Step 4: Install Hammerspoon config ─────────────────────────────────────
echo ""
info "Step 4/6: Setting up Hammerspoon..."

mkdir -p "$HAMMERSPOON_DIR"

# Create config directory for user settings
CONFIG_DIR="$HOME/.local-whisper"
mkdir -p "$CONFIG_DIR"
ok "Config directory: $CONFIG_DIR"

if [[ -f "$HAMMERSPOON_DIR/init.lua" ]]; then
    if grep -q "local-whisper" "$HAMMERSPOON_DIR/init.lua"; then
        # Existing local-whisper config — update it but preserve user settings
        # (user settings live in ~/.local-whisper/, not in init.lua)
        cp "$SCRIPT_DIR/hammerspoon/init.lua" "$HAMMERSPOON_DIR/init.lua"
        ok "Hammerspoon config updated"
    else
        warn "Existing init.lua found — backing up to init.lua.backup"
        cp "$HAMMERSPOON_DIR/init.lua" "$HAMMERSPOON_DIR/init.lua.backup"
        cp "$SCRIPT_DIR/hammerspoon/init.lua" "$HAMMERSPOON_DIR/init.lua"
        ok "Hammerspoon config installed (backup saved)"
    fi
else
    cp "$SCRIPT_DIR/hammerspoon/init.lua" "$HAMMERSPOON_DIR/init.lua"
    ok "Hammerspoon config installed"
fi

# Install example voice commands if user doesn't have a config yet
if [[ ! -f "$HAMMERSPOON_DIR/local_whisper_actions.lua" ]]; then
    if [[ -f "$SCRIPT_DIR/hammerspoon/local_whisper_actions.example.lua" ]]; then
        cp "$SCRIPT_DIR/hammerspoon/local_whisper_actions.example.lua" "$HAMMERSPOON_DIR/local_whisper_actions.lua"
        ok "Voice commands config installed (edit ~/.hammerspoon/local_whisper_actions.lua to customize)"
    fi
fi

# ─── Step 5: Setup (permissions, trigger key, audio device, HS CLI) ─────────
echo ""
info "Step 5/6: Running setup (permissions, trigger key, audio device)..."
echo ""
bash "$SCRIPT_DIR/setup.sh"

# ─── Step 6: Optional — meeting recording mode ───────────────────────────────
echo ""
info "Step 6/6: Meeting recording mode (optional)"
echo ""
echo "  Adds 'Meeting Mode' to the menu bar — captures system audio during"
echo "  calls (Zoom, Meet, Teams, etc.), produces a live transcript and"
echo "  Ollama summary."
echo ""
echo "  Requires BlackHole 2ch (free virtual audio driver). On opt-in, this"
echo "  installer also builds a small Swift helper that creates a"
echo "  Multi-Output Device automatically — no Audio MIDI Setup needed."
echo ""
echo "  Skip if you only want hold-to-dictate. Re-run this installer later"
echo "  to enable it."
echo ""
read -r -p "  Enable meeting recording mode? [y/N]: " ENABLE_MEETING

if [[ "$ENABLE_MEETING" =~ ^[Yy]$ ]]; then
    if brew list --cask blackhole-2ch &>/dev/null; then
        ok "BlackHole 2ch already installed"
    else
        info "Installing BlackHole 2ch..."
        brew install --cask blackhole-2ch
        ok "BlackHole 2ch installed"
    fi

    HELPER_SRC="$SCRIPT_DIR/tools/aggregate-audio.swift"
    HELPER_BIN_DIR="$CONFIG_DIR/bin"
    HELPER_BIN="$HELPER_BIN_DIR/aggregate-audio"
    if [[ ! -f "$HELPER_SRC" ]]; then
        error "Missing $HELPER_SRC — meeting mode helper cannot be built."
        exit 1
    fi
    mkdir -p "$HELPER_BIN_DIR"
    info "Building audio helper (swiftc)..."
    if swiftc -O "$HELPER_SRC" -o "$HELPER_BIN"; then
        ok "Helper installed at $HELPER_BIN"
    else
        error "Failed to build audio helper. Is the Xcode Command Line Tools package installed?"
        error "  xcode-select --install"
        exit 1
    fi

    info "Creating 'local-whisper Output' Multi-Output Device..."
    if AGG_UID=$("$HELPER_BIN" create 2>&1); then
        ok "Aggregate device ready (UID: $AGG_UID)"
        echo ""
        echo "  Meeting mode will switch your system output to this device only"
        echo "  while a meeting is recording, then switch back when you stop."
        echo "  No further setup needed — start meetings from the menu bar."
    else
        warn "Could not create aggregate device automatically:"
        warn "  $AGG_UID"
        warn "If you just installed BlackHole, you may need to reboot first,"
        warn "then re-run this installer."
    fi
else
    ok "Skipped — meeting mode disabled. Re-run installer to enable."
fi
