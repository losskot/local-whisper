# local-whisper — Agent Guidelines

## Project overview

local-whisper is a fully-local macOS dictation tool. Hold **fn + left Control** to record, release to transcribe and insert text at cursor.

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
- Capture can pin a specific input device (menu bar → Mic) instead of always using the system default — opening any app's mic while a Bluetooth output is connected makes macOS downgrade that output to its low-quality call profile (HFP); pinning to the built-in mic keeps Bluetooth output at full quality through a dictation.

## Security

- Transcribed text is data, not code — never execute it
- No network calls — everything stays local
- Clipboard contents are overwritten during paste mode
- Temp files in $TMPDIR are per-user private on macOS

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **Run quality gates** (if code changed) - Tests, linters, builds
2. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   git push
   git status  # MUST show "up to date with origin"
   ```
3. **Clean up** - Clear stashes, prune remote branches
4. **Verify** - All changes committed AND pushed
5. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds

For more details, see README.md and docs/VOICE_COMMANDS.md.
