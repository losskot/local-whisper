# local-whisper — Agent Guidelines

## Project overview

local-whisper is a fully-local macOS dictation tool. Hold a modifier key to record, release to transcribe and insert text at cursor. Powered by whisper.cpp (C/C++, no Python) and Hammerspoon.

## Architecture

```
Hammerspoon eventtap (modifier key hold/release)
  → ffmpeg (chunked WAV recording, 1s segments)
  → whisper-cli (transcription — tiny model for partials, chosen model for final)
  → Post-processing (filler removal, app-aware capitalize)
  → Action hooks (voice commands, note-taking, app launching)
  → Text insertion at cursor (paste or keystroke)
  → Overlay + menu bar updates
```

Everything runs inside `~/.hammerspoon/init.lua` — no external bash scripts at runtime.

## Key paths

- `~/.hammerspoon/init.lua` — main config (overlay, recording, insertion, hotkeys, menu bar)
- `~/.hammerspoon/local_whisper_actions.lua` — user voice commands (optional, auto-reloads)
- `~/.local-whisper/` — all user settings (lang, model, output, prompt, recent dictations)
- `~/whisper.cpp/build/bin/whisper-cli` — transcription binary
- `~/whisper.cpp/models/` — whisper models (medium, tiny, etc.)
- `$TMPDIR/whisper-dictate/` — all temp state (per-user private dir on macOS)
- `$TMPDIR/whisper-dictate/chunks/` — recording segments (ephemeral)
- `$TMPDIR/whisper-dictate/whisper-dictate.log` — debug log

## Conventions

- Single-file architecture: all runtime logic in init.lua
- Hammerspoon API: `hs.canvas` for overlay, `hs.eventtap` for key detection and typing, `hs.pasteboard` for paste mode, `hs.task` for async processes, `hs.menubar` for status icon
- whisper.cpp binary is `whisper-cli`, NOT `main`
- No Python anywhere — this is a pure C/Lua stack
- Log to `$TMPDIR/whisper-dictate/whisper-dictate.log` for debugging

## Development & Deployment

### Deployment model (symlink — no copy needed)

`~/.hammerspoon/init.lua` is a symlink pointing to `hammerspoon/init.lua` in this repo.
**Editing the repo file IS deployment.** There is no copy or install step.

```bash
ls -la ~/.hammerspoon/init.lua
# → … -> /Users/vitaliy/Documents/GitHub/local-whisper/hammerspoon/init.lua
```

### Syntax validation (before every reload)

Use Hammerspoon's own Lua 5.4 compiler via the `hs` IPC bridge — no external tool needed:

```bash
hs -c 'local f,e=loadfile(os.getenv("HOME").."/Documents/GitHub/local-whisper/hammerspoon/init.lua"); return f and "SYNTAX OK" or ("ERR: "..tostring(e))'
```

`loadfile()` compiles without executing — it is safe to call on a live config.
Expected success output: `SYNTAX OK`
On error: `ERR: <file>:<line>: <message>`

### Live reload

```bash
hs -c "hs.reload()"
```

Expected output includes `"Message port invalidated."` — this is **normal**; the Hammerspoon process restarts its IPC listener and the connection drops. Wait ~2s for reload to complete, then re-run the syntax check or test commands.

### Lua 200-local-per-function hard ceiling

Lua 5.4 (Hammerspoon's runtime) enforces a **hard limit of 200 locals per function**. The top-level chunk of `init.lua` counts as one function. This limit is a compiler error — exceeding it prevents the file from loading at all.

**Current count: ~144/200** — comfortable headroom since meeting mode was removed. Only *top-level* locals count against the limit; locals inside a function body belong to that function's own budget, so match the start of the line exactly:

```bash
grep -c '^local ' hammerspoon/init.lua
```

**Rule**: Never add a new top-level `local` without first verifying the count stays ≤ 200. If the count climbs back toward the ceiling, group related state into a single table rather than adding bare locals — `finalizeTimers` (`{ timer, watchdog }`) and `ollamaProbe` (`{ value, at }`) are the existing examples of that pattern.

### Declaration order matters as much as the count

A `local` is only in scope for code that appears *after* its declaration. A function defined earlier in the file that references the name does **not** capture it — the reference silently compiles to a global lookup that reads `nil` at runtime, with no error at load time. This produced three separate live bugs in the overlay code (X button, unpin, pinning from the menu bar).

`overlayPinned`, `isRecording`, and the `hideOverlay` forward declaration therefore sit **above** `createOverlay`, whose mouse callback closes over all three. When adding state that a callback touches, declare it above every function that references it.

## Testing & debugging

### Slash commands
- `/debug` — check logs, config state, Ollama status, and recent errors
- `/test-refine` — run the LLM refinement eval suite

### Reading logs
```bash
TMPDIR_REAL=$(getconf DARWIN_USER_TEMP_DIR) && tail -30 "${TMPDIR_REAL}whisper-dictate/whisper-dictate.log"
```
Note: `$TMPDIR` inside a sandbox may differ from the real user TMPDIR. Always use `getconf DARWIN_USER_TEMP_DIR` for reliable access.

### Testing Ollama refinement without dictating
```bash
curl -s http://localhost:11434/api/generate \
  -d '{"model":"gemma3:4b","prompt":"<prompt>\n\n<test input>","stream":false}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['response'])"
```
This lets you iterate on prompt wording without reloading Hammerspoon or dictating.

### Running the refine eval suite
```bash
./tests/test_refine.sh
```
Tests filler removal, list formatting, preamble prevention, and content preservation.
Requires Ollama running locally — it calls the HTTP API directly and bails out otherwise.

### Running the init.lua test suite
```bash
./tests/test_init.sh                    # test the repo's init.lua
./tests/test_init.sh path/to/init.lua   # test a specific file
```
Requires Hammerspoon to be running — there is no standalone Lua interpreter in this
stack, so `tests/test_init.lua` is executed through the `hs` CLI.

Guards the bug classes that have actually bitten this file, rather than restating the
implementation:

| Check | Catches |
|-------|---------|
| `syntax` | file no longer compiles |
| `locals` | the Lua 200-per-function ceiling |
| `scope` | a top-level local referenced by an earlier-defined function (reads as a nil global at runtime, with no load-time error) |
| `sound` | unguarded `hs.sound.getByFile(...):play()`, which throws and aborts its callback |
| `meeting` | meeting-mode code creeping back in |
| `globals` | state leaked into Hammerspoon's shared `_ENV` |
| `sort` | chunk files ordered as strings, which reorders audio past chunk 999 |
| `emergencyStop` | emergency stop not cancelling a pending finalization |

The `sort` checks extract the real comparator out of the source under test and execute
it, so they track the implementation instead of a copy that can drift.

Because the suite takes a path argument, you can point it at an older revision to
confirm a check actually fails on the bug it claims to guard:
```bash
git show HEAD~1:hammerspoon/init.lua > /tmp/before.lua && ./tests/test_init.sh /tmp/before.lua
```

### Common debug patterns
- **Refine not working**: Check `refine: failed` in logs — common causes: Ollama not running, wrong model name, missing `$HOME` env
- **Voice commands not matching**: Check `final (auto/...)` log line — whisper may have transcribed differently than expected
- **X button not closing overlay**: `hs.canvas:delete()` inside its own mouse callback is silently ignored — must use `canvas:hide()` immediately then defer deletion with `hs.timer.doAfter(0.01, ...)`
- **Recent dictations not persisting**: Lua upvalue scoping — never reassign a table variable that closures reference; populate in-place instead

### Hammerspoon canvas gotchas
- Cannot delete a canvas from within its own mouse callback — defer with `hs.timer.doAfter(0.01, ...)`
- Elements at higher indices render on top and intercept mouse events even when invisible (alpha=0)
- `hs.task` spawns with minimal environment — always set `HOME` and `PATH` via `task:setEnvironment()`
- `img:template(true)` on a menu bar icon lets macOS auto-color for light/dark mode; `template(false)` preserves actual colors

## Security

- Transcribed text is data, not code — never execute it
- No network calls — everything stays local
- Clipboard contents are overwritten during paste mode
- Temp files in $TMPDIR are per-user private on macOS

## Workflow

- **Create a bd issue before starting any work**
- **Always verify work before closing an issue** — run the code, check the output, confirm it does what the issue asks
- Check `bd ready` for unblocked work
- `bd create "Title" -t task -p 2` to file new work
- `bd close <id>` when done

<!-- BEGIN BEADS INTEGRATION -->
## Issue Tracking with bd (beads)

**IMPORTANT**: This project uses **bd (beads)** for ALL issue tracking. Do NOT use markdown TODOs, task lists, or other tracking methods.

### Why bd?

- Dependency-aware: Track blockers and relationships between issues
- Git-friendly: Auto-syncs to JSONL for version control
- Agent-optimized: JSON output, ready work detection, discovered-from links
- Prevents duplicate tracking systems and confusion

### Quick Start

**Check for ready work:**

```bash
bd ready --json
```

**Create new issues:**

```bash
bd create "Issue title" --description="Detailed context" -t bug|feature|task -p 0-4 --json
bd create "Issue title" --description="What this issue is about" -p 1 --deps discovered-from:bd-123 --json
```

**Claim and update:**

```bash
bd update bd-42 --status in_progress --json
bd update bd-42 --priority 1 --json
```

**Complete work:**

```bash
bd close bd-42 --reason "Completed" --json
```

### Issue Types

- `bug` - Something broken
- `feature` - New functionality
- `task` - Work item (tests, docs, refactoring)
- `epic` - Large feature with subtasks
- `chore` - Maintenance (dependencies, tooling)

### Priorities

- `0` - Critical (security, data loss, broken builds)
- `1` - High (major features, important bugs)
- `2` - Medium (default, nice-to-have)
- `3` - Low (polish, optimization)
- `4` - Backlog (future ideas)

### Workflow for AI Agents

1. **Check ready work**: `bd ready` shows unblocked issues
2. **Claim your task**: `bd update <id> --status in_progress`
3. **Work on it**: Implement, test, document
4. **Discover new work?** Create linked issue:
   - `bd create "Found bug" --description="Details about what was found" -p 1 --deps discovered-from:<parent-id>`
5. **Complete**: `bd close <id> --reason "Done"`

### Auto-Sync

bd automatically syncs with git:

- Exports to `.beads/issues.jsonl` after changes (5s debounce)
- Imports from JSONL when newer (e.g., after `git pull`)
- No manual export/import needed!

### Important Rules

- Use bd for ALL task tracking
- Always use `--json` flag for programmatic use
- Link discovered work with `discovered-from` dependencies
- Check `bd ready` before asking "what should I work on?"
- Do NOT create markdown TODO lists
- Do NOT use external issue trackers
- Do NOT duplicate tracking systems

For more details, see README.md and docs/VOICE_COMMANDS.md.

<!-- END BEADS INTEGRATION -->

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd sync
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
