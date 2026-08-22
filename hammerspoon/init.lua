-- init.lua — local-whisper: Hammerspoon-only dictation
-- Hold a modifier key → record → transcribe → insert at cursor
-- No Karabiner needed. Just Hammerspoon + ffmpeg + whisper.cpp

require("hs.ipc")

-- Required so the overlay canvas can appear above full-screen apps/spaces on any
-- display (e.g. a full-screen Remote Desktop session) — see hs.canvas:bringToFront notes.
hs.dockicon.hide()

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
-- Native mic recorder (tools/lw-record.swift). ffmpeg's avfoundation input drops ~10% of
-- the samples it captures — see the comment at the top of that file. ffmpeg still does the
-- segment concat here and all format conversion in tools/transcribe.sh; only the microphone
-- is opened by this binary.
local RECORDER_BIN = CONFIG_DIR .. "/bin/lw-record"
local MODELS_DIR = HOME .. "/whisper.cpp/models"
local MODEL_FILE = CONFIG_DIR .. "/model"

-- Remote OpenAI-compatible transcription API (alternative to local whisper-cli)
local API = {
    MODEL_NAME = "API",  -- sentinel value stored in MODEL_FILE when API mode is selected
    URL = "http://192.168.0.13:13305/v1/audio/transcriptions",
    MODEL_ID = "Whisper-Large-v3",  -- must match the model id the server has loaded (GET /v1/models)
    CURL_BIN = "/usr/bin/curl",
}

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
    if saved == API.MODEL_NAME then return API.MODEL_NAME end
    if saved ~= "" then
        -- Verify model file exists
        local path = MODELS_DIR .. "/ggml-" .. saved .. ".bin"
        local attr = hs.fs.attributes(path)
        if attr then return saved end
    end
    return "medium"  -- default
end

local function isApiMode()
    return getModelName() == API.MODEL_NAME
end

local function getModelPath()
    return MODELS_DIR .. "/ggml-" .. getModelName() .. ".bin"
end

-- Audio device: lw-record captures from the system default input (AVAudioEngine's input
-- node). The old AUDIO_DEVICE constant selected an ffmpeg avfoundation index and was
-- hardcoded to ":default", so nothing is lost by dropping it.

-- Trigger: which modifier(s) must be held down to record. See TRIGGERS below.
local TRIGGER_KEY = "fnLeftCtrl"

-- User preference files (all in CONFIG_DIR)
local LANG_FILE = CONFIG_DIR .. "/lang"
local OUTPUT_FILE = CONFIG_DIR .. "/output"
local ENTER_FILE = CONFIG_DIR .. "/enter"
local PROMPT_FILE = CONFIG_DIR .. "/prompt"
local RECENT_FILE = CONFIG_DIR .. "/recent.json"
local LOG_FILE = WHISPER_TMP .. "/whisper-dictate.log"

-- Action hooks config
local ACTIONS_FILE = HOME .. "/.hammerspoon/local_whisper_actions.lua"

-- Timing
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

local RAWFLAGS = hs.eventtap.event.rawFlagMasks

-- Two masks per trigger, because the press and the release are read through different
-- APIs that do not report the same bits:
--   mask     — matched against a flagsChanged event's rawFlags, which carry the
--              device-specific bits (deviceLeftControl), so left and right stay distinct.
--   heldMask — matched against hs.eventtap.checkKeyboardModifiers(true)._raw, which comes
--              from CGEventSourceFlagsState and reports ONLY the generic bits. Posting
--              rawFlags 0x800001 (fn|deviceLeftControl) reads back as 0x800000: the device
--              bit is gone. A device bit in heldMask can therefore never match, and the
--              release poller would stop the recording 0.1s after it started.
local TRIGGERS = {
    rightAlt   = { mask = RAWFLAGS.deviceRightAlternate, heldMask = RAWFLAGS.alternate, label = "right Option" },
    rightCmd   = { mask = RAWFLAGS.deviceRightCommand,   heldMask = RAWFLAGS.command,   label = "right Command" },
    rightCtrl  = { mask = RAWFLAGS.deviceRightControl,   heldMask = RAWFLAGS.control,   label = "right Control" },
    fnLeftCtrl = { mask     = RAWFLAGS.secondaryFn | RAWFLAGS.deviceLeftControl,
                   heldMask = RAWFLAGS.secondaryFn | RAWFLAGS.control,
                   label    = "fn + left Control" },
}

local trigger = TRIGGERS[TRIGGER_KEY]
if not trigger then
    hs.notify.new({ title = "local-whisper", informativeText = "ERROR: Invalid TRIGGER_KEY: " .. TRIGGER_KEY }):send()
    return
end

-- Every bit of the mask must be set. A combo trigger (fn + left Control) must not fire on
-- Control alone, which is exactly what a `> 0` test would do — and it would then start a
-- recording on every Ctrl-C the user types.
local function triggerPressed(rawFlags)
    return (rawFlags & trigger.mask) == trigger.mask
end

-- flagsChanged does not fire on key-up for every modifier, so the release is polled by
-- re-reading the live keyboard state — through heldMask, since this API drops the
-- device-specific bits (see TRIGGERS above).
local function triggerHeld()
    local raw = hs.eventtap.checkKeyboardModifiers(true)._raw or 0
    return (raw & trigger.heldMask) == trigger.heldMask
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

-- Compile tools/lw-record.swift → RECORDER_BIN if it is missing or older than its source.
-- Runs at load time, never on a keypress, so a rebuild can't delay a recording. The repo
-- lives wherever this file's symlink points, so resolve it rather than hardcoding a path.
local function ensureRecorder()
    local this = debug.getinfo(1, "S").source:match("^@(.*)$")
    if not this then return end
    local real = hs.fs.symlinkAttributes(this, "target") or this
    local src = real:match("^(.*)/hammerspoon/init%.lua$")
    if not src then return end
    src = src .. "/tools/lw-record.swift"

    local srcAttr = hs.fs.attributes(src)
    if not srcAttr then
        log("recorder: source missing at " .. src)
        return
    end
    local binAttr = hs.fs.attributes(RECORDER_BIN)
    if binAttr and binAttr.modification >= srcAttr.modification then return end

    log("recorder: building " .. RECORDER_BIN)
    os.execute("mkdir -p '" .. CONFIG_DIR .. "/bin'")
    local ok = os.execute("/usr/bin/swiftc -O -o '" .. RECORDER_BIN .. "' '" .. src .. "' 2>>'" .. LOG_FILE .. "'")
    log("recorder: build " .. (ok and "OK" or "FAILED — recording will not work"))
end

ensureRecorder()

-- Play a system sound by name. getByFile returns nil if the file is missing or AudioToolbox
-- fails to load it, and indexing that nil throws — which previously aborted whichever
-- callback was mid-flight, stranding the overlay on screen. Never let a chime break a flow.
local function playSound(name, volume)
    local ok, snd = pcall(hs.sound.getByFile, "/System/Library/Sounds/" .. name .. ".aiff")
    if not ok or not snd then
        log("sound: could not load " .. name)
        return
    end
    if volume then snd:volume(volume) end
    pcall(function() snd:play() end)
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
    if mode == "copy" then return "copy" end
    return "paste"
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
    -- Sort by the numeric index, not lexicographically: the recorder's %03d overflows past
    -- 999 ("chunk_1000.wav" sorts before "chunk_999.wav" as a string), which would splice the
    -- tail of any recording longer than ~16m40s into the middle of the transcript.
    table.sort(chunks, function(a, b)
        local ia = tonumber(a:match("chunk_(%d+)%.wav$")) or 0
        local ib = tonumber(b:match("chunk_(%d+)%.wav$")) or 0
        if ia == ib then return a < b end
        return ia < ib
    end)
    return chunks
end

-- RMS of a 16-bit mono WAV, read directly in Lua (no subprocess — this runs once per
-- candidate chunk while the user waits for their text).
local function getWavRMS(wavPath)
    local f = io.open(wavPath, "rb")
    if not f then return math.huge end
    f:seek("set", 44)  -- skip standard WAV header
    local data = f:read("*all")
    f:close()
    if not data or #data < 2 then return math.huge end
    local sum = 0
    local n = math.floor(#data / 2)
    for i = 1, n * 2 - 1, 2 do
        local lo = data:byte(i)
        local hi = data:byte(i + 1)
        local s = hi * 256 + lo
        if s >= 32768 then s = s - 65536 end
        sum = sum + s * s
    end
    return n > 0 and math.sqrt(sum / n) or math.huge
end

-- Split the chunk list into groups no longer than maxSecs, breaking at the quietest
-- 1-second chunk within the last lookbackSecs of each window rather than at a fixed
-- index. A hard cut lands mid-word: the two halves are transcribed independently, so
-- the word is mangled or duplicated across the seam ("...передавали." / "давали...").
local function splitAtSilence(chunks, maxSecs, lookbackSecs)
    lookbackSecs = lookbackSecs or 8
    local groups = {}
    local i = 1
    while i <= #chunks do
        if #chunks - i + 1 <= maxSecs then
            local group = {}
            for j = i, #chunks do table.insert(group, chunks[j]) end
            table.insert(groups, group)
            break
        end
        -- Scan back from the hard boundary for the quietest chunk, but never move the
        -- boundary earlier than halfway through the window — otherwise a long unbroken
        -- passage would shrink every segment down to maxSecs/2.
        local hardEnd   = i + maxSecs - 1
        local scanStart = math.max(i + math.floor(maxSecs / 2), hardEnd - lookbackSecs + 1)
        local bestIdx   = hardEnd
        local bestRMS   = math.huge
        for j = hardEnd, scanStart, -1 do
            local rms = getWavRMS(chunks[j])
            if rms < bestRMS then
                bestRMS = rms
                bestIdx = j
                if rms < 300 then break end  -- near-silence found, good enough
            end
        end
        local group = {}
        for j = i, bestIdx do table.insert(group, chunks[j]) end
        table.insert(groups, group)
        log("split: seg ends at chunk " .. bestIdx .. " (RMS=" .. math.floor(bestRMS) .. ", hard=" .. hardEnd .. ")")
        i = bestIdx + 1
    end
    return groups
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
    table.insert(models, API.MODEL_NAME)  -- remote API is the last stop in the cycle
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
    local cur = getOutputMode()
    local next = (cur == "paste") and "type" or (cur == "type") and "copy" or "paste"
    writeFile(OUTPUT_FILE, next)
    return next
end

local function cycleEnter()
    local next = getEnterMode() and "off" or "on"
    writeFile(ENTER_FILE, next)
    return next
end

-- Human-readable message for a curl exit code, for overlay/notification display.
local CURL_ERROR_MESSAGES = {
    [6] = "host not found",
    [7] = "connection refused",
    [22] = "server returned an error",
    [28] = "request timed out",
    [35] = "SSL error",
}
local function curlErrorMessage(code, err)
    local msg = CURL_ERROR_MESSAGES[code] or ("curl error " .. tostring(code))
    err = (err or ""):gsub("%s+$", "")
    if err ~= "" then msg = msg .. ": " .. err end
    return msg
end

-- Full language name -> ISO-639-1 code, matching whisper.cpp's g_lang table (src/whisper.cpp).
-- The remote API returns names like "english"/"russian" in verbose_json; the rest of this
-- app (getLang/action hooks) works in short codes like "en"/"ru".
local function normalizeApiLang(lang)
    if not lang then return nil end
    local nameToCode = {
        english = "en", chinese = "zh", german = "de", spanish = "es", russian = "ru",
        korean = "ko", french = "fr", japanese = "ja", portuguese = "pt", turkish = "tr",
        polish = "pl", catalan = "ca", dutch = "nl", arabic = "ar", swedish = "sv",
        italian = "it", indonesian = "id", hindi = "hi", finnish = "fi", vietnamese = "vi",
        hebrew = "he", ukrainian = "uk", greek = "el", malay = "ms", czech = "cs",
        romanian = "ro", danish = "da", hungarian = "hu", tamil = "ta", norwegian = "no",
        thai = "th", urdu = "ur", croatian = "hr", bulgarian = "bg", lithuanian = "lt",
        latin = "la", maori = "mi", malayalam = "ml", welsh = "cy", slovak = "sk",
        telugu = "te", persian = "fa", latvian = "lv", bengali = "bn", serbian = "sr",
        azerbaijani = "az", slovenian = "sl", kannada = "kn", estonian = "et", macedonian = "mk",
        breton = "br", basque = "eu", icelandic = "is", armenian = "hy", nepali = "ne",
        mongolian = "mn", bosnian = "bs", kazakh = "kk", albanian = "sq", swahili = "sw",
        galician = "gl", marathi = "mr", punjabi = "pa", sinhala = "si", khmer = "km",
        shona = "sn", yoruba = "yo", somali = "so", afrikaans = "af", occitan = "oc",
        georgian = "ka", belarusian = "be", tajik = "tg", sindhi = "sd", gujarati = "gu",
        amharic = "am", yiddish = "yi", lao = "lo", uzbek = "uz", faroese = "fo",
        ["haitian creole"] = "ht", pashto = "ps", turkmen = "tk", nynorsk = "nn", maltese = "mt",
        sanskrit = "sa", luxembourgish = "lb", myanmar = "my", tibetan = "bo", tagalog = "tl",
        malagasy = "mg", assamese = "as", tatar = "tt", hawaiian = "haw", lingala = "ln",
        hausa = "ha", bashkir = "ba", javanese = "jw", sundanese = "su", cantonese = "yue",
    }
    lang = lang:lower()
    return nameToCode[lang] or lang
end

-- Whisper decodes each window into exactly one language — there is no "mixed" mode. Left to
-- itself it picks the dominant one and normalises everything else into it, which rewrites
-- Ukrainian words as Russian and transliterates English terms. The initial prompt is the only
-- real lever: whisper continues in whatever style the prompt establishes, so a prompt that is
-- itself a sample of the mix biases it to reproduce the mix. Edit ~/.local-whisper/prompt to
-- match how you actually speak — it is a writing sample, not an instruction.
--
-- Declared above transcribeViaAPI on purpose: a local is only in scope for code that appears
-- after it, so a function defined earlier would silently read nil at runtime.
local PROMPT_DEFAULT =
    "Ок, давай подивимось: треба задеплоїти цей pull request, потім перевірити логи на сервері. " ..
    "Я говорю суржиком — українська, русский и English терміни впереміш, наприклад: " ..
    "закоміть зміни, зроби rebase, подивись у Slack, потом отправь в прод. Пиши саме так, як звучить."

local function readPrompt()
    return readFile(PROMPT_FILE):gsub("%s+$", "")
end

local function ensurePromptFile()
    if hs.fs.attributes(PROMPT_FILE) then return end
    local f = io.open(PROMPT_FILE, "w")
    if f then f:write(PROMPT_DEFAULT .. "\n"); f:close() end
end

ensurePromptFile()

-- Transcribe a WAV file via the remote OpenAI-compatible API instead of local whisper-cli.
-- Returns the hs.task so callers can terminate it on timeout if needed.
-- callback(text, detectedLang, errMsg) — errMsg is set (and text empty) on failure.
local function transcribeViaAPI(wavPath, lang, timeoutSecs, callback)
    local args = {
        "-s", "-S", "-f", "-m", tostring(timeoutSecs or 30),
        "-F", "file=@" .. wavPath,
        "-F", "model=" .. API.MODEL_ID,
        "-F", "response_format=verbose_json",
        -- Server translates to English if 'language' is omitted entirely (even with
        -- task=transcribe) — always send it, "auto" included, to force transcription.
        "-F", "language=" .. (lang or "auto"),
        -- temperature=0 is the OpenAI-API equivalent of pinning the decoder: the server
        -- won't climb its fallback ladder and start paraphrasing on a hard passage.
        "-F", "temperature=0",
    }
    -- Same mixed-language anchor as the local path. The OpenAI transcription API takes the
    -- style sample as 'prompt'; without it the remote model normalises the mix exactly as
    -- whisper-cli did. There is no --carry-initial-prompt equivalent over the wire, which is
    -- another reason segments are kept short.
    local promptText = readPrompt()
    if promptText ~= "" then
        table.insert(args, "-F")
        table.insert(args, "prompt=" .. promptText)
    end
    table.insert(args, API.URL)

    local task = hs.task.new(API.CURL_BIN, function(code, out, err)
        if code ~= 0 then
            local errMsg = curlErrorMessage(code, err)
            log("api: curl failed code=" .. tostring(code) .. " err=" .. tostring(err))
            callback("", nil, errMsg)
            return
        end
        local ok, decoded = pcall(hs.json.decode, out or "")
        if not ok or type(decoded) ~= "table" or not decoded.text then
            log("api: unexpected response: " .. tostring(out))
            callback("", nil, "unexpected server response")
            return
        end
        callback(decoded.text, normalizeApiLang(decoded.language), nil)
    end, args)
    task:start()
    return task
end

-- Read custom vocabulary prompt for whisper
local function getPromptArgs()
    local content = readPrompt()
    -- --carry-initial-prompt re-prepends the prompt to every 30s window whisper decodes
    -- internally. Without it the style anchor only applies to the first window, so a long
    -- segment drifts back to single-language output partway through.
    if content ~= "" then return { "--prompt", content, "--carry-initial-prompt" } end
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

-- Declared here, above createOverlay, because createOverlay's mouse callback closes over
-- them. A `local` declared further down the chunk is NOT in scope for a function defined
-- earlier — the reference would silently compile to a nil global instead.
local overlayPinned = false
local isRecording = false
local hideOverlay  -- assigned below

-- Element indices: 1=bg, 2=text, 3=dot, 4=timer, 5=bar_bg, 6=bar_rec, 7=bar_txn, 8=close
local EL = { text = 2, dot = 3, timer = 4, bar_bg = 5, bar_rec = 6, bar_txn = 7, close = 8 }

local function createOverlay()
    local screen = hs.screen.mainScreen()
    local frame = screen:frame()  -- excludes menu bar, so y=frame.y sits right under it
    local width, height = 420, 56
    local padding = 20
    local x = frame.x + (frame.w - width) / 2  -- centered under the menu bar
    local y = frame.y + padding

    overlay = hs.canvas.new({ x = x, y = y, w = width, h = height })

    -- 1: Background (click to pin overlay open)
    overlay:appendElements({
        id = "bg",
        type = "rectangle", action = "fill",
        roundedRectRadii = { xRadius = 10, yRadius = 10 },
        fillColor = { red = 0.93, green = 0.93, blue = 0.95, alpha = 0.92 },
        trackMouseUp = true,
    })

    -- 2: Transcript text — left side of the single-line strip
    overlay:appendElements({
        id = "text", type = "text", text = "Listening...",
        textColor = { red = 0.12, green = 0.12, blue = 0.14, alpha = 1.0 },
        textSize = 14,
        frame = { x = "4%", y = "16%", w = "58%", h = "55%" },
    })
    -- 3: Recording indicator (pulsing red dot) — right side
    overlay:appendElements({
        id = "dot", type = "oval", action = "fill",
        fillColor = { red = 0.85, green = 0.1, blue = 0.1, alpha = 0.0 },
        frame = { x = "81%", y = "24%", w = "4%", h = "30%" },
    })
    -- 4: Elapsed time display — right side
    overlay:appendElements({
        id = "timer", type = "text", text = "",
        textColor = { red = 0.75, green = 0.15, blue = 0.15, alpha = 0.0 },
        textSize = 10,
        frame = { x = "64%", y = "18%", w = "16%", h = "45%" },
        textAlignment = "right",
    })
    -- 5: Progress bar background (gray track) — thin strip along the bottom edge
    overlay:appendElements({
        id = "bar_bg", type = "rectangle", action = "fill",
        roundedRectRadii = { xRadius = 2, yRadius = 2 },
        fillColor = { red = 0.55, green = 0.55, blue = 0.58, alpha = 0.0 },
        frame = { x = 17, y = 48, w = 386, h = 4 },
    })
    -- 6: Recording progress (red/orange) — total recorded duration
    overlay:appendElements({
        id = "bar_rec", type = "rectangle", action = "fill",
        roundedRectRadii = { xRadius = 2, yRadius = 2 },
        fillColor = { red = 1.0, green = 0.35, blue = 0.15, alpha = 0.0 },
        frame = { x = 17, y = 48, w = 1, h = 4 },
    })
    -- 7: Transcription progress (blue) — chases the red bar as segments finish
    overlay:appendElements({
        id = "bar_txn", type = "rectangle", action = "fill",
        roundedRectRadii = { xRadius = 2, yRadius = 2 },
        fillColor = { red = 0.2, green = 0.75, blue = 1.0, alpha = 0.0 },
        frame = { x = 17, y = 48, w = 1, h = 4 },
    })
    -- 8: Close button (X) — right edge, last element so it's on top and clickable
    overlay:appendElements({
        id = "close", type = "text", text = "✕",
        textColor = { red = 0.75, green = 0.15, blue = 0.15, alpha = 0.85 },
        textSize = 16, textAlignment = "center",
        frame = { x = "87%", y = "12%", w = "10%", h = "45%" },
        trackMouseDown = true, trackMouseUp = true, trackMouseEnterExit = true,
    })

    -- High level + join-all-spaces/fullscreen-auxiliary so it shows above every app,
    -- fullscreen space, and display — same as the system volume/brightness HUD.
    overlay:level(hs.canvas.windowLevels.screenSaver)
    overlay:behavior({ "canJoinAllSpaces", "stationary", "fullScreenAuxiliary" })

    -- Mouse handler: click bg to pin, X to close (settings live in the menu bar only)
    overlay:canvasMouseEvents(true, true, false, false)  -- mouseDown + mouseUp
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

        if event == "mouseUp" and id == "bg" then
            overlayPinned = not overlayPinned
            if overlayPinned then
                canvas[1].fillColor = { red = 0.85, green = 0.89, blue = 0.97, alpha = 0.95 }
                log("overlay pinned")
            else
                canvas[1].fillColor = { red = 0.93, green = 0.93, blue = 0.95, alpha = 0.92 }
                log("overlay unpinned")
                if not isRecording then hideOverlay() end
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

hideOverlay = function()
    if overlayPinned then return end  -- pinned overlay stays open
    -- Never tear down mid-dictation: a previous dictation's finalization can still be in
    -- flight when a new recording starts, and its deferred hide would kill the live overlay.
    if isRecording then return end
    if overlay then overlay:delete(); overlay = nil end
end

local function forceHideOverlay()
    overlayPinned = false
    if overlay then overlay:delete(); overlay = nil end
end

local function setOverlayText(text)
    if overlay then overlay[EL.text].text = text end
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

-- isRecording and overlayPinned are declared in the Overlay UI section above,
-- because createOverlay's mouse callback captures them.
local recorderTask = nil
local recordStartedAt = nil
-- Seconds lw-record says it captured. Parsed in the streaming callback, not the termination
-- one: hs.task routes stdout to the streaming callback when there is one, and hands the
-- termination callback an empty string — so reading it there silently never fires.
local recorderCaptured = nil
local finalizationPending = false  -- true between stopRecording() and doFinalTranscription() actually starting
local finalizeTimers = { timer = nil, watchdog = nil }

-- Menu bar
local menuBar = nil

-- Recording indicator state
local pulseTimer = nil
local clockTimer = nil
local recordingStartTime = 0
local recordedSecs = nil    -- frozen recording duration once stopped; nil while recording
local pulseAlpha = 1.0
local pulseFading = true

-- Progress bar state
local transcribedSecs = 0   -- seconds of audio fully transcribed so far
local barMaxSecs = 180       -- current max duration displayed (expands at 90%)

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
        title = "Model: " .. (isApiMode() and "API (remote)" or getModelName()),
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
-- Recording indicator (pulsing dot + timer + progress bar)
--------------------------------------------------------------------------------

local function updateProgressBar()
    if not overlay then return end
    local BAR_MAX = 386  -- px, matches bar_bg width in createOverlay
    -- Freeze at the final duration once recording stops. Left live, this keeps climbing
    -- during transcription and re-trips the auto-expand below on every segment, so
    -- barMaxSecs outruns transcribedSecs and the blue bar never reaches 100%.
    local elapsed = recordedSecs or (hs.timer.secondsSinceEpoch() - recordingStartTime)
    -- Auto-expand: when recording reaches 90% of max, extend by another 3 min
    if elapsed >= barMaxSecs * 0.9 then barMaxSecs = barMaxSecs + 180 end
    local recFrac = math.min(elapsed / barMaxSecs, 1.0)
    local txnFrac = math.min(transcribedSecs / barMaxSecs, 1.0)
    overlay[EL.bar_rec].frame = { x = 17, y = 48, w = math.max(1, math.floor(recFrac * BAR_MAX)), h = 4 }
    overlay[EL.bar_txn].frame = { x = 17, y = 48, w = math.max(1, math.floor(txnFrac * BAR_MAX)), h = 4 }
end

local function hideProgressBar()
    if not overlay then return end
    overlay[EL.bar_bg].fillColor  = { red = 0.3, green = 0.3, blue = 0.3, alpha = 0.0 }
    overlay[EL.bar_rec].fillColor = { red = 1.0, green = 0.35, blue = 0.15, alpha = 0.0 }
    overlay[EL.bar_txn].fillColor = { red = 0.2, green = 0.75, blue = 1.0, alpha = 0.0 }
end

local function startRecordingIndicator()
    if not overlay then return end
    recordingStartTime = hs.timer.secondsSinceEpoch()
    recordedSecs = nil
    transcribedSecs = 0
    barMaxSecs = 180
    pulseAlpha = 1.0
    pulseFading = true

    -- Show dot and timer
    overlay[EL.dot].fillColor = { red = 0.85, green = 0.1, blue = 0.1, alpha = 1.0 }
    overlay[EL.timer].textColor = { red = 0.75, green = 0.15, blue = 0.15, alpha = 1.0 }

    -- Show progress bar track
    overlay[EL.bar_bg].fillColor  = { red = 0.3, green = 0.3, blue = 0.3, alpha = 0.6 }
    overlay[EL.bar_rec].fillColor = { red = 1.0, green = 0.35, blue = 0.15, alpha = 0.85 }
    overlay[EL.bar_txn].fillColor = { red = 0.2, green = 0.75, blue = 1.0, alpha = 0.9 }
    updateProgressBar()

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
        overlay[EL.dot].fillColor = { red = 0.85, green = 0.1, blue = 0.1, alpha = pulseAlpha }
    end)

    -- Update elapsed time and recording progress every second
    clockTimer = hs.timer.doEvery(1, function()
        if not overlay then return end
        local elapsed = math.floor(hs.timer.secondsSinceEpoch() - recordingStartTime)
        local min = math.floor(elapsed / 60)
        local sec = elapsed % 60
        overlay[EL.timer].text = string.format("%d:%02d", min, sec)
        updateProgressBar()
    end)
end

local function stopRecordingIndicator()
    -- Freeze the elapsed duration so the progress bar stops advancing during transcription.
    recordedSecs = hs.timer.secondsSinceEpoch() - recordingStartTime
    if pulseTimer then pulseTimer:stop(); pulseTimer = nil end
    if clockTimer then clockTimer:stop(); clockTimer = nil end
    if overlay then
        overlay[EL.dot].fillColor = { red = 0.85, green = 0.1, blue = 0.1, alpha = 0.0 }
        overlay[EL.timer].textColor = { red = 0.75, green = 0.15, blue = 0.15, alpha = 0.0 }
        overlay[EL.timer].text = ""
    end
end

--------------------------------------------------------------------------------
-- Emergency stop (forward declaration)
--------------------------------------------------------------------------------

-- Forward declaration: the streaming pipeline is defined further down (it needs
-- insertTranscribedText, which is itself defined below this point), but emergencyStop has
-- to be able to tear it down. Declaring it here means the call below captures this local
-- instead of silently compiling to a nil global lookup.
local pipelineReset

function emergencyStop()
    log("emergency stop")
    isRecording = false
    -- Cancel any in-flight finalization, otherwise the timer armed by stopRecording()
    -- still fires and pastes the transcript into whatever is focused after the stop.
    finalizationPending = false
    if finalizeTimers.timer then finalizeTimers.timer:stop(); finalizeTimers.timer = nil end
    if finalizeTimers.watchdog then finalizeTimers.watchdog:stop(); finalizeTimers.watchdog = nil end
    stopRecordingIndicator()
    -- Stop dispatching, and drop the segments already transcribed: emergency stop must not
    -- paste a partial transcript a moment later.
    pipelineReset()
    -- terminate(), not interrupt(): emergency stop throws the audio away, so there is no
    -- reason to let the recorder flush a final chunk first. The handle is left for the
    -- termination callback to clear, so a re-press can still detect a slow exit.
    if recorderTask and recorderTask:isRunning() then recorderTask:terminate() end
    forceHideOverlay()
    updateMenuBar()
    os.execute("killall whisper-cli 2>/dev/null")
    hs.notify.new({ title = "local-whisper", informativeText = "Stopped" }):send()
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
    elseif mode == "copy" then
        -- Clipboard only, no auto-paste — user pastes manually when ready.
        hs.pasteboard.setContents(text)
    else
        hs.eventtap.keyStrokes(text)
    end
end

-- Finish insertion after all processing (post-process, hooks)
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
        insertTextAtCursor(finalText, ctx.outputMode)
        ctx.inserted = true

        -- Press Enter after insertion if enter mode is on (not applicable to copy-only mode)
        if getEnterMode() and ctx.outputMode ~= "copy" then
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
    playSound("Glass")
    hs.timer.doAfter(OVERLAY_LINGER, hideOverlay)
end

-- Insert transcribed text at cursor, with post-processing and action hooks
local function insertTranscribedText(text, detectedLang)
    if text == "" or isHallucination(text) then
        hideOverlay()
        return
    end

    -- Apply app-aware post-processing
    text = postProcess(text, capturedAppBundleID)
    if text == "" then hideOverlay(); return end

    finishInsertion(text, detectedLang)
end

-- Max seconds per whisper call — keeps each segment within whisper's sweet spot
-- and prevents the model from losing the beginning of long recordings.
local FINAL_SEGMENT_SECS = 55

-- Streaming pipeline.
--
-- Segments are dispatched to whisper *while the user is still talking*, so a three-minute
-- dictation does not sit through three minutes of transcription after the key comes up.
-- Waiting for the release before starting meant the wait scaled with the recording; now
-- only the tail segment is left when recording stops.
--
-- Grouped into one table on purpose: init.lua is bounded by Lua's 200-locals-per-function
-- ceiling, so related state goes in a table rather than eight bare locals.
local pipe = {
    results    = {},    -- [segN] = text, filled as each segment completes (order preserved)
    lang       = nil,   -- first detected language across all segments
    nextChunk  = 1,     -- 1-based index of the next chunk not yet claimed by a segment
    nextSeg    = 1,     -- next segment number to assign
    total      = 0,     -- fixed once recording stops and the tail is dispatched
    done       = 0,     -- segments finished so far
    finalizing = false, -- true once `total` is known
    apiError   = nil,
    timer      = nil,   -- polls during recording for a segment that is ready to dispatch
}

-- Assigned, not declared: the local is forward-declared above emergencyStop.
pipelineReset = function()
    if pipe.timer then pipe.timer:stop(); pipe.timer = nil end
    pipe.results    = {}
    pipe.lang       = nil
    pipe.nextChunk  = 1
    pipe.nextSeg    = 1
    pipe.total      = 0
    pipe.done       = 0
    pipe.finalizing = false
    pipe.apiError   = nil
end

local function pipelineFinalize()
    local parts = {}
    for n = 1, pipe.total do
        local t = pipe.results[n] or ""
        if t ~= "" then table.insert(parts, t) end
    end
    local finalText = table.concat(parts, " "):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    log("pipeline: finalized " .. pipe.total .. " seg(s): '" .. finalText .. "'")

    if finalText == "" then
        hideProgressBar()
        if pipe.apiError then
            setOverlayText("API error: " .. pipe.apiError)
            hs.notify.new({ title = "local-whisper", informativeText = "API error: " .. pipe.apiError }):send()
            hs.timer.doAfter(2.5, hideOverlay)
        else
            hideOverlay()
        end
        return
    end
    -- Flash the blue bar to 100% to confirm all audio was transcribed, then fade it
    transcribedSecs = barMaxSecs
    if overlay then updateProgressBar() end
    hs.timer.doAfter(0.4, hideProgressBar)
    insertTranscribedText(finalText, pipe.lang)
end

-- chunkCount drives the progress bar, which measures transcribed seconds against
-- recorded seconds — one chunk is one second.
local function onPipelineDone(n, text, detected, chunkCount)
    pipe.results[n] = text
    if detected and not pipe.lang then pipe.lang = detected end
    pipe.done = pipe.done + 1
    transcribedSecs = transcribedSecs + (chunkCount or 0)
    if overlay then updateProgressBar() end
    log("pipeline: seg " .. n .. " complete (done=" .. pipe.done .. "/" ..
        (pipe.finalizing and pipe.total or "?") .. ")")

    -- While recording, the overlay belongs to the timer — don't stomp it. Only once the
    -- total is known does the countdown make sense.
    if not pipe.finalizing then return end
    local left = pipe.total - pipe.done
    if left > 0 then
        setOverlayText(string.format("Transcribing... (%d left)", left))
    else
        pipelineFinalize()
    end
end

-- Concat a chunk group → WAV → whisper (or the remote API), then report via
-- onPipelineDone. Fully async: several segments may be in flight at once.
local function dispatchSegment(segN, group)
    local lang       = getLang()
    local promptArgs = getPromptArgs()
    local nChunks    = #group
    local concatFile = WHISPER_TMP .. "/pipe_concat_" .. segN .. ".txt"
    local segWav     = WHISPER_TMP .. "/pipe_seg_" .. segN .. ".wav"

    local f, ferr = io.open(concatFile, "w")
    if not f then
        log("pipeline: seg " .. segN .. " ERROR opening concat file: " .. tostring(ferr))
        onPipelineDone(segN, "", nil, nChunks)
        return
    end
    for _, chunk in ipairs(group) do f:write("file '" .. chunk .. "'\n") end
    f:close()

    local gfirst = group[1]:match("([^/]+)$") or group[1]
    local glast  = group[nChunks]:match("([^/]+)$") or group[nChunks]
    log("pipeline: seg " .. segN .. " concat " .. nChunks .. " chunks (" .. gfirst .. " … " .. glast .. ")")

    local concatTask = hs.task.new(FFMPEG, function(code)
        if code ~= 0 then
            log("pipeline: seg " .. segN .. " concat FAILED (code=" .. tostring(code) .. ")")
            onPipelineDone(segN, "", nil, nChunks)
            return
        end
        local wavSize = (hs.fs.attributes(segWav) or {}).size or -1
        log("pipeline: seg " .. segN .. " concat OK — wav size=" .. wavSize .. " bytes")

        local function onSegmentText(text, detected)
            if text ~= "" and not isHallucination(text) then
                log("pipeline: seg " .. segN .. " accepted: '" .. text:sub(1, 120) .. "'")
            else
                log("pipeline: seg " .. segN .. " REJECTED (empty or hallucination): '" .. text:sub(1, 80) .. "'")
                text = ""
            end
            onPipelineDone(segN, text, detected, nChunks)
        end

        -- Auto-detect stays per segment for code-switching (surzhyk / mixed language):
        -- forcing a later segment into an earlier segment's language would translate it.
        local effectiveLang = lang

        if isApiMode() then
            log("pipeline: seg " .. segN .. " starting API transcription lang=" .. effectiveLang)
            transcribeViaAPI(segWav, effectiveLang, 60, function(text, detected, errMsg)
                if errMsg then
                    log("pipeline: seg " .. segN .. " API error: " .. errMsg)
                    pipe.apiError = errMsg
                    onSegmentText("", nil)
                    return
                end
                text = (text or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
                onSegmentText(text, effectiveLang == "auto" and detected or effectiveLang)
            end)
            return
        end

        log("pipeline: seg " .. segN .. " starting whisper lang=" .. effectiveLang ..
            " model=" .. getModelPath():match("([^/]+)$"))

        if effectiveLang == "auto" then
            local autoArgs = { "-m", getModelPath(), "-f", segWav, "-l", "auto", "-nt" }
            for _, a in ipairs(promptArgs) do table.insert(autoArgs, a) end
            hs.task.new(WHISPER_BIN, function(code2, out2, err2)
                log("pipeline: seg " .. segN .. " whisper(auto) exit=" .. tostring(code2) ..
                    " outlen=" .. #(out2 or ""))
                if code2 ~= 0 then
                    log("pipeline: seg " .. segN .. " whisper FAILED (auto)")
                    onPipelineDone(segN, "", nil, nChunks)
                    return
                end
                local detected = (err2 or ""):match("auto%-detected language:%s*(%w+)")
                log("pipeline: seg " .. segN .. " auto-detected: " .. tostring(detected))
                onSegmentText((out2 or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " "), detected)
            end, autoArgs):start()
        else
            local langArgs = { "-m", getModelPath(), "-f", segWav, "-l", effectiveLang, "-nt", "--no-prints" }
            for _, a in ipairs(promptArgs) do table.insert(langArgs, a) end
            hs.task.new(WHISPER_BIN, function(code2, out2)
                log("pipeline: seg " .. segN .. " whisper(" .. effectiveLang .. ") exit=" .. tostring(code2) ..
                    " outlen=" .. #(out2 or ""))
                if code2 ~= 0 then
                    log("pipeline: seg " .. segN .. " whisper FAILED")
                    onPipelineDone(segN, "", nil, nChunks)
                    return
                end
                onSegmentText((out2 or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " "), effectiveLang)
            end, langArgs):start()
        end
    end, { "-y", "-f", "concat", "-safe", "0", "-i", concatFile, "-c", "copy", segWav })
    concatTask:start()
end

-- Polled during recording. Dispatches at most one segment per tick, and only when enough
-- unclaimed audio has accumulated for splitAtSilence to make a real pause-bounded cut.
local function streamCheckAndDispatch()
    if not isRecording then return end

    local all = getChunkFiles()
    -- lw-record renames each chunk into place only when it is complete, so every visible
    -- file is whole. Still leave the newest one alone as cheap insurance.
    local safeCount = #all - 1
    local candidates = {}
    for j = pipe.nextChunk, safeCount do table.insert(candidates, all[j]) end

    -- Strictly greater: at exactly FINAL_SEGMENT_SECS, splitAtSilence returns the whole
    -- list as its trailing "everything remaining" group, which is not a silence-bounded
    -- cut and is still growing. Waiting one chunk longer gets a real boundary.
    if #candidates <= FINAL_SEGMENT_SECS then return end

    local firstGroup = splitAtSilence(candidates, FINAL_SEGMENT_SECS)[1]
    if not firstGroup or #firstGroup < 15 then return end

    local segN = pipe.nextSeg
    pipe.nextSeg   = pipe.nextSeg + 1
    pipe.nextChunk = pipe.nextChunk + #firstGroup
    log("stream: dispatching seg " .. segN .. " live during recording (" .. #firstGroup ..
        " chunks, " .. (#all - pipe.nextChunk + 1) .. " still unclaimed)")
    dispatchSegment(segN, firstGroup)
end

local function doFinalTranscription()
    if pipe.timer then pipe.timer:stop(); pipe.timer = nil end

    local all = getChunkFiles()
    log("final: START — total chunks=" .. #all .. ", already streamed=" .. (pipe.nextSeg - 1) ..
        " seg(s), next unclaimed chunk=" .. pipe.nextChunk)

    local remaining = {}
    for j = pipe.nextChunk, #all do table.insert(remaining, all[j]) end

    if pipe.nextSeg == 1 and #remaining < 2 then
        log("final: not enough chunks, skipping")
        hideProgressBar()
        hideOverlay()
        return
    end

    setOverlayText("Transcribing...")

    -- Whatever the streaming pass never claimed — the tail, plus anything it was too
    -- conservative to take. Still split at silence so the seams stay off mid-word.
    if #remaining >= 2 then
        for _, grp in ipairs(splitAtSilence(remaining, FINAL_SEGMENT_SECS)) do
            local segN = pipe.nextSeg
            pipe.nextSeg   = pipe.nextSeg + 1
            pipe.nextChunk = pipe.nextChunk + #grp
            log("final: dispatching tail seg " .. segN .. " → " .. #grp .. " chunks")
            dispatchSegment(segN, grp)
        end
    end

    pipe.total      = pipe.nextSeg - 1
    pipe.finalizing = true
    log("final: total=" .. pipe.total .. " seg(s), done=" .. pipe.done)

    if pipe.total == 0 then
        log("final: no segments at all, skipping")
        hideProgressBar()
        hideOverlay()
        return
    end

    local left = pipe.total - pipe.done
    if left > 0 then
        setOverlayText(string.format("Transcribing... (%d left)", left))
    else
        -- Every streamed segment already finished before the key came up.
        pipelineFinalize()
    end
end

--------------------------------------------------------------------------------
-- Start / stop recording
--------------------------------------------------------------------------------

-- Warmup state
local warmupTimer = nil
local isWarmingUp = false
local warmupAttempt = 0
local WARMUP_ATTEMPT_SECS = 1.0   -- timeout per attempt
local WARMUP_MAX_ATTEMPTS = 10    -- give up after this many retries

-- Called once lw-record reports its engine is running and audio is flowing.
local function onRecorderReady()
    if not isWarmingUp then return end   -- key already released, or a retry raced us
    isWarmingUp = false
    warmupAttempt = 0
    isRecording = true
    if warmupTimer then warmupTimer:stop(); warmupTimer = nil end
    log("recording: start (audio flowing)")

    setOverlayText("")
    startRecordingIndicator()
    updateMenuBar()
    playSound("Pop")

    -- Start dispatching finished segments to whisper while the user keeps talking. 3s is
    -- just the poll interval — a segment is only sent once a pause-bounded group is ready.
    if pipe.timer then pipe.timer:stop() end
    pipe.timer = hs.timer.doEvery(3, streamCheckAndDispatch)
end

local function cancelWarmup()
    if warmupTimer then warmupTimer:stop(); warmupTimer = nil end
    if recorderTask and recorderTask:isRunning() then
        recorderTask:terminate(); recorderTask = nil
    end
end

local tryWarmup  -- forward declaration for recursion

local warmupTick = hs.sound.getByFile("/System/Library/Sounds/Tink.aiff")
if warmupTick then warmupTick:volume(0.15) end

-- The recorder IS the warmup probe. It used to be a throwaway `ffmpeg -f null` open followed
-- by a second open for the real recording, which meant two device opens per dictation and
-- every word spoken during the probe was captured into /dev/null. lw-record prints READY the
-- moment its engine is actually running, and it has been recording since before that line —
-- so the lead-in is kept instead of discarded, and the retry loop still guards a dead device.
tryWarmup = function()
    if not isWarmingUp then return end

    warmupAttempt = warmupAttempt + 1
    log("warmup: attempt " .. warmupAttempt .. "/" .. WARMUP_MAX_ATTEMPTS)

    -- Subtle tick before each attempt
    if warmupTick then warmupTick:play() end
    setOverlayText("... " .. warmupAttempt .. "/" .. WARMUP_MAX_ATTEMPTS)

    -- A recorder from the previous dictation can still be alive here: stopRecording() only
    -- sends SIGINT, and lw-record then takes a moment to flush its final chunk. If it is
    -- still writing when we clear CHUNK_DIR, its tail lands in the new recording's directory
    -- and gets spliced onto the front of the next transcript. Kill it before clearing.
    if recorderTask and recorderTask:isRunning() then
        log("warmup: terminating a still-running recorder from the previous dictation")
        recorderTask:terminate()
    end
    recorderTask = nil

    -- Each attempt records from scratch: a stale chunk from a failed attempt would be
    -- concatenated into the front of the transcript.
    os.execute("rm -rf '" .. CHUNK_DIR .. "'")
    os.execute("mkdir -p '" .. CHUNK_DIR .. "'")

    -- Chunk indices restart at 0, so any pipeline state from the previous dictation would
    -- claim the wrong audio.
    pipelineReset()

    captureActiveApp()
    log("recording: app=" .. tostring(capturedAppName) .. " (" .. tostring(capturedAppBundleID) .. ")")

    -- Health check: lw-record reports exactly how much audio it captured, so a future
    -- capture regression shows up in the log as a gap against the wall clock instead of
    -- silently shortening words. ffmpeg lost ~10% here and nothing recorded it.
    recordStartedAt = hs.timer.secondsSinceEpoch()
    recorderCaptured = nil

    -- Captured so the callback can tell whether it is still the current recorder: a slow
    -- exit from the previous dictation must not clear the handle of the one now running.
    local thisTask
    -- Rolling tail of this recorder's stdout. hs.task delivers whatever happened to be in
    -- the pipe, so the final "CAPTURED 100.199" can land split across two calls ("CAPTU" +
    -- "RED 100.199"), matching neither. Matching against the joined tail is immune to that.
    -- 200 chars is far more than the line needs and cannot grow with recording length.
    local stdoutTail = ""
    thisTask = hs.task.new(RECORDER_BIN,
        function(code, out, err)  -- termination callback
            local isCurrent = (recorderTask == thisTask)
            if isCurrent then recorderTask = nil end
            log("recording: recorder exited " .. tostring(code))
            if not isCurrent then return end   -- superseded: its counters belong to a newer run
            if code ~= 0 and not recorderCaptured then
                log("recording: ERROR — lw-record failed: " .. tostring(err))
                return
            end
            -- hs.task normally routes stdout to the streaming callback and leaves `out`
            -- empty, but take it from either source: the health check going quiet is how a
            -- capture regression would slip past unnoticed a second time.
            local captured = recorderCaptured or tonumber((out or ""):match("CAPTURED%s+([%d%.]+)"))
            if captured and recordStartedAt then
                local wall = hs.timer.secondsSinceEpoch() - recordStartedAt
                log(string.format("recording: captured %.2fs of %.2fs wall (%.0f%%)",
                    captured, wall, wall > 0 and (captured / wall * 100) or 0))
            else
                -- Never fail silently here. Fall back to measuring the chunks on disk, which
                -- is the same number the transcription is about to be built from.
                local secs = 0
                for _, p in ipairs(getChunkFiles()) do
                    local a = hs.fs.attributes(p)
                    if a and a.size then secs = secs + (a.size - 44) / 32000 end
                end
                local wall = recordStartedAt and (hs.timer.secondsSinceEpoch() - recordStartedAt) or 0
                log(string.format("recording: no CAPTURED line — chunks on disk hold %.2fs of %.2fs wall (%.0f%%)",
                    secs, wall, wall > 0 and (secs / wall * 100) or 0))
            end
        end,
        function(task, stdout, stderr)  -- streaming: READY, then the final CAPTURED total
            -- Ignore a superseded recorder's output entirely: its READY would start a
            -- recording the user already released, and its CAPTURED would overwrite the
            -- health check of the run now in progress.
            if recorderTask ~= thisTask then return true end
            if stdout then
                if isWarmingUp and stdout:find("READY", 1, true) then
                    log("warmup: device ready on attempt " .. warmupAttempt)
                    onRecorderReady()
                end
                stdoutTail = (stdoutTail .. stdout):sub(-200)
                local c = tonumber(stdoutTail:match("CAPTURED%s+([%d%.]+)"))
                if c then recorderCaptured = c end
            end
            return true
        end,
        { CHUNK_DIR, "1", "16000" })
    recorderTask = thisTask
    recorderTask:start()

    -- If no READY within 1s, kill and retry (up to max)
    warmupTimer = hs.timer.doAfter(WARMUP_ATTEMPT_SECS, function()
        warmupTimer = nil
        if not isWarmingUp then return end
        if recorderTask and recorderTask:isRunning() then
            recorderTask:terminate(); recorderTask = nil
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
            playSound("Basso")
            hs.timer.doAfter(2.5, hideOverlay)
        end
    end)
end

local function startRecording()
    if isRecording or isWarmingUp then return end
    if finalizationPending then
        -- A previous dictation is still waiting to be finalized (fast re-press inside the
        -- 0.3s window, or the timer was dropped across sleep). Flush it now and fall
        -- through — returning here would silently swallow the keypress the user just made.
        finalizationPending = false
        if finalizeTimers.timer then finalizeTimers.timer:stop(); finalizeTimers.timer = nil end
        if finalizeTimers.watchdog then finalizeTimers.watchdog:stop(); finalizeTimers.watchdog = nil end
        log("recovery: flushing pending finalization, then starting the new recording")
        doFinalTranscription()
    end
    isWarmingUp = true
    warmupAttempt = 0
    log("warmup: probing audio device...")

    setOverlayText("...")
    showOverlay()

    tryWarmup()
end

local function stopRecording()
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

    stopRecordingIndicator()
    updateMenuBar()

    if recorderTask and recorderTask:isRunning() then
        recorderTask:interrupt()   -- SIGINT: lw-record flushes its partial final chunk, then exits 0
    end
    -- Deliberately keep the handle: the process is still flushing. Its termination callback
    -- clears it, and until then tryWarmup() needs it to detect and kill a slow predecessor
    -- before wiping CHUNK_DIR out from under it.

    -- Brief delay for the recorder to finalize last chunk. A short timer scheduled right as the
    -- system suspends can be silently dropped across sleep (see sleepWatcher below), so track
    -- pending state and recover on wake instead of just losing the recording silently.
    finalizationPending = true
    finalizeTimers.timer = hs.timer.doAfter(0.3, function()
        finalizeTimers.timer = nil
        if not finalizationPending then return end
        finalizationPending = false
        if finalizeTimers.watchdog then finalizeTimers.watchdog:stop(); finalizeTimers.watchdog = nil end
        doFinalTranscription()
    end)
    finalizeTimers.watchdog = hs.timer.doAfter(5, function()
        finalizeTimers.watchdog = nil
        if not finalizationPending then return end
        finalizationPending = false
        if finalizeTimers.timer then finalizeTimers.timer:stop(); finalizeTimers.timer = nil end
        log("recovery: finalization timer delayed, starting directly")
        doFinalTranscription()
    end)

    playSound("Tink")
end

--------------------------------------------------------------------------------
-- Key detection (replaces Karabiner)
--------------------------------------------------------------------------------

local releasePoller = nil

local modTap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(event)
    -- Wrap in pcall so errors don't kill the eventtap
    local ok, err = pcall(function()
        local triggered = triggerPressed(event:rawFlags())

        if triggered and not isRecording then
            startRecording()
            -- Poll for release since flagsChanged doesn't fire on key-up
            if releasePoller then releasePoller:stop() end
            releasePoller = hs.timer.doEvery(0.1, function()
                if not triggerHeld() then
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

-- Root the tap in a global. Hammerspoon garbage-collects eventtaps, repeating timers
-- and watchers that nothing in Lua still references, and collecting one unregisters it
-- from the system: the tap keeps reporting isEnabled() right up until it is collected,
-- then simply stops receiving events, with nothing logged. The chunk's own locals do not
-- count — once init.lua finishes, a local survives only while some live closure captures
-- it, and the only closure holding modTap was the watchdog timer below, which is itself
-- collectible. This is why the trigger worked for a few minutes after every reload and
-- then went dead.
LocalWhisper = LocalWhisper or {}
LocalWhisper.modTap = modTap

-- Re-enable eventtap if it gets disabled (e.g. by secure input)
LocalWhisper.tapWatchdog = hs.timer.doEvery(5, function()
    if not modTap:isEnabled() then
        log("eventtap was disabled, re-enabling")
        modTap:start()
    end
end)

-- Recover from macOS suspending the process mid-dictation: a stalled recording (isRecording
-- still true) or a lost finalization timer (see stopRecording) both look like the app just
-- hung with no feedback, when actually the system was asleep the whole time.
local sleepWatcher = hs.caffeinate.watcher.new(function(eventType)
    if eventType ~= hs.caffeinate.watcher.systemDidWake then return end
    log("system: woke from sleep")
    if finalizationPending then
        finalizationPending = false
        if finalizeTimers.timer then finalizeTimers.timer:stop(); finalizeTimers.timer = nil end
        if finalizeTimers.watchdog then finalizeTimers.watchdog:stop(); finalizeTimers.watchdog = nil end
        log("system: finalization timer was lost across sleep, resuming now")
        doFinalTranscription()
    elseif isRecording then
        log("system: recording was still active across sleep, forcing stop")
        stopRecording()
    end
end)
sleepWatcher:start()
LocalWhisper.sleepWatcher = sleepWatcher  -- see LocalWhisper.modTap: unrooted watchers are collected

--------------------------------------------------------------------------------
-- Startup
--------------------------------------------------------------------------------

-- Request mic permission (child processes via hs.task inherit it)
if type(hs.microphoneState) == "function" and not hs.microphoneState() then
    log("requesting microphone permission")
    hs.microphoneState(true)
end

-- Create menu bar icon
createMenuBar()

-- Load action hooks
local actionsEnabled = loadActionConfig() ~= nil
log("actions: " .. (actionsEnabled and "enabled" or "disabled"))

local enterStatus = getEnterMode() and "⏎" or ""
local actionsFlag = actionsEnabled and " +actions" or ""
log("loaded (trigger=" .. TRIGGER_KEY .. ", lang=" .. getLang() .. ", output=" .. getOutputMode() .. ", model=" .. getModelName() .. ")")
hs.notify.new({
    title = "local-whisper",
    informativeText = "Loaded (" .. getLang():upper() .. " / " .. getOutputMode():upper() .. enterStatus .. " / " .. getModelName() .. actionsFlag .. ") — hold " .. trigger.label
}):send()
