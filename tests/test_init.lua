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
-- 5. Meeting mode stays removed
--------------------------------------------------------------------------------

local meetingHits = {}
for i, s in ipairs(stripped) do
    local low = s:lower()
    if low:find("meeting") or low:find("blackhole") or low:find("aggregate") then
        meetingHits[#meetingHits + 1] = "L" .. i
    end
end
check("meeting: no meeting-mode code remains",
      #meetingHits == 0,
      "found at " .. table.concat(meetingHits, ", "))

--------------------------------------------------------------------------------
-- 6. No unintended top-level globals
--------------------------------------------------------------------------------
-- AGENTS.md: never leak state into Hammerspoon's shared _ENV, where another config
-- or Spoon can collide with it. A short allowlist covers the deliberate ones.

local allowedGlobals = {
    _whisper       = true,  -- state probe for `hs -c`
    WhisperActions = true,  -- user-facing action-hook API
    emergencyStop  = true,  -- called from the overlay callback and the menu bar
    updateMenuBar  = true,
    stopRecording  = true,
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
-- Emit results
--------------------------------------------------------------------------------

local out = io.open(OUT, "w")
for _, r in ipairs(results) do
    out:write((r.passed and "PASS" or "FAIL") .. "\t" .. r.name .. "\t" .. r.detail .. "\n")
end
out:close()
