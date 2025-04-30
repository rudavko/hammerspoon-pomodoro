-- Pomodoro timer module for Hammerspoon
local log = hs.logger.new('pomodoro', 'debug')

-- Initialize module
local pomodoro = {}

-- Constants
local WORK_NOTIFICATION_TIME = 25 * 60  -- 25 minutes in seconds
local SUBSEQUENT_NOTIFICATION_TIME = 27 * 60  -- 27 minutes in seconds
local IDLE_THRESHOLD = 60  -- 1 minute in seconds
local RESET_THRESHOLD = 5 * 60  -- 5 minutes in seconds
local PERSISTENCE_KEY = 'pomodoro.state'
local CHECK_INTERVAL = 1  -- Check every second

-- States
local STATE = {
    WORK = 'work',
    IDLE = 'idle',
    FRESH = 'fresh'
}

-- State variables
pomodoro.state = {
    currentState = STATE.FRESH,
    workTime = 0,  -- Seconds
    idleTime = 0,  -- Seconds
    lastUpdate = os.time(),  -- When state was last updated
    notifiedAt = {}  -- Track notification times
}

-- Menu bar item
pomodoro.menuBar = nil

-- Timers
pomodoro.timer = nil

-- Format time for display
local function formatTime(state, seconds)
    if state == STATE.WORK then
        if seconds < 60 then
            return string.format("work %ds", seconds)
        else
            return string.format("work: %dm", math.floor(seconds / 60))
        end
    elseif state == STATE.IDLE then
        if seconds < 60 then
            return string.format("idle %ds", seconds)
        else
            return string.format("idle: %dm", math.floor(seconds / 60))
        end
    elseif state == STATE.FRESH then
        return "fresh"
    end
    return "unknown"  -- Should never happen
end

-- Update menu bar display
local function updateMenuBar()
    if pomodoro.menuBar then
        local formattedTime
        if pomodoro.state.currentState == STATE.WORK then
            formattedTime = formatTime(STATE.WORK, pomodoro.state.workTime)
        elseif pomodoro.state.currentState == STATE.IDLE then
            formattedTime = formatTime(STATE.IDLE, pomodoro.state.idleTime)
        else
            formattedTime = formatTime(STATE.FRESH, 0)
        end
        pomodoro.menuBar:setTitle(formattedTime)
    end
end

-- Send a notification
local function sendNotification(duration)
    local notification = hs.notify.new({
        title = "Pomodoro",
        informativeText = string.format("You've been working for %d minutes", math.floor(duration / 60)),
        withdrawAfter = 0  -- Persist until dismissed
    })
    notification:send()
    
    -- Record that we've notified at this time
    pomodoro.state.notifiedAt[duration] = true
end

-- Check if we need to send notifications
local function checkNotifications()
    -- First notification at 25 minutes
    if pomodoro.state.workTime >= WORK_NOTIFICATION_TIME and not pomodoro.state.notifiedAt[WORK_NOTIFICATION_TIME] then
        sendNotification(WORK_NOTIFICATION_TIME)
    end
    
    -- Subsequent notifications every minute after 27 minutes
    if pomodoro.state.workTime >= SUBSEQUENT_NOTIFICATION_TIME then
        local minutesSinceSubsequent = math.floor((pomodoro.state.workTime - SUBSEQUENT_NOTIFICATION_TIME) / 60)
        for i = 0, minutesSinceSubsequent do
            local notificationTime = SUBSEQUENT_NOTIFICATION_TIME + (i * 60)
            if pomodoro.state.workTime >= notificationTime and not pomodoro.state.notifiedAt[notificationTime] then
                sendNotification(notificationTime)
            end
        end
    end
end

-- Save state to persistence
local function saveState()
    local stateToSave = {
        currentState = pomodoro.state.currentState,
        workTime = pomodoro.state.workTime,
        idleTime = pomodoro.state.idleTime,
        lastUpdate = os.time()  -- Always save current time as last update
    }
    hs.settings.set(PERSISTENCE_KEY, stateToSave)
    -- Only log state saves when debugging is needed
    -- log.d("State saved, last update:", stateToSave.lastUpdate)
end

-- Load state from persistence
local function loadState()
    local savedState = hs.settings.get(PERSISTENCE_KEY)
    if savedState then
        local now = os.time()
        local timeSinceLastUpdate = now - savedState.lastUpdate
        
        log.d("Loaded saved state from", savedState.lastUpdate, "time elapsed:", timeSinceLastUpdate)
        
        -- If we've been away for more than the reset threshold, reset to fresh
        if timeSinceLastUpdate > RESET_THRESHOLD then
            log.d("More than reset threshold has passed, resetting to fresh state")
            pomodoro.state.currentState = STATE.FRESH
            pomodoro.state.workTime = 0
            pomodoro.state.idleTime = 0
        else
            -- Restore saved state
            pomodoro.state.currentState = savedState.currentState
            pomodoro.state.workTime = savedState.workTime
            pomodoro.state.idleTime = savedState.idleTime
            
            -- If we were working before, add the time we were away (if it was less than idle threshold)
            if pomodoro.state.currentState == STATE.WORK and timeSinceLastUpdate < IDLE_THRESHOLD then
                pomodoro.state.workTime = pomodoro.state.workTime + timeSinceLastUpdate
            -- If we were idling before, add the time we were away
            elseif pomodoro.state.currentState == STATE.IDLE then
                pomodoro.state.idleTime = pomodoro.state.idleTime + timeSinceLastUpdate
                
                -- Check if we've been idle long enough to reset to fresh
                if pomodoro.state.idleTime >= RESET_THRESHOLD then
                    pomodoro.state.currentState = STATE.FRESH
                    pomodoro.state.workTime = 0
                    pomodoro.state.idleTime = 0
                end
            end
        end
        
        pomodoro.state.lastUpdate = now
    end
end

-- Timer callback function
local function timerCallback()
    local now = os.time()
    local idleTime = hs.host.idleTime()
    
    -- Calculate elapsed time since last check
    local elapsed = now - pomodoro.state.lastUpdate
    pomodoro.state.lastUpdate = now
    
    -- Determine state transition based on idle time
    if idleTime >= RESET_THRESHOLD then
        -- User has been idle for 5+ minutes
        if pomodoro.state.currentState ~= STATE.FRESH then
            log.d("Transitioning to FRESH state after", idleTime, "seconds of inactivity")
            pomodoro.state.currentState = STATE.FRESH
            pomodoro.state.workTime = 0
            pomodoro.state.idleTime = 0
            pomodoro.state.notifiedAt = {}  -- Reset notifications
        end
    elseif idleTime >= IDLE_THRESHOLD then
        -- User has been idle for 1+ minute but less than 5 minutes
        if pomodoro.state.currentState == STATE.WORK then
            log.d("Transitioning from WORK to IDLE after", idleTime, "seconds of inactivity")
            pomodoro.state.currentState = STATE.IDLE
            pomodoro.state.idleTime = idleTime  -- Start counting from current idle time
        elseif pomodoro.state.currentState == STATE.IDLE then
            -- Already in idle state, update idle time
            pomodoro.state.idleTime = idleTime
        elseif pomodoro.state.currentState == STATE.FRESH then
            -- Stay in fresh state
        end
    else
        -- User is active
        if pomodoro.state.currentState == STATE.FRESH or 
           pomodoro.state.currentState == STATE.IDLE then
            log.d("Transitioning to WORK state from", pomodoro.state.currentState)
            pomodoro.state.currentState = STATE.WORK
            pomodoro.state.workTime = 0  -- Reset work timer when coming from FRESH or IDLE
            pomodoro.state.idleTime = 0
            pomodoro.state.notifiedAt = {}  -- Reset notifications
        elseif pomodoro.state.currentState == STATE.WORK then
            -- Already in work state, increment work time
            pomodoro.state.workTime = pomodoro.state.workTime + elapsed
            checkNotifications()  -- Check if we need to send notifications
        end
    end
    
    -- Update menu bar
    updateMenuBar()
    
    -- Save state
    saveState()
end

-- Initialize the pomodoro timer
function pomodoro.init()
    -- Create menu bar item
    pomodoro.menuBar = hs.menubar.new()
    if pomodoro.menuBar then
        updateMenuBar()
    end
    
    -- Load saved state
    loadState()
    
    -- Start the timer
    pomodoro.timer = hs.timer.doEvery(CHECK_INTERVAL, timerCallback)
    
    log.d("Pomodoro timer initialized")
    return pomodoro
end

-- Stop the pomodoro timer
function pomodoro.stop()
    if pomodoro.timer then
        pomodoro.timer:stop()
        pomodoro.timer = nil
    end
    
    if pomodoro.menuBar then
        pomodoro.menuBar:delete()
        pomodoro.menuBar = nil
    end
    
    log.d("Pomodoro timer stopped")
end

-- Start the module
return pomodoro.init()