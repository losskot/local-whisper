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

-- strip() is line-oriented on purpose: in a Lua pattern `.` matches newlines, so running it
-- over a whole function body would delete everything after its first `--` comment.
local function stripBlock(text)
    local out = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do out[#out + 1] = strip(line) end
    return table.concat(out, "\n")
end

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
    -- The old subsystem stays deleted: it auto-stopped *every* dictation, and it was
    -- removed as pure ballast (checkSilence() was never called, silenceTimer never
    -- created). The voice trigger since brought back a deliberately narrower version
    -- under its own name -- a dictation started by the wake word has no key to release,
    -- so something has to end it. The frontier pattern below still catches a bare
    -- `silenceTimer` while allowing `wakeSilenceTimer`, so the guard keeps its teeth.
    { name = "autostop",    what = "silence auto-stop",
      patterns = { "checksilence", "silentchunk", "%f[%w]silencetimer",
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
-- The recorder's output template and the sort comparator's pattern must agree; changing
-- one without the other silently breaks ordering again. The writer moved out of init.lua
-- into tools/lw-record.swift when ffmpeg stopped doing the capture, so accept it in either
-- place -- that also keeps this check meaningful when pointed at an older revision.

local REPO = TARGET:match("^(.*)/hammerspoon/init%.lua$")
    or (HOME .. "/Documents/GitHub/local-whisper")
local recorderSrc = readSource(REPO .. "/tools/lw-record.swift") or ""

local writerPattern = (recorderSrc:find('chunk_%%03d%.wav', 1, false) ~= nil)
    or (src:find('chunk_%%03d%.wav', 1, false) ~= nil)
local readerPattern = src:find('chunk_%(%%d%+%)%%%.wav', 1, false) ~= nil
check("sort: recorder output template and comparator pattern agree",
      writerPattern and readerPattern,
      "writer chunk_%03d.wav=" .. tostring(writerPattern) ..
      ", reader chunk_(%d+)%.wav=" .. tostring(readerPattern))

--------------------------------------------------------------------------------
-- 8b. Live capture never goes back through ffmpeg's avfoundation input
--------------------------------------------------------------------------------
-- ffmpeg's avfoundation indev hands over ~90% of the samples it captures: a fixed 20s
-- capture produced 18.04s of PCM, and every 1-second chunk came out 0.885-0.917s long.
-- The loss is spread evenly, so short words vanish and whisper papers over the gaps with
-- fluent invented text. No ffmpeg flag fixed it (-thread_queue_size, -drop_late_frames
-- false, -use_wallclock_as_timestamps, -capture_raw_data, other device indexes, dropping
-- the segmenter or the resampler). Capture must stay on the native recorder.
--
-- ffmpeg is still correct for concat here and for format conversion in tools/transcribe.sh,
-- so this only forbids pairing it with avfoundation.

-- Match the quoted argument form, so the comment explaining *why* we avoid it stays legal.
local usesAvfoundation = src:find('"avfoundation"', 1, true) ~= nil
check("capture: init.lua does not capture through ffmpeg's avfoundation input",
      not usesAvfoundation,
      'found "avfoundation" as an argument -- that input device drops ~10% of the audio')

check("capture: the native recorder binary is invoked",
      src:find("RECORDER_BIN", 1, true) ~= nil,
      "RECORDER_BIN not referenced -- what is opening the microphone?")

check("capture: the recorder reports captured seconds for the health check",
      src:find("CAPTURED", 1, true) ~= nil and recorderSrc:find("CAPTURED", 1, true) ~= nil,
      "the CAPTURED handshake is how a future capture regression becomes visible in the log")

-- hs.task hands stdout to the streaming callback when one is registered and leaves the
-- termination callback's `out` empty, so parsing CAPTURED *only* at termination reads nil
-- forever and the health check silently never fires. It must be parsed in the stream.
do
    local streamStart = src:find("streaming: READY", 1, true)
    local capturedInStream = streamStart and src:find("CAPTURED%%s%+", streamStart, false)
    check("capture: CAPTURED is parsed in the streaming callback",
          capturedInStream ~= nil,
          "hs.task leaves the termination callback's stdout empty once a streaming callback exists")

    -- hs.task delivers whatever is in the pipe, so the final line can arrive split across
    -- two callbacks ("CAPTU" + "RED 100.199") and match neither half. Verified: feeding
    -- those two halves separately yields nil twice; matching a joined tail recovers it.
    check("capture: the CAPTURED match runs against an accumulated tail, not one delivery",
          src:find("stdoutTail", 1, true) ~= nil,
          "a split read would silently lose the health check again")

    -- And when it goes missing anyway, say so rather than logging nothing at all.
    check("capture: a missing CAPTURED line still logs a measurement",
          src:find("no CAPTURED line", 1, true) ~= nil,
          "silence here is exactly how the original ~10% loss stayed invisible")
end

--------------------------------------------------------------------------------
-- 8c. Segment splitting cuts at a pause and never loses a chunk
--------------------------------------------------------------------------------
-- A fixed-index cut lands mid-word: the halves are transcribed by independent whisper
-- calls, so the word is mangled or duplicated across the seam. splitAtSilence() scans back
-- for the quietest chunk instead. The invariant that actually matters is that regrouping
-- preserves every chunk exactly once -- a bug there silently truncates the transcript.

do
    local dir = os.getenv("TMPDIR") or "/tmp/"
    if dir:sub(-1) ~= "/" then dir = dir .. "/" end
    dir = dir .. "lw_split_test"
    os.execute("rm -rf '" .. dir .. "' && mkdir -p '" .. dir .. "'")

    -- getWavRMS reads int16 LE starting at byte 44, so only the header length matters.
    local function writeWav(path, amplitude, frames)
        local f = io.open(path, "wb")
        if not f then return false end
        f:write(string.rep("\0", 44))
        for _ = 1, frames do f:write(string.pack("<i2", amplitude)) end
        f:close()
        return true
    end

    local TOTAL, QUIET_AT = 120, 50
    local paths = {}
    for i = 1, TOTAL do
        local p = string.format("%s/chunk_%03d.wav", dir, i - 1)
        writeWav(p, i == QUIET_AT and 0 or 6000, 64)
        paths[i] = p
    end

    local env = setmetatable({ log = function() end }, { __index = _G })
    local rms = liftFunction("getWavRMS", env)
    check("split: getWavRMS is liftable and compiles", rms ~= nil, "could not lift getWavRMS")

    if rms then
        env.getWavRMS = rms
        check("split: a silent chunk reads quieter than a loud one",
              rms(paths[QUIET_AT]) < 300 and rms(paths[1]) > 300,
              "quiet=" .. tostring(rms(paths[QUIET_AT])) .. " loud=" .. tostring(rms(paths[1])))

        local split, splitErr = liftFunction("splitAtSilence", env)
        check("split: splitAtSilence is liftable and compiles", split ~= nil, tostring(splitErr))

        if split then
            local groups = split(paths, 55, 8)

            -- Every chunk survives, in order, exactly once.
            local flat = {}
            for _, g in ipairs(groups) do
                for _, p in ipairs(g) do flat[#flat + 1] = p end
            end
            local sameOrder = #flat == TOTAL
            if sameOrder then
                for i = 1, TOTAL do
                    if flat[i] ~= paths[i] then sameOrder = false break end
                end
            end
            check("split: regrouping preserves every chunk exactly once, in order",
                  sameOrder, "got " .. #flat .. " chunks back out of " .. TOTAL)

            check("split: the first cut lands on the silent chunk, not the hard boundary",
                  #groups[1] == QUIET_AT,
                  "first group is " .. #groups[1] .. " chunks, expected " .. QUIET_AT ..
                  " (hard boundary would be 55)")

            -- With no pause anywhere, it must still bound the segment at maxSecs.
            local loud = {}
            for i = 1, TOTAL do
                local p = string.format("%s/loud_%03d.wav", dir, i - 1)
                writeWav(p, 6000, 64)
                loud[i] = p
            end
            local loudGroups = split(loud, 55, 8)
            local maxLen = 0
            for _, g in ipairs(loudGroups) do
                if #g > maxLen then maxLen = #g end
            end
            check("split: an unbroken passage is still bounded by maxSecs",
                  maxLen <= 55, "longest group was " .. maxLen .. " chunks")
        end
    end

    os.execute("rm -rf '" .. dir .. "'")
end

--------------------------------------------------------------------------------
-- 8d. The streaming pipeline claims every chunk exactly once
--------------------------------------------------------------------------------
-- Segments are dispatched to whisper while recording continues, so the audio is handed out
-- in two places: streamCheckAndDispatch() during recording and doFinalTranscription() for
-- the tail. If those two disagree by even one chunk, a second of speech is either dropped
-- from the transcript or transcribed twice -- and both read as a plausible sentence, so
-- neither is visible without checking the indices.

do
    local dir = os.getenv("TMPDIR") or "/tmp/"
    if dir:sub(-1) ~= "/" then dir = dir .. "/" end
    dir = dir .. "lw_pipe_test"
    os.execute("rm -rf '" .. dir .. "' && mkdir -p '" .. dir .. "'")

    local function writeWav(path, amplitude)
        local f = io.open(path, "wb")
        if not f then return end
        f:write(string.rep("\0", 44))
        for _ = 1, 64 do f:write(string.pack("<i2", amplitude)) end
        f:close()
    end

    -- 190 chunks with pauses scattered through, so splitAtSilence has real cuts to find.
    local TOTAL = 190
    local paths = {}
    for i = 1, TOTAL do
        local p = string.format("%s/chunk_%03d.wav", dir, i - 1)
        writeWav(p, (i % 47 == 0) and 0 or 6000)
        paths[i] = p
    end

    local env = setmetatable({ log = function() end }, { __index = _G })
    local rms = liftFunction("getWavRMS", env)
    local split = rms and (function() env.getWavRMS = rms; return liftFunction("splitAtSilence", env) end)()

    if split then
        env.splitAtSilence = split
        env.FINAL_SEGMENT_SECS = tonumber(src:match("local%s+FINAL_SEGMENT_SECS%s*=%s*(%d+)")) or 55

        local dispatched = {}
        env.dispatchSegment = function(segN, group) dispatched[segN] = group end
        env.isRecording = true
        env.pipe = { gen = 1, dir = dir, results = {}, nextChunk = 1, nextSeg = 1,
                     total = 0, done = 0, finalizing = false }

        local visible = 0
        env.getChunkFiles = function()
            local out = {}
            for i = 1, visible do out[i] = paths[i] end
            return out
        end

        local stream, streamErr = liftFunction("streamCheckAndDispatch", env)
        check("pipeline: streamCheckAndDispatch is liftable and compiles", stream ~= nil, tostring(streamErr))

        if stream then
            -- Nothing may be dispatched before a full pause-bounded segment exists.
            visible = env.FINAL_SEGMENT_SECS
            stream()
            check("pipeline: nothing is dispatched before a full segment has accumulated",
                  env.pipe.nextSeg == 1,
                  "dispatched " .. (env.pipe.nextSeg - 1) .. " segment(s) too early")

            -- Grow the recording one chunk at a time, exactly as the 3s poll sees it.
            for n = env.FINAL_SEGMENT_SECS + 1, TOTAL do
                visible = n
                stream()
            end

            local streamedSegs = env.pipe.nextSeg - 1
            check("pipeline: segments are dispatched during recording, not all at the end",
                  streamedSegs >= 2,
                  "only " .. streamedSegs .. " segment(s) dispatched live over " .. TOTAL .. " chunks")

            -- The tail doFinalTranscription() would pick up.
            local remaining = {}
            for j = env.pipe.nextChunk, TOTAL do remaining[#remaining + 1] = paths[j] end
            for _, grp in ipairs(split(remaining, env.FINAL_SEGMENT_SECS)) do
                dispatched[env.pipe.nextSeg] = grp
                env.pipe.nextSeg = env.pipe.nextSeg + 1
            end

            -- Streaming plus tail must reconstruct the recording exactly.
            local flat = {}
            for n = 1, env.pipe.nextSeg - 1 do
                for _, p in ipairs(dispatched[n] or {}) do flat[#flat + 1] = p end
            end
            local exact = #flat == TOTAL
            if exact then
                for i = 1, TOTAL do
                    if flat[i] ~= paths[i] then exact = false break end
                end
            end
            check("pipeline: streamed segments plus the tail cover every chunk exactly once, in order",
                  exact,
                  "reassembled " .. #flat .. " chunks from " .. TOTAL ..
                  " (a mismatch means dropped or doubled audio)")

            check("pipeline: no segment is dispatched empty",
                  (function()
                      for n = 1, env.pipe.nextSeg - 1 do
                          if not dispatched[n] or #dispatched[n] == 0 then return false end
                      end
                      return true
                  end)(),
                  "an empty segment would burn a whisper call and a slot in the ordered results")
        end
    end

    os.execute("rm -rf '" .. dir .. "'")
end

--------------------------------------------------------------------------------
-- 8e. A new recording must not swallow the dictation still being transcribed
--------------------------------------------------------------------------------
-- Pressing the trigger again while the previous dictation was still in whisper used to
-- reset the one shared pipeline table and wipe the one shared chunk directory. Its finished
-- segments were dropped from `results`, `finalizing` went back to false so nothing was ever
-- assembled, and the concat of its remaining audio failed with ffmpeg exit 254 because the
-- WAVs were gone. A 92-second dictation vanished with no error anywhere but those two lines.
--
-- Each keypress now owns a job. These checks pin the two halves of the contract: a job that
-- finishes behind a newer recording keeps its text, and that text is delivered -- with the
-- next insertion, oldest first, because the user is still holding the trigger combo when it
-- arrives and both insertion modes post keystrokes.

do
    local env = baseEnv()
    env.log = function() end
    env.overlay = nil
    env.transcribedSecs = 0
    env.barMaxSecs = 180
    env.hs = {
        notify = { new = function() return { send = function() end } end },
        timer  = { doAfter = function() end },
    }
    local inserted = {}
    env.insertTranscribedText = function(text, lang)
        inserted[#inserted + 1] = { text = text, lang = lang }
    end
    env.hideProgressBar   = function() end
    env.hideOverlay       = function() end
    env.setOverlayText    = function() end
    env.updateProgressBar = function() end
    env.pipeCleanup       = function() end
    env.pipeJobs = { live = {}, pending = {}, lastGen = 2 }
    -- A recording is in progress, so a transcript landing now cannot be typed anywhere.
    local insertSafe = false
    env.pipeInsertIsSafe = function() return insertSafe end

    local takePending = liftFunction("pipeTakePending", env)
    local finalize    = liftFunction("pipelineFinalize", env)
    local done        = liftFunction("onPipelineDone", env)
    check("detach: the pipeline finalizers are liftable and compile",
          takePending ~= nil and finalize ~= nil and done ~= nil,
          "could not lift pipeTakePending/pipelineFinalize/onPipelineDone")

    if takePending and finalize and done then
        env.pipeTakePending  = takePending
        env.pipelineFinalize = finalize

        -- gen 1: released, still in whisper. gen 2: the recording started on top of it.
        local old = { gen = 1, results = {}, lang = "ru", nextChunk = 1, nextSeg = 2,
                      total = 1, done = 0, finalizing = true, inserted = false, abandoned = false }
        local new = { gen = 2, results = {}, lang = nil, nextChunk = 1, nextSeg = 1,
                      total = 0, done = 0, finalizing = false, inserted = false, abandoned = false }
        env.pipeJobs.live[1] = old
        env.pipeJobs.live[2] = new
        env.pipe = new

        done(old, 1, "первое сообщение", "ru", 30)
        check("detach: a dictation that finishes behind a newer recording is not lost",
              #env.pipeJobs.pending == 1 and env.pipeJobs.pending[1].text == "первое сообщение",
              #env.pipeJobs.pending .. " queued -- the transcript was dropped on the floor")
        check("detach: it is not typed into the recording in progress",
              #inserted == 0,
              "inserted " .. #inserted .. " transcript(s) while the trigger was still held")
        check("detach: an older job's segments never move the current progress bar",
              env.transcribedSecs == 0,
              "transcribedSecs moved to " .. tostring(env.transcribedSecs))

        -- The new dictation finishes: both texts arrive together, oldest first.
        insertSafe = true
        new.total, new.finalizing = 1, true
        done(new, 1, "второе сообщение", "ru", 10)
        check("detach: the queued dictation is inserted with the next one, in spoken order",
              #inserted == 1 and inserted[1].text == "первое сообщение второе сообщение",
              "inserted " .. #inserted .. ": '" .. (inserted[1] and inserted[1].text or "") .. "'")
        check("detach: the queue is emptied once it has been inserted",
              #env.pipeJobs.pending == 0,
              #env.pipeJobs.pending .. " still queued -- it would reappear on a later dictation")

        -- Emergency stop abandons every job; whatever comes back after it is dropped.
        local stopped = { gen = 3, results = {}, total = 1, done = 0,
                          finalizing = true, inserted = false, abandoned = true }
        done(stopped, 1, "не вставлять", "ru", 5)
        check("detach: a segment returning after an emergency stop is dropped",
              #inserted == 1 and stopped.results[1] == nil,
              "an abandoned job still delivered text")
    end
end

--------------------------------------------------------------------------------
-- 8f. The two places that used to destroy a dictation in progress
--------------------------------------------------------------------------------

do
    local twStart, twEnd
    for i, s in ipairs(stripped) do
        if not twStart and s:match("^tryWarmup%s*=%s*function%s*%(") then twStart = i end
        if twStart and not twEnd and i > twStart and s:match("^end%s*$") then twEnd = i end
    end
    if not (twStart and twEnd) then
        check("detach: tryWarmup() is locatable", false, "could not find tryWarmup = function()")
    else
        local body = table.concat({ table.unpack(stripped, twStart, twEnd) }, "\n")
        -- The wipe scan runs on the raw lines: the path it deletes lives inside a string
        -- literal, and strip() blanks those.
        local rawBody = table.concat({ table.unpack(lines, twStart, twEnd) }, "\n")
        check("detach: starting a recording does not reset the pipeline",
              body:find("pipelineReset") == nil,
              "tryWarmup() calls pipelineReset() -- that wipes the results of a dictation " ..
              "that is still being transcribed")
        local wipes = {}
        for line in rawBody:gmatch("[^\n]+") do
            if line:find("rm %-rf") then wipes[#wipes + 1] = line end
        end
        local perJob = #wipes > 0
        for _, line in ipairs(wipes) do
            if not line:find("pipe%.dir") then perJob = false end
        end
        check("detach: a new recording only clears its own chunk directory",
              perJob,
              "tryWarmup() clears " .. (#wipes == 0 and "nothing" or table.concat(wipes, " | ")) ..
              " -- clearing the shared directory deletes audio another dictation is still reading")
    end

    local srcStart = extractFunction("startRecording")
    check("detach: startRecording() gives the keypress its own job",
          srcStart ~= nil and stripBlock(srcStart):find("pipeStartJob") ~= nil,
          "startRecording() does not call pipeStartJob() -- the new recording would share " ..
          "state with the dictation still in flight")

    local dispatch = extractFunction("dispatchSegment")
    if not dispatch then
        check("detach: dispatchSegment() is locatable", false, "could not find dispatchSegment()")
    else
        local body = stripBlock(dispatch)
        check("detach: dispatchSegment() captures its job instead of reading `pipe` later",
              body:find("job%s*=%s*job%s+or%s+pipe") ~= nil and
              body:find("onPipelineDone%(job,") ~= nil and
              body:find("onPipelineDone%(segN") == nil,
              "a whisper callback that reports into `pipe` writes into whatever dictation is " ..
              "current when it finishes, not the one it belongs to")
    end
end

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
    local calls = { final = 0, warmup = 0, overlayText = 0, showOverlay = 0, newJob = 0 }
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
    env.pipeStartJob         = function() calls.newJob = calls.newJob + 1 end

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
-- 16. The text lands where it was aimed (behavioral -- runs the real finishInsertion)
--------------------------------------------------------------------------------
-- Whisper answers seconds after the key comes up, and a cursor that moved in between used
-- to receive the text anyway: a paragraph typed into a chat, a terminal or a search box,
-- with no undo for keystrokes another app already accepted. The destination is pinned at
-- release (focusTargetId) and re-checked right before insertion. A mismatch means clipboard
-- only -- and two chimes instead of one, because "nothing was typed" has to be audible
-- without looking at the screen.

do
    local env = baseEnv()
    local HERE  = "com.editor|1|100|Doc.txt|AXTextArea||||"
    local THERE = "com.chat|2|200|Chat|AXTextField||||"
    local focusNow = HERE
    local inserts, sounds = {}, {}

    env.log                  = function() end
    env.getLang              = function() return "ru" end
    env.getEnterMode         = function() return false end
    env.getOutputMode        = function() return "paste" end
    env.focusTargetId        = function() return focusNow end
    env.normalizeText        = function(t) return t end
    env.buildActionContext   = function(text, lang, mode)
        return { text = text, originalText = text, lang = lang, outputMode = mode,
                 insert = true, inserted = false }
    end
    env.runPreInsertActions  = function() end
    env.runPostInsertActions = function() end
    env.insertTextAtCursor   = function(text, mode) inserts[#inserts + 1] = { text = text, mode = mode } end
    env.playSound            = function(name) sounds[#sounds + 1] = name end
    env.setOverlayText       = function() end
    env.hideOverlay          = function() end
    env.saveRecentDictations = function() end
    env.recentDictations     = {}
    env.MAX_RECENT           = 10
    env.capturedAppName      = "Editor"
    env.OVERLAY_LINGER       = 0.5
    -- Deferred work runs inline, so the second chime is counted where it is scheduled.
    env.hs = { timer = { doAfter = function(_, fn) if fn then fn() end end } }

    local finish, fErr = liftFunction("finishInsertion", env)
    check("focus: finishInsertion is liftable and compiles", finish ~= nil, tostring(fErr))

    if finish then
        finish("привет", "ru", HERE)
        check("focus: an unmoved cursor still receives the text",
              #inserts == 1 and inserts[1].mode == "paste",
              "inserted " .. #inserts .. " time(s), mode=" .. tostring(inserts[1] and inserts[1].mode))
        check("focus: one chime when the text went where it was aimed",
              #sounds == 1, #sounds .. " sound(s) played")

        inserts, sounds = {}, {}
        focusNow = THERE
        finish("привет", "ru", HERE)
        check("focus: a cursor that moved gets the clipboard, not keystrokes",
              #inserts == 1 and inserts[1].mode == "copy",
              "mode=" .. tostring(inserts[1] and inserts[1].mode) ..
              " -- the text was typed into whatever is focused now")
        check("focus: two chimes say nothing was typed",
              #sounds == 2, #sounds .. " sound(s) played, want 2")

        -- No destination recorded (AX unavailable, or a path that never captured one):
        -- behave exactly as before the check existed rather than refusing to type.
        inserts, sounds = {}, {}
        finish("привет", "ru", nil)
        check("focus: no recorded destination still types, as before",
              #inserts == 1 and inserts[1].mode == "paste" and #sounds == 1,
              "mode=" .. tostring(inserts[1] and inserts[1].mode) .. ", " .. #sounds .. " sound(s)")
    end

    -- Wiring: the destination is only worth checking if it is captured at release and
    -- carried by the job all the way to the insertion, including through the queue.
    local stopSrc = extractFunction("stopRecording")
    check("focus: stopRecording pins the destination when the key comes up",
          stopSrc ~= nil and stripBlock(stopSrc):find("focusTargetId") ~= nil,
          "stopRecording() never calls focusTargetId() -- nothing is recorded to check against")

    local bare = {}
    for _, s in ipairs(stripped) do
        if not s:match("function%s+insertTranscribedText") then
            local argsSrc = s:match("insertTranscribedText%s*(%b())")
            if argsSrc then
                local commas = select(2, argsSrc:gsub(",", ""))
                if commas < 2 then bare[#bare + 1] = s:match("^%s*(.-)%s*$") end
            end
        end
    end
    check("focus: every insertion carries the destination it was aimed at",
          #bare == 0,
          "called without a target: " .. table.concat(bare, " | "))

    check("focus: a dictation waiting in the queue keeps its own destination",
          src:find("pipeJobs%.pending%s*,%s*{[^}]*target") ~= nil,
          "queued transcripts drop their target -- a late insertion would type into " ..
          "whatever window happens to be focused when it lands")
end

--------------------------------------------------------------------------------
-- 9. Voice trigger (wake word)
--------------------------------------------------------------------------------
-- The listener holds the microphone open for as long as it runs, which is the whole
-- cost of the feature and the reason for every guard below.

do
    check("wake: the trigger entry point hangs off the persistent global",
          src:find("function%s+LocalWhisper%.voiceTrigger") ~= nil,
          "lw-wake.py reaches Hammerspoon through the `hs` CLI, which can only see " ..
          "globals -- a local function is unreachable and the daemon fires into nothing")

    check("wake: a detection cannot start a second dictation over a live one",
          src:find("function%s+LocalWhisper%.voiceTrigger.-isRecording%s+or%s+isWarmingUp") ~= nil,
          "voiceTrigger does not bail out while a dictation is already running")

    -- The microphone is what costs something, so it must be released the moment the
    -- screen sleeps -- see AGENTS.md on the PreventUserIdleSystemSleep assertion.
    check("wake: the listener is torn down when the screen sleeps",
          src:find("screensDidSleep.-wakeStop") ~= nil,
          "nothing stops the listener on screensDidSleep -- the microphone would stay " ..
          "open, and its sleep assertion with it, while nobody is at the machine")

    check("wake: the listener comes back when the screen wakes",
          src:find("screensDidWake.-wakeStart") ~= nil,
          "the listener never restarts, so the trigger dies at the first screen sleep")

    -- Same garbage-collection bug class as LocalWhisper.modTap: an unrooted watcher is
    -- collected, and collecting it unregisters it with nothing logged.
    for _, name in ipairs({ "wakeScreenWatcher", "wakeBatteryWatcher", "wakeTask", "wakeSilenceTimer" }) do
        check("wake: " .. name .. " is rooted in the persistent global",
              src:find("LocalWhisper%." .. name .. "%s*=") ~= nil,
              name .. " is never rooted -- Hammerspoon collects it and it silently stops")
    end

    -- The microphone is the expensive half, and this is a fanless laptop: on battery the
    -- listener must not run at all.
    check("wake: the listener refuses to start on battery",
          src:find("function%s+wakeStart.-wakeOnPower") ~= nil,
          "wakeStart does not check the power source -- the listener would hold the " ..
          "microphone open on battery")

    check("wake: unplugging tears the listener down",
          src:find("wakeStop%(\"running on battery\"%)") ~= nil,
          "nothing stops the listener when the power source changes to battery")

    check("wake: a machine with no battery counts as plugged in",
          src:find("function%s+wakeOnPower.-src%s*==%s*nil") ~= nil,
          "hs.battery.powerSource() returns nil on a desktop; treating that as battery " ..
          "would disable the trigger on every machine without a battery")

    check("wake: the power watcher acts only on a real change of source",
          src:find("onPower%s*==%s*wakeLastPower") ~= nil,
          "hs.battery.watcher fires on every percentage tick -- without this guard the " ..
          "listener would be restarted, and logged, once a minute forever")

    check("wake: a reload terminates the previous run's listener",
          src:find("LocalWhisper%.wakeTask.-terminate") ~= nil,
          "reloading would leave the old listener holding the microphone, invisible " ..
          "to the new instance")

    -- A voice-started dictation has no key release, so every path out of it has to be
    -- bounded: silence, nobody speaking at all, and a hard cap.
    for _, field in ipairs({ "SILENCE_SECS", "LEAD_SECS", "MAX_SECS" }) do
        check("wake: " .. field .. " bounds a voice-started dictation",
              src:find("%f[%w]" .. field .. "%s*=") ~= nil,
              field .. " is gone -- a voice-started dictation could run unbounded")
    end
end

--------------------------------------------------------------------------------
-- Emit results
--------------------------------------------------------------------------------

local out = io.open(OUT, "w")
for _, r in ipairs(results) do
    out:write((r.passed and "PASS" or "FAIL") .. "\t" .. r.name .. "\t" .. r.detail .. "\n")
end
out:write("DONE\t\t\n")
out:close()
