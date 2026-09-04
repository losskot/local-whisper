# local-whisper

A fast, fully-local speech-to-text dictation tool for macOS with voice commands, powered by [whisper.cpp](https://github.com/ggml-org/whisper.cpp). No subscriptions, no cloud — just local transcription optimized for Apple Silicon.

Hold **fn + left Control**, speak, release — text appears at your cursor.

## Features

- **Hold-to-dictate**: Hold the trigger combo to record, release to transcribe and insert
- **Voice trigger (optional)**: Say "hey mycroft" to start a dictation hands-free; tap the trigger key to finish, or let it time out. Off by default — see [Voice trigger](#voice-trigger)
- **Segmented transcription**: Recordings are cut into 55-second segments and transcribed one after another, keeping each whisper call inside the model's sweet spot no matter how long you talk
- **Progress bar**: A two-colour strip shows recorded audio (red) against transcribed audio (blue), so long dictations report real progress
- **Voice commands**: Say "voice command note buy coffee" to save a note, "voice command open app Safari" to launch apps, and more — fully customizable
- **Recording indicator**: Pulsing red dot and elapsed timer in the overlay
- **Multi-language**: English, Russian, Ukrainian, and auto-detect (per segment, so mixed-language speech is not "translated")
- **App-aware processing**: Auto-capitalizes in most apps, skips in terminals and code editors
- **Text post-processing**: Remove filler words (um, uh, hmm), clean whitespace
- **Custom vocabulary / mixed-language anchor**: `~/.local-whisper/prompt` is a *writing sample*, not an instruction — whisper continues in whatever style it establishes. Seeded with a ru/uk/en example on first run; edit it to match how you actually speak. Applied to both the local model (with `--carry-initial-prompt`) and the remote API
- **Pipelined transcription**: Segments are transcribed while you are still talking, so the wait after releasing the key does not grow with the length of the dictation — only the tail segment is left. Text is inserted once all segments are back
- **Lossless capture**: A native AVAudioEngine recorder (`lw-record`) opens the microphone. ffmpeg's avfoundation input silently dropped ~10% of every recording, which swallowed whole words; the recorder logs captured-vs-wall-clock seconds after every dictation so a regression is visible
- **Warmup probe**: The recorder signals when audio is genuinely flowing; if the device never responds within 10 seconds, recording aborts with an error sound
- **Sleep recovery**: A dictation interrupted by system sleep is finalized on wake instead of being silently lost
- **Menu bar**: Waveform icon shows recording status (turns red), click for settings and recent dictations
- **Recent dictations**: View and re-paste your last 10 dictations from the menu bar
- **Fully local**: All processing on-device via whisper.cpp — nothing leaves your machine

## Voice Commands

Voice commands turn dictation into actions. All commands start with **"voice command"** to prevent false matches on normal speech.

| Say | What happens |
|-----|-------------|
| "voice command note buy coffee" | Saves to `~/whisper_notes.md` |
| "voice command remind call mom" | Creates a Reminder in the Reminders app |
| "voice command open app Safari" | Launches or focuses an app |
| "voice command copy" | Fires Cmd+C |
| "voice command paste" | Fires Cmd+V |
| "voice command select all" | Fires Cmd+A |
| "voice command undo" | Fires Cmd+Z |
| "voice command cancel" | Discards the current dictation (works mid-sentence) |

Voice commands are fully customizable — edit `~/.hammerspoon/local_whisper_actions.lua` to add your own. The config auto-reloads when you save.

For a full guide on writing custom commands, see **[docs/VOICE_COMMANDS.md](docs/VOICE_COMMANDS.md)**.

## Requirements

- macOS (Apple Silicon recommended — tested on M4)
- [Homebrew](https://brew.sh)

## Install

```bash
git clone https://github.com/luisalima/local-whisper.git && cd local-whisper && ./install.sh
```

The installer handles everything: Homebrew dependencies, building whisper.cpp, downloading models, and setting up Hammerspoon. It then runs `setup.sh` which walks you through choosing your trigger key, microphone, and granting permissions.

To change the trigger key or re-run setup later:

```bash
./setup.sh
```

<details>
<summary>Manual install (if you prefer)</summary>

```bash
# 1. Dependencies
brew install ffmpeg cmake git
brew install --cask hammerspoon

# 2. Build whisper.cpp
cd ~
git clone https://github.com/ggml-org/whisper.cpp
cd whisper.cpp
cmake -B build
cmake --build build -j --config Release

# 3. Download model (~1.5 GB)
./models/download-ggml-model.sh medium

# 4. Copy Hammerspoon config
cp hammerspoon/init.lua ~/.hammerspoon/init.lua
```

</details>

## Uninstall

```bash
./uninstall.sh
```

Removes Hammerspoon config, `~/.local-whisper/` settings, and temp files. Optionally removes `~/whisper.cpp`. Does not uninstall Homebrew packages.

## Setup

### Permissions (System Settings > Privacy & Security)

| App | Permission |
|-----|-----------|
| Hammerspoon | Accessibility, Microphone |
| Terminal (or your terminal app) | Accessibility (for `hs` CLI) |

### Hammerspoon CLI

Open Hammerspoon console and run once:

```lua
hs.ipc.cliInstall()
```

This installs the `hs` command-line tool used for IPC.

### Audio device

local-whisper records from your **macOS default input device**, so it follows your system
choice and survives dock/undock. To use a different microphone, change it in
**System Settings → Sound → Input**. There is no device setting in `init.lua`.

## Menu bar

A waveform icon in the menu bar shows recording status (turns red when recording). Click it to:

- See current language, model, output mode, and enter mode
- Click any setting to cycle it
- Toggle the voice trigger on and off
- View and re-paste recent dictations
- Reload voice commands
- Emergency stop

All settings are accessible from the menu bar — no keyboard shortcuts needed.

### Output modes

Click **Output** in the menu bar to cycle through three modes:

| Mode | Behaviour |
|------|-----------|
| **PASTE** | Writes text to clipboard via `pbcopy`, then sends `Cmd+V` automatically. Default for normal use. |
| **TYPE** | Types text character-by-character using keystroke events. Works in apps that block paste. Note: Cyrillic/non-ASCII may not work correctly in some apps. |
| **COPY** | Writes text to clipboard via `pbcopy` but does **not** send `Cmd+V`. Useful when working in **Microsoft Remote Desktop** or other remote-desktop/VM apps where clipboard sync to the guest OS is asynchronous — dictate, wait a moment for the clipboard to sync, then press `Ctrl+V` manually in the Windows window. |

**In every mode, the text only goes where you aimed it.** The spot your cursor was in when
you released the keys is remembered, and checked again just before the text is inserted. If
you clicked elsewhere, switched tabs or changed apps while whisper was still working, nothing
is typed: the transcript goes to the clipboard, you hear **two** chimes instead of one, and
the overlay shows `CLIPBOARD:` — paste it wherever you actually want it.

## Voice trigger

Optional hands-free start. A small wake-word model listens for **"hey mycroft"** and starts
a dictation exactly as the key does — transcription is unchanged and still goes to whichever
model is selected. Off by default.

```bash
./tools/lw-wake-setup.sh          # one-time: builds ~/.local-whisper/wake-venv (~200 MB)
```

Then enable it from the menu bar: **Voice trigger**.

**How it ends.** Tapping the trigger combo ends a voice-started dictation immediately — that
is the normal way to finish. The silence timeout is a safety net for when you forget: 8 s of
silence, or 12 s if you never start talking, with a 240 s cap.

Those numbers come from 182 archived dictations on this machine rather than from taste.
Pauses *inside* a dictation run to a median of 1 s but a 95th percentile of 4 s and a maximum
of 11 s, so a short timeout cuts people off mid-thought: 2.5 s would have ended roughly one
pause in five, while 8 s ends one in 134. Recorded dictations reach 122 s and 5.4% pass 90 s,
so the cap is set well clear of both.

When your hands are already on the keyboard the key trigger is still the better tool — a
keyboard click reads as speech and holds the dictation open.

**It only listens on mains power, while the screen is on.** On battery the listener does not
run at all — the microphone is the expensive half of the feature and a fanless laptop's
battery is the one resource it can visibly eat. Unplugging tears it down, plugging back in
revives it; the menu bar says `ON · on battery` while it is held down.

 An open microphone makes macOS hold a
`PreventUserIdleSystemSleep` assertion, so the listener is torn down the moment the screen
sleeps and the microphone is released. Voice deliberately cannot wake a sleeping Mac; that
would mean holding the microphone open around the clock to save a keypress.

**What it costs.** Measured on an M2 MacBook Air, screen on, quiet room:

| | % of one core |
|---|---|
| detector (`lw-wake.py`) | 4.8 |
| capture (`lw-record`) | 0.8 |
| `coreaudiod`, extra for the open mic | 4.5 |
| **total** | **~10% of one core ≈ 1.3% of an 8-core M2** |

**Accuracy.** The detection threshold is 0.95 rather than openWakeWord's documented 0.5.
Across 114 minutes of archived ru/uk/en dictation from this machine (85,500 frames), exactly
two frames crossed 0.5 — at 0.564 and 0.900 — while a real "hey mycroft" scores 0.998-1.000
and holds it for eight consecutive frames. If your own voice scores below 0.95 in practice,
lower `WAKE.THRESHOLD` in `hammerspoon/init.lua`; that is the only knob that should move.

To watch what the model is actually scoring:

```bash
~/.local-whisper/bin/lw-record - 0.08 16000 \
  | ~/.local-whisper/wake-venv/bin/python tools/lw-wake.py --scores
```

## Custom vocabulary prompt

Create `~/.local-whisper/prompt` with terms whisper should recognize better:

```
Claude, Hammerspoon, whisper.cpp, ffmpeg, macOS, Lua, Anthropic
```

This text is passed as `--prompt` to whisper-cli for every segment of the recording. Adding your voice command trigger words here also improves recognition.

## App-aware text processing

Post-processing adapts to the frontmost application when you start recording:

- **Terminals** (Terminal, iTerm2, Warp): skips auto-capitalize (commands are lowercase)
- **Code editors** (VS Code, Xcode, Zed, Sublime Text): skips auto-capitalize
- **Everything else**: auto-capitalizes first letter, removes filler words

The active app is also available in voice command hooks as `ctx.appName` and `ctx.appBundleID`.

## Writing custom voice commands

Edit `~/.hammerspoon/local_whisper_actions.lua` to add your own commands. The file returns a table with hooks that run on each dictation:

```lua
return {
    beforeInsert = function(ctx)
        -- Match and handle commands here
    end,
    actions = { },
    afterInsert = function(ctx)
        -- Post-insertion logic (logging, etc.)
    end,
}
```

### Hook context

| Field / Method | Description |
|---------------|-------------|
| `ctx.text` | Current text (mutable via `ctx:setText()`) |
| `ctx.textLower` | Lowercase version for case-insensitive matching |
| `ctx.originalText` | Original transcription (immutable) |
| `ctx.appName` | App name where dictation started (e.g. "Safari") |
| `ctx.appBundleID` | Bundle ID (e.g. "com.apple.Safari") |
| `ctx:setText(text)` | Replace text before insertion |
| `ctx:disableInsert()` | Skip cursor insertion (for command-only actions) |
| `ctx:appendToFile(path, line)` | Append a line to a file (creates parent dirs) |
| `ctx:launchApp("Safari")` | Launch or focus an app |
| `ctx:runShell("cmd", input)` | Run a shell command with optional stdin |
| `ctx:keystroke({"cmd"}, "a")` | Fire a keystroke |
| `ctx:notify("msg")` | Show a notification |
| `ctx.handled` | Set to `true` to skip remaining actions |

The config auto-reloads when you save the file. For more patterns and examples, see **[docs/VOICE_COMMANDS.md](docs/VOICE_COMMANDS.md)**.

## How it works

```
Trigger combo hold/release (detected by Hammerspoon eventtap on raw device flags)
  → lw-record opens the mic (AVAudioEngine) and reports READY once audio is flowing
  → it writes chunked WAV segments (1s each), losing no samples
  → every 3s: any finished ≤55s segment (cut at a pause) goes to whisper immediately,
    while recording continues — several segments may transcribe concurrently
  ↓  (key released)
  → doFinalTranscription(): only the unclaimed tail is left to transcribe
  → per segment: ffmpeg concat → whisper-cli (or the remote API), in order
  → progress bar tracks transcribed seconds against recorded seconds
  → join the segment texts, drop whisper's known silence hallucinations
  → Post-processing: remove fillers, capitalize, app-aware adjustments
  → Voice command hooks: beforeInsert → actions → text insertion → afterInsert
  → the cursor spot recorded at key release is re-checked; if it moved, clipboard only
  → Text inserted at cursor via paste (Cmd+V), keystroke, or clipboard-only (COPY mode)
```

## Troubleshooting

- **No transcription output**: Check `$TMPDIR/whisper-dictate/whisper-dictate.log` for errors (run `echo $TMPDIR` to find the path)
- **Words missing from the middle of sentences**: Check the capture health line — `grep "recording: captured"` in the log. It should read ~97% of wall clock; anything near 90% means capture regressed
- **Wrong microphone**: Change the input device in System Settings → Sound → Input. local-whisper follows the system default
- **`lw-record` build failed**: Needs the Xcode command line tools (`xcode-select --install`). init.lua rebuilds it automatically when the source changes; errors land in the log
- **Trigger key does nothing**: Accessibility permission may need toggling. Go to System Settings > Privacy & Security > Accessibility, toggle Hammerspoon **OFF then ON**, then run `hs.reload()` in the Hammerspoon console
- **External keyboard mapping**: Some keyboards (e.g., Logitech MX Keys) send non-standard modifier flags, and most non-Apple keyboards have no `fn` key at all. Pick a different `TRIGGER_KEY` in init.lua — `fnLeftCtrl` (default), `rightCmd`, `rightAlt`, or `rightCtrl` — or add your own entry to the `TRIGGERS` table
- **`hs` command not found**: Run `hs.ipc.cliInstall()` in Hammerspoon console
- **Voice commands not triggering**: Check the log to see what whisper transcribed — add command words to `~/.local-whisper/prompt`
- **Overlay not appearing**: Hammerspoon may need Accessibility permission re-granted after updates

## Disclaimer

This project was **vibe-coded** — built quickly with AI assistance for personal use. It works on my machine (M4 MacBook Pro), it might work on yours. PRs and issues welcome.

## License

[MIT](LICENSE)
