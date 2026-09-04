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
- The voice trigger is a separate ~860 KB binary classifier (openWakeWord, "hey mycroft"), never whisper on a rolling window — whisper invents words on near-silence, which is what the HALLUCINATIONS list exists to clean up after, and running it always-on would make that failure constant instead of occasional.
- What always-on listening actually costs is the open microphone, not the model — measured here, holding capture open adds ~4.5 pp to coreaudiod plus ~0.9 pp for lw-record, and macOS takes a `PreventUserIdleSystemSleep` assertion named `com.apple.audio.BuiltInMicrophoneDevice.context.preventuseridlesleep` for exactly as long as the device is open.
- The listener follows the screen, not the system — while the screen is on, powerd already holds that identical sleep assertion ("Prevent sleep while display is on"), so an open microphone adds nothing to it; when the screen sleeps the daemon goes down and the device is released. Voice deliberately cannot wake a sleeping machine: that would mean holding the microphone open around the clock to save a keypress.
- The listener runs only on mains power — the microphone is the expensive half of the feature and this is a fanless Air, so `hs.battery.watcher` tears it down on unplug and revives it on plug-in; a machine reporting a nil power source has no battery and counts as plugged in.
- The daemon fires through a `hammerspoon://` URL, never the `hs` CLI — the CLI is a synchronous round-trip to Hammerspoon's main thread and blocks for seconds exactly when a trigger arrives (while a recording is starting), sometimes never returning at all; a URL event is delivered asynchronously, so a busy Hammerspoon delays the trigger instead of losing it.
- The trigger call runs on its own thread, whatever the channel — `open` is a process spawn, and any stall in the read loop makes the daemon deaf for its duration, which is exactly when a user who saw nothing happen repeats the word.
- Which wake word suits a voice is measured with `tools/lw-wake-score.sh`, never chosen by ear or by guideline — on the author's voice "hey mycroft" peaks at 1.000 across 10 consecutive frames while "hey jarvis" reaches 0.968 in a single frame and "hey rhasspy" never crosses 0.05; a word that feels close can score nothing at all. A solid word holds above threshold for several frames in a row, and one frame over the line is a coin flip in a real room.
- That scoring tool deliberately does not transcribe the attempts — a transcript is text, and whisper normalises whatever it hears into the nearest familiar word, so it is evidence about vocabulary rather than about the sounds produced; the wake model's own score is the only direct measurement.
- Only the selected word is armed, so saying a different candidate cannot fire anything however well it would score — a fact worth stating plainly, because "it did not react to X" reads as a model failure when X was never loaded.
- The wake word is switchable from the menu because the code cannot know which word a given voice will actually produce — a Russian speaker reaching for "mycroft" lands on "Minecraft", which scores zero rather than merely below threshold.
- The detection threshold is 0.95, not openWakeWord's documented 0.5 — across 114 minutes (85,500 frames) of this machine's own archived ru/uk/en dictation exactly two frames crossed 0.5, at 0.564 and 0.900, while a genuine "hey mycroft" scores 0.998-1.000 and holds it for eight consecutive frames.
- The daemon skips inference on quiet frames but keeps a ~1 s pre-roll and replays it when the room gets loud — dropping quiet frames outright would hand the model an empty history exactly when the wake word arrives and score it far below a phrase it had heard the approach to.
- openWakeWord's default tflite-runtime backend has no macOS distribution at all (pip: "No matching distribution found"), which reads like a broken environment rather than an unsupported platform — the onnx backend is forced in lw-wake.py and installed explicitly by lw-wake-setup.sh; neither half of that pairing may be dropped.
- `lw-record -` streams raw PCM to stdout instead of writing WAV chunks, and the wake daemon consumes that rather than opening its own device — ffmpeg's avfoundation input drops ~10% of samples and PortAudio would be a new dependency on an unverified capture path, while lw-record is the one capture already proven here not to lose audio.
- The two halves of the listener pipeline die together by design — lw-record terminates itself when its stdout write fails and lw-wake exits on stdin EOF — because hs.task:terminate() signals only the process Hammerspoon spawned, and an orphaned recorder would hold the microphone open forever.
- The "API" model setting is a combined mode, not a plain remote/local switch — the endpoint is probed in parallel with recording (started at key-down, not after release) so the answer is ready before the first segment needs it; if it doesn't respond, or a request to it fails mid-dictation, transcription silently drops to the local fallback model (`API.FALLBACK_MODEL` in init.lua, currently large-v3-turbo-q5_0 — the model the model-comparison test recommended, not large-v3, which hallucinates harder and can hang for minutes on short clips) for the rest of that recording instead of erroring or waiting out the API's own timeout on every segment.

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
