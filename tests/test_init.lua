-- test_init.lua — structural and behavioral tests for hammerspoon/init.lua
--
-- Run via tests/test_init.sh (which drives it through the Hammerspoon `hs` CLI,
-- since there is no standalone Lua interpreter in this stack).
--
-- These tests guard the bug classes that have actually bitten this file:
--   * a top-level local referenced by an earlier-defined function, which silently
--     compiles to a nil global instead of capturing the local
--   * the Lua 200-local-per-function ceiling
--   * unguarded hs.sound.getByFile(...):play(), which throws and aborts its callback
--   * chunk filenames sorted as strings, which reorders audio past chunk 999
--   * a modifier-combo trigger matched with `flags & mask > 0`, which fires on half
--     the combo -- every Ctrl-C would start a recording
--   * removed subsystems (meeting mode, LLM refine, silence auto-stop, ...) creeping back
--
-- Config (set as globals by the runner; `hs` does not inherit the caller's environment):
--   LW_TARGET  path to the init.lua under test (default: repo copy)
--   LW_OUT     path to write results to (default: /tmp/lw_test_init.txt)

local HOME   = os.getenv("HOME")
local TARGET = _G.LW_TARGET or (HOME .. "/Documents/GitHub/local-whisper/hammerspoon/init.lua")
local OUT    = _G.LW_OUT or "/tmp/lw_test_init.txt"

--------------------------------------------------------------------------------
-- Harness
--------------------------------------------------------------------------------

local results = {}

local function record(name, passed, detail)
    results[#results + 1] = {
        name   = name,
        passed = passed and true or false,
        detail = detail or "",
    }
end

local function check(name, passed, detail)
    record(name, passed, passed and "" or (detail or ""))
end

--------------------------------------------------------------------------------
-- Source loading + lexical helpers
--------------------------------------------------------------------------------

local function readSource(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local src = f:read("*a")
    f:close()
    return src
end

local src = readSource(TARGET)
if not src then
    record("source readable", false, "cannot open " .. TARGET)
    local f = io.open(OUT, "w")
    f:write("FAIL\tsource readable\tcannot open " .. TARGET .. "\n")
    f:close()
    return
end

local lines = {}
for line in (src .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
end

-- Blank out string literals and comments so scans don't match inside them.
local function strip(line)
    line = line:gsub('"[^"]*"', '""')
    line = line:gsub("'[^']*'", "''")
    line = line:gsub("%-%-.*$", "")
    return line
end

local stripped = {}
for i, l in ipairs(lines) do stripped[i] = strip(l) end

-- Word-boundary match for an identifier.
local function usesName(line, name)
    return line:find("%f[%w_]" .. name .. "%f[^%w_]") ~= nil
end

-- Blank out identifier occurrences that are not variable *reads*, so the
-- use-before-declaration scan doesn't fire on them:
--   * field access / method call  -- obj.name, obj:name
--   * assignment targets and table-constructor keys -- name = ..., { name = ... }
-- A read of `name` on the right-hand side survives, which is what the scan wants.
local function readsOnly(s)
    s = s:gsub("%.%s*[%w_]+", " ")
    s = s:gsub(":%s*[%w_]+", " ")
    s = s:gsub("[%w_]+%s*=[^=]", " ")
    return s
end

--------------------------------------------------------------------------------
-- Sandbox helpers (behavioral tests)
--------------------------------------------------------------------------------
-- Functions are lifted out of the source under test and executed against stubbed
-- globals, so the tests exercise the real implementation rather than a copy that
-- drifts. Every name the lifted function closes over in init.lua resolves to the
-- sandbox _ENV here, which is what makes the stubs and the after-the-fact state
-- assertions work.

local function baseEnv()
    return {
        math = math, string = string, table = table, os = os,
        tostring = tostring, tonumber = tonumber, type = type,
        ipairs = ipairs, pairs = pairs, select = select,
    }
end

local function loadIn(chunk, env, name)
    return load(chunk, name or "sandbox", "t", env)
end

-- Source text of a top-level `local function NAME(...) ... end`, located by its
-- declaration and terminated by the matching column-0 `end`.
local function extractFunction(name)
    local startLine
    for i, s in ipairs(stripped) do
        if s:match("^local%s+function%s+" .. name .. "%s*%(") then startLine = i break end
    end
    if not startLine then return nil end
    for i = startLine + 1, #lines do
        if stripped[i]:match("^end%s*$") then
            return table.concat({ table.unpack(lines, startLine, i) }, "\n")
        end
    end
    return nil
end

-- Load a lifted `local function` and return it, bound to `env`.
local function liftFunction(name, env)
    local fnSrc = extractFunction(name)
    if not fnSrc then return nil, "could not locate local function " .. name .. "()" end
    local factory, err = loadIn(fnSrc .. "\nreturn " .. name, env, name)
    if not factory then return nil, tostring(err) end
    return factory()
end

--------------------------------------------------------------------------------
-- 1. Syntax
--------------------------------------------------------------------------------

local chunk, loadErr = loadfile(TARGET)
check("syntax: file compiles", chunk ~= nil, tostring(loadErr))

--------------------------------------------------------------------------------
-- 2. Lua 200-local-per-function ceiling (AGENTS.md hard limit)
--------------------------------------------------------------------------------

local topLevelLocals = 0
for _, s in ipairs(stripped) do
    if s:match("^local%s") then topLevelLocals = topLevelLocals + 1 end
end
check("locals: top-level count within Lua's 200 ceiling",
      topLevelLocals <= 200,
      "found " .. topLevelLocals .. " top-level locals (limit 200)")

--------------------------------------------------------------------------------
-- 3. No top-level local referenced before it is declared
--------------------------------------------------------------------------------
-- A `local` is only in scope after its declaration. A function defined earlier that
-- references the name does NOT capture it -- the reference compiles to a global read
-- that is nil at runtime, with no load-time error. This produced three live bugs in
-- the overlay code (X button, unpin, menu-bar pinning).

-- Collect top-level declarations: name -> first declaring line.
local decls = {}
for i, s in ipairs(stripped) do
    local fname = s:match("^local%s+function%s+([%w_]+)")
    if fname then
        decls[fname] = decls[fname] or i
    else
        local names = s:match("^local%s+([%w_%s,]-)%s*=") or s:match("^local%s+([%w_%s,]+)%s*$")
        if names then
            for n in names:gmatch("[%w_]+") do
                if n ~= "function" then decls[n] = decls[n] or i end
            end
        end
    end
end

-- A name is "shadowed" before line `upto` if some earlier line binds it as a local,
-- a function parameter, or a loop variable -- in which case an earlier textual use
-- refers to that binding, not to the top-level one, and is not a bug.
local function shadowedBefore(name, upto)
    for i = 1, upto - 1 do
        local s = stripped[i]
        if s:match("%f[%w_]local%f[^%w_][^=]*%f[%w_]" .. name .. "%f[^%w_]") then return true end
        if s:match("%f[%w_]for%f[^%w_][^=]*%f[%w_]" .. name .. "%f[^%w_]") then return true end
        local params = s:match("function%s*(%b())")
        if params and usesName(params, name) then return true end
    end
    return false
end

local violations = {}
for name, declLine in pairs(decls) do
    for i = 1, declLine - 1 do
        if usesName(readsOnly(stripped[i]), name) and not shadowedBefore(name, i + 1) then
            violations[#violations + 1] = string.format("%s used at L%d, declared at L%d", name, i, declLine)
            break
        end
    end
end
table.sort(violations)
check("scope: no top-level local used before its declaration",
      #violations == 0,
      table.concat(violations, "; "))

--------------------------------------------------------------------------------
-- 4. No unguarded system-sound playback
--------------------------------------------------------------------------------
-- hs.sound.getByFile returns nil when the file is missing or AudioToolbox fails to
-- load it; indexing that nil throws and aborts whatever callback is mid-flight,
-- which previously stranded the overlay on screen. All playback goes through
-- playSound(), which nil-checks.

local unguarded = {}
for i, s in ipairs(stripped) do
    if s:find("hs%.sound%.getByFile%s*%b()%s*:%s*play") then
        unguarded[#unguarded + 1] = "L" .. i
    end
end
check("sound: no unguarded getByFile():play()",
      #unguarded == 0,
      "unguarded playback at " .. table.concat(unguarded, ", "))

--------------------------------------------------------------------------------
-- 5. Deleted subsystems stay deleted
--------------------------------------------------------------------------------
-- Each of these was removed deliberately. Patterns run against the stripped source,
-- so a mention in a comment or a string literal does not trip them -- only real code.

local REMOVED = {
    { name = "meeting",     what = "meeting-mode",
      patterns = { "%f[%w]meeting", "blackhole", "aggregate" } },
    { name = "refine",      what = "LLM refinement / Ollama",
      patterns = { "%f[%w]refine", "ollama" } },
    { name = "preferred",   what = "preferred-languages",
      patterns = { "preferred" } },
    { name = "autostop",    what = "silence auto-stop",
      patterns = { "checksilence", "silentchunk", "silencetimer",
                   "lastcheckedchunk", "auto_stop", "volumedetect" } },
    { name = "undo",        what = "undo tracking",
      patterns = { "lastinsertedtext" } },
    { name = "whisperprobe", what = "_whisper state-probe global",
      patterns = { "%f[%w_]_whisper%f[^%w_]" } },
}

for _, sub in ipairs(REMOVED) do
    local hits = {}
    for i, s in ipairs(stripped) do
        local low = s:lower()
        for _, pat in ipairs(sub.patterns) do
            if low:find(pat) then hits[#hits + 1] = "L" .. i break end
        end
    end
    check(sub.name .. ": no " .. sub.what .. " code remains",
          #hits == 0,
          "found at " .. table.concat(hits, ", "))
end

--------------------------------------------------------------------------------
-- 6. No unintended top-level globals
--------------------------------------------------------------------------------
-- AGENTS.md: never leak state into Hammerspoon's shared _ENV, where another config
-- or Spoon can collide with it. A short allowlist covers the deliberate ones.

local allowedGlobals = {
    LocalWhisper   = true,  -- GC root for the eventtap, its watchdog and the sleep watcher
    WhisperActions = true,  -- user-facing action-hook API
    emergencyStop  = true,  -- called from the overlay callback and the menu bar
    updateMenuBar  = true,
}

-- `decls` holds every top-level local, including forward declarations. Assigning to
-- one of those (e.g. `hideOverlay = function() ... end`) writes the local, not a global.
local leaked = {}
for i, s in ipairs(stripped) do
    -- top-level `name = ...` (not local, not indented, not a comparison)
    local name = s:match("^([%w_]+)%s*=[^=]")
    if name and not allowedGlobals[name] and not decls[name] then
        leaked[#leaked + 1] = name .. " (L" .. i .. ")"
    end
    local gfn = s:match("^function%s+([%w_]+)%s*%(")
    if gfn and not allowedGlobals[gfn] and not decls[gfn] then
        leaked[#leaked + 1] = gfn .. "() (L" .. i .. ")"
    end
end
check("globals: no unintended top-level globals",
      #leaked == 0,
      "leaked: " .. table.concat(leaked, ", "))

--------------------------------------------------------------------------------
-- 7. Chunk ordering (behavioral -- exercises the real comparator)
--------------------------------------------------------------------------------
-- The comparator is extracted from the source under test rather than reimplemented,
-- so this test tracks the real implementation instead of a copy that can drift.

local cmpSrc = src:match("table%.sort%(chunks,%s*(function%s*%(a,%s*b%).-end)%)")
if not cmpSrc then
    check("sort: comparator is extractable from source", false,
          "could not locate table.sort(chunks, function(a, b) ... end)")
else
    check("sort: comparator is extractable from source", true)
    local factory, err = load("return " .. cmpSrc)
    if not factory then
        check("sort: comparator compiles", false, tostring(err))
    else
        check("sort: comparator compiles", true)
        local cmp = factory()

        -- ffmpeg writes chunk_%03d.wav, which overflows past 999. Build an
        -- out-of-order list spanning the overflow boundary.
        local indices = { 1200, 3, 1000, 999, 0, 100, 1001, 99, 1 }
        local files = {}
        for _, n in ipairs(indices) do
            files[#files + 1] = string.format("/tmp/chunks/chunk_%03d.wav", n)
        end
        table.sort(files, cmp)

        local got = {}
        for _, f in ipairs(files) do got[#got + 1] = tonumber(f:match("chunk_(%d+)%.wav$")) end

        local expect = { 0, 1, 3, 99, 100, 999, 1000, 1001, 1200 }
        local same = #got == #expect
        if same then
            for i = 1, #expect do
                if got[i] ~= expect[i] then same = false break end
            end
        end
        check("sort: chunks order numerically across the 999 boundary", same,
              "got " .. table.concat(got, ",") .. " want " .. table.concat(expect, ","))

        -- Guard the specific regression: 999 must precede 1000, which plain
        -- lexicographic sorting gets wrong ("chunk_1000" < "chunk_999").
        local pos = {}
        for i, n in ipairs(got) do pos[n] = i end
        check("sort: chunk 999 precedes chunk 1000 (lexicographic would not)",
              pos[999] and pos[1000] and pos[999] < pos[1000],
              "999 at index " .. tostring(pos[999]) .. ", 1000 at index " .. tostring(pos[1000]))
    end
end

--------------------------------------------------------------------------------
-- 8. Chunk filename pattern stays in sync between writer and reader
--------------------------------------------------------------------------------
-- ffmpeg's -segment output template and the sort comparator's pattern must agree;
-- changing one without the other silently breaks ordering again.

local writerPattern = src:find('chunk_%%03d%.wav', 1, false) ~= nil
local readerPattern = src:find('chunk_%(%%d%+%)%%%.wav', 1, false) ~= nil
check("sort: ffmpeg output template and comparator pattern agree",
      writerPattern and readerPattern,
      "writer chunk_%03d.wav=" .. tostring(writerPattern) ..
      ", reader chunk_(%d+)%.wav=" .. tostring(readerPattern))

--------------------------------------------------------------------------------
-- 9. Emergency stop cancels pending finalization
--------------------------------------------------------------------------------
-- Otherwise the timer armed by stopRecording() still fires after the user hits
-- Emergency Stop, and pastes the transcript into whatever is focused by then.

local esStart, esEnd
for i, s in ipairs(stripped) do
    if s:match("^function%s+emergencyStop%s*%(") then esStart = i end
    if esStart and not esEnd and i > esStart and s:match("^end%s*$") then esEnd = i end
end
if not (esStart and esEnd) then
    check("emergencyStop: function body is locatable", false, "could not find emergencyStop()")
else
    check("emergencyStop: function body is locatable", true)
    local body = table.concat({ table.unpack(stripped, esStart, esEnd) }, "\n")
    check("emergencyStop: clears finalizationPending",
          body:find("finalizationPending%s*=%s*false") ~= nil,
          "emergencyStop() does not clear finalizationPending")
    check("emergencyStop: stops the finalization timers",
          body:find("finalizeTimers%.timer") ~= nil and body:find("finalizeTimers%.watchdog") ~= nil,
          "emergencyStop() does not stop finalizeTimers.timer/.watchdog")
end

--------------------------------------------------------------------------------
-- 10. Overlay state is declared above the callback that closes over it
--------------------------------------------------------------------------------
-- The generic scan above is heuristic; these three names are the ones that actually
-- broke (X button, unpin, menu-bar pinning), so pin the invariant explicitly.

local createLine
for i, s in ipairs(stripped) do
    if s:match("^local%s+function%s+createOverlay%s*%(") then createLine = i break end
end
if not createLine then
    check("overlay: createOverlay() is locatable", false, "could not find createOverlay()")
else
    check("overlay: createOverlay() is locatable", true)
    local late = {}
    for _, name in ipairs({ "overlayPinned", "isRecording", "hideOverlay" }) do
        if not decls[name] or decls[name] > createLine then
            late[#late + 1] = name .. " (declared at L" .. tostring(decls[name]) .. ")"
        end
    end
    check("overlay: pin/recording state is declared above createOverlay",
          #late == 0,
          "declared below createOverlay (L" .. createLine .. "): " .. table.concat(late, ", "))
end

--------------------------------------------------------------------------------
-- 11. Overlay click behavior (behavioral -- runs the real mouse callback)
--------------------------------------------------------------------------------
-- Two live bugs live here: clicking X mid-recording used to hide the overlay while
-- ffmpeg kept running, and deleting the canvas from inside its own mouse callback is
-- silently ignored by hs.canvas, so the delete must stay deferred.

local cbSrc = src:match("overlay:mouseCallback(%b())")
if not cbSrc then
    check("overlay: mouse callback is extractable from source", false,
          "could not locate overlay:mouseCallback(function(canvas, event, id, ...) ... end)")
else
    check("overlay: mouse callback is extractable from source", true)

    -- Click the overlay and return the resulting stub state. Deferred work is captured
    -- rather than run, so a test can assert on both sides of the hs.timer.doAfter.
    local function click(opts)
        local env    = baseEnv()
        local calls  = { hide = 0, delete = 0, emergency = 0, hideOverlay = 0 }
        local defer  = {}
        local canvas = {
            [1]    = { fillColor = {} },
            hide   = function() calls.hide = calls.hide + 1 end,
            delete = function() calls.delete = calls.delete + 1 end,
        }
        env.log           = function() end
        env.isRecording   = opts.recording and true or false
        env.overlayPinned = opts.pinned and true or false
        env.overlay       = canvas
        env.emergencyStop = function() calls.emergency = calls.emergency + 1 end
        env.hideOverlay   = function() calls.hideOverlay = calls.hideOverlay + 1 end
        env.hs = { timer = { doAfter = function(d, fn) defer[#defer + 1] = { delay = d, fn = fn } end } }

        local factory, err = loadIn("return " .. cbSrc, env, "mouseCallback")
        if not factory then return nil, tostring(err) end
        -- A raw error here would abort the whole suite, so report it as a failure instead.
        local ok, runErr = pcall(factory(), canvas, opts.event, opts.id, 0, 0)
        if not ok then return nil, "callback errored: " .. tostring(runErr) end
        return { env = env, calls = calls, defer = defer, canvas = canvas }
    end

    local probe, probeErr = click({ event = "mouseDown", id = "close", recording = true })
    check("overlay: mouse callback compiles", probe ~= nil, tostring(probeErr))

    if probe then
        -- X mid-recording: hide now, tear down on the deferred pass.
        check("overlay: X hides the canvas immediately",
              probe.calls.hide == 1, "canvas:hide() called " .. probe.calls.hide .. " times")
        check("overlay: X defers the canvas delete (deleting inside the callback is ignored)",
              #probe.defer == 1 and probe.calls.delete == 0,
              #probe.defer .. " deferred call(s), delete called " .. probe.calls.delete .. " times synchronously")

        if #probe.defer == 1 then
            probe.defer[1].fn()
            check("overlay: X during recording stops the recording",
                  probe.calls.emergency == 1,
                  "emergencyStop() called " .. probe.calls.emergency .. " times")
            check("overlay: X during recording leaves teardown to emergencyStop",
                  probe.calls.delete == 0,
                  "overlay:delete() called directly instead of via emergencyStop()")
            check("overlay: X unpins the overlay",
                  probe.env.overlayPinned == false,
                  "overlayPinned = " .. tostring(probe.env.overlayPinned))
        end

        -- X while idle: no recording to stop, so the callback owns the teardown.
        local idle = click({ event = "mouseDown", id = "close", recording = false, pinned = true })
        if idle and #idle.defer == 1 then
            idle.defer[1].fn()
            check("overlay: X while idle deletes the overlay and clears the handle",
                  idle.calls.delete == 1 and idle.env.overlay == nil,
                  "delete called " .. idle.calls.delete .. " times, overlay = " .. tostring(idle.env.overlay))
            check("overlay: X while idle does not call emergencyStop",
                  idle.calls.emergency == 0,
                  "emergencyStop() called " .. idle.calls.emergency .. " times")
        else
            check("overlay: X while idle deletes the overlay and clears the handle", false,
                  "expected exactly one deferred call, got " .. tostring(idle and #idle.defer))
        end

        -- mouseUp on the X must not fall through to the background pin toggle.
        local upOnX = click({ event = "mouseUp", id = "close", recording = false, pinned = false })
        check("overlay: mouseUp on X does not toggle pinning",
              upOnX and upOnX.env.overlayPinned == false and upOnX.calls.hide == 0,
              "overlayPinned = " .. tostring(upOnX and upOnX.env.overlayPinned))

        -- Unpinning must not hide the overlay while a recording is still running.
        local unpinRec = click({ event = "mouseUp", id = "bg", recording = true, pinned = true })
        check("overlay: unpinning mid-recording keeps the overlay on screen",
              unpinRec and unpinRec.env.overlayPinned == false and unpinRec.calls.hideOverlay == 0,
              "hideOverlay() called " .. tostring(unpinRec and unpinRec.calls.hideOverlay) .. " times while recording")

        local unpinIdle = click({ event = "mouseUp", id = "bg", recording = false, pinned = true })
        check("overlay: unpinning while idle hides the overlay",
              unpinIdle and unpinIdle.env.overlayPinned == false and unpinIdle.calls.hideOverlay == 1,
              "hideOverlay() called " .. tostring(unpinIdle and unpinIdle.calls.hideOverlay) .. " times while idle")
    end
end

--------------------------------------------------------------------------------
-- 12. startRecording re-press recovery (behavioral)
--------------------------------------------------------------------------------
-- Pressing the trigger again inside the 0.3s finalization window must flush the
-- pending dictation AND start the new one. Returning after the flush swallowed the
-- keypress -- the user held the key and nothing recorded.

local function pressTrigger(state)
    local env   = baseEnv()
    local calls = { final = 0, warmup = 0, overlayText = 0, showOverlay = 0 }
    local timerStub = function(tag)
        return { stop = function() calls["stopped_" .. tag] = true end }
    end

    env.log                  = function() end
    env.isRecording          = state.recording and true or false
    env.isWarmingUp          = state.warmingUp and true or false
    env.finalizationPending  = state.pending and true or false
    env.warmupAttempt        = 7  -- non-zero, so the reset is observable
    env.finalizeTimers       = { timer = timerStub("timer"), watchdog = timerStub("watchdog") }
    env.doFinalTranscription = function() calls.final = calls.final + 1 end
    env.setOverlayText       = function() calls.overlayText = calls.overlayText + 1 end
    env.showOverlay          = function() calls.showOverlay = calls.showOverlay + 1 end
    env.tryWarmup            = function() calls.warmup = calls.warmup + 1 end

    local fn, err = liftFunction("startRecording", env)
    if not fn then return nil, err end
    local ok, runErr = pcall(fn)
    if not ok then return nil, "startRecording() errored: " .. tostring(runErr) end
    return { env = env, calls = calls }
end

local repress, repressErr = pressTrigger({ pending = true })
check("startRecording: function is liftable and compiles", repress ~= nil, tostring(repressErr))

if repress then
    check("startRecording: a pending finalization is flushed on re-press",
          repress.calls.final == 1,
          "doFinalTranscription() called " .. repress.calls.final .. " times")
    check("startRecording: re-press still starts the new recording (keypress not swallowed)",
          repress.calls.warmup == 1 and repress.env.isWarmingUp == true,
          "tryWarmup() called " .. repress.calls.warmup .. " times, isWarmingUp = " ..
          tostring(repress.env.isWarmingUp))
    check("startRecording: the flush cancels both finalization timers",
          repress.calls.stopped_timer and repress.calls.stopped_watchdog and
          repress.env.finalizeTimers.timer == nil and repress.env.finalizeTimers.watchdog == nil,
          "timer stopped=" .. tostring(repress.calls.stopped_timer) ..
          " watchdog stopped=" .. tostring(repress.calls.stopped_watchdog) ..
          " timer=" .. tostring(repress.env.finalizeTimers.timer) ..
          " watchdog=" .. tostring(repress.env.finalizeTimers.watchdog))
    check("startRecording: the flush clears finalizationPending",
          repress.env.finalizationPending == false,
          "finalizationPending = " .. tostring(repress.env.finalizationPending))
    check("startRecording: the new recording shows the overlay",
          repress.calls.showOverlay == 1 and repress.calls.overlayText == 1,
          "showOverlay=" .. repress.calls.showOverlay .. " setOverlayText=" .. repress.calls.overlayText)

    local plain = pressTrigger({})
    check("startRecording: with nothing pending it just starts recording",
          plain and plain.calls.final == 0 and plain.calls.warmup == 1,
          "doFinalTranscription=" .. tostring(plain and plain.calls.final) ..
          " tryWarmup=" .. tostring(plain and plain.calls.warmup))

    local busy = pressTrigger({ recording = true, pending = true })
    check("startRecording: no-ops while already recording",
          busy and busy.calls.warmup == 0 and busy.calls.final == 0,
          "tryWarmup=" .. tostring(busy and busy.calls.warmup) ..
          " doFinalTranscription=" .. tostring(busy and busy.calls.final))

    local warming = pressTrigger({ warmingUp = true, pending = true })
    check("startRecording: no-ops while already warming up",
          warming and warming.calls.warmup == 0 and warming.calls.final == 0,
          "tryWarmup=" .. tostring(warming and warming.calls.warmup) ..
          " doFinalTranscription=" .. tostring(warming and warming.calls.final))
end

--------------------------------------------------------------------------------
-- 13. Progress bar reaches 100% (behavioral)
--------------------------------------------------------------------------------
-- Left on the live clock, `elapsed` keeps climbing during transcription and re-trips
-- the 90% auto-expand on every finished segment, so barMaxSecs outruns transcribedSecs
-- and the blue bar never catches the red one. stopRecordingIndicator() freezes the
-- duration into recordedSecs; updateProgressBar() must honour it.

local elSrc = src:match("local%s+EL%s*=%s*(%b{})")
local EL = elSrc and loadIn("return " .. elSrc, baseEnv(), "EL")
EL = EL and EL()
check("progress: EL element-index table is extractable", type(EL) == "table",
      "could not read `local EL = { ... }` from source")

if type(EL) == "table" then
    -- Drive updateProgressBar() over a scripted timeline of (clock, transcribedSecs).
    local function runBar(steps, recordedSecs)
        local env  = baseEnv()
        local now  = 0
        env.EL     = EL
        env.overlay = { [EL.bar_rec] = {}, [EL.bar_txn] = {} }
        env.recordingStartTime = 0
        env.recordedSecs       = recordedSecs
        env.transcribedSecs    = 0
        env.barMaxSecs         = 180
        env.hs = { timer = { secondsSinceEpoch = function() return now end } }

        local fn, err = liftFunction("updateProgressBar", env)
        if not fn then return nil, err end
        for _, step in ipairs(steps) do
            now = step[1]
            env.transcribedSecs = step[2]
            if step[3] ~= nil then env.recordedSecs = step[3] end
            local ok, runErr = pcall(fn)
            if not ok then return nil, "updateProgressBar() errored: " .. tostring(runErr) end
        end
        return {
            rec = env.overlay[EL.bar_rec].frame.w,
            txn = env.overlay[EL.bar_txn].frame.w,
            barMaxSecs = env.barMaxSecs,
            env = env,
        }
    end

    -- 100s of audio, then transcription finishes while the wall clock runs on to 240s
    -- (past 0.9 * 180 = 162s, which is what used to re-trip the auto-expand).
    local bar, barErr = runBar({
        { 60,  0 },              -- mid-recording
        { 100, 0 },              -- key released at 100s
        { 130, 33,  100 },       -- stopRecordingIndicator() froze recordedSecs = 100
        { 170, 66 },
        { 240, 100 },            -- all 100s transcribed
    })
    check("progress: updateProgressBar is liftable and compiles", bar ~= nil, tostring(barErr))

    if bar then
        check("progress: the blue bar reaches the red bar when transcription completes",
              bar.txn == bar.rec,
              "transcribed bar w=" .. bar.txn .. ", recorded bar w=" .. bar.rec)
        check("progress: the bar scale stops expanding once recording stops",
              bar.barMaxSecs == 180,
              "barMaxSecs grew to " .. bar.barMaxSecs .. " after the recording ended")
        check("progress: the bars are drawn at a visible width",
              bar.rec == math.floor((100 / 180) * 386),
              "recorded bar w=" .. bar.rec .. ", want " .. math.floor((100 / 180) * 386))

        -- Half-transcribed audio must still read as half, not as full.
        local partial = runBar({ { 100, 0 }, { 300, 50, 100 } })
        check("progress: a partially transcribed recording shows a partial blue bar",
              partial and partial.txn < partial.rec and partial.txn > 1,
              "transcribed w=" .. tostring(partial and partial.txn) ..
              ", recorded w=" .. tostring(partial and partial.rec))

        -- The freeze must not disable the auto-expand for genuinely long recordings.
        local long = runBar({ { 60, 0 }, { 170, 0 } })
        check("progress: the bar still auto-expands during a long recording",
              long and long.barMaxSecs == 360,
              "barMaxSecs = " .. tostring(long and long.barMaxSecs) .. " at 170s recorded (want 360)")
    end

    -- The two halves of the freeze contract that updateProgressBar depends on.
    local startBody = extractFunction("startRecordingIndicator")
    local stopBody  = extractFunction("stopRecordingIndicator")
    check("progress: startRecordingIndicator clears the frozen duration",
          startBody ~= nil and startBody:find("recordedSecs%s*=%s*nil") ~= nil,
          "startRecordingIndicator() does not reset recordedSecs = nil")
    check("progress: stopRecordingIndicator freezes the recorded duration",
          stopBody ~= nil and stopBody:find("recordedSecs%s*=%s*hs%.timer%.secondsSinceEpoch") ~= nil,
          "stopRecordingIndicator() does not freeze recordedSecs from the clock")

    -- BAR_MAX in updateProgressBar and the bar_bg track width in createOverlay are
    -- separate literals; drifting apart would misreport progress at the right edge.
    local barMax  = src:match("local%s+BAR_MAX%s*=%s*(%d+)")
    local trackW  = src:match('id%s*=%s*"bar_bg".-w%s*=%s*(%d+)')
    check("progress: BAR_MAX matches the bar_bg track width",
          barMax ~= nil and barMax == trackW,
          "BAR_MAX=" .. tostring(barMax) .. ", bar_bg w=" .. tostring(trackW))
end

--------------------------------------------------------------------------------
-- 14. Long-lived system objects are rooted against the garbage collector
--------------------------------------------------------------------------------
-- Hammerspoon collects eventtaps, repeating timers and watchers that nothing in Lua
-- references, and collecting one unregisters it from the system: no error, no log line,
-- isEnabled() still true right up to the collection, then events silently stop arriving.
-- init.lua's own top-level locals are NOT a root -- once the chunk returns, a local lives
-- only as long as some reachable closure captures it. Removing the `_whisper` global once
-- killed the trigger this way: it looked like dead state, but it was the only strong
-- reference to the eventtap, which then died a few minutes after every reload.

local GC_ROOT       = "LocalWhisper"
local LONG_LIVED    = {
    ["hs%.eventtap%.new"]           = "eventtap",
    ["hs%.caffeinate%.watcher%.new"] = "watcher",
    ["hs%.timer%.doEvery"]          = "repeating timer",
}

local discarded, unrooted = {}, {}
for i, s in ipairs(stripped) do
    for pat, kind in pairs(LONG_LIVED) do
        -- Top level only: an indented call belongs to a function body, whose own
        -- lifetime is decided by whatever roots that function.
        if s:match("^" .. pat) then
            discarded[#discarded + 1] = kind .. " at L" .. i
        end
        local name = s:match("^local%s+([%w_]+)%s*=%s*" .. pat)
        if name and not src:find(GC_ROOT .. "%.[%w_]+%s*=%s*" .. name .. "%f[^%w_]") then
            unrooted[#unrooted + 1] = name .. " (" .. kind .. ", L" .. i .. ")"
        end
    end
end

check("lifetime: no long-lived object is created and discarded at top level",
      #discarded == 0,
      "unreferenced: " .. table.concat(discarded, ", "))
check("lifetime: every top-level eventtap/watcher/repeating timer is stored in " .. GC_ROOT,
      #unrooted == 0,
      "not rooted: " .. table.concat(unrooted, ", "))
check("lifetime: the trigger eventtap itself is rooted",
      src:find(GC_ROOT .. "%.modTap%s*=") ~= nil,
      GC_ROOT .. ".modTap is never assigned — the tap will be collected mid-session")

--------------------------------------------------------------------------------
-- 15. Trigger matching (behavioral -- runs the real triggerPressed/triggerHeld)
--------------------------------------------------------------------------------
-- The trigger is a modifier COMBO (fn + left Control), which opens two failure modes
-- a single-modifier trigger never had:
--   * `rawFlags & mask > 0` fires on half the combo -- plain Control would start a
--     recording, i.e. every Ctrl-C in a terminal
--   * polling the release through generic modifier names ("ctrl") cannot tell left
--     Control from right Control, so the poller both over- and under-fires
-- Both are exercised against the trigger actually configured in the source.

local RAWFLAGS     = hs.eventtap.event.rawFlagMasks
local triggerKey   = src:match('local%s+TRIGGER_KEY%s*=%s*"([%w_]+)"')
local triggersSrc  = src:match("local%s+TRIGGERS%s*=%s*(%b{})")
check("trigger: TRIGGER_KEY and the TRIGGERS table are extractable",
      triggerKey ~= nil and triggersSrc ~= nil,
      "TRIGGER_KEY=" .. tostring(triggerKey) .. ", TRIGGERS table found=" .. tostring(triggersSrc ~= nil))

if triggerKey and triggersSrc then
    local tEnv = baseEnv()
    tEnv.RAWFLAGS = RAWFLAGS
    local tFactory, tErr = loadIn("return " .. triggersSrc, tEnv, "TRIGGERS")
    local TRIGGERS = tFactory and tFactory()
    local trig = type(TRIGGERS) == "table" and TRIGGERS[triggerKey] or nil

    check("trigger: TRIGGER_KEY names a defined trigger with a mask and a label",
          type(trig) == "table" and type(trig.mask) == "number" and type(trig.label) == "string",
          "TRIGGERS[" .. triggerKey .. "] = " .. tostring(trig) .. " " .. tostring(tErr))

    if trig and type(trig.mask) == "number" then
        -- Pin today's choice: hold fn + left Control to dictate.
        check("trigger: the configured trigger is fn + left Control",
              trig.mask == (RAWFLAGS.secondaryFn | RAWFLAGS.deviceLeftControl),
              string.format("mask=0x%x, want 0x%x (fn|deviceLeftControl)",
                            trig.mask, RAWFLAGS.secondaryFn | RAWFLAGS.deviceLeftControl))

        local env = baseEnv()
        env.trigger = trig
        local pressed, pErr = liftFunction("triggerPressed", env)
        check("trigger: triggerPressed is liftable and compiles", pressed ~= nil, tostring(pErr))

        if pressed then
            check("trigger: the full combo fires", pressed(trig.mask) == true,
                  string.format("triggerPressed(0x%x) = false", trig.mask))
            check("trigger: no modifiers at all does not fire", pressed(0) == false,
                  "triggerPressed(0) = true")

            -- Every individual bit of a combo mask must be insufficient on its own.
            -- This is the `> 0` regression, expressed without hardcoding which combo.
            local partials = {}
            local bit = 1
            local bitCount = 0
            while bit <= trig.mask do
                if (trig.mask & bit) ~= 0 then
                    bitCount = bitCount + 1
                    if bit ~= trig.mask and pressed(bit) then
                        partials[#partials + 1] = string.format("0x%x", bit)
                    end
                end
                bit = bit << 1
            end
            check("trigger: no single half of the combo fires on its own",
                  #partials == 0,
                  "these partial flag sets fired: " .. table.concat(partials, ", "))
            check("trigger: the trigger is an actual combo (more than one modifier bit)",
                  bitCount > 1, "mask has " .. bitCount .. " bit(s)")

            -- Real events carry the generic bits too (control alongside deviceLeftControl),
            -- plus whatever else the user happens to be holding.
            local noise = RAWFLAGS.control | RAWFLAGS.shift | RAWFLAGS.deviceLeftShift | RAWFLAGS.nonCoalesced
            check("trigger: unrelated modifiers held at the same time do not block it",
                  pressed(trig.mask | noise) == true,
                  string.format("triggerPressed(0x%x) = false", trig.mask | noise))

            -- The mirror-image modifier must stay inert: right Control is not left Control.
            local mirrored = (trig.mask & ~RAWFLAGS.deviceLeftControl) | RAWFLAGS.deviceRightControl | RAWFLAGS.control
            check("trigger: the right-hand twin of the modifier does not fire",
                  pressed(mirrored) == false,
                  string.format("triggerPressed(0x%x) = true — right Control matched a left-Control trigger", mirrored))
        end

        -- triggerHeld() drives the release poller, and it reads a DIFFERENT API than the
        -- eventtap: hs.eventtap.checkKeyboardModifiers(true)._raw comes from
        -- CGEventSourceFlagsState, which reports only the generic modifier bits. The
        -- device-specific bits an event carries (deviceLeftControl = 0x1) are simply not
        -- there. A trigger polled through its event mask therefore never reads as held,
        -- and the poller stops the recording 0.1s after the key went down -- which is
        -- exactly how the first fn+Control build shipped broken.
        local DEVICE_BITS = RAWFLAGS.deviceLeftShift  | RAWFLAGS.deviceRightShift
                          | RAWFLAGS.deviceLeftControl| RAWFLAGS.deviceRightControl
                          | RAWFLAGS.deviceLeftAlternate | RAWFLAGS.deviceRightAlternate
                          | RAWFLAGS.deviceLeftCommand   | RAWFLAGS.deviceRightCommand
                          | RAWFLAGS.deviceAlphaShiftStateless

        check("trigger: the trigger defines a separate heldMask for polling",
              type(trig.heldMask) == "number" and trig.heldMask ~= 0,
              "heldMask = " .. tostring(trig.heldMask))

        if type(trig.heldMask) == "number" then
            check("trigger: heldMask contains no device-specific bit (the poll API drops them)",
                  (trig.heldMask & DEVICE_BITS) == 0,
                  string.format("heldMask=0x%x carries device bits 0x%x, which CGEventSourceFlagsState never reports",
                                trig.heldMask, trig.heldMask & DEVICE_BITS))

            -- The generic counterpart must describe the same physical combo: same number
            -- of modifiers, and each device bit answered by its generic bit.
            local function bits(mask)
                local n, b = 0, 1
                while b <= mask do
                    if (mask & b) ~= 0 then n = n + 1 end
                    b = b << 1
                end
                return n
            end
            check("trigger: heldMask describes the same combo as mask",
                  bits(trig.heldMask) == bits(trig.mask),
                  string.format("mask=0x%x has %d modifier(s), heldMask=0x%x has %d",
                                trig.mask, bits(trig.mask), trig.heldMask, bits(trig.heldMask)))
        end

        local held, hErr = liftFunction("triggerHeld", baseEnv())
        check("trigger: triggerHeld is liftable and compiles", held ~= nil, tostring(hErr))

        if held and type(trig.heldMask) == "number" then
            local liveFlags, rawArg = 0, nil
            local hEnv = baseEnv()
            hEnv.trigger        = trig
            hEnv.triggerPressed = pressed
            hEnv.hs = { eventtap = { checkKeyboardModifiers = function(raw)
                rawArg = raw
                return { _raw = liveFlags }
            end } }
            held = liftFunction("triggerHeld", hEnv)

            -- What the real API actually returns while the combo is down: generic bits only.
            liveFlags = trig.heldMask
            check("trigger: triggerHeld is true for the flags the poll API really returns",
                  held() == true,
                  string.format("held() = false for _raw=0x%x — the poller would stop the recording immediately",
                                trig.heldMask))
            check("trigger: triggerHeld asks for the raw flag word",
                  rawArg == true,
                  "checkKeyboardModifiers() called with " .. tostring(rawArg) .. ", want true")

            -- Releasing either half must end the recording.
            local released = {}
            local bit = 1
            while bit <= trig.heldMask do
                if (trig.heldMask & bit) ~= 0 and bit ~= trig.heldMask then
                    liveFlags = trig.heldMask & ~bit
                    if held() then released[#released + 1] = string.format("0x%x", bit) end
                end
                bit = bit << 1
            end
            check("trigger: releasing either modifier reads as released",
                  #released == 0,
                  "still held after releasing: " .. table.concat(released, ", "))

            liveFlags = 0
            check("trigger: nothing held reads as released", held() == false, "held() = true with no modifiers")
        end
    end

    -- Wiring: both paths must go through the helpers above rather than re-deriving
    -- the match inline, which is how the two failure modes got in last time.
    check("trigger: the eventtap matches through triggerPressed(event:rawFlags())",
          src:find("triggerPressed%s*%(%s*event:rawFlags%s*%(%s*%)%s*%)") ~= nil,
          "the flagsChanged handler does not call triggerPressed(event:rawFlags())")

    local pollSrc = src:match("releasePoller%s*=%s*hs%.timer%.doEvery%s*(%b())")
    check("trigger: the release poller re-checks the trigger through triggerHeld()",
          pollSrc ~= nil and pollSrc:find("triggerHeld") ~= nil,
          "release poller body: " .. tostring(pollSrc and pollSrc:sub(1, 120)))
end

--------------------------------------------------------------------------------
-- Emit results
--------------------------------------------------------------------------------

local out = io.open(OUT, "w")
for _, r in ipairs(results) do
    out:write((r.passed and "PASS" or "FAIL") .. "\t" .. r.name .. "\t" .. r.detail .. "\n")
end
out:close()
