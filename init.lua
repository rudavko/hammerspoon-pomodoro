-- Pomodoro timer module for Hammerspoon
local log = hs.logger.new('pomodoro', 'info') -- Changed from 'debug' to 'info' level

-- Initialize module
local pomodoro = {}

-- Load the enhanced notification module
local notification = require('pomodoro.notification')

-- Constants
local WORK_NOTIFICATION_TIME = 25 * 60  -- 25 minutes in seconds
local SUBSEQUENT_NOTIFICATION_TIME = 27 * 60  -- 27 minutes in seconds
local MAX_NOTIFICATION_TIME = 29 * 60  -- 29 minutes in seconds, notifications stop after this
local IDLE_THRESHOLD = 120  -- 2 minutes in seconds
local RESET_THRESHOLD = 5 * 60  -- 5 minutes in seconds
local PERSISTENCE_KEY = 'pomodoro.state'
local CHECK_INTERVAL = 1  -- Check every second
local BANNER_GRACE    = 60   -- seconds
local REPEAT_INTERVAL = 120  -- seconds
local STATE = {
    WORK = 'work',
    IDLE = 'idle',
    FRESH = 'fresh'
}

-- Notification view‑modes (finite‑state machine)
local NOTIFY_MODE = {
    NONE    = "none",
    BANNER  = "banner",
    OVERLAY = "overlay"
}

-- ------------------------------------------------------------------
--  Helper: transition to FRESH and clear all runtime artefacts
-- ------------------------------------------------------------------
local function enterFresh(reason)
    log.d("Transitioning to FRESH (" .. (reason or "n/a") .. ")")
    pomodoro.state.currentState = STATE.FRESH
    pomodoro.state.workTime     = 0
    pomodoro.state.idleTime     = 0
    pomodoro.state.notifiedAt   = {}
    pomodoro.state.lastNotificationAcknowledged = true

    -- Reset notification FSM
    pomodoro.notificationMode    = NOTIFY_MODE.NONE
    pomodoro.notificationEntered = nil
    pomodoro.nextBannerDue       = nil

    -- Dismiss any outstanding UI handles
    if notification.resetRuntimeHandles then
        notification.resetRuntimeHandles(pomodoro)
    else
        if pomodoro.bannerHandle  then notification.dismiss(pomodoro.bannerHandle)  ; pomodoro.bannerHandle  = nil end
        if pomodoro.overlayHandle then notification.dismiss(pomodoro.overlayHandle) ; pomodoro.overlayHandle = nil end
    end

    -- Clean up enhanced notification window if it exists
    if pomodoro.enhancedNotificationElements then
        notification.cleanupNotificationElements(pomodoro.enhancedNotificationElements)
        pomodoro.enhancedNotificationElements = nil
    end
end

-- State variables
pomodoro.state = {
    currentState = STATE.FRESH,
    workTime = 0,  -- Seconds
    idleTime = 0,  -- Seconds
    lastUpdate = os.time(),  -- When state was last updated
    notifiedAt = {},  -- Track notification times
    lastNotificationAcknowledged = true  -- Track if the last notification was acknowledged
}

-- Menu bar item
pomodoro.menuBar = nil

-- Timers
pomodoro.timer = nil
pomodoro.bannerHandle  = nil
pomodoro.overlayHandle = nil
-- Notification‑FSM runtime fields
pomodoro.notificationMode    = NOTIFY_MODE.NONE   -- current view‑state
pomodoro.notificationEntered = nil                -- os.time() when mode entered
pomodoro.nextBannerDue       = nil                -- next allowed banner time

-- Enhanced notification elements reference
pomodoro.enhancedNotificationElements = nil

-- Initialize the notification module with references to pomodoro and logger
notification.init(log)


-- Pure formatter for menu‑bar and status strings
local function formatMenu(state, work, idle)
    if state == STATE.FRESH then return "fresh" end
    local secs = (state == STATE.WORK) and work or idle
    local unit = secs < 60 and "s" or "m"
    local n    = secs < 60 and secs or math.floor(secs / 60)
    return string.format("%s %d%s", state, n, unit)
end

local function updateMenuBar()
    if not pomodoro.menuBar then return end

    local title = formatMenu(pomodoro.state.currentState,
                             pomodoro.state.workTime,
                             pomodoro.state.idleTime)
    pomodoro.menuBar:setTitle(title)

    pomodoro.menuBar:setClickCallback(function()
        local info = hs.inspect(pomodoro.state):sub(1, 300)
        hs.alert.show(info, 5)
        return false
    end)
end

-- Send a notification
local function sendNotification(duration)
    notification.sendNotification(duration)
end



-- Alert kinds configuration ---------------------------------------
local ALERT = {
  banner  = { kind = NOTIFY_MODE.BANNER,
              build = function(minutes, onAck)
                  return notification.showBanner(minutes, onAck)
              end,
              grace = BANNER_GRACE },
  overlay = { kind = NOTIFY_MODE.OVERLAY,
              build = function(minutes, onAck)
                  return notification.showOverlay(minutes, onAck)
              end,
              grace = math.huge }           -- never auto‑escalate
}

-- Generic alert raiser --------------------------------------------
local function raiseAlert(which, minutes)
  local cfg = ALERT[which]
  if not cfg then return end

  -- dismiss any existing UI
  if notification.resetRuntimeHandles then
      notification.resetRuntimeHandles(pomodoro)
  else
      if pomodoro.bannerHandle  then notification.dismiss(pomodoro.bannerHandle)  ; pomodoro.bannerHandle  = nil end
      if pomodoro.overlayHandle then notification.dismiss(pomodoro.overlayHandle) ; pomodoro.overlayHandle = nil end
  end

  local h = cfg.build(minutes, function()  -- on acknowledge/dismiss
      pomodoro.state.lastNotificationAcknowledged = true
      if notification.resetRuntimeHandles then
          notification.resetRuntimeHandles(pomodoro)
      else
          if pomodoro.bannerHandle  then notification.dismiss(pomodoro.bannerHandle)  ; pomodoro.bannerHandle  = nil end
          if pomodoro.overlayHandle then notification.dismiss(pomodoro.overlayHandle) ; pomodoro.overlayHandle = nil end
      end
      pomodoro.notificationMode    = NOTIFY_MODE.NONE
      pomodoro.notificationEntered = nil
      pomodoro.nextBannerDue       = os.time() + REPEAT_INTERVAL
  end)

  if cfg.kind == NOTIFY_MODE.BANNER then
      pomodoro.bannerHandle = h
  else
      pomodoro.overlayHandle = h
  end

  pomodoro.notificationMode    = cfg.kind
  pomodoro.notificationEntered = os.time()
  pomodoro.state.lastNotificationAcknowledged = false
end

local function updateNotifications(now)
    -- guard: only operate in WORK state
    if pomodoro.state.currentState ~= STATE.WORK then return end

    local workSec = pomodoro.state.workTime

    if pomodoro.notificationMode == NOTIFY_MODE.NONE then
        if (workSec >= WORK_NOTIFICATION_TIME) and
           (pomodoro.nextBannerDue == nil or now >= pomodoro.nextBannerDue) then
            raiseAlert("banner", math.floor(workSec / 60))
        end

    elseif pomodoro.notificationMode == NOTIFY_MODE.BANNER then
        if (not pomodoro.state.lastNotificationAcknowledged) and
           (now - pomodoro.notificationEntered >= ALERT.banner.grace) then
            raiseAlert("overlay", math.floor(workSec / 60))
        end
    end
end

local function saveState()
    local stateToSave = {
        currentState = pomodoro.state.currentState,
        workTime = pomodoro.state.workTime,
        idleTime = pomodoro.state.idleTime,
        lastUpdate = os.time(),
        notifiedAt = pomodoro.state.notifiedAt,
        lastNotificationAcknowledged = pomodoro.state.lastNotificationAcknowledged
    }
    hs.settings.set(PERSISTENCE_KEY, stateToSave)

    if pomodoro.state.currentState == STATE.WORK and pomodoro.state.workTime % 60 == 0 then
        log.d("State saved at", stateToSave.workTime, "seconds")
    end
end

local function loadState()
    local savedState = hs.settings.get(PERSISTENCE_KEY)
    if savedState then
        local now = os.time()
        local timeSinceLastUpdate = now - savedState.lastUpdate

        log.d("Loaded saved state from", savedState.lastUpdate, "time elapsed:", timeSinceLastUpdate)

        -- If we've been away for more than the reset threshold, reset to fresh
        if timeSinceLastUpdate > RESET_THRESHOLD then
            log.d("More than reset threshold has passed, resetting to fresh state")
            enterFresh("resume‑timeout")
        else
            -- Restore saved state
            pomodoro.state.currentState = savedState.currentState
            pomodoro.state.workTime = savedState.workTime
            pomodoro.state.idleTime = savedState.idleTime

            -- Restore acknowledgment state, defaulting to true if not present (for backward compatibility)
            pomodoro.state.lastNotificationAcknowledged = savedState.lastNotificationAcknowledged
            if pomodoro.state.lastNotificationAcknowledged == nil then
                pomodoro.state.lastNotificationAcknowledged = true
            end

            pomodoro.state.notifiedAt = savedState.notifiedAt or {}

            -- If we were working before, add the time we were away (if it was less than idle threshold)
            if pomodoro.state.currentState == STATE.WORK and timeSinceLastUpdate < IDLE_THRESHOLD then
                pomodoro.state.workTime = pomodoro.state.workTime + timeSinceLastUpdate
            -- If we were idling before, add the time we were away
            elseif pomodoro.state.currentState == STATE.IDLE then
                pomodoro.state.idleTime = pomodoro.state.idleTime + timeSinceLastUpdate

                -- Check if we've been idle long enough to reset to fresh
                if pomodoro.state.idleTime >= RESET_THRESHOLD then
                    enterFresh("resume‑timeout")
                end
            end
        end

        pomodoro.state.lastUpdate = now
    end
end

------------------------------------------------------------------
--  Forward‑declare transition helpers so they’re in scope earlier
------------------------------------------------------------------
local enterWork, enterIdle

local function timerCallback()
    local now = os.time()
    local prevState = pomodoro.state.currentState
    local idleTime = hs.host.idleTime()
    
    -- Calculate elapsed time since last check
    local elapsed = now - pomodoro.state.lastUpdate
    pomodoro.state.lastUpdate = now

    -- Detect genuine sleep or long Lua stall (≥ 3× the tick interval)
    local sleepGap = elapsed - idleTime
    local longPause = sleepGap > CHECK_INTERVAL * 3
    local effectiveIdle        = idleTime               -- for 2‑minute IDLE threshold
    local effectiveIdleForReset = longPause and elapsed or idleTime  -- for 5‑minute FRESH reset
    
    -- Determine state transition based on idle time
    if effectiveIdleForReset >= RESET_THRESHOLD then
        -- User has been idle for 5+ minutes
        if pomodoro.state.currentState ~= STATE.FRESH then
            enterFresh("idle‑timeout (" .. effectiveIdleForReset .. " s)")
        end
    elseif effectiveIdle >= IDLE_THRESHOLD then
        -- User has been idle for 1+ minute but less than 5 minutes
        if pomodoro.state.currentState == STATE.WORK then
            log.d("Transitioning from WORK to IDLE after", effectiveIdle, "seconds of inactivity")
            pomodoro.state.currentState = STATE.IDLE
            pomodoro.state.idleTime = effectiveIdle  -- Account for possible sleep gap
        elseif pomodoro.state.currentState == STATE.IDLE then
            -- Already in idle state, update idle time
            pomodoro.state.idleTime = effectiveIdle
        elseif pomodoro.state.currentState == STATE.FRESH then
            -- Stay in fresh state
        end
    else
        -- User is active again (effectiveIdle < IDLE_THRESHOLD)
        if pomodoro.state.currentState == STATE.WORK then
            pomodoro.state.workTime = pomodoro.state.workTime + elapsed
            updateNotifications(now)
        elseif pomodoro.state.currentState == STATE.FRESH then
            enterWork(false)   -- start a brand‑new session
        elseif pomodoro.state.currentState == STATE.IDLE then
            enterWork(true)    -- resume existing session
        end
    end
    
    -- Update menu bar
    updateMenuBar()
    
    ------------------------------------------------------------------
    --  Persist only when useful
    ------------------------------------------------------------------
    local stateChanged = (prevState ~= pomodoro.state.currentState)
    local crossedMinute = (pomodoro.state.currentState == STATE.WORK) and
                          (pomodoro.state.workTime % 60 == 0) and
                          (elapsed > 0)
    if stateChanged or crossedMinute then
        saveState()
    end
end

------------------------------------------------------------------
--  State helpers for transitions
------------------------------------------------------------------
enterWork = function(resumed)
    pomodoro.state.currentState = STATE.WORK
    if not resumed then pomodoro.state.workTime = 0 end
    pomodoro.state.idleTime = 0
    pomodoro.state.lastNotificationAcknowledged = true
    pomodoro.notificationMode    = NOTIFY_MODE.NONE
    pomodoro.notificationEntered = nil
    pomodoro.nextBannerDue       = nil
    if notification.resetRuntimeHandles then
        notification.resetRuntimeHandles(pomodoro)
    end
end

enterIdle = function(sec)
    pomodoro.state.currentState, pomodoro.state.idleTime = STATE.IDLE, sec
end

function pomodoro.init()
    -- Create menu bar item
    pomodoro.menuBar = hs.menubar.new()
    if pomodoro.menuBar then
        updateMenuBar()

        -- Add menu options
        pomodoro.menuBar:setMenu(function()
            return {
                { title = "Reset Timer", fn = function()
                    enterFresh("manual‑reset")
                    updateMenuBar()
                    saveState()
                    hs.alert.show("Timer reset")
                end },
                { title = "-" },  -- Separator
                { title = "Current: "..formatMenu(pomodoro.state.currentState,
                                                  pomodoro.state.workTime,
                                                  pomodoro.state.idleTime), disabled = true },
                { title = string.format("Idle Time: %02d:%02d", math.floor(pomodoro.state.idleTime / 60), pomodoro.state.idleTime % 60), disabled = true },
                { title = string.format("Notification at: %d-%d minutes", WORK_NOTIFICATION_TIME / 60, MAX_NOTIFICATION_TIME / 60), disabled = true },
                { title = string.format("Last notification acknowledged: %s", pomodoro.state.lastNotificationAcknowledged and "Yes" or "No"), disabled = true }
            }
        end)
    end
    
    -- Load saved state
    loadState()
    
    -- Start the timer
    pomodoro.timer = hs.timer.doEvery(CHECK_INTERVAL, timerCallback)
    
    log.d("Pomodoro timer initialized with notification at", WORK_NOTIFICATION_TIME, "seconds")
    return pomodoro
end

-- Stop the pomodoro timer
function pomodoro.stop()
    if pomodoro.timer then
        pomodoro.timer:stop()
        pomodoro.timer = nil
    end
    
    -- Clean up enhanced notification window if it exists
    if pomodoro.enhancedNotificationElements then
        notification.cleanupNotificationElements(pomodoro.enhancedNotificationElements)
        pomodoro.enhancedNotificationElements = nil
    end
    
    if pomodoro.menuBar then
        pomodoro.menuBar:delete()
        pomodoro.menuBar = nil
    end

        if pomodoro.bannerHandle then
        notification.dismiss(pomodoro.bannerHandle)
        pomodoro.bannerHandle = nil
    end

    -- (repeatTimer removal: nothing to do)
    
    -- Save state before stopping
    saveState()
    
    log.d("Pomodoro timer stopped")
end

------------------------------------------------------------------
--  Module entry‑point
------------------------------------------------------------------
return pomodoro.init()