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
local VOICE_ARCHIVE_DIR = CONFIG_DIR .. "/voice-archive"
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

-- Remote OpenAI-compatible transcription API (alternative to local whisper-cli).
--
-- "API" is a combined mode, not a plain switch: every recording probes the endpoint in
-- parallel with capturing audio (see checkApiAvailable, started at key-down) instead of
-- waiting to find out at transcription time. If it answers, its segments go over the wire;
-- if it doesn't — or a request to it fails mid-dictation — transcription silently drops to
-- FALLBACK_MODEL locally for the rest of that recording. Nothing here changes the saved
-- setting or asks the user to choose; the fallback is invisible on purpose.
local API = {
    MODEL_NAME = "API",  -- sentinel value stored in MODEL_FILE when API mode is selected
    URL = "http://192.168.0.13:13305/v1/audio/transcriptions",
    MODEL_ID = "Whisper-Large-v3-Turbo-Q5",  -- must match the model id the server has loaded (GET /v1/models)
    CURL_BIN = "/usr/bin/curl",
    FALLBACK_MODEL = "large-v3-turbo-q5_0",  -- local model used whenever the endpoint doesn't respond
    HEALTH_TIMEOUT_SECS = 2,
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
-- node) unless MIC_FILE below pins it to a specific device UID. Pinning matters mainly for
-- Bluetooth: macOS downgrades a paired Bluetooth output to its low-quality call profile
-- (HFP) as soon as ANY app opens the mic, unless the mic in use is a different device (e.g.
-- the built-in one) — so fixing capture to "MacBook Pro Microphone" keeps Bluetooth output
-- at full quality through a dictation.

-- Trigger: which modifier(s) must be held down to record. See TRIGGERS below.
local TRIGGER_KEY = "fnLeftCtrl"

-- User preference files (all in CONFIG_DIR)
local LANG_FILE = CONFIG_DIR .. "/lang"
local OUTPUT_FILE = CONFIG_DIR .. "/output"
local ENTER_FILE = CONFIG_DIR .. "/enter"
local MIC_FILE = CONFIG_DIR .. "/mic"
local PROMPT_FILE = CONFIG_DIR .. "/prompt"
local WAKE_FILE = CONFIG_DIR .. "/wake"
local WAKE_MODEL_FILE = CONFIG_DIR .. "/wake-model"
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
os.execute("mkdir -p '" .. VOICE_ARCHIVE_DIR .. "'")
-- Prune voice archive entries older than 2 days
os.execute("find '" .. VOICE_ARCHIVE_DIR .. "' -maxdepth 1 -mindepth 1 -mtime +2 -exec rm -rf {} \\; 2>/dev/null")

-- Every dictation records into its own CHUNK_DIR/g<N> subdirectory and owns its own segment
-- files, so a new recording can never delete audio a previous one is still transcribing.
-- Generation numbers restart at 1 on every load, so clear what an earlier instance left.
os.execute("rm -rf '" .. CHUNK_DIR .. "' '" .. WHISPER_TMP .. "'/pipe_seg_* '" ..
           WHISPER_TMP .. "'/pipe_concat_* 2>/dev/null")
os.execute("mkdir -p '" .. CHUNK_DIR .. "'")

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

-- Pinned input device UID, or nil for "system default". A saved UID that no longer matches
-- any connected device (unplugged since) is treated the same as unset, rather than handing
-- lw-record a device it will fail to find.
local function getMicDevice()
    local uid = readFile(MIC_FILE):gsub("%s+", "")
    if uid == "" then return nil end
    if hs.audiodevice.findInputByUID(uid) then return uid end
    return nil
end

local function getMicDeviceLabel()
    local uid = getMicDevice()
    if not uid then return "System Default" end
    local dev = hs.audiodevice.findInputByUID(uid)
    return dev and dev:name() or "System Default"
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

-- Chunks live in a per-dictation subdirectory of CHUNK_DIR (see pipeNewJob), so the caller
-- always names the recording it means. A dictation that is still being transcribed keeps its
-- own directory, which is what stops the next recording from deleting audio out from under it.
local function getChunkFiles(dir)
    local chunks = {}
    local ok, iter, d = pcall(hs.fs.dir, dir)
    if not ok then return chunks end
    for file in iter, d do
        if file:match("^chunk_.*%.wav$") then
            table.insert(chunks, dir .. "/" .. file)
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

-- Cycles: System Default -> each currently connected input device -> System Default.
-- Built fresh from hs.audiodevice.allInputDevices() every call, so devices that came or
-- went since the last cycle just fall in or out of the rotation.
local function cycleMic()
    local uids = { false }  -- false = "System Default"; nil can't live in a table slot reliably
    for _, dev in ipairs(hs.audiodevice.allInputDevices()) do
        table.insert(uids, dev:uid())
    end
    local current = getMicDevice() or false
    local idx = 1
    for i, u in ipairs(uids) do
        if u == current then idx = i; break end
    end
    local next = uids[(idx % #uids) + 1]
    writeFile(MIC_FILE, next or "")
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
local function readPrompt()
    return readFile(PROMPT_FILE):gsub("%s+$", "")
end

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

-- Probes the remote API endpoint without waiting for a segment to need it. Started at
-- key-down (pipeStartJob) so it runs in parallel with recording; by the time the first
-- segment is ready to dispatch, this has almost always already resolved. A HEAD request is
-- enough — any HTTP response (even a 404/405 the endpoint gives a HEAD it doesn't like)
-- proves the server is up, since curl only exits non-zero on a connection-level failure
-- (refused, host unreachable, timed out). Result lands on job.apiAvailable; dispatchSegment
-- reads it, and also flips it to false itself if an in-flight request later fails.
local function checkApiAvailable(job)
    local args = { "-s", "-o", "/dev/null", "-I", "-m", tostring(API.HEALTH_TIMEOUT_SECS), API.URL }
    hs.task.new(API.CURL_BIN, function(code, _, err)
        job.apiAvailable = (code == 0)
        if job.apiAvailable then
            log("api: gen " .. job.gen .. " endpoint check OK — using remote API")
        else
            log("api: gen " .. job.gen .. " endpoint check failed (" .. curlErrorMessage(code, err) ..
                ") — falling back to local " .. API.FALLBACK_MODEL)
        end
    end, args):start()
end

local function getPromptArgs()
    local content = readPrompt()
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

-- Where the dictated text is meant to land.
--
-- Whisper answers seconds after the key comes up, and in those seconds the user may have
-- clicked into another field, switched a tab or moved to another app. Typing there is worse
-- than not typing at all: the text lands in a chat, a search box or a terminal that was
-- never the target, and there is no undo for keystrokes someone else's app received. So the
-- destination is identified at release and re-checked right before insertion (finishInsertion).
--
-- It is a *signature*, not an object reference: AX hands back a fresh element on every query,
-- and Electron apps (VS Code among them) expose no focused element at all -- there the app,
-- the window id and the window title are all there is to go on. Volatile attributes are left
-- out on purpose (window frame, the field's own value): they change while the user keeps
-- working in exactly the right place, and a false alarm costs a manual paste every time.
--
-- Returns nil if AX is unavailable or an app is unresponsive -- no identifier at all means
-- the check is skipped, which is the pre-existing behaviour rather than a wrong verdict.
local function focusTargetId()
    local parts = {}
    local ok = pcall(function()
        local app = hs.application.frontmostApplication()
        parts[#parts + 1] = app and (app:bundleID() or app:name() or "?") or "?"
        parts[#parts + 1] = app and tostring(app:pid()) or "?"

        local win = hs.window.focusedWindow()
        parts[#parts + 1] = win and tostring(win:id()) or "-"
        parts[#parts + 1] = (win and win:title()) or ""

        local ae   = app and hs.axuielement.applicationElement(app)
        local elem = ae and ae:attributeValue("AXFocusedUIElement")
        if elem then
            for _, attr in ipairs({ "AXRole", "AXSubrole", "AXIdentifier", "AXDOMIdentifier", "AXTitle" }) do
                local v = elem:attributeValue(attr)
                parts[#parts + 1] = (type(v) == "string") and v or ""
            end
        end
    end)
    if not ok then return nil end
    return table.concat(parts, "|")
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

-- The window itself IS the progress bar: the background rectangle (1) is the track —
-- its light fill is the empty portion, and the colored bars (2,3) fill over it, full
-- window height. Text/dot/timer/close sit on top, centered on the single-line strip.
-- Element indices: 1=bg(track), 2=bar_rec, 3=bar_txn, 4=text, 5=dot, 6=timer, 7=close
local EL = { bg = 1, bar_rec = 2, bar_txn = 3, text = 4, dot = 5, timer = 6, close = 7 }

local function createOverlay()
    local screen = hs.screen.mainScreen()
    local frame = screen:frame()  -- excludes menu bar, so y=frame.y sits right under it
    local width, height = 420, 28
    local padding = 20
    local x = frame.x + (frame.w - width) / 2  -- centered under the menu bar
    local y = frame.y + padding

    overlay = hs.canvas.new({ x = x, y = y, w = width, h = height })

    -- 1: Background — this IS the progress track. Its light fill is the empty (unfilled)
    -- portion of the bar; the colored bars below fill over it, full window height.
    -- Click to pin overlay open.
    overlay:appendElements({
        id = "bg",
        type = "rectangle", action = "fill",
        roundedRectRadii = { xRadius = 8, yRadius = 8 },
        fillColor = { red = 0.93, green = 0.93, blue = 0.95, alpha = 0.50 },
        trackMouseUp = true,
    })

    -- 2: Recording progress (red/orange) — total recorded duration, fills the whole
    -- window (no inset — the window background is the bar) and grows left→right.
    overlay:appendElements({
        id = "bar_rec", type = "rectangle", action = "fill",
        roundedRectRadii = { xRadius = 8, yRadius = 8 },
        fillColor = { red = 1.0, green = 0.35, blue = 0.15, alpha = 0.0 },
        frame = { x = 0, y = 0, w = 1, h = height },
    })
    -- 3: Transcription progress (blue) — chases the red bar as segments finish
    overlay:appendElements({
        id = "bar_txn", type = "rectangle", action = "fill",
        roundedRectRadii = { xRadius = 8, yRadius = 8 },
        fillColor = { red = 0.2, green = 0.75, blue = 1.0, alpha = 0.0 },
        frame = { x = 0, y = 0, w = 1, h = height },
    })

    -- 4: Transcript text — left side, centered on the single-line strip, over the bar
    overlay:appendElements({
        id = "text", type = "text", text = "Listening...",
        textColor = { red = 0.12, green = 0.12, blue = 0.14, alpha = 1.0 },
        textSize = 13,
        frame = { x = "4%", y = "14%", w = "58%", h = "72%" },
    })
    -- 5: Recording indicator (pulsing red dot) — right side, vertically centered
    overlay:appendElements({
        id = "dot", type = "oval", action = "fill",
        fillColor = { red = 0.85, green = 0.1, blue = 0.1, alpha = 0.0 },
        frame = { x = 341, y = 10, w = 8, h = 8 },
    })
    -- 6: Elapsed time display — right side
    overlay:appendElements({
        id = "timer", type = "text", text = "",
        textColor = { red = 0.75, green = 0.15, blue = 0.15, alpha = 0.0 },
        textSize = 10,
        frame = { x = "63%", y = "18%", w = "16%", h = "64%" },
        textAlignment = "right",
    })
    -- 7: Close button (X) — right edge, last element so it's on top and clickable
    overlay:appendElements({
        id = "close", type = "text", text = "✕",
        textColor = { red = 0.75, green = 0.15, blue = 0.15, alpha = 0.85 },
        textSize = 15, textAlignment = "center",
        frame = { x = "87%", y = "8%", w = "10%", h = "84%" },
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
                canvas[1].fillColor = { red = 0.85, green = 0.89, blue = 0.97, alpha = 0.55 }
                log("overlay pinned")
            else
                canvas[1].fillColor = { red = 0.93, green = 0.93, blue = 0.95, alpha = 0.38 }
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
-- Declared here rather than next to the warmup code that drives it: the pipeline below asks
-- whether it is safe to type a finished transcript, and a reference to a local declared
-- further down would compile to a nil global read instead (see AGENTS.md).
local isWarmingUp = false

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

-- The voice trigger lives next to the recording functions it drives, far below, but the
-- menu is built here. Same forward-declaration pattern as pipelineReset and tryWarmup.
local getWakeEnabled, cycleWake, wakeStatusLabel, cycleWakeWord, wakeWordLabel

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
        title = "Model: " .. (isApiMode() and "API (auto-fallback)" or getModelName()),
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

    -- Mic device (pin to a specific input to stop Bluetooth output quality dropping to
    -- call-quality whenever a dictation opens the mic)
    table.insert(items, {
        title = "Mic: " .. getMicDeviceLabel(),
        fn = function() cycleMic(); updateMenuBar() end,
    })

    -- Voice trigger (wake word). Listens only while the screen is on — see the Voice
    -- trigger section for why the microphone, not the model, is what that gate protects.
    table.insert(items, {
        title = "Voice trigger: " .. (wakeStatusLabel and wakeStatusLabel() or "OFF"),
        fn = function() if cycleWake then cycleWake() end; updateMenuBar() end,
    })
    table.insert(items, {
        title = "Wake word: " .. (wakeWordLabel and wakeWordLabel() or "hey mycroft"),
        fn = function() if cycleWakeWord then cycleWakeWord() end; updateMenuBar() end,
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
    local BAR_MAX = 420  -- px, full window width — the bar fills the window edge to edge
    -- Freeze at the final duration once recording stops. Left live, this keeps climbing
    -- during transcription and re-trips the auto-expand below on every segment, so
    -- barMaxSecs outruns transcribedSecs and the blue bar never reaches 100%.
    local elapsed = recordedSecs or (hs.timer.secondsSinceEpoch() - recordingStartTime)
    -- Auto-expand: when recording reaches 5s before the max, extend by another 60s.
    -- Starts at 60s, so the first bounce is at 0:55, then 1:55, 2:55, …
    if elapsed >= barMaxSecs - 5 then barMaxSecs = barMaxSecs + 60 end
    local recFrac = math.min(elapsed / barMaxSecs, 1.0)
    local txnFrac = math.min(transcribedSecs / barMaxSecs, 1.0)
    overlay[EL.bar_rec].frame = { x = 0, y = 0, w = math.max(1, math.floor(recFrac * BAR_MAX)), h = 28 }
    overlay[EL.bar_txn].frame = { x = 0, y = 0, w = math.max(1, math.floor(txnFrac * BAR_MAX)), h = 28 }
end

local function hideProgressBar()
    if not overlay then return end
    overlay[EL.bar_rec].fillColor = { red = 1.0, green = 0.35, blue = 0.15, alpha = 0.0 }
    overlay[EL.bar_txn].fillColor = { red = 0.2, green = 0.75, blue = 1.0, alpha = 0.0 }
end

local function startRecordingIndicator()
    if not overlay then return end
    recordingStartTime = hs.timer.secondsSinceEpoch()
    recordedSecs = nil
    transcribedSecs = 0
    barMaxSecs = 60
    pulseAlpha = 1.0
    pulseFading = true

    -- Show dot and timer
    overlay[EL.dot].fillColor = { red = 0.85, green = 0.1, blue = 0.1, alpha = 1.0 }
    overlay[EL.timer].textColor = { red = 0.75, green = 0.15, blue = 0.15, alpha = 1.0 }

    -- Fill the bar over the track (the light window background)
    overlay[EL.bar_rec].fillColor = { red = 1.0, green = 0.35, blue = 0.15, alpha = 0.50 }
    overlay[EL.bar_txn].fillColor = { red = 0.2, green = 0.75, blue = 1.0, alpha = 0.50 }
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
    -- terminate(), not interrupt(): emergency stop throws the audio away, so there is no
    -- reason to let the recorder flush a final chunk first. The handle is left for the
    -- termination callback to clear, so a re-press can still detect a slow exit. Killed
    -- before the cleanup below, which deletes the directory it is writing into.
    if recorderTask and recorderTask:isRunning() then recorderTask:terminate() end
    -- Stop dispatching, and drop the segments already transcribed: emergency stop must not
    -- paste a partial transcript a moment later. This abandons every job still in flight,
    -- including one a newer recording detached, and rescues an already-finished transcript
    -- to the clipboard rather than dropping it on the floor.
    local rescued = pipelineReset()
    forceHideOverlay()
    updateMenuBar()
    os.execute("killall whisper-cli 2>/dev/null")
    hs.notify.new({ title = "local-whisper", informativeText = rescued and
        "Stopped — the earlier dictation is on the clipboard" or "Stopped" }):send()
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
local function finishInsertion(text, detectedLang, target)
    -- The cursor may have moved while whisper was working. If the place the text was meant
    -- for is no longer focused, nothing is typed: the transcript goes to the clipboard and
    -- the user gets two chimes instead of one.
    local mode, misdirected = getOutputMode(), false
    if target and mode ~= "copy" then
        local now = focusTargetId()
        if now and now ~= target then
            misdirected = true
            mode = "copy"
            log("insert: focus moved since the key was released -- clipboard only\n" ..
                "  target: " .. target .. "\n  now:    " .. now)
        end
    end

    -- Build action context and run pre-insert hooks
    local ctx = buildActionContext(normalizeText(text), detectedLang or getLang(), mode)
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
    if misdirected then display = "CLIPBOARD: " .. display end
    setOverlayText(display)
    playSound("Glass")
    if misdirected then
        -- Two chimes, not one: nothing was typed, the text is waiting on the clipboard.
        hs.timer.doAfter(0.35, function() playSound("Glass") end)
    end
    hs.timer.doAfter(misdirected and (OVERLAY_LINGER + 1.5) or OVERLAY_LINGER, hideOverlay)
end

-- Insert transcribed text at cursor, with post-processing and action hooks
local function insertTranscribedText(text, detectedLang, target)
    if text == "" or isHallucination(text) then
        hideOverlay()
        return
    end

    -- Apply app-aware post-processing
    text = postProcess(text, capturedAppBundleID)
    if text == "" then hideOverlay(); return end

    finishInsertion(text, detectedLang, target)
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
--
-- State is *per dictation*, not global. Pressing the trigger again while the previous
-- dictation is still being transcribed used to reset this table and wipe the shared chunk
-- directory, which lost that dictation whole: its finished segments were dropped from
-- `results`, `finalizing` went back to false so nothing was ever assembled, and the
-- concat of its remaining audio failed with ffmpeg exit 254 because the WAVs were gone.
-- Each keypress now gets its own job (own chunk directory, own segment files, own results)
-- and an older job keeps transcribing and delivers its text on its own.
local pipeJobs = {
    live    = {},   -- [gen] = job, every job that can still produce text
    pending = {},   -- finished transcripts waiting for a safe moment to be inserted
    lastGen = 0,
}

local function pipeNewJob()
    pipeJobs.lastGen = pipeJobs.lastGen + 1
    local job = {
        gen        = pipeJobs.lastGen,
        dir        = CHUNK_DIR .. "/g" .. pipeJobs.lastGen,  -- this dictation's audio, nobody else's
        results    = {},    -- [segN] = text, filled as each segment completes (order preserved)
        lang       = nil,   -- first detected language across all segments
        target     = nil,   -- focusTargetId() of where the text belongs, taken at key release
        nextChunk  = 1,     -- 1-based index of the next chunk not yet claimed by a segment
        nextSeg    = 1,     -- next segment number to assign
        total      = 0,     -- fixed once recording stops and the tail is dispatched
        done       = 0,     -- segments finished so far
        finalizing = false, -- true once `total` is known
        inserted   = false, -- true once its text was inserted or queued, so it happens once
        abandoned  = false, -- emergency stop: its segments are dropped as they come back
        -- nil while the check is in flight, then true/false. In API mode only; dispatchSegment
        -- treats nil like true (optimistic — the check almost always beats the first segment)
        -- and a request failure can still flip it to false mid-job.
        apiAvailable = nil,
        timer      = nil,   -- polls during recording for a segment that is ready to dispatch
    }
    pipeJobs.live[job.gen] = job
    os.execute("mkdir -p '" .. job.dir .. "'")
    return job
end

-- The dictation the trigger is currently driving. Reassigned per keypress by pipeStartJob;
-- everything already in flight holds its own job reference instead of reading this.
local pipe = pipeNewJob()

-- A job's audio and intermediates are removed only when nothing can still read them.
-- Deleting them early is exactly the bug this rework fixes.
local function pipeCleanup(job)
    pipeJobs.live[job.gen] = nil
    if job.timer then job.timer:stop(); job.timer = nil end
    -- Archive chunks for 2 days instead of deleting: useful for diagnosing hallucinations
    local archiveDest = VOICE_ARCHIVE_DIR .. "/" .. os.date("%Y%m%d_%H%M%S") .. "_g" .. job.gen
    os.execute("mv '" .. job.dir .. "' '" .. archiveDest .. "' 2>/dev/null || rm -rf '" .. job.dir .. "'")
    os.execute("rm -f '" .. WHISPER_TMP .. "'/pipe_seg_g" .. job.gen ..
               "_* '" .. WHISPER_TMP .. "'/pipe_concat_g" .. job.gen .. "_* 2>/dev/null")
end

-- Transcripts that finished while a newer recording was running, oldest first.
local function pipeTakePending()
    if #pipeJobs.pending == 0 then return nil, nil, nil end
    local parts, lang = {}, nil
    local target = pipeJobs.pending[1].target
    for _, p in ipairs(pipeJobs.pending) do
        table.insert(parts, p.text)
        lang = lang or p.lang
        -- Dictations aimed at different places have no single destination left between them:
        -- "" matches no focus, so the whole batch takes the clipboard route.
        if p.target ~= target then target = "" end
    end
    for i = #pipeJobs.pending, 1, -1 do pipeJobs.pending[i] = nil end
    return table.concat(parts, " "), lang, target
end

-- True when a finished transcript can be typed *right now*: nothing is recording, the
-- trigger combo is not held (both insertion modes post keystrokes, and ⌘V or a letter
-- landing inside a held fn+ctrl is not what the user asked for), and no dictation in
-- progress owns the overlay.
local function pipeInsertIsSafe()
    if isRecording or isWarmingUp or finalizationPending then return false end
    if triggerHeld() then return false end
    local cur = pipeJobs.live[pipe.gen]
    if cur and (cur.nextSeg > 1 or cur.finalizing) then return false end
    return true
end

-- Insert whatever earlier dictations left queued. Returns true if it inserted something, so
-- callers that would otherwise just hide the overlay can tell.
local function pipeFlushPending()
    local text, lang, target = pipeTakePending()
    if not text then return false end
    log("pipeline: flushing a queued dictation (" .. #text .. " chars)")
    insertTranscribedText(text, lang, target)
    return true
end

-- Called once per keypress, before the recorder starts. The previous job is *detached*, not
-- reset: if its transcription is still running it keeps its results, its chunk directory and
-- its segment files, and delivers its own text when it finishes. Reassigning `pipe` is safe
-- only because nothing in flight reads it — dispatchSegment captures the job it belongs to
-- and every callback below takes that job explicitly.
local function pipeStartJob()
    if pipe.timer then pipe.timer:stop(); pipe.timer = nil end
    local prev = pipe
    if pipeJobs.live[prev.gen] then
        if prev.nextSeg > 1 or prev.finalizing then
            log("pipeline: gen " .. prev.gen .. " still transcribing — detached, it delivers its own text")
        else
            pipeCleanup(prev)   -- nothing was ever dispatched from it: its audio is dead weight
        end
    end
    pipe = pipeNewJob()
    if isApiMode() then
        checkApiAvailable(pipe)  -- runs in parallel with the recording that's about to start
    end
    log("pipeline: gen " .. pipe.gen .. " started")
end

-- Assigned, not declared: the local is forward-declared above emergencyStop.
--
-- Emergency stop means nothing from any of this reaches the cursor, so every job still in
-- flight is abandoned — including one a newer recording detached. A transcript that already
-- finished is not silently dropped: it goes to the clipboard, and the return value says so.
pipelineReset = function()
    for gen, job in pairs(pipeJobs.live) do
        job.abandoned = true
        log("pipeline: gen " .. gen .. " abandoned")
        pipeCleanup(job)
    end
    local queued = pipeTakePending()
    if not queued then return false end
    hs.pasteboard.setContents(queued)
    log("pipeline: a finished dictation was still queued — copied to the clipboard: '" .. queued .. "'")
    return true
end

local function pipelineFinalize(job)
    if job.abandoned or job.inserted then return end
    job.inserted = true

    local parts = {}
    for n = 1, job.total do
        local t = job.results[n] or ""
        if t ~= "" then table.insert(parts, t) end
    end
    local finalText = table.concat(parts, " "):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    log("pipeline: gen " .. job.gen .. " finalized " .. job.total .. " seg(s): '" .. finalText .. "'")
    pipeCleanup(job)

    -- This dictation finished behind a newer one. Typing it now would post keystrokes into
    -- the trigger combo the user is still holding, and the overlay belongs to the recording
    -- in progress — so queue it. The next insertion carries it, in the order it was spoken.
    if job ~= pipe and not pipeInsertIsSafe() then
        if finalText ~= "" then
            table.insert(pipeJobs.pending, { text = finalText, lang = job.lang, target = job.target })
            log("pipeline: gen " .. job.gen .. " queued behind the current dictation (" ..
                #pipeJobs.pending .. " pending)")
        end
        return
    end

    if job ~= pipe then
        -- Nothing is recording and nothing else owns the overlay: deliver it on its own.
        log("pipeline: gen " .. job.gen .. " inserting late — the recorder is idle")
        if finalText ~= "" then insertTranscribedText(finalText, job.lang, job.target) end
        return
    end

    -- The queued text rides along to this dictation's destination: the user is standing in
    -- it right now, having just spoken into it. Its own target is deliberately dropped.
    local queued, queuedLang = pipeTakePending()
    if queued then
        finalText = (finalText ~= "") and (queued .. " " .. finalText) or queued
        if not job.lang then job.lang = queuedLang end
        log("pipeline: prepended a queued dictation (" .. #queued .. " chars) from an earlier recording")
    end

    if finalText == "" then
        hideProgressBar()
        hideOverlay()
        return
    end
    -- Flash the blue bar to 100% to confirm all audio was transcribed, then fade it
    transcribedSecs = barMaxSecs
    if overlay then updateProgressBar() end
    hs.timer.doAfter(0.4, hideProgressBar)
    insertTranscribedText(finalText, job.lang, job.target)
end

-- chunkCount drives the progress bar, which measures transcribed seconds against
-- recorded seconds — one chunk is one second.
local function onPipelineDone(job, n, text, detected, chunkCount)
    if job.abandoned then
        log("pipeline: gen " .. job.gen .. " seg " .. n .. " came back after a stop — dropped")
        return
    end
    job.results[n] = text
    if detected and not job.lang then job.lang = detected end
    job.done = job.done + 1
    -- The progress bar and the overlay belong to the dictation in progress; a detached job
    -- reporting in must not move them.
    if job == pipe then
        transcribedSecs = transcribedSecs + (chunkCount or 0)
        if overlay then updateProgressBar() end
    end
    log("pipeline: gen " .. job.gen .. " seg " .. n .. " complete (done=" .. job.done .. "/" ..
        (job.finalizing and job.total or "?") .. ")")

    -- While recording, the overlay belongs to the timer — don't stomp it. Only once the
    -- total is known does the countdown make sense.
    if not job.finalizing then return end
    local left = job.total - job.done
    if left > 0 then
        if job == pipe then setOverlayText(string.format("Transcribing... (%d left)", left)) end
    else
        pipelineFinalize(job)
    end
end

-- Concat a chunk group → WAV → whisper (or the remote API), then report via
-- onPipelineDone. Fully async: several segments may be in flight at once.
-- `job` defaults to the current dictation, and every callback below closes over it instead
-- of reading `pipe`: by the time whisper answers, `pipe` may already be the *next* dictation,
-- and writing the result there is how a finished transcript vanished.
local function dispatchSegment(segN, group, job)
    job = job or pipe
    local lang       = getLang()
    local promptArgs = getPromptArgs()
    local nChunks    = #group
    local concatFile = WHISPER_TMP .. "/pipe_concat_g" .. job.gen .. "_" .. segN .. ".txt"
    local segWav     = WHISPER_TMP .. "/pipe_seg_g" .. job.gen .. "_" .. segN .. ".wav"

    local f, ferr = io.open(concatFile, "w")
    if not f then
        log("pipeline: gen " .. job.gen .. " seg " .. segN .. " ERROR opening concat file: " .. tostring(ferr))
        onPipelineDone(job, segN, "", nil, nChunks)
        return
    end
    for _, chunk in ipairs(group) do f:write("file '" .. chunk .. "'\n") end
    f:close()

    local gfirst = group[1]:match("([^/]+)$") or group[1]
    local glast  = group[nChunks]:match("([^/]+)$") or group[nChunks]
    log("pipeline: gen " .. job.gen .. " seg " .. segN .. " concat " .. nChunks .. " chunks (" .. gfirst .. " … " .. glast .. ")")

    local concatTask = hs.task.new(FFMPEG, function(code)
        if code ~= 0 then
            log("pipeline: gen " .. job.gen .. " seg " .. segN .. " concat FAILED (code=" .. tostring(code) .. ")")
            onPipelineDone(job, segN, "", nil, nChunks)
            return
        end
        local wavSize = (hs.fs.attributes(segWav) or {}).size or -1
        log("pipeline: gen " .. job.gen .. " seg " .. segN .. " concat OK — wav size=" .. wavSize .. " bytes")

        local function onSegmentText(text, detected)
            if text ~= "" and not isHallucination(text) then
                log("pipeline: gen " .. job.gen .. " seg " .. segN .. " accepted: '" .. text:sub(1, 120) .. "'")
            else
                log("pipeline: gen " .. job.gen .. " seg " .. segN .. " REJECTED (empty or hallucination): '" .. text:sub(1, 80) .. "'")
                text = ""
            end
            onPipelineDone(job, segN, text, detected, nChunks)
        end

        -- Auto-detect stays per segment for code-switching (surzhyk / mixed language):
        -- forcing a later segment into an earlier segment's language would translate it.
        local effectiveLang = lang

        -- Timestamps are requested from whisper-cli (no -nt) even though we discard them below:
        -- disabling them isn't just a print-formatting toggle, it removes the timestamp tokens
        -- the decoder itself relies on to keep advancing through pauses. Without them, whisper
        -- can decide a mid-recording pause after a complete sentence is the end of the audio,
        -- silently dropping everything spoken after it and replacing the tail with a short
        -- hallucinated fragment. Stripping "[00:00:00.000 --> 00:00:01.000]" markers from the
        -- text ourselves costs nothing and keeps that continuation logic intact.
        local function stripTimestamps(s)
            return (s or ""):gsub("%[[^%]]*%]", "")
                :gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
        end

        -- modelPath/modelLabel are parameterized so the API-mode fallback can force
        -- large-v3 regardless of what MODEL_FILE holds (it holds the "API" sentinel there,
        -- not a real model file) while normal local mode keeps using getModelPath().
        local function runLocalWhisper(modelPath, modelLabel)
            log("pipeline: gen " .. job.gen .. " seg " .. segN .. " starting whisper lang=" .. effectiveLang ..
                " model=" .. modelLabel)
            if effectiveLang == "auto" then
                local autoArgs = { "-m", modelPath, "-f", segWav, "-l", "auto" }
                for _, a in ipairs(promptArgs) do table.insert(autoArgs, a) end
                hs.task.new(WHISPER_BIN, function(code2, out2, err2)
                    log("pipeline: gen " .. job.gen .. " seg " .. segN .. " whisper(auto) exit=" .. tostring(code2) ..
                        " outlen=" .. #(out2 or ""))
                    if code2 ~= 0 then
                        log("pipeline: gen " .. job.gen .. " seg " .. segN .. " whisper FAILED (auto)")
                        onPipelineDone(job, segN, "", nil, nChunks)
                        return
                    end
                    local detected = (err2 or ""):match("auto%-detected language:%s*(%w+)")
                    log("pipeline: gen " .. job.gen .. " seg " .. segN .. " auto-detected: " .. tostring(detected))
                    onSegmentText(stripTimestamps(out2), detected)
                end, autoArgs):start()
            else
                local langArgs = { "-m", modelPath, "-f", segWav, "-l", effectiveLang, "--no-prints" }
                for _, a in ipairs(promptArgs) do table.insert(langArgs, a) end
                hs.task.new(WHISPER_BIN, function(code2, out2)
                    log("pipeline: gen " .. job.gen .. " seg " .. segN .. " whisper(" .. effectiveLang .. ") exit=" .. tostring(code2) ..
                        " outlen=" .. #(out2 or ""))
                    if code2 ~= 0 then
                        log("pipeline: gen " .. job.gen .. " seg " .. segN .. " whisper FAILED")
                        onPipelineDone(job, segN, "", nil, nChunks)
                        return
                    end
                    onSegmentText(stripTimestamps(out2), effectiveLang)
                end, langArgs):start()
            end
        end

        if isApiMode() then
            local fallbackPath = MODELS_DIR .. "/ggml-" .. API.FALLBACK_MODEL .. ".bin"

            -- The parallel key-down probe already knows the endpoint is unreachable — skip
            -- straight to local instead of paying transcribeViaAPI's own timeout again.
            if job.apiAvailable == false then
                runLocalWhisper(fallbackPath, API.FALLBACK_MODEL .. " (API unreachable)")
                return
            end

            -- apiAvailable is true or still nil (probe pending — optimistic: it almost always
            -- resolves before the first segment is ready). Either way, try the API first.
            log("pipeline: gen " .. job.gen .. " seg " .. segN .. " starting API transcription lang=" .. effectiveLang)
            transcribeViaAPI(segWav, effectiveLang, 60, function(text, detected, errMsg)
                if errMsg then
                    log("pipeline: gen " .. job.gen .. " seg " .. segN .. " API error: " .. errMsg ..
                        " — falling back to local " .. API.FALLBACK_MODEL)
                    job.apiAvailable = false  -- stop retrying the API for the rest of this dictation
                    runLocalWhisper(fallbackPath, API.FALLBACK_MODEL .. " (API failed)")
                    return
                end
                text = (text or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
                onSegmentText(text, effectiveLang == "auto" and detected or effectiveLang)
            end)
            return
        end

        runLocalWhisper(getModelPath(), getModelName())
    end, { "-y", "-f", "concat", "-safe", "0", "-i", concatFile, "-c", "copy", segWav })
    concatTask:start()
end

-- Polled during recording. Dispatches at most one segment per tick, and only when enough
-- unclaimed audio has accumulated for splitAtSilence to make a real pause-bounded cut.
local function streamCheckAndDispatch()
    if not isRecording then return end

    local all = getChunkFiles(pipe.dir)
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
    log("stream: gen " .. pipe.gen .. " dispatching seg " .. segN .. " live during recording (" ..
        #firstGroup .. " chunks, " .. (#all - pipe.nextChunk + 1) .. " still unclaimed)")
    dispatchSegment(segN, firstGroup, pipe)
end

local function doFinalTranscription()
    local job = pipe
    if job.timer then job.timer:stop(); job.timer = nil end
    if job.abandoned then log("final: gen " .. job.gen .. " was abandoned, nothing to do"); return end
    if job.finalizing then log("final: gen " .. job.gen .. " is already finalizing"); return end

    local all = getChunkFiles(job.dir)
    log("final: gen " .. job.gen .. " START — total chunks=" .. #all .. ", already streamed=" ..
        (job.nextSeg - 1) .. " seg(s), next unclaimed chunk=" .. job.nextChunk)

    local remaining = {}
    for j = job.nextChunk, #all do table.insert(remaining, all[j]) end

    if job.nextSeg == 1 and #remaining < 2 then
        log("final: not enough chunks, skipping")
        pipeCleanup(job)
        hideProgressBar()
        -- Nothing came of this recording, so an earlier dictation waiting on it is inserted
        -- now rather than sitting in the queue until the user happens to dictate again.
        if not pipeFlushPending() then hideOverlay() end
        return
    end

    setOverlayText("Transcribing...")

    -- Whatever the streaming pass never claimed — the tail, plus anything it was too
    -- conservative to take. Still split at silence so the seams stay off mid-word.
    if #remaining >= 2 then
        for _, grp in ipairs(splitAtSilence(remaining, FINAL_SEGMENT_SECS)) do
            local segN = job.nextSeg
            job.nextSeg   = job.nextSeg + 1
            job.nextChunk = job.nextChunk + #grp
            log("final: dispatching tail seg " .. segN .. " → " .. #grp .. " chunks")
            dispatchSegment(segN, grp, job)
        end
    end

    job.total      = job.nextSeg - 1
    job.finalizing = true
    log("final: total=" .. job.total .. " seg(s), done=" .. job.done)

    if job.total == 0 then
        log("final: no segments at all, skipping")
        pipeCleanup(job)
        hideProgressBar()
        if not pipeFlushPending() then hideOverlay() end
        return
    end

    local left = job.total - job.done
    if left > 0 then
        setOverlayText(string.format("Transcribing... (%d left)", left))
    else
        -- Every streamed segment already finished before the key came up.
        pipelineFinalize(job)
    end
end

--------------------------------------------------------------------------------
-- Start / stop recording
--------------------------------------------------------------------------------

-- Warmup state (isWarmingUp is declared far above, with the recording state)
local warmupTimer = nil
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
    -- sends SIGINT, and lw-record then takes a moment to flush its final chunk. Its tail can
    -- no longer contaminate this recording (it writes into its own generation's directory),
    -- but it still holds the microphone — kill it before opening the device again.
    if recorderTask and recorderTask:isRunning() then
        log("warmup: terminating a still-running recorder from the previous dictation")
        recorderTask:terminate()
    end
    recorderTask = nil

    -- Each attempt records from scratch: a stale chunk from a failed attempt would be
    -- concatenated into the front of the transcript. Only *this* dictation's directory is
    -- cleared. The shared one used to be wiped here, which deleted audio a previous dictation
    -- was still concatenating — ffmpeg exited 254 and that transcript was lost whole.
    os.execute("rm -rf '" .. pipe.dir .. "'")
    os.execute("mkdir -p '" .. pipe.dir .. "'")

    -- Chunk indices restart at 0 along with the directory, so the claim cursors go back too.
    pipe.nextChunk = 1
    pipe.nextSeg   = 1

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
    -- The directory this recorder writes into, captured so the callbacks below measure the
    -- run they belong to even after the next keypress has moved `pipe` on.
    local jobDir = pipe.dir
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
                for _, p in ipairs(getChunkFiles(jobDir)) do
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
        { jobDir, "1", "16000", getMicDevice() or "" })
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
    -- This keypress gets its own job — chunk directory, segment files, results. The previous
    -- dictation keeps everything it needs to finish and deliver its text.
    pipeStartJob()
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
        -- Nothing is held any more, so a transcript queued while this recording was starting
        -- goes in now instead of waiting for a dictation that may never come.
        pipeFlushPending()
        return
    end

    if not isRecording then return end
    isRecording = false
    log("recording: stop")

    -- Pin down where this dictation is meant to go, while the user is still there. It is
    -- re-checked just before insertion; if it moved, the text goes to the clipboard.
    pipe.target = focusTargetId()
    log("insert: target at release: " .. tostring(pipe.target))

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
-- Voice trigger (wake word)
--------------------------------------------------------------------------------
-- A second, far smaller model listens for one phrase and starts a dictation exactly as the
-- key does. Transcription is untouched: it still goes to whichever model is selected, API
-- or local. The listener is a ~860 KB binary classifier over a mel spectrogram, not a
-- recognizer. whisper-tiny on a rolling window was the obvious alternative and is the wrong
-- tool twice over — measured here it costs ~3% of a core against a fraction of that, and it
-- invents words on near-silence, which is the failure HALLUCINATIONS above already exists to
-- clean up after. Running that generator 24/7 would make it constant instead of occasional.
--
-- The model is not what costs anything; the open microphone is. Measured on this machine:
-- holding capture open adds ~4.5 pp to coreaudiod plus ~0.9 pp for lw-record itself (~5.4%
-- of one core), and macOS takes a sleep assertion named
-- "com.apple.audio.BuiltInMicrophoneDevice.context.preventuseridlesleep" for exactly as long
-- as the device stays open. That assertion is the whole reason the listener is gated on the
-- screen: while the screen is on, powerd already holds the identical assertion ("Prevent
-- sleep while display is on"), so an open microphone adds nothing to it. The moment the
-- screen sleeps the daemon goes down and the device is released. A sleeping machine is never
-- woken by voice, deliberately — that would mean holding the microphone open around the clock
-- to save a keypress.

LocalWhisper = LocalWhisper or {}

-- A reload re-runs this file while the previous run's listener is still alive and still
-- holding the microphone, invisible to the new instance. Unrooted Hammerspoon objects are
-- garbage-collected, but a live hs.task is not — it has to be terminated explicitly.
if LocalWhisper.wakeTask then
    pcall(function()
        if LocalWhisper.wakeTask:isRunning() then LocalWhisper.wakeTask:terminate() end
    end)
    LocalWhisper.wakeTask = nil
end

local WAKE = {
    VENV_PY   = CONFIG_DIR .. "/wake-venv/bin/python",
    -- Pretrained models that ship with openWakeWord. "alexa" is deliberately absent: a
    -- television or someone else's speaker sets it off. Which word suits a given voice is
    -- not something the code can know -- a Russian speaker reaching for "mycroft" tends to
    -- land on "Minecraft", which scores zero -- so this is switchable from the menu.
    WORDS     = { "hey_mycroft", "hey_jarvis", "hey_rhasspy" },
    -- Not the documented default of 0.5. Measured against 114 minutes of this machine's own
    -- archived dictation (85,500 frames of real ru/uk/en speech): exactly two frames ever
    -- crossed 0.5, scoring 0.564 and 0.900, while a genuine "hey mycroft" scores 0.998-1.000
    -- and holds it for eight consecutive frames. 0.95 clears both false positives with margin
    -- and still sits far below the real thing. If a live voice turns out to score lower than
    -- that test did, this is the number to lower — nothing else.
    THRESHOLD = "0.95",
    -- A voice-started dictation has no key to release, so it must end itself. Measured on
    -- this machine rather than guessed: this room's noise floor runs 15-19 RMS per frame,
    -- archived dictation seconds sit at 42 (10th percentile) and 141 (20th), and speech
    -- averages 400-700. 100 falls in the gap with margin on both sides. Note that a keyboard
    -- click peaks near 900, so typing through a voice-started dictation holds it open until
    -- the cap — the key trigger is the better tool when hands are already on the keyboard.
    SILENCE_RMS  = 100,
    -- All three come from 182 archived dictations on this machine, not from taste.
    -- Pauses *inside* a dictation: median 1 s, 95th percentile 4 s, longest 11 s. A 2.5 s
    -- timeout would have cut roughly one pause in five; 8 s cuts one in 134. The timeout is
    -- meant as a safety net rather than the normal way to finish — tapping the trigger key
    -- ends a voice-started dictation immediately — so it is set long enough to never
    -- interrupt a thought.
    SILENCE_SECS = 8,     -- consecutive quiet seconds that end the dictation
    LEAD_SECS    = 12,    -- if nobody starts talking at all, give up and release the mic
    -- Recorded dictations run to 122 s here and 5.4% pass 90 s, so a 90 s cap would have
    -- truncated one in eighteen. Voice-started ones run longer still, since an 8 s pause no
    -- longer ends them. This is a stuck-detection backstop, nothing more.
    MAX_SECS     = 240,
}

-- Same resolution trick ensureRecorder uses: find the repo this init.lua was loaded from,
-- following the symlink Hammerspoon is usually configured with.
local function repoPath(rel)
    local this = debug.getinfo(1, "S").source:match("^@(.*)$")
    if not this then return nil end
    local real = hs.fs.symlinkAttributes(this, "target") or this
    local root = real:match("^(.*)/hammerspoon/init%.lua$")
    if not root then return nil end
    return root .. "/" .. rel
end

getWakeEnabled = function()
    return (readFile(WAKE_FILE):gsub("%s+", "")) == "on"
end

local function getWakeWord()
    local saved = (readFile(WAKE_MODEL_FILE):gsub("%s+", ""))
    for _, w in ipairs(WAKE.WORDS) do
        if w == saved then return w end
    end
    return WAKE.WORDS[1]
end

wakeWordLabel = function()
    return (getWakeWord():gsub("_", " "))
end

local wakeTask = nil
local wakeSilenceTimer = nil

-- On battery the listener does not run at all. The microphone is the expensive half of this
-- feature (see the section header), and this is a fanless Air whose battery is the one
-- resource a background listener can visibly eat. A machine with no battery at all reports
-- nil, which is a desktop: always treat that as plugged in.
local function wakeOnPower()
    local src = hs.battery.powerSource()
    return src == nil or src ~= "Battery Power"
end

local wakeLastPower = wakeOnPower()

local function wakeIsRunning()
    return wakeTask ~= nil and wakeTask:isRunning()
end

local function wakeStopSilenceWatch()
    if wakeSilenceTimer then wakeSilenceTimer:stop(); wakeSilenceTimer = nil end
    LocalWhisper.wakeSilenceTimer = nil
end

-- Ends a voice-started dictation on silence, because there is no key release to end it.
-- Only finished chunks are judged: the one the recorder is writing right now is short and
-- would read as silence every time.
local function wakeStartSilenceWatch()
    wakeStopSilenceWatch()
    local job = pipe
    local startedAt = hs.timer.secondsSinceEpoch()
    local heardSpeech = false
    local quietSince = nil

    wakeSilenceTimer = hs.timer.doEvery(0.5, function()
        -- The dictation ended some other way: key press, emergency stop, or a newer
        -- recording took over. Nothing left for this watcher to end.
        if not (isRecording or isWarmingUp) or pipe ~= job then
            wakeStopSilenceWatch()
            return
        end

        local now = hs.timer.secondsSinceEpoch()
        local elapsed = now - startedAt

        if elapsed >= WAKE.MAX_SECS then
            log("wake: hit the " .. WAKE.MAX_SECS .. "s cap, stopping")
            wakeStopSilenceWatch(); stopRecording(); return
        end

        local chunks = getChunkFiles(job.dir)
        if #chunks >= 2 then
            local rms = getWavRMS(chunks[#chunks - 1])
            if rms >= WAKE.SILENCE_RMS then
                heardSpeech = true
                quietSince = nil
            elseif heardSpeech then
                quietSince = quietSince or now
                if now - quietSince >= WAKE.SILENCE_SECS then
                    log(string.format("wake: %.1fs of silence, stopping", now - quietSince))
                    wakeStopSilenceWatch(); stopRecording(); return
                end
            end
        end

        if not heardSpeech and elapsed >= WAKE.LEAD_SECS then
            log("wake: nothing was said within " .. WAKE.LEAD_SECS .. "s, stopping")
            wakeStopSilenceWatch(); stopRecording()
        end
    end)
    LocalWhisper.wakeSilenceTimer = wakeSilenceTimer  -- see LocalWhisper.modTap on rooting
end

local function wakeStop(reason)
    if wakeTask then
        if wakeTask:isRunning() then
            log("wake: stopping listener (" .. reason .. ")")
            wakeTask:terminate()
        end
        wakeTask = nil
        LocalWhisper.wakeTask = nil
    end
    wakeStopSilenceWatch()
end

local function wakeStart(reason)
    if wakeIsRunning() or not getWakeEnabled() then return end
    if not wakeOnPower() then
        log("wake: on battery, listener stays down (" .. reason .. ")")
        return
    end

    local runner = repoPath("tools/lw-wake-run.sh")
    local script = repoPath("tools/lw-wake.py")
    if not runner or not script then
        log("wake: cannot locate tools/ from " .. tostring(debug.getinfo(1, "S").source))
        return
    end
    if not hs.fs.attributes(WAKE.VENV_PY) then
        log("wake: venv missing at " .. WAKE.VENV_PY .. " — run tools/lw-wake-setup.sh")
        return
    end

    log("wake: starting listener (" .. reason .. ", model=" .. getWakeWord() .. ")")
    wakeTask = hs.task.new(runner, function(code)
        log("wake: listener exited, code=" .. tostring(code))
        wakeTask = nil
        LocalWhisper.wakeTask = nil
    end, {
        RECORDER_BIN, getMicDevice() or "", WAKE.VENV_PY, script,
        LOG_FILE, getWakeWord(), WAKE.THRESHOLD,
    })
    if wakeTask then
        wakeTask:start()
        LocalWhisper.wakeTask = wakeTask
    end
end

wakeStatusLabel = function()
    if not getWakeEnabled() then return "OFF" end
    if not hs.fs.attributes(WAKE.VENV_PY) then return "ON — run lw-wake-setup.sh" end
    if not wakeOnPower() then return "ON \u{00B7} on battery" end
    if not wakeIsRunning() then return "ON \u{00B7} paused" end
    return "ON \u{00B7} " .. wakeWordLabel()
end

-- Changing the word means restarting the listener: the model is loaded once at startup.
cycleWakeWord = function()
    local cur, nextWord = getWakeWord(), nil
    for i, w in ipairs(WAKE.WORDS) do
        if w == cur then nextWord = WAKE.WORDS[(i % #WAKE.WORDS) + 1] break end
    end
    writeFile(WAKE_MODEL_FILE, nextWord or WAKE.WORDS[1])
    if getWakeEnabled() then
        wakeStop("switching wake word")
        wakeStart("wake word changed to " .. getWakeWord())
    end
end

cycleWake = function()
    local on = not getWakeEnabled()
    writeFile(WAKE_FILE, on and "on" or "off")
    if on then wakeStart("enabled from menu") else wakeStop("disabled from menu") end
end

-- Called when the phrase is heard. Kept on the persistent global so it can be invoked by
-- hand from the console or the `hs` CLI, but the daemon reaches it through the URL handler
-- below rather than the CLI.
function LocalWhisper.voiceTrigger()
    if not getWakeEnabled() then return end
    if isRecording or isWarmingUp then
        log("wake: detection ignored, a dictation is already running")
        return
    end
    log("wake: detected, starting dictation")
    playSound("Morse", 0.3)
    startRecording()
    wakeStartSilenceWatch()
end

-- The daemon fires through this rather than `hs -c`. The CLI is a synchronous round-trip to
-- this process's main thread and blocks for seconds exactly when a trigger arrives -- while
-- a recording is being started -- sometimes never returning ("CFMessagePort: dropping
-- corrupt reply Mach message" in the log). A URL event is delivered asynchronously by the
-- system, so a busy Hammerspoon delays the trigger instead of losing it.
hs.urlevent.bind("lw-voice-trigger", function()
    LocalWhisper.voiceTrigger()
end)

-- The listener follows the screen, not the system. screensDidSleep is the point where an
-- open microphone would start costing something nobody is there to benefit from, and where
-- its sleep assertion stops being masked by powerd's.
local screenWatcher = hs.caffeinate.watcher.new(function(event)
    if event == hs.caffeinate.watcher.screensDidSleep then
        wakeStop("screen off")
    elseif event == hs.caffeinate.watcher.screensDidWake then
        wakeStart("screen on")
    end
end)
screenWatcher:start()
LocalWhisper.wakeScreenWatcher = screenWatcher  -- see LocalWhisper.modTap on rooting

-- Unplugging kills the listener, plugging back in revives it. hs.battery.watcher fires on
-- every battery change including each percentage tick, so the callback acts only on an
-- actual change of power source -- otherwise it would log a line a minute forever.
local batteryWatcher = hs.battery.watcher.new(function()
    local onPower = wakeOnPower()
    if onPower == wakeLastPower then return end
    wakeLastPower = onPower
    if onPower then wakeStart("power connected") else wakeStop("running on battery") end
    updateMenuBar()
end)
batteryWatcher:start()
LocalWhisper.wakeBatteryWatcher = batteryWatcher  -- see LocalWhisper.modTap on rooting

if getWakeEnabled() then wakeStart("enabled at load") end

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
log("loaded (trigger=" .. TRIGGER_KEY .. ", lang=" .. getLang() .. ", output=" .. getOutputMode() .. ", model=" .. getModelName() .. ", mic=" .. getMicDeviceLabel() .. ")")
hs.notify.new({
    title = "local-whisper",
    informativeText = "Loaded (" .. getLang():upper() .. " / " .. getOutputMode():upper() .. enterStatus .. " / " .. getModelName() .. actionsFlag .. ") — hold " .. trigger.label
}):send()
