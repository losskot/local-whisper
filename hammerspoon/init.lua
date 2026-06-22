-- init.lua — local-whisper: Hammerspoon-only dictation
-- Hold a modifier key → record → transcribe → insert at cursor
-- No Karabiner needed. Just Hammerspoon + ffmpeg + whisper.cpp

require("hs.ipc")

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

local HOME = os.getenv("HOME")
local TMPDIR = os.getenv("TMPDIR") or "/tmp"
local WHISPER_TMP = TMPDIR .. "/whisper-dictate"
local CHUNK_DIR = WHISPER_TMP .. "/chunks"

-- Config directory (all user settings live here)
local CONFIG_DIR = HOME .. "/.local-whisper"
os.execute("mkdir -p '" .. CONFIG_DIR .. "'")

-- External binaries (absolute paths, with ARM/Intel fallback)
local FFMPEG = hs.fs.attributes("/opt/homebrew/bin/ffmpeg") and "/opt/homebrew/bin/ffmpeg" or "/usr/local/bin/ffmpeg"
local WHISPER_BIN = HOME .. "/whisper.cpp/build/bin/whisper-cli"
local MODELS_DIR = HOME .. "/whisper.cpp/models"
local MODEL_FILE = CONFIG_DIR .. "/model"

-- Scan available models
local function getAvailableModels()
    local models = {}
    local ok, iter, dir = pcall(hs.fs.dir, MODELS_DIR)
    if not ok then return models end
    for file in iter, dir do
        local name = file:match("^ggml%-(.+)%.bin$")
        if name then table.insert(models, name) end
    end
    table.sort(models)
    return models
end

-- Get/set active model
local function getModelName()
    local saved = ""
    local f = io.open(MODEL_FILE, "r")
    if f then saved = f:read("*a"):gsub("%s+", ""); f:close() end
    if saved ~= "" then
        -- Verify model file exists
        local path = MODELS_DIR .. "/ggml-" .. saved .. ".bin"
        local attr = hs.fs.attributes(path)
        if attr then return saved end
    end
    return "medium"  -- default
end

local function getModelPath()
    return MODELS_DIR .. "/ggml-" .. getModelName() .. ".bin"
end

-- Audio device: ":default" for system default, ":0", ":1" etc. for specific
-- Note: avfoundation requires colon prefix for audio-only (":0" not "0")
local AUDIO_DEVICE = ":default"

-- Auto-fix missing colon prefix (common setup mistake)
if AUDIO_DEVICE ~= ":default" and not AUDIO_DEVICE:match("^:") then
    AUDIO_DEVICE = ":" .. AUDIO_DEVICE
end

-- Trigger key: "rightAlt", "rightCmd", "rightCtrl"
local TRIGGER_KEY = "rightCmd"

-- User preference files (all in CONFIG_DIR)
local LANG_FILE = CONFIG_DIR .. "/lang"
local OUTPUT_FILE = CONFIG_DIR .. "/output"
local PREFERRED_LANGS_FILE = CONFIG_DIR .. "/preferred_langs"
local ENTER_FILE = CONFIG_DIR .. "/enter"
local PROMPT_FILE = CONFIG_DIR .. "/prompt"
local RECENT_FILE = CONFIG_DIR .. "/recent.json"
local LOG_FILE = WHISPER_TMP .. "/whisper-dictate.log"

-- Action hooks config
local ACTIONS_FILE = HOME .. "/.hammerspoon/local_whisper_actions.lua"

-- Auto-stop on silence
local AUTO_STOP_SILENCE_SECONDS = 3
local AUTO_STOP_THRESHOLD_DB = -40

-- LLM refinement (requires Ollama)
local REFINE_FILE = CONFIG_DIR .. "/refine"
local REFINE_PROMPT_FILE = CONFIG_DIR .. "/refine_prompt"
local REFINE_MODEL_FILE = CONFIG_DIR .. "/refine_model"
local REFINE_DEFAULT_MODEL = "gemma3:4b"
local REFINE_MIN_CHARS = 50  -- skip refinement for short text
local REFINE_DEFAULT_PROMPT = "You are a text cleanup tool. Output ONLY the cleaned text, nothing else. Fix punctuation and capitalization. Remove ONLY filler words like um, uh, you know, I mean. Do NOT remove sentences or meaningful content. When the text lists sequential items using first/second/third or one/two/three, convert them into a numbered list with each item on a new line. NEVER add commentary or preamble. Just output the cleaned text."

local function getRefineModel()
    local f = io.open(REFINE_MODEL_FILE, "r")
    if f then
        local val = f:read("*a"):gsub("%s+", ""); f:close()
        if val ~= "" then return val end
    end
    return REFINE_DEFAULT_MODEL
end

local function getRefinePrompt()
    local f = io.open(REFINE_PROMPT_FILE, "r")
    if f then
        local content = f:read("*a"); f:close()
        content = content:gsub("^%s+", ""):gsub("%s+$", "")
        if content ~= "" then return content end
    end
    return REFINE_DEFAULT_PROMPT
end

local function hasOllama()
    -- Check if Ollama API is reachable
    local ok = os.execute("curl -s -o /dev/null -w '' http://localhost:11434/api/tags 2>/dev/null")
    if ok then return true end
    -- Fallback: check if binary exists
    return os.execute("command -v ollama >/dev/null 2>&1")
end

local function getRefineMode()
    local f = io.open(REFINE_FILE, "r")
    if not f then return false end
    local val = f:read("*a"):gsub("%s+", ""); f:close()
    return val == "on"
end

local function setRefineMode(on)
    local f = io.open(REFINE_FILE, "w")
    if f then f:write(on and "on" or "off"); f:close() end
end

local function cycleRefine()
    local current = getRefineMode()
    setRefineMode(not current)
end

-- Timing
local PARTIAL_INTERVAL = 2.0   -- seconds between partial transcriptions
local OVERLAY_LINGER = 0.5     -- seconds to show final text before closing

-- Known whisper hallucinations on silence/short audio
local HALLUCINATIONS = {
    "you", "thank you", "thanks for watching", "thanks for listening",
    "bye", "goodbye", "the end", "thank you for watching",
    "subscribe", "like and subscribe", "see you", "you.",
    "(applause)", "(keyboard clicking)", "(typing)", "(silence)",
    "(soft music)", "(lighter clicking)", "(applauding)",
    "[BLANK_AUDIO]", "[silence]",
}

--------------------------------------------------------------------------------
-- Trigger key mapping
--------------------------------------------------------------------------------

local TRIGGER_MASKS = {
    rightAlt  = hs.eventtap.event.rawFlagMasks["deviceRightAlternate"],
    rightCmd  = hs.eventtap.event.rawFlagMasks["deviceRightCommand"],
    rightCtrl = hs.eventtap.event.rawFlagMasks["deviceRightControl"],
}

local triggerMask = TRIGGER_MASKS[TRIGGER_KEY]
if not triggerMask then
    hs.notify.new({ title = "local-whisper", informativeText = "ERROR: Invalid TRIGGER_KEY: " .. TRIGGER_KEY }):send()
    return
end

--------------------------------------------------------------------------------
-- Utilities
--------------------------------------------------------------------------------

os.execute("mkdir -p '" .. WHISPER_TMP .. "'")

local function log(msg)
    local f = io.open(LOG_FILE, "a")
    if f then
        f:write(os.date("[%H:%M:%S] ") .. msg .. "\n")
        f:close()
    end
end

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return "" end
    local content = f:read("*a") or ""
    f:close()
    return content
end

local function writeFile(path, content)
    local f = io.open(path, "w")
    if not f then return end
    f:write(content)
    f:close()
end

local function getLang()
    local lang = readFile(LANG_FILE):gsub("%s+", "")
    if lang == "en" or lang == "ru" or lang == "uk" or lang == "auto" then return lang end
    return "en"
end

local function getOutputMode()
    local mode = readFile(OUTPUT_FILE):gsub("%s+", "")
    if mode == "type" then return "type" end
    return "paste"
end

local function getPreferredLangs()
    local content = readFile(PREFERRED_LANGS_FILE):gsub("%s+$", "")
    if content == "" then return {"en"} end
    local langs = {}
    for lang in content:gmatch("[^,]+") do
        lang = lang:match("^%s*(.-)%s*$")
        if lang ~= "" then table.insert(langs, lang) end
    end
    return #langs > 0 and langs or {"en"}
end

local function getEnterMode()
    local mode = readFile(ENTER_FILE):gsub("%s+", "")
    return mode == "on"
end

local function shellQuote(text)
    return "'" .. tostring(text):gsub("'", "'\\''") .. "'"
end

local function expandPath(path)
    if type(path) ~= "string" then return nil end
    if path:sub(1, 2) == "~/" then return HOME .. path:sub(2) end
    return path
end

local function ensureParentDir(path)
    local parent = path:match("^(.*)/[^/]+$")
    if not parent or parent == "" then return true end
    local ok = os.execute("mkdir -p " .. shellQuote(parent))
    return ok == true or ok == 0
end

local function normalizeText(text)
    return ((text or ""):gsub("%s+", " ")):gsub("^%s+", ""):gsub("%s+$", "")
end

-- App bundle IDs where auto-capitalize should be skipped (terminals, code editors)
local NO_CAPITALIZE_APPS = {
    ["com.apple.Terminal"] = true,
    ["com.googlecode.iterm2"] = true,
    ["dev.warp.Warp-Stable"] = true,
    ["com.microsoft.VSCode"] = true,
    ["com.apple.dt.Xcode"] = true,
    ["com.jetbrains.intellij"] = true,
    ["com.sublimetext.4"] = true,
    ["com.github.atom"] = true,
    ["dev.zed.Zed"] = true,
}

-- Text post-processing: capitalize, remove fillers, clean whitespace
-- appBundleID is optional; when provided, adjusts behavior per-app
local function postProcess(text, appBundleID)
    -- Trim
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return text end
    -- Remove filler words (standalone, case-insensitive)
    text = text:gsub("%f[%w][Uu][mm]%f[%W]", "")
    text = text:gsub("%f[%w][Uu][hh]%f[%W]", "")
    text = text:gsub("%f[%w][Hh][Mm][Mm]+%f[%W]", "")
    -- Remove "like," used as filler (comma-following)
    text = text:gsub("%f[%w][Ll]ike,%s*", "")
    -- Collapse multiple spaces
    text = text:gsub("%s+", " ")
    -- Trim again after removals
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    -- Auto-capitalize first letter (skip for terminals and code editors)
    if not (appBundleID and NO_CAPITALIZE_APPS[appBundleID]) then
        text = text:gsub("^%l", string.upper)
    end
    return text
end

local function refineWithOllama(text, callback)
    if not getRefineMode() or not hasOllama() or #text < REFINE_MIN_CHARS then
        callback(text)
        return
    end
    log("refine: sending to Ollama API (" .. #text .. " chars)")
    local prompt = getRefinePrompt() .. "\n\n" .. text
    local model = getRefineModel()
    -- Use Ollama HTTP API (more reliable than CLI, avoids version mismatch issues)
    local jsonPayload = hs.json.encode({
        model = model,
        prompt = prompt,
        stream = false,
    })
    local tmpPayload = WHISPER_TMP .. "/refine_payload.json"
    local f = io.open(tmpPayload, "w")
    if f then f:write(jsonPayload); f:close() end
    local task = hs.task.new("/usr/bin/curl", function(code, stdout, stderr)
        if code == 0 and stdout and #stdout > 0 then
            local ok, result = pcall(hs.json.decode, stdout)
            if ok and result and result.response then
                local refined = result.response:gsub("^%s+", ""):gsub("%s+$", "")
                -- Strip common LLM preamble
                refined = refined:gsub("^[Hh]ere%s+is%s+the%s+cleaned%s+text:%s*\n?", "")
                refined = refined:gsub("^[Hh]ere'?s?%s+the%s+cleaned[%-]?%s*text:%s*\n?", "")
                refined = refined:gsub("^[Hh]ere%s+is%s+the%s+refined%s+text:%s*\n?", "")
                refined = refined:gsub("^[Ss]ure[,!]?%s*[Hh]?e?r?e?'?s?%s*t?h?e?%s*", "")
                refined = refined:gsub("^%s+", "")
                if refined ~= "" then
                    log("refine: success (" .. #refined .. " chars)")
                    callback(refined)
                    return
                end
            end
        end
        log("refine: failed (code=" .. tostring(code) .. "), using original")
        callback(text)
    end, {
        "-s", "-X", "POST",
        "http://localhost:11434/api/generate",
        "-H", "Content-Type: application/json",
        "-d", "@" .. tmpPayload,
    })
    task:setEnvironment({ HOME = HOME, PATH = "/usr/bin:/bin" })
    task:start()
end

local function isHallucination(text)
    local lower = text:lower():gsub("^%s+", ""):gsub("%s+$", "")
    -- strip trailing period for comparison
    local stripped = lower:gsub("[%.%!%?]+$", "")
    for _, h in ipairs(HALLUCINATIONS) do
        if stripped == h:lower() or lower == h:lower() then return true end
    end
    -- Also filter anything in brackets/parens (whisper noise markers)
    if lower:match("^%[.*%]$") or lower:match("^%(.*%)$") then return true end
    return false
end

local function getChunkFiles()
    local chunks = {}
    local ok, iter, dir = pcall(hs.fs.dir, CHUNK_DIR)
    if not ok then return chunks end
    for file in iter, dir do
        if file:match("^chunk_.*%.wav$") then
            table.insert(chunks, CHUNK_DIR .. "/" .. file)
        end
    end
    table.sort(chunks)
    return chunks
end

-- Cycle helpers
local function cycleLang()
    local cycle = { en = "ru", ru = "uk", uk = "auto", auto = "en" }
    local next = cycle[getLang()] or "en"
    writeFile(LANG_FILE, next)
    return next
end

local function cycleModel()
    local models = getAvailableModels()
    if #models == 0 then return getModelName() end
    local current = getModelName()
    local next = models[1]
    for i, m in ipairs(models) do
        if m == current and models[i + 1] then
            next = models[i + 1]
            break
        end
    end
    if next == current then next = models[1] end
    writeFile(MODEL_FILE, next)
    return next
end

local function cycleOutput()
    local next = (getOutputMode() == "paste") and "type" or "paste"
    writeFile(OUTPUT_FILE, next)
    return next
end

local function cycleEnter()
    local next = getEnterMode() and "off" or "on"
    writeFile(ENTER_FILE, next)
    return next
end

-- Pick fastest available model for live partial transcription
local function getPartialModelPath()
    local preferred = { "tiny", "tiny.en", "base", "base.en", "small", "small.en" }
    for _, name in ipairs(preferred) do
        local path = MODELS_DIR .. "/ggml-" .. name .. ".bin"
        if hs.fs.attributes(path) then return path end
    end
    return getModelPath()  -- fall back to main model
end

-- Read custom vocabulary prompt for whisper
local function getPromptArgs()
    local content = readFile(PROMPT_FILE):gsub("%s+$", "")
    if content ~= "" then return { "--prompt", content } end
    return {}
end

--------------------------------------------------------------------------------
-- App-aware context (captured at recording start)
--------------------------------------------------------------------------------

local capturedAppName = nil
local capturedAppBundleID = nil

local function captureActiveApp()
    local app = hs.application.frontmostApplication()
    if app then
        capturedAppName = app:name()
        capturedAppBundleID = app:bundleID()
    else
        capturedAppName = nil
        capturedAppBundleID = nil
    end
end

--------------------------------------------------------------------------------
-- Optional post-dictation action hooks (user config)
--------------------------------------------------------------------------------

local actionConfig = nil
local actionConfigMtime = 0

local function safeHookCall(label, fn, ctx)
    local ok, err = pcall(fn, ctx)
    if not ok then
        log("actions: " .. label .. " failed: " .. tostring(err))
    end
end

-- Auto-reload: check mtime and reload if file changed
local function loadActionConfig()
    local attr = hs.fs.attributes(ACTIONS_FILE)
    if not attr then
        actionConfig = nil
        actionConfigMtime = 0
        return nil
    end

    local mtime = attr.modification or 0
    if actionConfig and mtime == actionConfigMtime then
        return actionConfig
    end

    local chunk, err = loadfile(ACTIONS_FILE)
    if not chunk then
        log("actions: could not load config: " .. tostring(err))
        return nil
    end

    local ok, cfg = pcall(chunk)
    if not ok then
        log("actions: config execution failed: " .. tostring(cfg))
        return nil
    end
    if type(cfg) ~= "table" then
        log("actions: config must return a table")
        return nil
    end

    actionConfig = cfg
    actionConfigMtime = mtime
    log("actions: loaded " .. ACTIONS_FILE)
    return actionConfig
end

local function reloadActionConfig()
    actionConfigMtime = 0
    actionConfig = nil
    return loadActionConfig()
end

local function buildActionContext(text, lang, mode)
    local ctx = {
        text = text,
        textLower = text:lower(),
        originalText = text,
        lang = lang,
        outputMode = mode,
        appName = capturedAppName,
        appBundleID = capturedAppBundleID,
        insert = true,
        inserted = false,
        handled = false,
        timestamp = os.time(),
        isoTime = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }

    function ctx:setText(newText)
        if type(newText) ~= "string" then return end
        self.text = normalizeText(newText)
        self.textLower = self.text:lower()
    end

    function ctx:disableInsert()
        self.insert = false
    end

    function ctx:enableInsert()
        self.insert = true
    end

    function ctx:launchApp(appName)
        if type(appName) ~= "string" or appName == "" then return false end
        return hs.application.launchOrFocus(appName)
    end

    function ctx:appendToFile(path, line)
        local resolved = expandPath(path)
        if not resolved or resolved == "" then return false, "invalid path" end
        if not ensureParentDir(resolved) then return false, "mkdir failed" end
        local f = io.open(resolved, "a")
        if not f then return false, "open failed" end
        f:write(tostring(line or self.text or "") .. "\n")
        f:close()
        return true
    end

    function ctx:runShell(command, inputText)
        if type(command) ~= "string" or command == "" then
            return false, "", "invalid command", 1
        end
        local token = tostring(os.time()) .. "_" .. tostring(math.random(1000000))
        local stdinPath = WHISPER_TMP .. "/action_stdin_" .. token .. ".txt"
        writeFile(stdinPath, tostring(inputText or self.text or ""))
        local output, ok, kind, rc = hs.execute(command .. " < " .. shellQuote(stdinPath), true)
        os.remove(stdinPath)
        return ok, output, kind, rc
    end

    function ctx:keystroke(mods, key)
        hs.eventtap.keyStroke(mods or {}, key)
    end

    function ctx:notify(message)
        hs.notify.new({ title = "local-whisper", informativeText = tostring(message) }):send()
    end

    function ctx:log(message)
        log("action: " .. tostring(message))
    end

    return ctx
end

local function runActionList(actions, ctx)
    if type(actions) ~= "table" then return end
    for i, action in ipairs(actions) do
        if ctx.handled then break end
        if type(action) == "function" then
            safeHookCall("actions[" .. i .. "]", action, ctx)
        elseif type(action) == "table" and type(action.run) == "function" then
            local name = action.name or ("actions[" .. i .. "]")
            local shouldRun = true
            if type(action.when) == "function" then
                local ok, res = pcall(action.when, ctx)
                if not ok then
                    shouldRun = false
                    log("actions: " .. name .. ".when failed: " .. tostring(res))
                else
                    shouldRun = not not res
                end
            elseif type(action.pattern) == "string" then
                shouldRun = ctx.textLower:match(action.pattern) ~= nil
            end
            if shouldRun then
                safeHookCall(name, action.run, ctx)
            end
        end
    end
end

local function runPreInsertActions(ctx)
    local cfg = loadActionConfig()
    if type(cfg) ~= "table" then return end
    if type(cfg.beforeInsert) == "function" then
        safeHookCall("beforeInsert", cfg.beforeInsert, ctx)
    end
    if not ctx.handled then
        runActionList(cfg.actions, ctx)
    end
end

local function runPostInsertActions(ctx)
    local cfg = loadActionConfig()
    if type(cfg) ~= "table" then return end
    if type(cfg.afterInsert) == "function" then
        safeHookCall("afterInsert", cfg.afterInsert, ctx)
    end
end

-- Global reload function (used by hotkey and menu bar)
WhisperActions = WhisperActions or {}
function WhisperActions.reload()
    local cfg = reloadActionConfig()
    if cfg then
        hs.notify.new({ title = "local-whisper", informativeText = "Action hooks reloaded" }):send()
    else
        hs.notify.new({ title = "local-whisper", informativeText = "No action hook config found" }):send()
    end
end

--------------------------------------------------------------------------------
-- Overlay UI
--------------------------------------------------------------------------------

local overlay = nil
local btnColor = { red = 0.5, green = 0.8, blue = 1.0, alpha = 1.0 }
local btnHover = { red = 0.7, green = 0.9, blue = 1.0, alpha = 1.0 }

-- Element indices: 1=bg, 2=lang, 3=sep1, 4=output, 5=sep2, 6=enter, 7=sep3, 8=model, 9=sep4, 10=refine, 11=text, 12=dot, 13=timer, 14=close
local EL = { lang = 2, output = 4, enter = 6, model = 8, refine = 10, text = 11, dot = 12, timer = 13, close = 14 }

local enterOnColor = { red = 0.3, green = 1.0, blue = 0.3, alpha = 1.0 }
local enterOffColor = { red = 0.5, green = 0.5, blue = 0.5, alpha = 0.5 }
local refineOnColor = { red = 0.4, green = 0.8, blue = 1.0, alpha = 1.0 }
local refineOffColor = { red = 0.5, green = 0.5, blue = 0.5, alpha = 0.5 }

local function refreshOverlayLabels()
    if not overlay then return end
    overlay[EL.lang].text = getLang():upper()
    overlay[EL.output].text = getOutputMode():upper()
    overlay[EL.enter].text = "⏎"
    overlay[EL.enter].textColor = getEnterMode() and enterOnColor or enterOffColor
    overlay[EL.model].text = getModelName()
    local refineOn = getRefineMode() and hasOllama()
    overlay[EL.refine].text = refineOn and "refine ✓" or "refine ✗"
    overlay[EL.refine].textColor = refineOn and refineOnColor or refineOffColor
end

local function createOverlay()
    local screen = hs.screen.mainScreen()
    local frame = screen:frame()
    local width, height = 420, 100
    local padding = 20
    local x = frame.x + frame.w - width - padding
    local y = frame.y + frame.h - height - padding - 50

    overlay = hs.canvas.new({ x = x, y = y, w = width, h = height })

    -- 1: Background (click to pin overlay open)
    overlay:appendElements({
        id = "bg",
        type = "rectangle", action = "fill",
        roundedRectRadii = { xRadius = 10, yRadius = 10 },
        fillColor = { red = 0.1, green = 0.1, blue = 0.1, alpha = 0.85 },
        trackMouseUp = true,
    })

    -- Clickable status labels (each cycles on click)
    local sepColor = { red = 0.4, green = 0.4, blue = 0.4, alpha = 1 }

    -- 2: Language
    overlay:appendElements({
        id = "lang", type = "text", text = getLang():upper(),
        textColor = btnColor, textSize = 11,
        frame = { x = "4%", y = "6%", w = "10%", h = "25%" },
        trackMouseUp = true, trackMouseEnterExit = true,
    })
    -- 3: Separator
    overlay:appendElements({
        id = "sep1", type = "text", text = "|",
        textColor = sepColor, textSize = 11,
        frame = { x = "13%", y = "6%", w = "2%", h = "25%" },
    })
    -- 4: Output mode
    overlay:appendElements({
        id = "output", type = "text", text = getOutputMode():upper(),
        textColor = btnColor, textSize = 11,
        frame = { x = "15%", y = "6%", w = "13%", h = "25%" },
        trackMouseUp = true, trackMouseEnterExit = true,
    })
    -- 5: Separator
    overlay:appendElements({
        id = "sep2", type = "text", text = "|",
        textColor = sepColor, textSize = 11,
        frame = { x = "27%", y = "6%", w = "2%", h = "25%" },
    })
    -- 6: Enter mode (⏎ green=on, gray=off)
    overlay:appendElements({
        id = "enter", type = "text", text = "⏎",
        textColor = getEnterMode() and enterOnColor or enterOffColor, textSize = 11,
        frame = { x = "29%", y = "6%", w = "5%", h = "25%" },
        trackMouseUp = true, trackMouseEnterExit = true,
    })
    -- 7: Separator
    overlay:appendElements({
        id = "sep3", type = "text", text = "|",
        textColor = sepColor, textSize = 11,
        frame = { x = "34%", y = "6%", w = "2%", h = "25%" },
    })
    -- 8: Model
    overlay:appendElements({
        id = "model", type = "text", text = getModelName(),
        textColor = btnColor, textSize = 11,
        frame = { x = "36%", y = "6%", w = "20%", h = "25%" },
        trackMouseUp = true, trackMouseEnterExit = true,
    })
    -- 9: Separator
    overlay:appendElements({
        id = "sep4", type = "text", text = "|",
        textColor = sepColor, textSize = 11,
        frame = { x = "54%", y = "6%", w = "2%", h = "25%" },
    })
    -- 10: LLM refine toggle
    overlay:appendElements({
        id = "refine", type = "text",
        text = (getRefineMode() and hasOllama()) and "refine ✓" or "refine ✗",
        textColor = (getRefineMode() and hasOllama()) and refineOnColor or refineOffColor,
        textSize = 11,
        frame = { x = "57%", y = "6%", w = "18%", h = "25%" },
        trackMouseUp = true, trackMouseEnterExit = true,
    })
    -- 11: Transcript text
    overlay:appendElements({
        id = "text", type = "text", text = "Listening...",
        textColor = { red = 1, green = 1, blue = 1, alpha = 1.0 },
        textSize = 14,
        frame = { x = "5%", y = "35%", w = "90%", h = "60%" },
    })
    -- 12: Recording indicator (pulsing red dot)
    overlay:appendElements({
        id = "dot", type = "oval", action = "fill",
        fillColor = { red = 1, green = 0.15, blue = 0.15, alpha = 0.0 },
        frame = { x = "89%", y = "8%", w = "3%", h = "12%" },
    })
    -- 13: Elapsed time display
    overlay:appendElements({
        id = "timer", type = "text", text = "",
        textColor = { red = 1, green = 0.4, blue = 0.4, alpha = 0.0 },
        textSize = 10,
        frame = { x = "75%", y = "8%", w = "14%", h = "20%" },
        textAlignment = "right",
    })
    -- 14: Close button (X) — last element so it's on top and clickable
    overlay:appendElements({
        id = "close", type = "text", text = "✕",
        textColor = { red = 1, green = 0.4, blue = 0.4, alpha = 0.8 },
        textSize = 16, textAlignment = "center",
        frame = { x = "90%", y = "10%", w = "8%", h = "20%" },
        trackMouseDown = true, trackMouseUp = true, trackMouseEnterExit = true,
    })

    overlay:level(hs.canvas.windowLevels.floating)
    overlay:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)

    -- Map string IDs to numeric indices for element access
    local idMap = { bg = 1, lang = EL.lang, output = EL.output, enter = EL.enter, model = EL.model, refine = EL.refine, close = EL.close }

    -- Mouse handler: click bg to pin, click labels to cycle settings, X to close
    overlay:canvasMouseEvents(true, true, true, false)  -- mouseDown + mouseUp + enterExit
    overlay:mouseCallback(function(canvas, event, id, mx, my)
        -- Close button — hide immediately, delete deferred
        if id == "close" then
            if event == "mouseDown" then
                log("overlay: X close")
                canvas:hide()
                hs.timer.doAfter(0.01, function()
                    overlayPinned = false
                    if isRecording then
                        emergencyStop()
                    else
                        if overlay then overlay:delete(); overlay = nil end
                    end
                end)
            end
            return
        end

        if event == "mouseUp" then
            if id == "bg" then
                overlayPinned = not overlayPinned
                if overlayPinned then
                    canvas[1].fillColor = { red = 0.15, green = 0.15, blue = 0.2, alpha = 0.92 }
                    log("overlay pinned")
                else
                    canvas[1].fillColor = { red = 0.1, green = 0.1, blue = 0.1, alpha = 0.85 }
                    log("overlay unpinned")
                    if not isRecording then hideOverlay() end
                end
                return
            end

            if id == "lang" then cycleLang()
            elseif id == "output" then cycleOutput()
            elseif id == "enter" then cycleEnter()
            elseif id == "model" then cycleModel()
            elseif id == "refine" then cycleRefine()
            end
            refreshOverlayLabels()

        elseif event == "mouseEnter" then
            local idx = idMap[id]
            if not idx or id == "bg" then return end
            if id == "close" then
                canvas[idx].textColor = { red = 1, green = 0.3, blue = 0.3, alpha = 1 }
            elseif id == "enter" then
                canvas[idx].textColor = enterOnColor
            elseif id == "refine" then
                canvas[idx].textColor = refineOnColor
            else
                canvas[idx].textColor = btnHover
            end

        elseif event == "mouseExit" then
            local idx = idMap[id]
            if not idx or id == "bg" then return end
            if id == "close" then
                canvas[idx].textColor = { red = 1, green = 1, blue = 1, alpha = 0.5 }
            elseif id == "enter" then
                canvas[idx].textColor = getEnterMode() and enterOnColor or enterOffColor
            elseif id == "refine" then
                canvas[idx].textColor = (getRefineMode() and hasOllama()) and refineOnColor or refineOffColor
            else
                canvas[idx].textColor = btnColor
            end
        end
    end)
end

local function showOverlay()
    overlayPinned = false
    if overlay then overlay:delete() end
    createOverlay()
    overlay:show()
end

local function hideOverlay()
    if overlayPinned then return end  -- pinned overlay stays open
    if overlay then overlay:delete(); overlay = nil end
end

local function forceHideOverlay()
    overlayPinned = false
    if overlay then overlay:delete(); overlay = nil end
end

local function setOverlayText(text)
    if overlay then overlay[EL.text].text = text end
end

local function setOverlayStatus()
    refreshOverlayLabels()
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local isRecording = false
local overlayPinned = false
local ffmpegTask = nil
local partialTimer = nil
local partialBusy = false
local lastChunkCount = 0

-- Menu bar
local menuBar = nil

-- Recording indicator state
local pulseTimer = nil
local clockTimer = nil
local recordingStartTime = 0
local pulseAlpha = 1.0
local pulseFading = true

-- Undo state
local lastInsertedText = nil

-- Recent dictations (newest first, max 10)
local MAX_RECENT = 10

local recentDictations = {}

local function loadRecentDictations()
    local f = io.open(RECENT_FILE, "r")
    if not f then return end
    local data = f:read("*a"); f:close()
    local ok, result = pcall(hs.json.decode, data)
    if ok and type(result) == "table" then
        -- Clear and populate in-place (preserve table reference)
        for i = #recentDictations, 1, -1 do recentDictations[i] = nil end
        for i, entry in ipairs(result) do recentDictations[i] = entry end
    end
end

local function saveRecentDictations()
    local ok, json = pcall(hs.json.encode, recentDictations)
    if not ok then return end
    local f = io.open(RECENT_FILE, "w")
    if f then f:write(json); f:close() end
end

loadRecentDictations()

-- Auto-stop state
local silentChunkCount = 0
local silenceTimer = nil
local lastCheckedChunk = 0

--------------------------------------------------------------------------------
-- Menu bar status icon
--------------------------------------------------------------------------------

local function makeWaveformIcon(color, asTemplate)
    local w, h = 18, 18
    local c = hs.canvas.new({ x = 0, y = 0, w = w, h = h })
    -- Bar heights (symmetric waveform: short-medium-tall-medium-short)
    local bars = { 0.3, 0.55, 1.0, 0.55, 0.3 }
    local barW = 2
    local gap = 1.5
    local totalW = #bars * barW + (#bars - 1) * gap
    local startX = (w - totalW) / 2
    for i, scale in ipairs(bars) do
        local barH = math.floor(h * 0.75 * scale)
        local x = startX + (i - 1) * (barW + gap)
        local y = (h - barH) / 2
        c:appendElements({
            type = "rectangle",
            frame = { x = x, y = y, w = barW, h = barH },
            fillColor = color,
            roundedRectRadii = { xRadius = 1, yRadius = 1 },
            action = "fill",
        })
    end
    local img = c:imageFromCanvas()
    c:delete()
    img:template(asTemplate)
    return img
end

function updateMenuBar()
    if not menuBar then return end
    if isRecording then
        local icon = makeWaveformIcon({ red = 1, green = 0.15, blue = 0.15, alpha = 1 }, false)
        menuBar:setIcon(icon, false)
    else
        local icon = makeWaveformIcon({ red = 0, green = 0, blue = 0, alpha = 1 }, true)
        menuBar:setIcon(icon, true)
    end
end

-- Forward-declare meeting state and functions (defined in Meeting mode section below)
local meetingRecording = false
local meetingStartTime = nil
local startMeeting, stopMeeting

local function buildMenuBarMenu()
    local items = {}

    -- Current status
    table.insert(items, { title = isRecording and "● Recording..." or "Idle", disabled = true })
    table.insert(items, { title = "-" })

    -- Language
    local langDisplay = getLang():upper()
    table.insert(items, {
        title = "Language: " .. langDisplay,
        fn = function() cycleLang(); updateMenuBar() end,
    })

    -- Model
    table.insert(items, {
        title = "Model: " .. getModelName(),
        fn = function() cycleModel(); updateMenuBar() end,
    })

    -- Output mode
    table.insert(items, {
        title = "Output: " .. getOutputMode():upper(),
        fn = function() cycleOutput(); updateMenuBar() end,
    })

    -- Enter mode
    local enterState = getEnterMode() and "ON" or "OFF"
    table.insert(items, {
        title = "Enter after insert: " .. enterState,
        fn = function() cycleEnter(); updateMenuBar() end,
    })

    -- LLM refinement
    if hasOllama() then
        local refineState = getRefineMode() and "ON" or "OFF"
        table.insert(items, {
            title = "LLM Refine: " .. refineState .. " (" .. getRefineModel() .. ")",
            fn = function() cycleRefine(); updateMenuBar() end,
        })
    else
        table.insert(items, {
            title = "LLM Refine (install ollama.com)",
            disabled = true,
        })
    end

    -- Preferred langs
    local preferred = table.concat(getPreferredLangs(), ", ")
    table.insert(items, { title = "Preferred: " .. preferred, disabled = true })

    table.insert(items, { title = "-" })

    -- Meeting mode
    if meetingRecording then
        local elapsed = hs.timer.secondsSinceEpoch() - (meetingStartTime or 0)
        local mins = math.floor(elapsed / 60)
        table.insert(items, {
            title = "⏹ Stop Meeting Notes (" .. mins .. "m)",
            fn = function() stopMeeting() end,
        })
    else
        table.insert(items, {
            title = "🎙 Start Meeting Notes",
            fn = function() startMeeting() end,
        })
    end

    table.insert(items, { title = "-" })

    -- Settings overlay
    table.insert(items, {
        title = "Settings...",
        fn = function()
            if overlay then
                forceHideOverlay()
            else
                showOverlay()
                overlayPinned = true
                overlay[1].fillColor = { red = 0.15, green = 0.15, blue = 0.2, alpha = 0.92 }
                setOverlayText("Click labels to change settings")
            end
        end,
    })

    -- Recent dictations
    if #recentDictations > 0 then
        table.insert(items, { title = "-" })
        table.insert(items, { title = "Recent Dictations", disabled = true })
        for _, entry in ipairs(recentDictations) do
            local ago = os.time() - entry.time
            local timeStr
            if ago < 60 then timeStr = "just now"
            elseif ago < 3600 then timeStr = math.floor(ago / 60) .. "m ago"
            else timeStr = math.floor(ago / 3600) .. "h ago"
            end
            local preview = entry.text
            if #preview > 40 then preview = preview:sub(1, 37) .. "..." end
            local icon = entry.inserted and "⏎" or "⚡"
            table.insert(items, {
                title = icon .. " " .. preview .. "  " .. timeStr,
                fn = function()
                    hs.pasteboard.setContents(entry.text)
                    hs.eventtap.keyStroke({"cmd"}, 9)  -- keycode 9 = V (ANSI)
                    hs.notify.new({ title = "Pasted", informativeText = entry.text }):send()
                end,
            })
        end
    end

    table.insert(items, { title = "-" })

    -- Reload actions
    table.insert(items, {
        title = "Reload Actions",
        fn = function() WhisperActions.reload() end,
    })

    -- Emergency stop
    table.insert(items, { title = "-" })
    table.insert(items, {
        title = "Emergency Stop",
        fn = function() emergencyStop() end,
    })

    return items
end

local function createMenuBar()
    -- Clean up previous instance on reload
    if menuBar then menuBar:delete(); menuBar = nil end
    menuBar = hs.menubar.new()
    if not menuBar then return end
    updateMenuBar()
    menuBar:setMenu(buildMenuBarMenu)
end

--------------------------------------------------------------------------------
-- Recording indicator (pulsing dot + timer)
--------------------------------------------------------------------------------

local function startRecordingIndicator()
    if not overlay then return end
    recordingStartTime = hs.timer.secondsSinceEpoch()
    pulseAlpha = 1.0
    pulseFading = true

    -- Show dot and timer
    overlay[EL.dot].fillColor = { red = 1, green = 0.15, blue = 0.15, alpha = 1.0 }
    overlay[EL.timer].textColor = { red = 1, green = 0.4, blue = 0.4, alpha = 1.0 }

    -- Pulse the red dot
    pulseTimer = hs.timer.doEvery(0.05, function()
        if not overlay then return end
        if pulseFading then
            pulseAlpha = pulseAlpha - 0.03
            if pulseAlpha <= 0.2 then pulseFading = false end
        else
            pulseAlpha = pulseAlpha + 0.03
            if pulseAlpha >= 1.0 then pulseFading = true end
        end
        overlay[EL.dot].fillColor = { red = 1, green = 0.15, blue = 0.15, alpha = pulseAlpha }
    end)

    -- Update elapsed time every second
    clockTimer = hs.timer.doEvery(1, function()
        if not overlay then return end
        local elapsed = math.floor(hs.timer.secondsSinceEpoch() - recordingStartTime)
        local min = math.floor(elapsed / 60)
        local sec = elapsed % 60
        overlay[EL.timer].text = string.format("%d:%02d", min, sec)
    end)
end

local function stopRecordingIndicator()
    if pulseTimer then pulseTimer:stop(); pulseTimer = nil end
    if clockTimer then clockTimer:stop(); clockTimer = nil end
    if overlay then
        overlay[EL.dot].fillColor = { red = 1, green = 0.15, blue = 0.15, alpha = 0.0 }
        overlay[EL.timer].textColor = { red = 1, green = 0.4, blue = 0.4, alpha = 0.0 }
        overlay[EL.timer].text = ""
    end
end

--------------------------------------------------------------------------------
-- Emergency stop (forward declaration)
--------------------------------------------------------------------------------

function emergencyStop()
    log("emergency stop")
    isRecording = false
    if partialTimer then partialTimer:stop(); partialTimer = nil end
    if silenceTimer then silenceTimer:stop(); silenceTimer = nil end
    stopRecordingIndicator()
    if ffmpegTask and ffmpegTask:isRunning() then ffmpegTask:interrupt() end
    ffmpegTask = nil
    partialBusy = false
    silentChunkCount = 0
    lastCheckedChunk = 0
    forceHideOverlay()
    updateMenuBar()
    os.execute("killall whisper-cli 2>/dev/null")
    hs.notify.new({ title = "local-whisper", informativeText = "Stopped" }):send()
end

--------------------------------------------------------------------------------
-- Partial transcription (live preview while recording)
--------------------------------------------------------------------------------

local function doPartialTranscribe()
    if partialBusy or not isRecording then return end

    local chunks = getChunkFiles()
    local numChunks = #chunks
    if numChunks < 3 then return end

    local completed = numChunks - 1  -- skip last chunk (being written)
    if completed <= lastChunkCount then return end

    partialBusy = true

    -- Batch last 4 completed chunks
    local startIdx = math.max(1, completed - 3)
    local batchList = WHISPER_TMP .. "/partial_concat.txt"
    local f = io.open(batchList, "w")
    for i = startIdx, completed do
        f:write("file '" .. chunks[i] .. "'\n")
    end
    f:close()

    local batchWav = WHISPER_TMP .. "/partial_batch.wav"
    local concatTask = hs.task.new(FFMPEG, function(code)
        if code ~= 0 then
            partialBusy = false
            return
        end
        local lang = getLang()
        -- In auto mode, use first preferred lang for speed during partial transcription
        if lang == "auto" then lang = getPreferredLangs()[1] end
        local whisperArgs = { "-m", getPartialModelPath(), "-f", batchWav, "-l", lang, "-nt", "--no-prints" }
        local promptArgs = getPromptArgs()
        for _, a in ipairs(promptArgs) do table.insert(whisperArgs, a) end
        local whisperTask = hs.task.new(WHISPER_BIN, function(code2, out2)
            partialBusy = false
            lastChunkCount = completed
            if code2 ~= 0 or not isRecording then return end
            local text = (out2 or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
            if text ~= "" and not isHallucination(text) then
                local display = text
                if #display > 200 then display = "..." .. display:sub(-197) end
                setOverlayText(display)
                log("partial: " .. text)
            end
        end, whisperArgs)
        whisperTask:start()
    end, { "-y", "-f", "concat", "-safe", "0", "-i", batchList, "-c", "copy", batchWav })
    concatTask:start()
end

--------------------------------------------------------------------------------
-- Final transcription
--------------------------------------------------------------------------------

-- Low-level text insertion at cursor
local function insertTextAtCursor(text, mode)
    if mode == "paste" then
        -- Note: we intentionally don't save/restore clipboard — getContents() can block
        -- for 60+ seconds if another app holds a large object on the clipboard.
        hs.pasteboard.setContents(text)
        hs.eventtap.keyStroke({"cmd"}, 9)  -- keycode 9 = V (ANSI), works regardless of keyboard layout
    else
        hs.eventtap.keyStrokes(text)
    end
end

-- Finish insertion after all processing (post-process, refine, hooks)
local function finishInsertion(text, detectedLang)
    -- Build action context and run pre-insert hooks
    local ctx = buildActionContext(normalizeText(text), detectedLang or getLang(), getOutputMode())
    runPreInsertActions(ctx)

    local finalText = normalizeText(ctx.text)
    if finalText == "" then
        log("final: empty text after actions")
        hideOverlay()
        return
    end

    if ctx.insert then
        -- Track for undo
        lastInsertedText = finalText
        insertTextAtCursor(finalText, ctx.outputMode)
        ctx.inserted = true

        -- Press Enter after insertion if enter mode is on
        if getEnterMode() then
            hs.timer.doAfter(0.15, function()
                hs.eventtap.keyStroke({}, "return")
            end)
        end
    else
        log("final: insertion disabled by action hooks")
    end

    ctx.text = finalText
    runPostInsertActions(ctx)

    -- Track in recent dictations
    table.insert(recentDictations, 1, {
        text = ctx.originalText,
        time = os.time(),
        inserted = ctx.inserted,
        app = capturedAppName or "?",
    })
    while #recentDictations > MAX_RECENT do
        table.remove(recentDictations)
    end
    saveRecentDictations()

    local display = finalText
    if detectedLang then display = display .. " [" .. detectedLang:upper() .. "]" end
    setOverlayText(display)
    hs.sound.getByFile("/System/Library/Sounds/Glass.aiff"):play()
    hs.timer.doAfter(OVERLAY_LINGER, hideOverlay)
end

-- Insert transcribed text at cursor, with post-processing, optional LLM refinement, and action hooks
local function insertTranscribedText(text, detectedLang)
    if text == "" or isHallucination(text) then
        hideOverlay()
        return
    end

    -- Apply app-aware post-processing
    text = postProcess(text, capturedAppBundleID)
    if text == "" then hideOverlay(); return end

    -- Skip LLM refinement for voice commands (refine would strip the prefix)
    local isVoiceCommand = text:lower():match("voice%s+command")

    -- Optional LLM refinement (async, skips short text and voice commands)
    if not isVoiceCommand and getRefineMode() and #text >= REFINE_MIN_CHARS then
        setOverlayText("Refining...")
        refineWithOllama(text, function(refined)
            finishInsertion(refined, detectedLang)
        end)
    else
        finishInsertion(text, detectedLang)
    end
end

-- Max seconds per whisper call — must stay BELOW whisper's 30s internal window.
-- Exceeding 30s forces a window boundary crossing where the model reliably drops
-- 5-10s of content at the seam. 25s gives a safe margin inside one window.
local FINAL_SEGMENT_SECS = 25

local function doFinalTranscription()
    local chunks = getChunkFiles()

    -- ДИАГНОСТИКА: логируем все чанки и состояние
    log("final: START — total chunks=" .. #chunks .. ", partialBusy=" .. tostring(partialBusy))
    if #chunks > 0 then
        local first = chunks[1]:match("([^/]+)$") or chunks[1]
        local last  = chunks[#chunks]:match("([^/]+)$") or chunks[#chunks]
        log("final: first=" .. first .. "  last=" .. last .. "  duration≈" .. #chunks .. "s")
    end

    if #chunks < 2 then
        log("final: not enough chunks, skipping")
        hideOverlay()
        return
    end

    setOverlayText("Transcribing...")

    local lang = getLang()
    local preferred = getPreferredLangs()
    local promptArgs = getPromptArgs()

    -- Split 1-second chunks into groups of FINAL_SEGMENT_SECS
    local segmentGroups = {}
    local i = 1
    while i <= #chunks do
        local group = {}
        for j = i, math.min(i + FINAL_SEGMENT_SECS - 1, #chunks) do
            table.insert(group, chunks[j])
        end
        table.insert(segmentGroups, group)
        i = i + FINAL_SEGMENT_SECS
    end

    local totalSegs = #segmentGroups
    log("final: segments=" .. totalSegs .. " (FINAL_SEGMENT_SECS=" .. FINAL_SEGMENT_SECS .. ")")
    for si, grp in ipairs(segmentGroups) do
        local gfirst = grp[1]:match("([^/]+)$") or grp[1]
        local glast  = grp[#grp]:match("([^/]+)$") or grp[#grp]
        log("final: seg " .. si .. " → " .. #grp .. " chunks (" .. gfirst .. " … " .. glast .. ")")
    end

    local allTexts = {}
    local detectedLangOverall = nil
    local segIdx = 0

    local function finishAll()
        log("final: finishAll — collected " .. #allTexts .. " text segment(s)")
        local finalText = table.concat(allTexts, " "):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
        log("final combined (" .. totalSegs .. " seg(s)): '" .. finalText .. "'")
        if finalText == "" then
            hideOverlay()
            return
        end
        insertTranscribedText(finalText, detectedLangOverall)
    end

    local function transcribeNextSegment()
        segIdx = segIdx + 1
        if segIdx > totalSegs then
            finishAll()
            return
        end

        local group = segmentGroups[segIdx]
        local n = segIdx

        if totalSegs > 1 then
            setOverlayText(string.format("Transcribing %d/%d...", n, totalSegs))
        end

        local concatFile = WHISPER_TMP .. "/seg_concat_" .. n .. ".txt"
        local segWav    = WHISPER_TMP .. "/seg_" .. n .. ".wav"

        log("final: seg " .. n .. " writing concat list (" .. #group .. " files) → " .. concatFile)
        local f, ferr = io.open(concatFile, "w")
        if not f then
            log("final: seg " .. n .. " ERROR opening concat file: " .. tostring(ferr))
            transcribeNextSegment()
            return
        end
        for _, chunk in ipairs(group) do
            f:write("file '" .. chunk .. "'\n")
        end
        f:close()

        log("final: seg " .. n .. " starting ffmpeg concat → " .. segWav)
        local concatTask = hs.task.new(FFMPEG, function(code)
            if code ~= 0 then
                log("final: seg " .. n .. " concat FAILED (code=" .. tostring(code) .. ")")
                transcribeNextSegment()  -- skip bad segment, keep going
                return
            end
            local wavSize = (hs.fs.attributes(segWav) or {}).size or -1
            log("final: seg " .. n .. " concat OK — wav size=" .. wavSize .. " bytes")

            local function onSegmentText(text, detected)
                log("final: seg " .. n .. " onSegmentText hallucination=" .. tostring(isHallucination(text)) .. " len=" .. #text)
                if text ~= "" and not isHallucination(text) then
                    table.insert(allTexts, text)
                    log("final: seg " .. n .. " accepted text: '" .. text:sub(1, 120) .. "'")
                else
                    log("final: seg " .. n .. " REJECTED (empty or hallucination): '" .. text:sub(1, 80) .. "'")
                end
                if detected and not detectedLangOverall then
                    detectedLangOverall = detected
                end
                transcribeNextSegment()
            end

            -- Always use auto-detect per segment for code-switching (surzhyk/mixed language)
            -- Never reuse a previously detected language — each segment may have different dominant language
            local effectiveLang = lang

            log("final: seg " .. n .. " starting whisper lang=" .. effectiveLang .. " model=" .. getModelPath():match("([^/]+)$"))

            if effectiveLang == "auto" then
                local autoArgs = { "-m", getModelPath(), "-f", segWav, "-l", "auto", "-nt" }
                for _, a in ipairs(promptArgs) do table.insert(autoArgs, a) end
                local wTask = hs.task.new(WHISPER_BIN, function(code2, out2, err2)
                    log("final: seg " .. n .. " whisper(auto) exit=" .. tostring(code2) .. " outlen=" .. #(out2 or "") .. " errlen=" .. #(err2 or ""))
                    if code2 ~= 0 then
                        log("final: seg " .. n .. " whisper FAILED (auto)")
                        transcribeNextSegment()
                        return
                    end
                    local detected = (err2 or ""):match("auto%-detected language:%s*(%w+)")
                    log("seg " .. n .. " auto-detected: " .. tostring(detected))

                    -- Accept whatever language auto-detected — forcing a retry with preferred[1]
                    -- would cause "translation" of mixed-language content (surzhyk, English terms, etc.)
                    local text = (out2 or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
                    onSegmentText(text, detected)
                end, autoArgs)
                wTask:start()
            else
                local langArgs = { "-m", getModelPath(), "-f", segWav, "-l", effectiveLang, "-nt", "--no-prints" }
                for _, a in ipairs(promptArgs) do table.insert(langArgs, a) end
                local wTask = hs.task.new(WHISPER_BIN, function(code2, out2)
                    log("final: seg " .. n .. " whisper(" .. effectiveLang .. ") exit=" .. tostring(code2) .. " outlen=" .. #(out2 or ""))
                    if code2 ~= 0 then
                        log("final: seg " .. n .. " whisper FAILED")
                        transcribeNextSegment()
                        return
                    end
                    local text = (out2 or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
                    log("final seg " .. n .. "/" .. totalSegs .. ": '" .. text .. "'")
                    onSegmentText(text, effectiveLang)
                end, langArgs)
                wTask:start()
            end
        end, { "-y", "-f", "concat", "-safe", "0", "-i", concatFile, "-c", "copy", segWav })
        concatTask:start()
    end

    transcribeNextSegment()
end

--------------------------------------------------------------------------------
-- Auto-stop on silence
--------------------------------------------------------------------------------

local stopRecording -- forward declaration (defined below in Start/stop section)

local function checkSilence()
    if not isRecording then return end
    local chunks = getChunkFiles()
    local numChunks = #chunks
    -- Only check completed chunks (not the one being written)
    local completed = numChunks - 1
    if completed <= lastCheckedChunk then return end

    -- Check the latest completed chunk
    local chunkPath = chunks[completed]
    lastCheckedChunk = completed

    local volTask = hs.task.new(FFMPEG, function(code, out, err)
        if code ~= 0 or not isRecording then return end
        local maxVol = (err or ""):match("max_volume:%s*([-%.%d]+)")
        if maxVol then
            maxVol = tonumber(maxVol)
            if maxVol and maxVol < AUTO_STOP_THRESHOLD_DB then
                silentChunkCount = silentChunkCount + 1
                log("silence: chunk " .. completed .. " vol=" .. maxVol .. "dB (count=" .. silentChunkCount .. ")")
                if silentChunkCount >= AUTO_STOP_SILENCE_SECONDS then
                    log("auto-stop: " .. AUTO_STOP_SILENCE_SECONDS .. "s of silence")
                    stopRecording()
                end
            else
                silentChunkCount = 0
            end
        end
    end, { "-i", chunkPath, "-af", "volumedetect", "-f", "null", "-" })
    volTask:start()
end

--------------------------------------------------------------------------------
-- Start / stop recording
--------------------------------------------------------------------------------

-- Warmup state
local warmupTask = nil
local warmupTimer = nil
local isWarmingUp = false
local warmupAttempt = 0
local WARMUP_ATTEMPT_SECS = 1.0   -- timeout per attempt
local WARMUP_MAX_ATTEMPTS = 10    -- give up after this many retries

local function startActualRecording()
    isWarmingUp = false
    warmupAttempt = 0
    isRecording = true
    log("recording: start")

    os.execute("rm -rf '" .. CHUNK_DIR .. "'")
    os.execute("mkdir -p '" .. CHUNK_DIR .. "'")

    captureActiveApp()
    log("recording: app=" .. tostring(capturedAppName) .. " (" .. tostring(capturedAppBundleID) .. ")")

    setOverlayText("")
    startRecordingIndicator()
    updateMenuBar()
    -- Pop is played once the first chunk appears on disk (audio is truly flowing)

    ffmpegTask = hs.task.new(FFMPEG, function(code, out, err)
        log("recording: ffmpeg exited " .. tostring(code))
        if code == 251 or code == 1 then
            log("recording: ERROR — ffmpeg failed to open audio device '" .. AUDIO_DEVICE .. "'. Check device format (should be :default, :0, :1) and microphone permissions.")
        end
    end, {
        "-f", "avfoundation", "-i", AUDIO_DEVICE,
        "-ac", "1", "-ar", "16000",
        "-f", "segment", "-segment_time", "1", "-segment_format", "wav",
        CHUNK_DIR .. "/chunk_%03d.wav"
    })
    ffmpegTask:start()

    lastChunkCount = 0
    partialBusy = false
    silentChunkCount = 0
    lastCheckedChunk = 0
    -- Partial transcription disabled: low quality, not useful
    -- partialTimer = hs.timer.doEvery(PARTIAL_INTERVAL, doPartialTranscribe)

    -- Poll until first chunk exists on disk → audio is truly flowing → play Pop
    -- Uses recursive doAfter (not doEvery) to avoid stop-within-callback issues.
    local function pollForFirstChunk(attempt)
        if not isRecording then return end  -- recording already stopped, don't play Pop
        local firstChunk = CHUNK_DIR .. "/chunk_000.wav"
        local attr = hs.fs.attributes(firstChunk)
        if (attr and attr.size and attr.size > 200) or attempt >= 200 then
            if attr then
                log("recording: first chunk ready after " .. (attempt * 0.05) .. "s — audio flowing")
            else
                log("recording: first chunk timeout, playing Pop anyway")
            end
            hs.sound.getByFile("/System/Library/Sounds/Pop.aiff"):play()
        else
            hs.timer.doAfter(0.05, function() pollForFirstChunk(attempt + 1) end)
        end
    end
    pollForFirstChunk(0)
end

local function cancelWarmup()
    if warmupTimer then warmupTimer:stop(); warmupTimer = nil end
    if warmupTask and warmupTask:isRunning() then
        warmupTask:interrupt(); warmupTask = nil
    end
end

local tryWarmup  -- forward declaration for recursion

local warmupTick = hs.sound.getByFile("/System/Library/Sounds/Tink.aiff")
if warmupTick then warmupTick:volume(0.15) end

tryWarmup = function()
    if not isWarmingUp then return end

    warmupAttempt = warmupAttempt + 1
    log("warmup: attempt " .. warmupAttempt .. "/" .. WARMUP_MAX_ATTEMPTS)

    -- Subtle tick before each attempt
    if warmupTick then warmupTick:play() end
    setOverlayText("... " .. warmupAttempt .. "/" .. WARMUP_MAX_ATTEMPTS)

    warmupTask = hs.task.new(FFMPEG,
        function(code)  -- termination callback
            warmupTask = nil
        end,
        function(task, stdout, stderr)  -- streaming callback: ffmpeg writes to stderr once device is open
            if stderr and stderr ~= "" and isWarmingUp then
                log("warmup: device ready on attempt " .. warmupAttempt)
                if warmupTimer then warmupTimer:stop(); warmupTimer = nil end
                task:interrupt()
                startActualRecording()
            end
            return true
        end,
        { "-f", "avfoundation", "-i", AUDIO_DEVICE,
          "-ac", "1", "-ar", "16000",
          "-f", "null", "-" }
    )
    warmupTask:start()

    -- If no response within 1s, kill and retry (up to max)
    warmupTimer = hs.timer.doAfter(WARMUP_ATTEMPT_SECS, function()
        warmupTimer = nil
        if not isWarmingUp then return end
        if warmupTask and warmupTask:isRunning() then
            warmupTask:interrupt(); warmupTask = nil
        end
        if warmupAttempt < WARMUP_MAX_ATTEMPTS then
            log("warmup: no response, retrying...")
            tryWarmup()
        else
            -- All attempts exhausted — signal error, do NOT record
            isWarmingUp = false
            warmupAttempt = 0
            log("warmup: FAILED after " .. WARMUP_MAX_ATTEMPTS .. " attempts — audio device unresponsive")
            setOverlayText("Микрофон недоступен")
            hs.sound.getByFile("/System/Library/Sounds/Basso.aiff"):play()
            hs.timer.doAfter(2.5, hideOverlay)
        end
    end)
end

local function startRecording()
    if isRecording or isWarmingUp then return end
    isWarmingUp = true
    warmupAttempt = 0
    log("warmup: probing audio device...")

    setOverlayText("...")
    showOverlay()

    tryWarmup()
end

stopRecording = function()
    -- Cancel warmup if key released before device was ready
    if isWarmingUp then
        isWarmingUp = false
        warmupAttempt = 0
        cancelWarmup()
        log("warmup: cancelled (key released before device ready)")
        hideOverlay()
        return
    end

    if not isRecording then return end
    isRecording = false
    log("recording: stop")

    if partialTimer then partialTimer:stop(); partialTimer = nil end
    if silenceTimer then silenceTimer:stop(); silenceTimer = nil end
    partialBusy = false
    silentChunkCount = 0
    lastCheckedChunk = 0

    stopRecordingIndicator()
    updateMenuBar()

    if ffmpegTask and ffmpegTask:isRunning() then
        ffmpegTask:interrupt()
    end
    ffmpegTask = nil

    hs.sound.getByFile("/System/Library/Sounds/Tink.aiff"):play()

    -- Brief delay for ffmpeg to finalize last chunk
    hs.timer.doAfter(0.3, doFinalTranscription)
end

--------------------------------------------------------------------------------
-- Key detection (replaces Karabiner)
--------------------------------------------------------------------------------

-- Map trigger key to generic modifier name for polling
local GENERIC_MOD = { rightAlt = "alt", rightCmd = "cmd", rightCtrl = "ctrl" }
local genericMod = GENERIC_MOD[TRIGGER_KEY]

local releasePoller = nil

-- Global so we can inspect state via hs -c
_whisper = { modTap = nil, recording = false }

local modTap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(event)
    -- Wrap in pcall so errors don't kill the eventtap
    local ok, err = pcall(function()
        local rawFlags = event:rawFlags()
        local triggered = (rawFlags & triggerMask) > 0

        if triggered and not isRecording then
            startRecording()
            -- Poll for release since flagsChanged doesn't fire on key-up
            if releasePoller then releasePoller:stop() end
            releasePoller = hs.timer.doEvery(0.1, function()
                local mods = hs.eventtap.checkKeyboardModifiers()
                if not mods[genericMod] then
                    releasePoller:stop()
                    releasePoller = nil
                    stopRecording()
                end
            end)
        elseif not triggered and (isRecording or isWarmingUp) then
            if releasePoller then releasePoller:stop(); releasePoller = nil end
            stopRecording()
        end
    end)
    if not ok then log("eventtap error: " .. tostring(err)) end

    return false
end)
modTap:start()
_whisper.modTap = modTap

-- Re-enable eventtap if it gets disabled (e.g. by secure input)
hs.timer.doEvery(5, function()
    if not modTap:isEnabled() then
        log("eventtap was disabled, re-enabling")
        modTap:start()
    end
end)

--------------------------------------------------------------------------------
-- Meeting mode
--------------------------------------------------------------------------------

local MEETINGS_DIR = CONFIG_DIR .. "/meetings"
local MEETING_CHUNK_SECONDS = 8                       -- step between window starts
local MEETING_OVERLAP_SECONDS = 4                     -- audio reused at the head of each window for context
local MEETING_TRANSCRIBE_POLL_SECONDS = 2
local MEETING_WINDOW_TIMEOUT_SECONDS = 60             -- watchdog: kill task if it runs longer than this
local MEETING_PCM_BYTES_PER_SEC = 16000 * 2           -- 16 kHz, mono, 16-bit
local MEETING_AGGREGATE_NAME = "local-whisper Output"
local MEETING_HELPER_BIN = CONFIG_DIR .. "/bin/aggregate-audio"
-- meetingRecording and meetingStartTime are forward-declared before buildMenuBarMenu
local meetingFfmpegTask = nil
local meetingChunkDir = WHISPER_TMP .. "/meeting_chunks"
local meetingPcmPath = meetingChunkDir .. "/recording.pcm"
local meetingTranscript = {}
local meetingNotepad = nil
local meetingTranscribeTimer = nil
local meetingControlTimer = nil
local meetingNextWindowIdx = 1
local meetingLastEmittedText = ""
local meetingStopFlushed = false
local meetingWindowQueue = {}        -- pending windows waiting to slice+transcribe
local meetingProcessing = false      -- one slice+whisper pipeline at a time
local meetingPendingTranscriptions = 0
local meetingStopping = false
local meetingSavingOutput = false
local meetingPriorOutputUID = nil
-- Strong refs to in-flight hs.task objects so they can't be garbage-collected
-- before their callbacks fire. Hammerspoon's hs.task wraps a Lua userdata
-- whose __gc tears down the callback; without this table, locals in the
-- slice/whisper closures may be reaped between spawn and completion and
-- silently drop the callback. Keyed by an opaque token; cleared in callback.
local meetingActiveTasks = {}
local meetingActiveTasksSeq = 0
local saveMeetingOutput

-- Run the aggregate-audio helper synchronously; returns (stdout, exitCode).
local function runAudioHelper(...)
    if not hs.fs.attributes(MEETING_HELPER_BIN) then return nil, -1 end
    local args = { ... }
    local quoted = {}
    for _, a in ipairs(args) do table.insert(quoted, "'" .. tostring(a):gsub("'", "'\\''") .. "'") end
    local cmd = "'" .. MEETING_HELPER_BIN .. "' " .. table.concat(quoted, " ")
    local out, ok, _, code = hs.execute(cmd)
    if out then out = out:gsub("%s+$", "") end
    if ok then return out, 0 end
    return out, code or -1
end

-- Check that everything meeting mode needs is in place.
local function hasBlackHole()
    if not hs.audiodevice.findInputByName("BlackHole 2ch") then return false end
    if not hs.fs.attributes(MEETING_HELPER_BIN) then return false end
    return true
end

-- Get BlackHole device string for ffmpeg (audio-only via avfoundation)
local function getBlackHoleDevice()
    local devices = hs.audiodevice.allInputDevices()
    for _, dev in ipairs(devices) do
        if dev:name() == "BlackHole 2ch" then
            return ":BlackHole 2ch"
        end
    end
    return nil
end

-- Show setup instructions when meeting mode wasn't enabled at install time.
local function showBlackHoleSetup()
    local msg = "Meeting mode is disabled.\n\n"
        .. "To enable it, re-run the installer and answer 'y' when asked\n"
        .. "about meeting recording mode:\n\n"
        .. "  cd ~/code/local-free-openwhisper && ./install.sh\n\n"
        .. "The installer will:\n"
        .. "  1. Install BlackHole 2ch (virtual audio driver)\n"
        .. "  2. Build a small helper at ~/.local-whisper/bin/aggregate-audio\n"
        .. "  3. Create a Multi-Output Device automatically\n\n"
        .. "No manual Audio MIDI Setup steps required."
    hs.dialog.blockAlert("Meeting Mode Setup", msg, "OK")
end

-- Pick a sensible audible fallback output (anything that's not the
-- aggregate and not BlackHole). Used when the user is stranded on the
-- aggregate (e.g., a previous meeting got stuck and didn't restore).
local function pickFallbackOutput()
    local out, code = runAudioHelper("list")
    if code ~= 0 or not out then return nil end
    for line in out:gmatch("[^\n]+") do
        local uid, name = line:match("^([^\t]+)\t(.+)$")
        if uid and name
           and uid ~= "com.local-whisper.aggregate-output"
           and not name:find("BlackHole") then
            return uid
        end
    end
    return nil
end

-- Switch system default output to a freshly-built aggregate so audio
-- flows to both the user's current speakers and BlackHole. Always
-- recreates the aggregate so it tracks the user's current audible
-- device (handles disconnected monitors, headphones plugged in mid-day,
-- etc.). Saves the previous default for restoration on stopMeeting.
local function switchToAggregateOutput()
    local prior, code = runAudioHelper("default-uid")
    if code ~= 0 or not prior or prior == "" then
        log("meeting: cannot read system default output")
        return false
    end

    -- If the user is already stranded on our aggregate (previous meeting
    -- failed to restore), pick a fallback as the audible side first so
    -- the recreated aggregate has a real audible sub-device.
    if prior == "com.local-whisper.aggregate-output" then
        local fallback = pickFallbackOutput()
        if not fallback then
            log("meeting: stranded on aggregate, no audible fallback available")
            return false
        end
        log("meeting: stranded on aggregate, falling back to " .. fallback)
        runAudioHelper("set-default", fallback)
        prior = fallback
    end

    -- Tear down the old aggregate and rebuild against current default.
    local aggUid, aggCode = runAudioHelper("recreate")
    if aggCode ~= 0 or not aggUid or aggUid == "" then
        log("meeting: aggregate recreate failed (helper missing or BlackHole gone)")
        return false
    end

    meetingPriorOutputUID = prior
    local _, setCode = runAudioHelper("set-default", aggUid)
    if setCode ~= 0 then
        log("meeting: failed to switch system output to aggregate")
        meetingPriorOutputUID = nil
        return false
    end
    log("meeting: rebuilt aggregate, switched system output to it (was " .. prior .. ")")
    return true
end

-- On Hammerspoon load, if we boot with system default already on the
-- aggregate, a previous meeting got stuck and never restored. Drop us
-- onto a sensible fallback so the user has audible sound at startup.
local function recoverIfStrandedOnAggregate()
    if not hs.fs.attributes(MEETING_HELPER_BIN) then return end
    local prior = runAudioHelper("default-uid")
    if prior ~= "com.local-whisper.aggregate-output" then return end
    local fallback = pickFallbackOutput()
    if fallback then
        runAudioHelper("set-default", fallback)
        log("meeting: startup recovery — switched stranded output to " .. fallback)
    end
end

-- Restore the system default output saved by switchToAggregateOutput.
local function restorePriorOutput()
    if not meetingPriorOutputUID then return end
    local prior = meetingPriorOutputUID
    meetingPriorOutputUID = nil
    local _, code = runAudioHelper("set-default", prior)
    if code == 0 then
        log("meeting: restored system output to " .. prior)
    else
        log("meeting: failed to restore system output to " .. prior)
    end
end

-- Notepad HTML
local function meetingNotepadHTML(meetingTitle)
    return [[<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
        font-family: -apple-system, BlinkMacSystemFont, sans-serif;
        background: #1a1a2e;
        color: #e0e0e0;
        display: flex;
        flex-direction: column;
        height: 100vh;
        overflow: hidden;
    }
    .header {
        padding: 10px 14px;
        background: #16213e;
        border-bottom: 1px solid #0f3460;
        display: flex;
        justify-content: space-between;
        align-items: center;
        flex-shrink: 0;
    }
    .header h2 {
        font-size: 13px;
        color: #e94560;
        font-weight: 600;
    }
    .header-right {
        display: flex;
        align-items: center;
        gap: 10px;
    }
    .timer {
        font-size: 12px;
        color: #888;
        font-family: monospace;
    }
    .stop-btn {
        border: none;
        border-radius: 6px;
        background: #e94560;
        color: #fff;
        font-size: 11px;
        font-weight: 600;
        padding: 6px 10px;
        cursor: pointer;
    }
    .stop-btn:hover { background: #f15c74; }
    .stop-btn:disabled {
        background: #5b2a34;
        color: #c9a7af;
        cursor: default;
    }
    .tabs {
        display: flex;
        background: #16213e;
        border-bottom: 1px solid #0f3460;
        flex-shrink: 0;
    }
    .tab {
        padding: 6px 14px;
        font-size: 12px;
        cursor: pointer;
        color: #888;
        border-bottom: 2px solid transparent;
    }
    .tab.active {
        color: #e94560;
        border-bottom-color: #e94560;
    }
    .tab:hover { color: #ccc; }
    .panel {
        flex: 1;
        display: none;
        overflow: hidden;
    }
    .panel.active { display: flex; flex-direction: column; }
    .notes-hint {
        padding: 10px 14px 0 14px;
        font-size: 11px;
        line-height: 1.4;
        color: #7f8aa3;
    }
    #notes {
        flex: 1;
        background: #1a1a2e;
        color: #e0e0e0;
        border: none;
        padding: 12px 14px;
        font-size: 13px;
        line-height: 1.5;
        resize: none;
        outline: none;
        font-family: -apple-system, BlinkMacSystemFont, sans-serif;
    }
    #notes::placeholder { color: #555; }
    #transcript {
        flex: 1;
        padding: 12px 14px;
        font-size: 12px;
        line-height: 1.6;
        overflow-y: auto;
        color: #bbb;
        white-space: pre-wrap;
    }
    .transcript-empty {
        padding: 12px 14px;
        color: #6e7890;
        font-size: 12px;
    }
    .chunk {
        margin-bottom: 8px;
        padding-bottom: 8px;
        border-bottom: 1px solid #222;
    }
    .chunk-time {
        font-size: 10px;
        color: #e94560;
        margin-bottom: 2px;
    }
    .status {
        padding: 4px 14px;
        font-size: 11px;
        color: #555;
        background: #16213e;
        border-top: 1px solid #0f3460;
        flex-shrink: 0;
    }
</style>
</head>
<body>
    <div class="header">
        <h2>]] .. meetingTitle .. [[</h2>
        <div class="header-right">
            <span class="timer" id="timer">0:00</span>
            <button class="stop-btn" id="stop-btn" onclick="requestStop()">Stop &amp; Save</button>
        </div>
    </div>
    <div class="tabs">
        <div class="tab active" onclick="switchTab('notes')">My Notes</div>
        <div class="tab" onclick="switchTab('transcript')">Live Transcript</div>
    </div>
    <div class="panel active" id="panel-notes">
        <div class="notes-hint">Use this pane for your own notes. The live transcript appears in the Transcript tab every few seconds.</div>
        <textarea id="notes" placeholder="Type your meeting notes here...&#10;&#10;Tips:&#10;- Key decisions&#10;- Action items&#10;- Questions to follow up"></textarea>
    </div>
    <div class="panel" id="panel-transcript">
        <div class="transcript-empty" id="transcript-empty">Listening... first transcript chunk should appear in about ]] .. tostring(MEETING_CHUNK_SECONDS) .. [[ seconds.</div>
        <div id="transcript"></div>
    </div>
    <div class="status" id="status">Recording from BlackHole 2ch... waiting for first transcript chunk.</div>
<script>
    window.stopRequested = false;

    function switchTab(name) {
        document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
        document.querySelectorAll('.panel').forEach(p => p.classList.remove('active'));
        document.querySelector('.tab[onclick*="' + name + '"]').classList.add('active');
        document.getElementById('panel-' + name).classList.add('active');
    }

    // Timer
    let startTime = Date.now();
    let timerInterval = setInterval(() => {
        let elapsed = Math.floor((Date.now() - startTime) / 1000);
        let min = Math.floor(elapsed / 60);
        let sec = elapsed % 60;
        document.getElementById('timer').textContent = min + ':' + (sec < 10 ? '0' : '') + sec;
    }, 1000);

    function stopTimer() {
        if (timerInterval) { clearInterval(timerInterval); timerInterval = null; }
    }

    // Called from Lua to append transcript chunks
    function appendTranscript(time, text) {
        let empty = document.getElementById('transcript-empty');
        if (empty) empty.remove();
        let div = document.createElement('div');
        div.className = 'chunk';
        let timeDiv = document.createElement('div');
        timeDiv.className = 'chunk-time';
        timeDiv.textContent = time;
        let textDiv = document.createElement('div');
        textDiv.textContent = text;
        div.appendChild(timeDiv);
        div.appendChild(textDiv);
        let container = document.getElementById('transcript');
        container.appendChild(div);
        container.scrollTop = container.scrollHeight;
    }

    function setStatus(msg) {
        document.getElementById('status').textContent = msg;
    }

    function requestStop() {
        window.stopRequested = true;
        let button = document.getElementById('stop-btn');
        button.disabled = true;
        button.textContent = 'Stopping...';
        setStatus('Stopping meeting and saving notes...');
        stopTimer();
    }

    function setStoppingState() {
        let button = document.getElementById('stop-btn');
        button.disabled = true;
        button.textContent = 'Stopping...';
        stopTimer();
    }

    function setSavedState() {
        let button = document.getElementById('stop-btn');
        button.disabled = true;
        button.textContent = 'Saved';
        stopTimer();
    }

    function getNotes() {
        return document.getElementById('notes').value;
    }
</script>
</body>
</html>]]
end

-- Create and show the notepad window
local function showMeetingNotepad()
    if meetingNotepad then meetingNotepad:delete(); meetingNotepad = nil end

    local screen = hs.screen.mainScreen():frame()
    local w, h = 380, 500
    local x = screen.x + screen.w - w - 20
    local y = screen.y + 60

    local title = os.date("Meeting — %H:%M")

    meetingNotepad = hs.webview.new({ x = x, y = y, w = w, h = h })
    meetingNotepad:windowStyle({ "titled", "closable", "resizable", "miniaturizable" })
    meetingNotepad:level(hs.canvas.windowLevels.floating)
    meetingNotepad:allowTextEntry(true)
    meetingNotepad:windowTitle("Meeting Notes")
    meetingNotepad:html(meetingNotepadHTML(title))
    meetingNotepad:show()
    meetingNotepad:bringToFront()
end

-- Get user notes from the notepad
local function getMeetingNotes(callback)
    if not meetingNotepad then callback(""); return end
    meetingNotepad:evaluateJavaScript("getNotes()", function(result, err)
        callback(result or "")
    end)
end

-- Append a transcript chunk to the notepad
local function appendTranscriptToNotepad(timeStr, text)
    if not meetingNotepad then return end
    local escaped = text:gsub("\\", "\\\\"):gsub("'", "\\'"):gsub("\n", "\\n"):gsub("\r", "")
    local timeEscaped = timeStr:gsub("'", "\\'")
    meetingNotepad:evaluateJavaScript("appendTranscript('" .. timeEscaped .. "', '" .. escaped .. "')")
end

local function setNotepadStatus(msg)
    if not meetingNotepad then return end
    local escaped = msg:gsub("\\", "\\\\"):gsub("'", "\\'")
    meetingNotepad:evaluateJavaScript("setStatus('" .. escaped .. "')")
end

local function setNotepadStoppingState()
    if not meetingNotepad then return end
    meetingNotepad:evaluateJavaScript("setStoppingState()")
end

local function setNotepadSavedState()
    if not meetingNotepad then return end
    meetingNotepad:evaluateJavaScript("setSavedState()")
end

local function pollMeetingControls()
    if not meetingNotepad or not meetingRecording or meetingStopping then return end
    meetingNotepad:evaluateJavaScript("window.stopRequested === true", function(result, err)
        if result == true or result == "true" or result == 1 then
            stopMeeting()
        end
    end)
end

local function maybeFinalizeMeetingSave()
    if not meetingStopping or meetingSavingOutput or meetingPendingTranscriptions > 0 then return end
    meetingSavingOutput = true
    setNotepadStatus("Saving meeting notes...")
    getMeetingNotes(function(notes)
        saveMeetingOutput(notes, function(filepath)
            meetingStopping = false
            if meetingControlTimer then meetingControlTimer:stop(); meetingControlTimer = nil end
            restorePriorOutput()
            setNotepadSavedState()
            updateMenuBar()
            hs.notify.new({
                title = "Meeting notes saved",
                informativeText = filepath,
            }):send()
        end)
    end)
end

-- Bounds (in seconds) of the Nth transcription window. Windows after the
-- first start MEETING_OVERLAP_SECONDS earlier than the previous one ended,
-- giving whisper context across word boundaries.
local function meetingWindowBounds(idx)
    if idx == 1 then return 0, MEETING_CHUNK_SECONDS end
    local startSec = MEETING_CHUNK_SECONDS * (idx - 1) - MEETING_OVERLAP_SECONDS
    local endSec   = MEETING_CHUNK_SECONDS * idx
    return startSec, endSec
end

-- Remove the duplicated overlap region from the start of `curr`. Whisper's
-- output for the same audio shifts with context, so an exact suffix/prefix
-- match almost never fires. Instead: search for the last K words of `prev`
-- anywhere in the first half of `curr`, and strip everything up to and
-- including that match. K decreases from 6 down to 3 to allow for word
-- drops; below 3 false-positive risk on common phrases is too high.
local function stripOverlap(prev, curr)
    if prev == "" or curr == "" then return curr end
    local function words(s)
        local out = {}
        for w in s:gmatch("%S+") do table.insert(out, w) end
        return out
    end
    local function norm(w)
        local s = w:lower():gsub("^[%p]+", ""):gsub("[%p]+$", "")
        return s  -- discard gsub's replacement-count second return value
    end
    local p, c = words(prev), words(curr)
    if #p < 3 or #c < 3 then return curr end
    local searchLimit = math.min(#c - 1, math.max(8, math.floor(#c * 0.6)))
    for k = math.min(6, #p), 3, -1 do
        local tail = {}
        for i = #p - k + 1, #p do table.insert(tail, norm(p[i])) end
        for startPos = 1, searchLimit - k + 1 do
            local match = true
            for j = 1, k do
                if norm(c[startPos + j - 1]) ~= tail[j] then match = false; break end
            end
            if match then
                local out = {}
                for i = startPos + k, #c do table.insert(out, c[i]) end
                return table.concat(out, " ")
            end
        end
    end
    return curr
end

local sliceAndTranscribeWindow  -- forward decl

-- Pop the next pending window off the queue and run it. Whisper.cpp on
-- Apple Silicon Metal doesn't tolerate concurrent invocations well (they
-- deadlock racing for the GPU), so the pipeline serializes here.
local function processNextWindow()
    if meetingProcessing then return end
    if #meetingWindowQueue == 0 then return end
    local job = table.remove(meetingWindowQueue, 1)
    meetingProcessing = true
    sliceAndTranscribeWindow(job.idx, job.startSec, job.endSec)
end

-- Slice [startSec, endSec) from the growing PCM recording into a temp WAV,
-- then run whisper on it; on success, dedupe overlap and append to the
-- transcript. Two-stage hs.task pipeline: ffmpeg → whisper. Serialized
-- via meetingProcessing/meetingWindowQueue.
sliceAndTranscribeWindow = function(idx, startSec, endSec)
    local windowPath = string.format("%s/window_%04d.wav", meetingChunkDir, idx)
    local outPrefix  = string.format("%s/window_%04d", meetingChunkDir, idx)
    local outTxtPath = outPrefix .. ".txt"
    local startLabelSec = MEETING_CHUNK_SECONDS * (idx - 1)
    local timeStr = string.format("%d:%02d",
        math.floor(startLabelSec / 60), startLabelSec % 60)

    -- pending count was already incremented by enqueueWindow

    local released = false
    local taskToken
    local watchdog
    local function release(reason)
        if released then return end
        released = true
        if watchdog then watchdog:stop(); watchdog = nil end
        if taskToken then meetingActiveTasks[taskToken] = nil; taskToken = nil end
        os.remove(windowPath)
        os.remove(outTxtPath)
        meetingPendingTranscriptions = math.max(0, meetingPendingTranscriptions - 1)
        meetingProcessing = false
        if reason then log("meeting: window " .. idx .. " released: " .. reason) end
        maybeFinalizeMeetingSave()
        processNextWindow()
    end

    -- Single shell pipeline: ffmpeg slices PCM → whisper writes -otxt file.
    -- Replaces the previous nested hs.task (slice's callback spawning whisper),
    -- which was hanging on the second window — whisper exited cleanly but the
    -- inner hs.task callback never fired. With one task we get one reliable
    -- exit callback; whisper output is read from the file, not piped stdout.
    local model = getModelPath()
    local function shquote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
    local cmd = string.format(
        "set -e\n" ..
        "%s -y -hide_banner -loglevel error -f s16le -ar 16000 -ac 1 -ss %.3f -i %s -t %.3f %s\n" ..
        "%s -m %s -f %s -otxt -of %s --no-prints -t 4 -l auto >/dev/null 2>&1\n",
        shquote(FFMPEG), startSec, shquote(meetingPcmPath), endSec - startSec, shquote(windowPath),
        shquote(WHISPER_BIN), shquote(model), shquote(windowPath), shquote(outPrefix)
    )

    meetingActiveTasksSeq = meetingActiveTasksSeq + 1
    taskToken = "win_" .. idx .. "_" .. meetingActiveTasksSeq

    local task = hs.task.new("/bin/sh", function(code, _stdout, _stderr)
        if released then return end  -- watchdog already handled this
        if code ~= 0 then
            log("meeting: window " .. idx .. " pipeline exited " .. tostring(code))
            release(nil)
            return
        end
        local ok, err = pcall(function()
            local f = io.open(outTxtPath, "r")
            if not f then
                log("meeting: window " .. idx .. " no output file")
                return
            end
            local raw = f:read("*all") or ""
            f:close()
            local text = raw:gsub("%[.*%]", ""):gsub("^%s+", ""):gsub("%s+$", "")
            if text == "" or isHallucination(text) then return end
            local emit = stripOverlap(meetingLastEmittedText, text)
            meetingLastEmittedText = text
            if emit ~= "" then
                table.insert(meetingTranscript, { time = timeStr, text = emit })
                appendTranscriptToNotepad(timeStr, emit)
                log("meeting: window " .. idx .. " → " .. #emit .. " chars (raw " .. #text .. ")")
            end
        end)
        if not ok then
            log("meeting: window " .. idx .. " emit error: " .. tostring(err))
        end
        release(nil)
    end, { "-c", cmd })
    task:setEnvironment({ HOME = HOME, PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" })
    meetingActiveTasks[taskToken] = task

    -- Watchdog: if a window's pipeline runs longer than the timeout (whisper
    -- hangs, OS-level pipe stuck, whatever), kill it and release the lock so
    -- subsequent windows aren't blocked forever.
    watchdog = hs.timer.doAfter(MEETING_WINDOW_TIMEOUT_SECONDS, function()
        if released then return end
        log("meeting: window " .. idx .. " timed out after " .. MEETING_WINDOW_TIMEOUT_SECONDS .. "s, killing")
        if task and task:isRunning() then task:terminate() end
        release("watchdog timeout")
    end)

    log("meeting: window " .. idx .. " starting [" .. string.format("%.1f, %.1f", startSec, endSec) .. "]")
    if not task:start() then
        release("pipeline failed to start")
    end
end

-- Enqueue a window job and inc the pending count up front (so save logic
-- waits for it). Actual slicing+whisper runs serialized via processNextWindow.
local function enqueueWindow(idx, startSec, endSec)
    meetingPendingTranscriptions = meetingPendingTranscriptions + 1
    table.insert(meetingWindowQueue, { idx = idx, startSec = startSec, endSec = endSec })
end

-- Tick: enqueue any windows whose audio has fully arrived in recording.pcm.
local function emitReadyWindows()
    if not meetingRecording and not meetingStopping then return end
    local attr = hs.fs.attributes(meetingPcmPath)
    if not attr or attr.size <= 0 then return end
    local recordedSec = attr.size / MEETING_PCM_BYTES_PER_SEC
    local startSec, endSec = meetingWindowBounds(meetingNextWindowIdx)
    while recordedSec >= endSec do
        log(string.format("meeting: enqueue window %d [%.1f, %.1f] (recorded %.1fs, queue=%d, processing=%s)",
            meetingNextWindowIdx, startSec, endSec, recordedSec,
            #meetingWindowQueue, tostring(meetingProcessing)))
        enqueueWindow(meetingNextWindowIdx, startSec, endSec)
        meetingNextWindowIdx = meetingNextWindowIdx + 1
        startSec, endSec = meetingWindowBounds(meetingNextWindowIdx)
    end
    processNextWindow()
end

-- Stop-time flush: enqueue one last partial window for [next.start, recording-end).
local function emitFinalPartialWindow()
    if meetingStopFlushed then return end
    meetingStopFlushed = true
    local attr = hs.fs.attributes(meetingPcmPath)
    if not attr or attr.size <= 0 then return end
    local recordedSec = attr.size / MEETING_PCM_BYTES_PER_SEC
    local startSec, _ = meetingWindowBounds(meetingNextWindowIdx)
    if recordedSec - startSec < 1.0 then return end  -- skip tail under 1s
    enqueueWindow(meetingNextWindowIdx, startSec, recordedSec)
    meetingNextWindowIdx = meetingNextWindowIdx + 1
    processNextWindow()
end

-- Save meeting output as markdown
saveMeetingOutput = function(notes, callback)
    os.execute("mkdir -p '" .. MEETINGS_DIR .. "'")
    local filename = os.date("%Y-%m-%d-%H%M") .. ".md"
    local filepath = MEETINGS_DIR .. "/" .. filename

    -- Build transcript text
    local transcriptText = ""
    for _, chunk in ipairs(meetingTranscript) do
        transcriptText = transcriptText .. "[" .. chunk.time .. "] " .. chunk.text .. "\n\n"
    end

    -- Build the markdown
    local md = "# Meeting Notes — " .. os.date("%Y-%m-%d %H:%M") .. "\n\n"

    if notes and notes:gsub("%s+", "") ~= "" then
        md = md .. "## My Notes\n\n" .. notes .. "\n\n"
    end

    if transcriptText ~= "" then
        md = md .. "## Transcript\n\n" .. transcriptText
    end

    -- Try to summarize with Ollama
    if getRefineMode() and hasOllama() and #transcriptText > 100 then
        setNotepadStatus("Generating summary with Ollama...")
        local summaryPrompt = "Summarize this meeting transcript into: 1) Key Points (bullet list), 2) Action Items (bullet list), 3) Decisions Made (bullet list). Be concise. Output ONLY the summary in markdown format.\n\n" .. transcriptText:sub(1, 4000)
        local jsonPayload = hs.json.encode({
            model = getRefineModel(),
            prompt = summaryPrompt,
            stream = false,
        })
        local tmpPayload = WHISPER_TMP .. "/meeting_summary_payload.json"
        local f = io.open(tmpPayload, "w")
        if f then f:write(jsonPayload); f:close() end
        local task = hs.task.new("/usr/bin/curl", function(code, stdout, stderr)
            if code == 0 and stdout and #stdout > 0 then
                local ok, result = pcall(hs.json.decode, stdout)
                if ok and result and result.response then
                    local summary = result.response:gsub("^%s+", ""):gsub("%s+$", "")
                    if summary ~= "" then
                        md = "# Meeting Notes — " .. os.date("%Y-%m-%d %H:%M") .. "\n\n"
                            .. "## Summary\n\n" .. summary .. "\n\n"
                        if notes and notes:gsub("%s+", "") ~= "" then
                            md = md .. "## My Notes\n\n" .. notes .. "\n\n"
                        end
                        md = md .. "## Full Transcript\n\n" .. transcriptText
                        log("meeting: summary generated (" .. #summary .. " chars)")
                    end
                end
            end
            -- Save regardless of summary success
            local fout = io.open(filepath, "w")
            if fout then fout:write(md); fout:close() end
            log("meeting: saved to " .. filepath)
            setNotepadStatus("Saved to " .. filepath)
            callback(filepath)
        end, {
            "-s", "-X", "POST",
            "http://localhost:11434/api/generate",
            "-H", "Content-Type: application/json",
            "-d", "@" .. tmpPayload,
            "--max-time", "60",
        })
        task:setEnvironment({ HOME = HOME, PATH = "/usr/bin:/bin" })
        task:start()
    else
        local fout = io.open(filepath, "w")
        if fout then fout:write(md); fout:close() end
        log("meeting: saved to " .. filepath)
        setNotepadStatus("Saved to " .. filepath)
        callback(filepath)
    end
end

-- Start meeting recording
startMeeting = function()
    if meetingRecording then return end
    if not hasBlackHole() then
        showBlackHoleSetup()
        return
    end

    meetingRecording = true
    meetingStartTime = hs.timer.secondsSinceEpoch()
    meetingTranscript = {}
    meetingNextWindowIdx = 1
    meetingLastEmittedText = ""
    meetingStopFlushed = false
    meetingWindowQueue = {}
    meetingProcessing = false
    meetingPendingTranscriptions = 0
    meetingStopping = false
    meetingSavingOutput = false

    os.execute("rm -rf '" .. meetingChunkDir .. "'")
    os.execute("mkdir -p '" .. meetingChunkDir .. "'")

    log("meeting: start")

    -- Route system audio through the aggregate so BlackHole receives it.
    switchToAggregateOutput()

    -- Show notepad
    showMeetingNotepad()

    -- Record system audio (via BlackHole) AND the user's microphone, mixed
    -- into a single growing raw PCM file. A Lua-side slicer (emitReadyWindows)
    -- pulls overlapping windows out of this file and runs whisper on them,
    -- so words straddling chunk boundaries don't get cut.
    local bhDevice = getBlackHoleDevice()
    local micDev = hs.audiodevice.defaultInputDevice()
    local micName = micDev and micDev:name() or nil
    if micName == "BlackHole 2ch" then micName = nil end

    local args = { "-y", "-f", "avfoundation", "-i", bhDevice }
    if micName then
        table.insert(args, "-f")
        table.insert(args, "avfoundation")
        table.insert(args, "-i")
        table.insert(args, ":" .. micName)
        table.insert(args, "-filter_complex")
        table.insert(args, "[0:a][1:a]amix=inputs=2:duration=longest:dropout_transition=0")
        log("meeting: capturing system audio + mic '" .. micName .. "'")
    else
        log("meeting: capturing system audio only (no default input device)")
    end
    for _, a in ipairs({
        "-ac", "1", "-ar", "16000",
        "-f", "s16le",
        meetingPcmPath,
    }) do table.insert(args, a) end

    meetingFfmpegTask = hs.task.new(FFMPEG, function(code, out, err)
        log("meeting: ffmpeg exited " .. tostring(code))
    end, args)
    meetingFfmpegTask:setEnvironment({ HOME = HOME, PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" })
    meetingFfmpegTask:start()

    -- Periodically slice ready overlapping windows out of the growing PCM
    meetingTranscribeTimer = hs.timer.doEvery(MEETING_TRANSCRIBE_POLL_SECONDS, emitReadyWindows)
    if meetingControlTimer then meetingControlTimer:stop(); meetingControlTimer = nil end
    meetingControlTimer = hs.timer.doEvery(0.5, pollMeetingControls)

    updateMenuBar()
    hs.notify.new({ title = "local-whisper", informativeText = "Meeting recording started" }):send()
end

-- Stop meeting recording
stopMeeting = function()
    if not meetingRecording then return end
    meetingRecording = false
    log("meeting: stop")

    -- Stop ffmpeg
    if meetingFfmpegTask and meetingFfmpegTask:isRunning() then
        meetingFfmpegTask:interrupt()
    end
    meetingFfmpegTask = nil

    -- Stop the slice/poll timers
    if meetingTranscribeTimer then meetingTranscribeTimer:stop(); meetingTranscribeTimer = nil end
    if meetingControlTimer then meetingControlTimer:stop(); meetingControlTimer = nil end
    meetingStopping = true
    setNotepadStoppingState()

    setNotepadStatus("Transcribing final window...")
    hs.timer.doAfter(2, function()
        emitReadyWindows()         -- catch any complete windows still pending
        emitFinalPartialWindow()   -- flush trailing audio shorter than a full step
        maybeFinalizeMeetingSave()
    end)

    updateMenuBar()
end

--------------------------------------------------------------------------------
-- Startup
--------------------------------------------------------------------------------

-- Request mic permission (child processes via hs.task inherit it)
if type(hs.microphoneState) == "function" and not hs.microphoneState() then
    log("requesting microphone permission")
    hs.microphoneState(true)
end

-- If a previous Hammerspoon session left us stranded on the meeting
-- aggregate (e.g., the meeting got stuck and never restored), drop us
-- onto an audible fallback so the user has sound at startup.
recoverIfStrandedOnAggregate()

-- Global state-dump callable from outside Hammerspoon via:
--   /Applications/Hammerspoon.app/Contents/Frameworks/hs/hs -c "meetingDoctor()"
-- Used by tools/meeting-doctor.sh. Prints a one-shot snapshot of meeting
-- state — exactly what's needed to debug a stuck meeting without poking
-- around init.lua internals.
function _G.meetingDoctor()
    local lines = {}
    local function add(k, v) table.insert(lines, k .. "=" .. tostring(v)) end
    add("meetingRecording", meetingRecording)
    add("meetingStopping", meetingStopping)
    add("meetingSavingOutput", meetingSavingOutput)
    add("meetingProcessing", meetingProcessing)
    add("meetingPendingTranscriptions", meetingPendingTranscriptions)
    add("meetingNextWindowIdx", meetingNextWindowIdx)
    add("meetingQueueLen", #meetingWindowQueue)
    add("meetingPriorOutputUID", meetingPriorOutputUID or "<nil>")
    add("meetingFfmpegRunning", meetingFfmpegTask and meetingFfmpegTask:isRunning() or false)
    local active = 0
    for _ in pairs(meetingActiveTasks) do active = active + 1 end
    add("meetingActiveTasks", active)
    local activeKeys = {}
    for k, t in pairs(meetingActiveTasks) do
        table.insert(activeKeys, k .. "(running=" .. tostring(t and t:isRunning()) .. ")")
    end
    add("meetingActiveTasksDetail", table.concat(activeKeys, ","))
    local attr = hs.fs.attributes(meetingPcmPath)
    add("recordingPcmBytes", attr and attr.size or 0)
    if attr and attr.size > 0 then
        add("recordingPcmSeconds", string.format("%.1f", attr.size / MEETING_PCM_BYTES_PER_SEC))
    end
    return table.concat(lines, "\n")
end

-- Also restore on Hammerspoon shutdown / reload, in case a meeting is
-- mid-flight when the user reloads config.
hs.shutdownCallback = function()
    if meetingRecording or meetingStopping then
        if meetingFfmpegTask and meetingFfmpegTask:isRunning() then
            meetingFfmpegTask:interrupt()
        end
        if meetingPriorOutputUID then
            runAudioHelper("set-default", meetingPriorOutputUID)
        end
    end
end

-- Create default preferred langs file if it doesn't exist
if readFile(PREFERRED_LANGS_FILE) == "" then
    writeFile(PREFERRED_LANGS_FILE, "en,pt")
end

-- Create menu bar icon
createMenuBar()

-- Load action hooks
local actionsEnabled = loadActionConfig() ~= nil
log("actions: " .. (actionsEnabled and "enabled" or "disabled"))

local enterStatus = getEnterMode() and "⏎" or ""
local actionsFlag = actionsEnabled and " +actions" or ""
log("loaded (trigger=" .. TRIGGER_KEY .. ", lang=" .. getLang() .. ", output=" .. getOutputMode() .. ", model=" .. getModelName() .. ", preferred=" .. table.concat(getPreferredLangs(), ",") .. ")")
hs.notify.new({
    title = "local-whisper",
    informativeText = "Loaded (" .. getLang():upper() .. " / " .. getOutputMode():upper() .. enterStatus .. " / " .. getModelName() .. actionsFlag .. ") — hold " .. TRIGGER_KEY
}):send()
