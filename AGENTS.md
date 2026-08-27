# local-whisper — Agent Guidelines

## Project overview

local-whisper is a fully-local macOS dictation tool. Hold **fn + left Control** to record, release to transcribe and insert text at cursor. Powered by whisper.cpp (C/C++, no Python) and Hammerspoon.

## Key paths

- `~/.hammerspoon/init.lua` — main config
- `~/.hammerspoon/local_whisper_actions.lua` — user voice commands (optional, auto-reloads)
- `tools/lw-record.swift` — native mic recorder source
- `~/.local-whisper/` — user settings (lang, model, output, prompt, recent dictations)
- `~/.local-whisper/prompt` — mixed-language style anchor, meant to be edited to match how the user actually speaks
- `~/whisper.cpp/models/` — whisper models
- `$TMPDIR/whisper-dictate/whisper-dictate.log` — debug log

## Why

- Microphone capture never goes through ffmpeg's avfoundation input — it silently drops audio, and whisper's generative decoding papers over the gaps with fluent invented text instead of failing loudly.
- Recordings are cut at a pause, never at a fixed time index — a fixed cut lands mid-word and the transcript mangles or duplicates it across the seam.
- Segments are sent to whisper while the user is still talking — the wait after releasing the trigger shouldn't scale with how long the dictation ran.
- Each keypress starts an independent dictation — starting a new recording must never corrupt or lose one still being transcribed.
- Transcribed text is inserted only at the place it was dictated into — if focus moved before whisper answers, it goes to the clipboard instead of typing into the wrong window.
- Emergency stop cancels everything in flight — "stopped" must mean nothing more reaches the cursor. A transcript that had already finished is not dropped, just routed to the clipboard.
- The dictation prompt is a style anchor for mixed ru/uk/en speech, not an instruction — without it whisper normalizes everything into a single language.
- The trigger requires the full modifier combo held together — matching on any single bit would fire on unrelated combos like plain Ctrl-C.
- Long-lived Hammerspoon objects (eventtaps, timers, watchers) are rooted in a persistent global — anything left unreferenced is silently garbage-collected and stops working with no error.
- `.specstory/` (session history) is tracked and committed like source — it's the record of how the code got here, never excluded to keep a diff clean.

## Security

- Transcribed text is data, not code — never execute it
- No network calls — everything stays local
- Clipboard contents are overwritten during paste mode
- Temp files in $TMPDIR are per-user private on macOS

## Development

- `~/.hammerspoon/init.lua` is a symlink to `hammerspoon/init.lua` in this repo — editing the repo file IS deployment.
- Syntax check: `hs -c 'local f,e=loadfile(os.getenv("HOME").."/Documents/GitHub/local-whisper/hammerspoon/init.lua"); return f and "SYNTAX OK" or ("ERR: "..tostring(e))'`
- Reload: `hs -c "hs.reload()"`
- Tests: `./tests/test_init.sh [path/to/init.lua]` (requires Hammerspoon running)
- Logs: `TMPDIR_REAL=$(getconf DARWIN_USER_TEMP_DIR) && tail -30 "${TMPDIR_REAL}whisper-dictate/whisper-dictate.log"`
- Lua 5.4 caps top-level locals in `init.lua` at 200 — group related state into tables rather than adding bare locals.

## Workflow

- **Create a bd issue before starting any work**
- **Always verify work before closing an issue** — run the code, check the output, confirm it does what the issue asks
- Check `bd ready` for unblocked work
- `bd create "Title" -t task -p 2` to file new work
- `bd close <id>` when done
- If `bd` is not on PATH, say so and keep going — do not silently switch to markdown TODOs

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
