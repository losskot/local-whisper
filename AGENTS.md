# local-whisper — Agent Guidelines

## Project overview

local-whisper is a fully-local macOS dictation tool. Hold **fn + left Control** to record, release to transcribe and insert text at cursor. Powered by whisper.cpp (C/C++, no Python) and Hammerspoon.

## Architecture

```
Hammerspoon eventtap (trigger combo hold/release, matched on raw device flags)
  → ffmpeg (chunked WAV recording, 1s segments)
  → whisper-cli (transcription, 55s segments, chosen model — or the remote API)
  → Post-processing (filler removal, app-aware capitalize)
  → Action hooks (voice commands, note-taking, app launching)
  → Text insertion at cursor (paste or keystroke)
  → Overlay + menu bar updates
```

Transcription is not streamed: nothing is transcribed until the key is released. Older
docs describing live partials, silence-aware splitting, or chained segment prompts
describe code that no longer exists.

Everything runs inside `~/.hammerspoon/init.lua` — no external bash scripts at runtime.

## Key paths

- `~/.hammerspoon/init.lua` — main config (overlay, recording, insertion, hotkeys, menu bar)
- `~/.hammerspoon/local_whisper_actions.lua` — user voice commands (optional, auto-reloads)
- `~/.local-whisper/` — all user settings (lang, model, output, prompt, recent dictations)
- `~/whisper.cpp/build/bin/whisper-cli` — transcription binary
- `~/whisper.cpp/models/` — whisper models (medium, large-v3-turbo, etc.)
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

**Current count: ~121/200** — comfortable headroom after meeting mode, LLM refine, silence auto-stop and preferred languages were removed. Only *top-level* locals count against the limit; locals inside a function body belong to that function's own budget, so match the start of the line exactly:

```bash
grep -c '^local ' hammerspoon/init.lua
```

**Rule**: Never add a new top-level `local` without first verifying the count stays ≤ 200. If the count climbs back toward the ceiling, group related state into a single table rather than adding bare locals — `finalizeTimers` (`{ timer, watchdog }`) and `TRIGGERS` (per-trigger `{ mask, label }`) are the existing examples of that pattern.

### Declaration order matters as much as the count

A `local` is only in scope for code that appears *after* its declaration. A function defined earlier in the file that references the name does **not** capture it — the reference silently compiles to a global lookup that reads `nil` at runtime, with no error at load time. This produced three separate live bugs in the overlay code (X button, unpin, pinning from the menu bar).

`overlayPinned`, `isRecording`, and the `hideOverlay` forward declaration therefore sit **above** `createOverlay`, whose mouse callback closes over all three. When adding state that a callback touches, declare it above every function that references it.

### Long-lived objects must be rooted in a global, or the GC unregisters them

Hammerspoon collects eventtaps, repeating timers and watchers that nothing in Lua still
references, and collecting one **unregisters it from the system**. There is no error, no log
line, and `isEnabled()` keeps returning `true` right up to the collection — the object simply
stops receiving events.

init.lua's own top-level locals are **not** a root. Once the chunk returns, a local survives
only while a reachable closure captures it, so a chain of collectible objects (a timer that
was never stored holding the tap) collapses all at once. Everything that must outlive the
chunk therefore goes into the `LocalWhisper` table:

```lua
LocalWhisper.modTap       = modTap        -- the trigger eventtap
LocalWhisper.tapWatchdog  = hs.timer.doEvery(5, ...)
LocalWhisper.sleepWatcher = sleepWatcher
```

This is the bug that made the trigger "work right after a reload and die a few minutes
later". The `_whisper` global that was deleted as dead state was in fact the only strong
reference to the eventtap. Verify a change here by forcing collection and then posting an
event — the tap must still respond:

```bash
hs -c 'collectgarbage("collect"); collectgarbage("collect")
       local e=hs.eventtap.event.newEvent(); e:setType(hs.eventtap.event.types.flagsChanged)
       e:rawFlags(0x840001); e:post()'
# → the log must show a new "warmup: probing audio device..." line
```

### The trigger is a modifier combo

`TRIGGER_KEY` selects an entry from the `TRIGGERS` table; the default `fnLeftCtrl` ORs
`secondaryFn` with `deviceLeftControl`. Two rules follow from it being a *combo* rather
than a single modifier:

- Match with `(rawFlags & mask) == mask`, never `> 0` — the latter fires on either half,
  so plain Control would start a recording on every Ctrl-C.
- Press and release are read through **different APIs that report different bits**, so each
  trigger carries two masks. The flagsChanged event's `rawFlags` include the device-specific
  bits (`deviceLeftControl` = 0x1) — that is `mask`. The release poller reads
  `hs.eventtap.checkKeyboardModifiers(true)._raw`, which comes from `CGEventSourceFlagsState`
  and reports **only the generic bits** — that is `heldMask`.

Verify it yourself: post a synthetic event and read the state back.

```bash
hs -c 'local e=hs.eventtap.event.newEvent(); e:setType(hs.eventtap.event.types.flagsChanged)
       e:rawFlags(0x800001); e:post()
       return string.format("0x%x", hs.eventtap.checkKeyboardModifiers(true)._raw)'
# → 0x800000   (fn survived, deviceLeftControl did not)
```

A device bit in `heldMask` can therefore never match: the overlay flashes for one poll tick
and the recording dies 0.1s in, which reads to the user as "the key binding does nothing,
I don't even see the UI". Both rules are covered by the `trigger` checks in the test suite —
including one that fails if any device bit appears in a `heldMask`.

### Simulating a whole dictation without touching the keyboard

Posted flagsChanged events update the session flag state, so a synthetic press is held from
the app's point of view until you post the release — the release poller sees the generic bits
and keeps recording. This exercises the real pipeline end to end:

```bash
hs -c 'local function f(x) local e=hs.eventtap.event.newEvent()
         e:setType(hs.eventtap.event.types.flagsChanged); e:rawFlags(x); return e end
       f(0x840001):post()                                   -- fn + control + deviceLeftControl
       hs.timer.doAfter(6, function() f(0):post() end)'
```

Set `~/.local-whisper/output` to `copy` first and restore it afterwards — otherwise the
transcript is pasted into whatever window happens to be focused.

## Testing & debugging

### Reading logs
```bash
TMPDIR_REAL=$(getconf DARWIN_USER_TEMP_DIR) && tail -30 "${TMPDIR_REAL}whisper-dictate/whisper-dictate.log"
```
Note: `$TMPDIR` inside a sandbox may differ from the real user TMPDIR. Always use `getconf DARWIN_USER_TEMP_DIR` for reliable access.

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
| `meeting`, `refine`, `preferred`, `autostop`, `undo`, `whisperprobe` | a deleted subsystem creeping back in (meeting mode, LLM refine/Ollama, preferred languages, silence auto-stop, undo tracking, the `_whisper` global) |
| `trigger` | a combo trigger matched with `> 0` so half of it fires; a release poller polling bits the poll API never reports |
| `lifetime` | an eventtap, watcher or repeating timer left unrooted, which the GC silently unregisters mid-session |
| `globals` | state leaked into Hammerspoon's shared `_ENV` |
| `sort` | chunk files ordered as strings, which reorders audio past chunk 999 |
| `emergencyStop` | emergency stop not cancelling a pending finalization |
| `overlay` | clicking the X mid-recording leaving ffmpeg running; deleting the canvas from inside its own mouse callback; unpinning hiding the overlay while still recording |
| `startRecording` | a re-press inside the finalization window flushing the old dictation but swallowing the new keypress |
| `progress` | the blue transcription bar never catching the red recording bar, because a live clock re-trips the 90% auto-expand after recording stops |

The behavioral checks lift the real function out of the source under test — the sort
comparator, the overlay mouse callback, `startRecording()`, `updateProgressBar()`,
`triggerPressed()`/`triggerHeld()` — and
execute it against stubbed globals, so they track the implementation instead of a copy
that can drift. A lifted function's upvalues resolve to the sandbox `_ENV`, which is what
lets a test both inject state (`isRecording = true`) and assert on it afterwards
(`overlayPinned == false`).

Three behaviors remain untestable here and need a manual pass after touching the overlay:
whether the canvas actually disappears on screen, whether macOS delivers the click to the
X at all, and how the bars look while a real transcription runs.

Because the suite takes a path argument, you can point it at an older revision — or at a
deliberately broken copy — to confirm a check actually fails on the bug it claims to guard:
```bash
git show HEAD~1:hammerspoon/init.lua > /tmp/before.lua && ./tests/test_init.sh /tmp/before.lua
```
Prefer a one-line mutation of the *current* file over an old revision when checking a
specific guard: an old revision fails for many unrelated reasons at once, and a lifted
function whose helpers were since renamed fails by erroring rather than by asserting.

### Common debug patterns
- **Trigger does nothing**: the log shows no `warmup:` line at all — check that the keyboard actually has an `fn` key and that Hammerspoon still holds Accessibility permission
- **Voice commands not matching**: Check `final (auto/...)` log line — whisper may have transcribed differently than expected
- **X button not closing overlay**: `hs.canvas:delete()` inside its own mouse callback is silently ignored — must use `canvas:hide()` immediately then defer deletion with `hs.timer.doAfter(0.01, ...)`
- **Recent dictations not persisting**: Lua upvalue scoping — never reassign a table variable that closures reference; populate in-place instead

### Hammerspoon canvas gotchas
- `hs.eventtap.checkKeyboardModifiers(true)._raw` reports only generic modifier bits — every `deviceLeft*`/`deviceRight*` bit an event carries is missing there (see the trigger section)
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
- If `bd` is not on PATH, say so and keep going — do not silently switch to markdown TODOs

### `.specstory/` is code

`.specstory/` (session history, debug dumps, statistics) is **tracked, committed and pushed
like any source file**. Do not stash it, do not `.gitignore` it, do not leave it dirty at the
end of a session, and never exclude it to keep a diff "clean" — `git add -A` and push it with
the rest of the work. It is the record of how the code got here.

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
