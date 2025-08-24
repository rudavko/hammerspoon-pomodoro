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
pomodoro.config       = { workMinutes = 25 } -- default

local function saveConfig()
    hs.settings.set(CONFIG_KEY, { workMinutes = pomodoro.config.workMinutes })
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
end

local function workThresholdSeconds()
    return (pomodoro.config.workMinutes or 25) * 60
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
    lastNotificationAcknowledged = true
}

pomodoro.menuBar                      = nil
pomodoro.timer                        = nil
pomodoro.bannerHandle                 = nil
pomodoro.overlayHandle                = nil

pomodoro.notificationMode             = NOTIFY_MODE.NONE
pomodoro.notificationEntered          = nil
pomodoro.nextBannerDue                = nil

pomodoro.enhancedNotificationElements = nil

-- Optional no-op init (keeps API parity with notification.lua)
if notification.init then notification.init() end

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
end

-- ---- State transitions ------------------------------------------
local function enterFresh(_reason)
    pomodoro.state.currentState = STATE.FRESH
    pomodoro.state.workTime     = 0
    pomodoro.state.idleTime     = 0
    resetAlertState(true)
    resetUIHandles()
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
        build = function(minutes, onAck) return notification.showBanner(minutes, onAck) end
    },
    overlay = {
        kind  = NOTIFY_MODE.OVERLAY,
        grace = math.huge, -- never auto-escalate beyond overlay
        build = function(minutes, onAck) return notification.showOverlay(minutes, onAck) end
    }
}

local function raiseAlert(which, minutes)
    local cfg = ALERT[which]; if not cfg then return end
    resetUIHandles()

    local handle = cfg.build(minutes, function()
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
        lastNotificationAcknowledged = pomodoro.state.lastNotificationAcknowledged
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
