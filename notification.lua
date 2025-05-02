--------------------------------------------------------------------
-- pomodoro/notification.lua  •  2025-05-02
--------------------------------------------------------------------
local M            = {}
local P, log       = nil, nil -- injected by init.lua
local graceTimer, repeatTimer -- hs.timer objects
local lastBannerAt = 0        -- epoch (s) for duplicate-throttle

--------------------------------------------------------------------
local function d(...)
    if log and log.i then log.i(...) end   -- use info so it always prints
end

local function flagSent(duration)
    if P.enhancedNotificationElements then return end -- de-dupe
    P.state.notifiedAt[duration]         = true
    P.state.lastNotificationAcknowledged = false
end
--------------------------------------------------------------------
function M.init(pomodoro, logger)
    P, log = pomodoro, logger or { i = print }
    local interfaceStyle = hs.host.interfaceStyle()          -- "Dark" or nil
    local isDarkStart    = (interfaceStyle == "Dark")
    d("notification.lua init ➜ interfaceStyle:", interfaceStyle or "Light",
      "isDark:", isDarkStart)
end

--------------------------------------------------------------------
-- macOS banner (25-min & 2-min repeats)
--------------------------------------------------------------------
function M.sendNotification(duration)
    local now = os.time()
    if now - lastBannerAt < 110 then return end -- throttle
    lastBannerAt = now
    flagSent(duration)

    if graceTimer then
        graceTimer:stop(); graceTimer = nil
    end
    if repeatTimer then
        repeatTimer:stop(); repeatTimer = nil
    end

    local cb = function(_, event)
        if event == "activated" or event == "removed" then
            P.state.lastNotificationAcknowledged = true
            if graceTimer then
                graceTimer:stop(); graceTimer = nil
            end
            if repeatTimer then repeatTimer:stop() end
            repeatTimer = hs.timer.doAfter(120, function()
                if P.state.currentState == "work" then
                    M.sendNotification(P.state.workTime)
                end
            end)
        end
    end

    hs.notify.new(cb, {
        title           = "Pomodoro",
        informativeText = string.format(
            "You've been working for %d min – time to pause!",
            math.floor(duration / 60)
        ),
        hasActionButton = false
    }):withdrawAfter(0):send()

    graceTimer = hs.timer.doAfter(60, function()
        if not P.state.lastNotificationAcknowledged
            and not P.enhancedNotificationElements then
            P.enhancedNotificationElements =
                M.showPictureInPictureAlert(P.state.workTime)
        end
    end)
end

--------------------------------------------------------------------
-- prominent overlay (semi-transparent, every screen)
--------------------------------------------------------------------
function M.showPictureInPictureAlert(duration)
    flagSent(duration)
    local elems = { canvases = {} }

    local msg = string.format(
        "⏰  %d minutes of focus reached — take a break!",
        math.floor(duration / 60)
    )
    -- Adjust colours to match macOS Light / Dark appearance
    local isDark     = (hs.host.interfaceStyle() == "Dark")
    local panelColor = isDark and { white = 0.15, alpha = 0.95 }
                              or  { white = 1,   alpha = 0.95 }
    local txtColor   = isDark and { white = 1 }
                              or  { white = 0 }
    d("Overlay creation ➜ interfaceStyle:", hs.host.interfaceStyle() or "Light",
      "isDark:", isDark, "panelColor.white:", panelColor.white)

    local function dismiss()
        if repeatTimer then repeatTimer:stop() end
        M.cleanupNotificationElements(elems)
        P.state.lastNotificationAcknowledged = true
        P.enhancedNotificationElements       = nil
        repeatTimer                          = hs.timer.doAfter(120, function()
            if P.state.currentState == "work" then
                M.sendNotification(P.state.workTime)
            end
        end)
    end

    for _, scr in ipairs(hs.screen.allScreens()) do
        local f = scr:fullFrame()
        local c = hs.canvas.new(f)
            :level("popUpMenu")
            :clickActivating(true)
            :canvasMouseEvents(true, false) -- mouseDown only
            :mouseCallback(function(_, msg) -- msg == "mouseDown"
                if msg == "mouseDown" then dismiss() end
            end)
            :appendElements(
                {
                    type = "rectangle",
                    action = "fill",
                    fillColor = { alpha = 0.40, red = 0, green = 0, blue = 0 }
                },
                {
                    type = "rectangle",
                    action = "fill",
                    fillColor = panelColor,
                    roundedRectRadii = { xRadius = 10, yRadius = 10 },
                    frame = { x = "20%", y = "35%", w = "60%", h = "30%" },
                    trackMouseDown = true
                },                       -- makes the area clickable
                {
                    type = "text",
                    text = msg,
                    textColor = txtColor,
                    textSize = 36,
                    textAlignment = "center",
                    frame = { x = "20%", y = "42%", w = "60%", h = "16%" }
                }
            ):show()

        table.insert(elems.canvases, c)
    end

    elems.idleTimer = hs.timer.doEvery(5, function()
        if hs.host.idleTime() >= 60 then dismiss() end
    end)

    return elems
end

--------------------------------------------------------------------
function M.cleanupNotificationElements(e)
    if not e then return end
    if e.idleTimer then e.idleTimer:stop() end
    if e.canvases then
        for _, c in ipairs(e.canvases) do pcall(function() c:delete() end) end
    end
end

--------------------------------------------------------------------
return M
