# local-whisper — Agent Guidelines

## Project overview

local-whisper is a fully-local macOS dictation tool. Hold **fn + left Control** to record, release to transcribe and insert text at cursor. Powered by whisper.cpp (C/C++, no Python) and Hammerspoon.

## Architecture

```
Hammerspoon eventtap (trigger combo hold/release, matched on raw device flags)
  → lw-record (native AVAudioEngine capture, 1s WAV chunks)
  ↓  streaming pipeline: every 3s, dispatch any pause-bounded ≤55s segment already on disk
  → ffmpeg concat → whisper-cli (chosen model — or the remote API), several may run at once
  ↓  (key released) → only the tail segment is left to transcribe
  → Post-processing (filler removal, app-aware capitalize)
  → Action hooks (voice commands, note-taking, app launching)
  → Text insertion at cursor (paste or keystroke)
  → Overlay + menu bar updates
```

Transcription **is** pipelined: segments are sent to whisper while the user is still
talking, so the wait after release does not scale with the recording length. Text is still
only inserted once every segment is back — there are no live partials on screen. Older docs
claiming "nothing is transcribed until the key is released" describe the gap between
`ac4c275` (which deleted the pipeline) and its restoration; see the streaming section below.

Everything runs inside `~/.hammerspoon/init.lua` — no external bash scripts at runtime.
The one compiled helper is `lw-record`; init.lua builds it on load when it is missing or
older than its source, so there is still no install step.

## Key paths

- `~/.hammerspoon/init.lua` — main config (overlay, recording, insertion, hotkeys, menu bar)
- `~/.hammerspoon/local_whisper_actions.lua` — user voice commands (optional, auto-reloads)
- `tools/lw-record.swift` — native mic recorder source (the only thing that opens the mic)
- `~/.local-whisper/bin/lw-record` — the compiled recorder, built by init.lua on load
- `~/.local-whisper/` — all user settings (lang, model, output, prompt, recent dictations)
- `~/.local-whisper/prompt` — mixed-language style anchor; seeded with a default on first run
- `~/whisper.cpp/build/bin/whisper-cli` — transcription binary
- `~/whisper.cpp/models/` — whisper models (medium, large-v3-turbo, etc.)
- `$TMPDIR/whisper-dictate/` — all temp state (per-user private dir on macOS)
- `$TMPDIR/whisper-dictate/chunks/` — recording segments (ephemeral)
- `$TMPDIR/whisper-dictate/whisper-dictate.log` — debug log

## Audio capture: never go back to ffmpeg for the microphone

ffmpeg's avfoundation **input device** hands over roughly 90% of what it captures. Measured
with a fixed output duration: a `-t 20` run took 21.11s of wall clock, ffmpeg reported a
20.00s timeline, and the file held **18.04s** of PCM. Every 1-second chunk it wrote came out
0.885–0.917s long, so the loss is spread evenly — about 100ms missing from every second.
That swallows short words whole and clips longer ones, and because whisper is generative it
papers over the gaps with fluent invented text. The transcript reads *better* than the truth
while missing words, which is exactly what makes it hard to notice.

None of these changed it: `-thread_queue_size`, `-drop_late_frames false`,
`-use_wallclock_as_timestamps 1`, `-capture_raw_data true`, `-audio_device_index`, `:0` vs
`:default`, dropping the segment muxer, or dropping the resampler (native 48kHz loses the
same). It is inside the indev.

`tools/lw-record.swift` taps AVAudioEngine's input node instead and loses nothing: chunks
come out at exactly `1.000000` s. ffmpeg is still correct — and still used — for segment
concat here and for all format conversion in `tools/transcribe.sh`. **Only the microphone
moved.** The `capture` checks in the test suite fail if `"avfoundation"` reappears as an
argument in init.lua.

Verify capture health any time — the log line is written after every recording:

```bash
TMPDIR_REAL=$(getconf DARWIN_USER_TEMP_DIR)
grep "recording: captured" "${TMPDIR_REAL}whisper-dictate/whisper-dictate.log" | tail -3
# → recording: captured 19.54s of 20.11s wall (97%)
# Anything near 90% means capture regressed. The remainder is device-open latency.
```

`lw-record` prints `READY` when its engine is actually running and `CAPTURED <secs>` on exit.
Both arrive on **stdout via the streaming callback** — `hs.task` routes stdout there whenever
a streaming callback is registered and leaves the termination callback's `out` empty, so
parsing `CAPTURED` at termination silently reads nil forever.

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

**Current count: ~134/200** — comfortable headroom after meeting mode, LLM refine, silence auto-stop and preferred languages were removed. Only *top-level* locals count against the limit; locals inside a function body belong to that function's own budget, so match the start of the line exactly:

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

### Segmenting: cut at a pause, never at a fixed index

Recordings longer than `FINAL_SEGMENT_SECS` (55s) are split and each piece is transcribed by
an **independent** whisper call. A fixed-index cut therefore lands mid-word and the word is
mangled or duplicated across the seam — a real transcript showed segment 1 ending
`...чтобы меня передавали.` and segment 2 opening `давали по звучанию.`

`splitAtSilence()` scans back up to 8s from the hard boundary for the quietest 1-second chunk
(`getWavRMS` reads the PCM directly, no subprocess) and cuts there instead, stopping early at
RMS < 300. It never moves the boundary earlier than halfway through the window, so an
unbroken passage is still bounded by `maxSecs`.

This was written once, deleted in the "remove dead features" cleanup, and restored. If you
are tempted to delete it again: the seam artifact it prevents is invisible in every check
except a long real dictation.

### Streaming pipeline: dispatch while the user is still talking

`streamCheckAndDispatch()` runs every 3s during recording. When more than
`FINAL_SEGMENT_SECS` of *unclaimed* chunks have accumulated, it takes `splitAtSilence`'s
first pause-bounded group and hands it to whisper immediately; `doFinalTranscription()` then
only has the tail left. For a 3-minute dictation that is the difference between waiting for
three segments and waiting for one.

The state lives in one `pipe` table (locals ceiling), and the ordering rule is that
`pipe.results[segN]` is assembled by index, so segments finishing out of order still
concatenate in the right order. `pipe.total` is only fixed once recording stops — until
then `onPipelineDone` must not touch the overlay, which belongs to the recording timer.

Two invariants, both covered by the `pipeline` checks in the test suite:

- **Every chunk is claimed exactly once.** Audio is handed out in two places — the live
  dispatcher and the tail — and if they disagree by one chunk, a second of speech is either
  missing or transcribed twice. Both outcomes read as a plausible sentence, so nothing but
  index accounting catches it. The tests mutate `pipe.nextChunk` by ±1 and both fail.
- **Nothing is dispatched before a real pause-bounded cut exists.** The guard is strictly
  `> FINAL_SEGMENT_SECS`: at exactly that many chunks `splitAtSilence` returns the whole
  list as its trailing "everything remaining" group, which is not a silence cut and is
  still growing.

Concurrent whisper does **not** disturb capture — measured, because this feature would
otherwise quietly undo the capture fix. With two `whisper-cli` runs overlapping a live
recording, every chunk still came out exactly `1.000000` s and the recorder reported 49.63s
over ~50s of wall clock. AVAudioEngine's input tap is real-time scheduled and Metal work
does not starve it. Re-measure with the `recording: captured` log line if this changes.

`emergencyStop()` calls `pipelineReset()` — otherwise segments already transcribed would
still be assembled and pasted a moment after the user asked for a stop. `pipelineReset` is
**forward-declared above `emergencyStop`** because the pipeline itself has to be defined
below `insertTranscribedText`; the `scope` check catches this exact mistake.

### Mixed-language speech (surzhyk, ru/uk/en)

Whisper decodes each window into exactly one language — there is no mixed mode. Left alone it
picks the dominant language and normalises everything else into it, rewriting Ukrainian words
as Russian and transliterating English terms. `-l auto` is applied **per segment**, so a long
dictation can even flip language mid-way.

The initial prompt is the only real lever, and it is a **writing sample, not an instruction**
— whisper continues in whatever style the prompt establishes. `~/.local-whisper/prompt` is
seeded on first run with a ru/uk/en sample and is meant to be edited to match how the user
actually speaks.

Both transcription paths must stay in sync on this:

- **local** — `getPromptArgs()` passes `--prompt` plus `--carry-initial-prompt`. Without the
  latter the anchor only applies to whisper's first internal 30s window and long segments
  drift back to single-language output.
- **remote API** — `transcribeViaAPI()` sends the same text as the `prompt` form field, plus
  `temperature=0`. Before this it sent no prompt at all, so the LAN model normalised the mix
  exactly as whisper-cli did. There is no `--carry-initial-prompt` equivalent over the wire.

`PROMPT_DEFAULT`/`readPrompt()` are declared **above** `transcribeViaAPI` on purpose — see the
declaration-order rule above.

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

### Simulating a keypress — and why a whole dictation is hard to fake

A posted flagsChanged event does reach the eventtap, so a synthetic press **starts** a
recording. Holding one is the hard part, because the session flag state updates
**asynchronously** — roughly 200ms behind the post:

```bash
hs -c 'local e=hs.eventtap.event.newEvent(); e:setType(hs.eventtap.event.types.flagsChanged)
       e:rawFlags(0x800001); e:post()
       return string.format("0x%x", hs.eventtap.checkKeyboardModifiers(true)._raw)'
# → 0x0        immediately after the post
# → 0x800000   if you sleep ~200ms first (fn survived, deviceLeftControl did not)
```

The release poller runs every 0.1s, so it checks *before* the flags land, reads "nothing
held", and cancels the recording — the log shows `warmup: cancelled (key released before
device ready)` about a second after you posted a press you never released. A real key does
not race this, because its flags are already set when the tap fires.

Two traps if you try anyway:

- Re-posting the press on a timer to "hold" it does not work — every post is a fresh
  flagsChanged event, so the tap sees press/release churn and starts and stops repeatedly.
  That can leave two recorders writing into the same `chunks/` directory.
- **Root every timer you create in a global.** An `hs.timer.doAfter` stored nowhere in an
  `hs -c` one-liner gets collected before it fires, so the loop that was supposed to stop
  the simulation never runs. This is the same GC rule as the runtime code, and it bites
  throwaway test snippets just as hard.

Prefer testing the two halves separately — they cover everything except the trigger itself,
which a single real keypress verifies in seconds:

```bash
# capture half: spawn the recorder exactly as Hammerspoon does (inherits its mic permission)
hs -c 'LWT = hs.task.new(os.getenv("HOME").."/.local-whisper/bin/lw-record",
         function(c) print("exit "..tostring(c)) end, function() return true end,
         {"/tmp/lwtest","1","16000"}); LWT:start(); return "started"'
sleep 8; hs -c 'LWT:interrupt()'
# every chunk must be exactly 1.000000s

# transcribe half: run the real whisper args over any WAV
~/whisper.cpp/build/bin/whisper-cli -m ~/whisper.cpp/models/ggml-large-v3-turbo-q5_0.bin \
  -f /tmp/lwtest/chunk_000.wav -l auto -nt \
  --prompt "$(cat ~/.local-whisper/prompt)" --carry-initial-prompt
```

If you do run a full dictation, set `~/.local-whisper/output` to `copy` first and restore it
afterwards — otherwise the transcript is pasted into whatever window happens to be focused.

Note that synthesised speech (`say -v Milena`) is a poor quality probe: it is clean and
well-separated enough that whisper transcribes it perfectly even from audio missing 10% of
its samples. It validates that the pipeline runs, not that it transcribes well.

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
| `capture` | the microphone going back through ffmpeg's avfoundation input (drops ~10% of every recording); the recorder no longer being invoked; the `CAPTURED` health check being parsed where `hs.task` leaves it empty |
| `split` | a segment boundary cutting mid-word instead of at a pause, and — the invariant that matters most — regrouping losing or duplicating a chunk |
| `pipeline` | live dispatch silently reverting to transcribe-after-release; the live dispatcher and the tail disagreeing by a chunk, so a second of speech is dropped or transcribed twice |
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
