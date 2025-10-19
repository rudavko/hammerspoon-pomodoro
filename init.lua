-- Pomodoro timer module for Hammerspoon (no logging, timer selector)
local pomodoro        = {}
local notification    = require('pomodoro.notification')

-- ---- Constants ---------------------------------------------------
local IDLE_THRESHOLD  = 120     -- 2 minutes
local RESET_THRESHOLD = 5 * 60  -- 5 minutes
local PERSISTENCE_KEY = 'pomodoro.state'
local CONFIG_KEY      = 'pomodoro.config'
local CHECK_INTERVAL  = 1    -- seconds
local BANNER_GRACE    = 60   -- seconds
local REPEAT_INTERVAL = 120  -- seconds

local STATE           = { WORK = 'work', IDLE = 'idle', FRESH = 'fresh' }
local NOTIFY_MODE     = { NONE = "none", BANNER = "banner", OVERLAY = "overlay" }

-- ---- Config (persisted) ------------------------------------------
pomodoro.config       = { workMinutes = 25, aiProvider = nil } -- nil, "claude", "codex", or "none"

local function saveConfig()
    hs.settings.set(CONFIG_KEY, { workMinutes = pomodoro.config.workMinutes, aiProvider = pomodoro.config.aiProvider })
end

local function loadConfig()
    local cfg = hs.settings.get(CONFIG_KEY)
    if cfg and tonumber(cfg.workMinutes) then
        local m = tonumber(cfg.workMinutes)
        -- allow only 25/35/45; fallback to 25 if out of range
        if m == 25 or m == 35 or m == 45 then
            pomodoro.config.workMinutes = m
        else
            pomodoro.config.workMinutes = 25
        end
    end
    if cfg and cfg.aiProvider then
        pomodoro.config.aiProvider = cfg.aiProvider
    end
end

local function workThresholdSeconds()
    return (pomodoro.config.workMinutes or 25) * 60
end

-- ---- AI Provider detection ---------------------------------------
local function isCommandAvailable(cmd)
    local output, status = hs.execute(string.format("command -v %s >/dev/null 2>&1", cmd), true)
    return status == true
end

local function detectAIProvider()
    -- Check in order of preference: claude, then codex
    if isCommandAvailable("claude") then
        return "claude"
    elseif isCommandAvailable("codex") then
        return "codex"
    else
        return "none"
    end
end

local function setWorkMinutes(m)
    if pomodoro.config.workMinutes == m then return end
    pomodoro.config.workMinutes = m
    -- Clear throttling so a banner can appear immediately if threshold already passed
    pomodoro.nextBannerDue = nil
    saveConfig()
end

-- ---- State -------------------------------------------------------
pomodoro.state                        = {
    currentState = STATE.FRESH,
    workTime = 0,
    idleTime = 0,
    lastUpdate = os.time(),
    lastNotificationAcknowledged = true,
    messageHistory = {
        messages = {},
        maxHistory = 10,
        pendingMessage = nil,
        isGenerating = false
    }
}

pomodoro.menuBar                      = nil
pomodoro.timer                        = nil
pomodoro.bannerHandle                 = nil
pomodoro.overlayHandle                = nil

pomodoro.notificationMode             = NOTIFY_MODE.NONE
pomodoro.notificationEntered          = nil
pomodoro.nextBannerDue                = nil
pomodoro.notificationCount            = 0

pomodoro.enhancedNotificationElements = nil

-- Optional no-op init (keeps API parity with notification.lua)
if notification.init then notification.init() end

-- ---- Message generation ------------------------------------------
local function generateBreakMessage(minutes, count, history, callback)
    local historyStr = #history > 0 and table.concat(history, "; ") or "none"

    local prompt = string.format(
        "Generate ONE sentence for a Pomodoro timer interrupting someone deep in focus. " ..
        "Work time: %d minutes. Reminder number: %d. %s " ..
        "Be genuinely compelling, insightful, or eye-opening, not guilt-tripping. " ..
        "Don't repeat these approaches: %s " ..
        "Return ONLY the sentence.",
        minutes,
        count,
        count == 1 and "First reminder." or "Previous reminders were dismissed.",
        historyStr
    )

    local fallback = string.format("You've been working for %d minutes — time to pause!", minutes)

    -- Detect AI provider if not already set
    if not pomodoro.config.aiProvider then
        pomodoro.config.aiProvider = detectAIProvider()
        saveConfig()
    end

    -- If no AI provider available, use fallback immediately
    if pomodoro.config.aiProvider == "none" then
        callback(fallback)
        return
    end

    -- Escape single quotes for shell command
    local escapedPrompt = prompt:gsub("'", "'\\''")

    -- Build command based on provider
    local command
    if pomodoro.config.aiProvider == "claude" then
        command = string.format("claude --print '%s'", escapedPrompt)
    elseif pomodoro.config.aiProvider == "codex" then
        command = string.format("codex exec '%s' 2>&1", escapedPrompt)
    else
        callback(fallback)
        return
    end

    print(string.format("[Pomodoro] Using %s: %s", pomodoro.config.aiProvider, command))

    -- Run async in background thread to avoid blocking
    hs.timer.doAfter(0, function()
        local output, status, exitType, rc = hs.execute(command, true)

        if status and output and output ~= "" then
            local trimmed = output

            -- Parse output based on provider
            if pomodoro.config.aiProvider == "codex" then
                -- Skip the header lines from codex output
                local lines = {}
                for line in trimmed:gmatch("[^\r\n]+") do
                    table.insert(lines, line)
                end
                -- Find the actual response (after the header section)
                local responseStarted = false
                local response = {}
                for i, line in ipairs(lines) do
                    if responseStarted then
                        table.insert(response, line)
                    elseif line:match("^%-%-%-%-") then
                        -- Skip separator line, start collecting next line
                        responseStarted = true
                    elseif i > 10 and #line > 0 then
                        -- No separator found, include this line and continue
                        responseStarted = true
                        table.insert(response, line)
                    end
                end
                trimmed = table.concat(response, "\n")
            end

            -- Final trim
            trimmed = trimmed:gsub("^%s*(.-)%s*$", "%1")

            if #trimmed > 0 then
                callback(trimmed)
            else
                print(string.format("[Pomodoro] Empty response from %s", pomodoro.config.aiProvider))
                callback(fallback)
            end
        else
            print(string.format("[Pomodoro] %s failed. Status: %s, ExitType: %s, RC: %s",
                pomodoro.config.aiProvider, tostring(status), tostring(exitType), tostring(rc)))
            callback(fallback)
        end
    end)
end

local function prepareNextMessage()
    if pomodoro.state.messageHistory.isGenerating then return end
    if pomodoro.state.currentState ~= STATE.WORK then return end

    pomodoro.state.messageHistory.isGenerating = true

    local minutes = math.floor(pomodoro.state.workTime / 60)
    local nextCount = pomodoro.notificationCount + 1

    generateBreakMessage(minutes, nextCount, pomodoro.state.messageHistory.messages, function(message)
        pomodoro.state.messageHistory.pendingMessage = message
        pomodoro.state.messageHistory.isGenerating = false
    end)
end

-- ---- Small helpers ----------------------------------------------
local function formatMenu(state, work, idle)
    if state == STATE.FRESH then return "fresh" end
    local secs = (state == STATE.WORK) and work or idle
    local unit = secs < 60 and "s" or "m"
    local n    = secs < 60 and secs or math.floor(secs / 60)
    return string.format("%s %d%s", state, n, unit)
end

local function updateMenuBar()
    if not pomodoro.menuBar then return end
    local title = formatMenu(pomodoro.state.currentState, pomodoro.state.workTime, pomodoro.state.idleTime)
    pomodoro.menuBar:setTitle(title)
end

local function resetUIHandles()
    if notification.resetRuntimeHandles then
        notification.resetRuntimeHandles(pomodoro)
    else
        if pomodoro.bannerHandle then
            notification.dismiss(pomodoro.bannerHandle); pomodoro.bannerHandle = nil
        end
        if pomodoro.overlayHandle then
            notification.dismiss(pomodoro.overlayHandle); pomodoro.overlayHandle = nil
        end
    end
    if pomodoro.enhancedNotificationElements and notification.cleanupNotificationElements then
        notification.cleanupNotificationElements(pomodoro.enhancedNotificationElements)
    end
    pomodoro.enhancedNotificationElements = nil
end

local function resetAlertState(ack)
    pomodoro.notificationMode                   = NOTIFY_MODE.NONE
    pomodoro.notificationEntered                = nil
    pomodoro.nextBannerDue                      = nil
    pomodoro.state.lastNotificationAcknowledged = (ack ~= false)
    pomodoro.notificationCount                  = 0
end

-- ---- State transitions ------------------------------------------
local function enterFresh(_reason)
    pomodoro.state.currentState = STATE.FRESH
    pomodoro.state.workTime     = 0
    pomodoro.state.idleTime     = 0
    resetAlertState(true)
    resetUIHandles()
    -- Clear message history when timer is fresh
    pomodoro.state.messageHistory = {
        messages = {},
        maxHistory = 10,
        pendingMessage = nil,
        isGenerating = false
    }
end

local function enterWork(resumed)
    pomodoro.state.currentState = STATE.WORK
    if not resumed then pomodoro.state.workTime = 0 end
    pomodoro.state.idleTime = 0
    resetAlertState(true)
    resetUIHandles()
end

local function enterIdle(sec)
    pomodoro.state.currentState = STATE.IDLE
    pomodoro.state.idleTime = sec
end

-- ---- Alerts ------------------------------------------------------
local ALERT = {
    banner  = {
        kind  = NOTIFY_MODE.BANNER,
        grace = BANNER_GRACE,
        build = function(message, onAck) return notification.showBanner(message, onAck) end
    },
    overlay = {
        kind  = NOTIFY_MODE.OVERLAY,
        grace = math.huge, -- never auto-escalate beyond overlay
        build = function(message, onAck) return notification.showOverlay(message, onAck) end
    }
}

local function raiseAlert(which, minutes)
    local cfg = ALERT[which]; if not cfg then return end
    resetUIHandles()

    pomodoro.notificationCount = pomodoro.notificationCount + 1

    -- Use pre-generated message or fallback
    local message = pomodoro.state.messageHistory.pendingMessage or
                    string.format("You've been working for %d minutes — time to pause!", minutes)

    -- Store in history
    table.insert(pomodoro.state.messageHistory.messages, message)
    if #pomodoro.state.messageHistory.messages > pomodoro.state.messageHistory.maxHistory then
        table.remove(pomodoro.state.messageHistory.messages, 1)
    end

    -- Clear pending and start generating next
    pomodoro.state.messageHistory.pendingMessage = nil
    prepareNextMessage()

    local handle = cfg.build(message, function()
        pomodoro.state.lastNotificationAcknowledged = true
        resetUIHandles()
        resetAlertState(true)
        pomodoro.nextBannerDue = os.time() + REPEAT_INTERVAL
    end)

    if cfg.kind == NOTIFY_MODE.BANNER then
        pomodoro.bannerHandle = handle
    else
        pomodoro.overlayHandle = handle
    end

    pomodoro.notificationMode                   = cfg.kind
    pomodoro.notificationEntered                = os.time()
    pomodoro.state.lastNotificationAcknowledged = false
end

local function updateNotifications(now)
    if pomodoro.state.currentState ~= STATE.WORK then return end
    local workSec = pomodoro.state.workTime
    local threshold = workThresholdSeconds()

    if pomodoro.notificationMode == NOTIFY_MODE.NONE then
        if (workSec >= threshold) and (pomodoro.nextBannerDue == nil or now >= pomodoro.nextBannerDue) then
            raiseAlert("banner", math.floor(workSec / 60))
        end
    elseif pomodoro.notificationMode == NOTIFY_MODE.BANNER then
        if (not pomodoro.state.lastNotificationAcknowledged) and
            (now - pomodoro.notificationEntered >= ALERT.banner.grace) then
            raiseAlert("overlay", math.floor(workSec / 60))
        end
    end
end

-- ---- Persistence (state) ----------------------------------------
local function saveState()
    hs.settings.set(PERSISTENCE_KEY, {
        currentState                 = pomodoro.state.currentState,
        workTime                     = pomodoro.state.workTime,
        idleTime                     = pomodoro.state.idleTime,
        lastUpdate                   = os.time(),
        lastNotificationAcknowledged = pomodoro.state.lastNotificationAcknowledged,
        messageHistory               = pomodoro.state.messageHistory,
        notificationCount            = pomodoro.notificationCount
    })
end

local function loadState()
    local saved = hs.settings.get(PERSISTENCE_KEY)
    if not saved then return end

    local now = os.time()
    local dt  = now - (saved.lastUpdate or now)

    if dt > RESET_THRESHOLD then
        enterFresh("resume-timeout")
    else
        pomodoro.state.currentState                 = saved.currentState or STATE.FRESH
        pomodoro.state.workTime                     = saved.workTime or 0
        pomodoro.state.idleTime                     = saved.idleTime or 0
        pomodoro.state.lastNotificationAcknowledged =
            (saved.lastNotificationAcknowledged == nil) and true or saved.lastNotificationAcknowledged
        pomodoro.state.messageHistory               = saved.messageHistory or {
            messages = {},
            maxHistory = 10,
            pendingMessage = nil,
            isGenerating = false
        }
        -- Clear stale pending message and generation flag after reload
        pomodoro.state.messageHistory.pendingMessage = nil
        pomodoro.state.messageHistory.isGenerating = false
        pomodoro.notificationCount                  = saved.notificationCount or 0

        if pomodoro.state.currentState == STATE.WORK and dt < IDLE_THRESHOLD then
            pomodoro.state.workTime = pomodoro.state.workTime + dt
        elseif pomodoro.state.currentState == STATE.IDLE then
            pomodoro.state.idleTime = pomodoro.state.idleTime + dt
            if pomodoro.state.idleTime >= RESET_THRESHOLD then
                enterFresh("resume-timeout")
            end
        end
    end

    pomodoro.state.lastUpdate = now
end

-- ---- Timer tick --------------------------------------------------
local function timerCallback()
    local now                 = os.time()
    local prev                = pomodoro.state.currentState
    local idle                = hs.host.idleTime()
    local elapsed             = now - pomodoro.state.lastUpdate
    pomodoro.state.lastUpdate = now

    -- Treat long timer stalls as "idle for reset" checks
    local sleepGap            = elapsed - idle
    local longPause           = sleepGap > CHECK_INTERVAL * 3
    local idleForReset        = longPause and elapsed or idle

    if idleForReset >= RESET_THRESHOLD then
        if pomodoro.state.currentState ~= STATE.FRESH then enterFresh("idle-timeout") end
    elseif idle >= IDLE_THRESHOLD then
        if pomodoro.state.currentState == STATE.WORK then
            enterIdle(idle)
        elseif pomodoro.state.currentState == STATE.IDLE then
            enterIdle(idle)
        end
    else
        if pomodoro.state.currentState == STATE.WORK then
            pomodoro.state.workTime = pomodoro.state.workTime + elapsed

            -- Pre-generate message 2 minutes before threshold (or after if we missed the window)
            local threshold = workThresholdSeconds()
            local timeUntilThreshold = threshold - pomodoro.state.workTime

            if timeUntilThreshold <= 120 and
               not pomodoro.state.messageHistory.pendingMessage and
               not pomodoro.state.messageHistory.isGenerating then
                prepareNextMessage()
            end

            updateNotifications(now)
        elseif pomodoro.state.currentState == STATE.FRESH then
            enterWork(false) -- start new session
        elseif pomodoro.state.currentState == STATE.IDLE then
            enterWork(true) -- resume session
        end
    end

    updateMenuBar()

    local stateChanged  = (prev ~= pomodoro.state.currentState)
    local crossedMinute = (pomodoro.state.currentState == STATE.WORK) and (pomodoro.state.workTime % 60 == 0) and
    (elapsed > 0)
    if stateChanged or crossedMinute then saveState() end
end

-- ---- Public: init/stop ------------------------------------------
function pomodoro.init()
    loadConfig() -- ensure we have the user's preferred timer length before building the menu

    pomodoro.menuBar = hs.menubar.new()
    if pomodoro.menuBar then
        updateMenuBar()

        pomodoro.menuBar:setClickCallback(function()
            local info = hs.inspect(pomodoro.state):sub(1, 300)
            hs.alert.show(info, 5)
            return false
        end)

        pomodoro.menuBar:setMenu(function()
            return {
                {
                    title = "Reset Timer",
                    fn = function()
                        enterFresh("manual-reset")
                        updateMenuBar()
                        saveState()
                        hs.alert.show("Timer reset")
                    end
                },
                {
                    title = "Test Message Generation",
                    fn = function()
                        local minutes = math.floor(pomodoro.state.workTime / 60)
                        generateBreakMessage(minutes, 1, pomodoro.state.messageHistory.messages, function(message)
                            hs.alert.show(message, 5)
                        end)
                    end
                },
                { title = "-" },

                -- Timer length selector -----------------------------------
                { title = "Timer length", disabled = true },
                {
                    title = "25 minutes",
                    checked = (pomodoro.config.workMinutes == 25),
                    fn = function()
                        setWorkMinutes(25); updateMenuBar()
                    end
                },
                {
                    title = "35 minutes",
                    checked = (pomodoro.config.workMinutes == 35),
                    fn = function()
                        setWorkMinutes(35); updateMenuBar()
                    end
                },
                {
                    title = "45 minutes",
                    checked = (pomodoro.config.workMinutes == 45),
                    fn = function()
                        setWorkMinutes(45); updateMenuBar()
                    end
                },

                { title = "-" },

                -- AI Provider ---------------------------------------------
                { title = string.format("AI Provider: %s", pomodoro.config.aiProvider or "auto"), disabled = true },
                {
                    title = "Re-detect AI Provider",
                    fn = function()
                        local old = pomodoro.config.aiProvider
                        pomodoro.config.aiProvider = detectAIProvider()
                        saveConfig()
                        hs.alert.show(string.format("AI Provider: %s → %s", old or "none", pomodoro.config.aiProvider))
                    end
                },

                { title = "-" },

                -- Status readouts -----------------------------------------
                { title = "Current: " .. formatMenu(pomodoro.state.currentState, pomodoro.state.workTime, pomodoro.state.idleTime),           disabled = true },
                { title = string.format("Idle Time: %02d:%02d", math.floor(pomodoro.state.idleTime / 60), pomodoro.state.idleTime % 60),      disabled = true },
                { title = string.format("Notify at: %d min", pomodoro.config.workMinutes),                                                    disabled = true },
                { title = string.format("Last notification acknowledged: %s", pomodoro.state.lastNotificationAcknowledged and "Yes" or "No"), disabled = true }
            }
        end)
    end

    loadState()
    pomodoro.timer = hs.timer.doEvery(CHECK_INTERVAL, timerCallback)
    return pomodoro
end

function pomodoro.stop()
    if pomodoro.timer then
        pomodoro.timer:stop(); pomodoro.timer = nil
    end
    resetUIHandles()
    if pomodoro.menuBar then
        pomodoro.menuBar:delete(); pomodoro.menuBar = nil
    end
    saveState()
end

return pomodoro.init()
