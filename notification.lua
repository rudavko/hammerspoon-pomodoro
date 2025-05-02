-- ~/.hammerspoon/pomodoro/notification.lua
--------------------------------------------------------------------
-- stateless UI helpers
--------------------------------------------------------------------
local M, log = {}, nil
function M.init(logger) log = logger or { i = print } end
local function i(...) if log and log.i then log.i(...) end end

-- Banner ----------------------------------------------------------
function M.showBanner(minutes, onClick)
  local n = hs.notify.new(function(_, ev)
      if (ev == "activated" or ev == "removed") and onClick then onClick() end
    end,
    { title="Pomodoro",
      informativeText=string.format("You've been working for %d min – time to pause!", minutes),
      hasActionButton=false })
  n:withdrawAfter(0):send()
  return n
end

-- Overlay ---------------------------------------------------------
local function buildOverlay(minutes, onDismiss)
  local obj = { canvases={} }
  local msg = string.format("⏰  %d minutes of focus reached — take a break!", minutes)
  local dark = (hs.host.interfaceStyle()=="Dark")
  local pCol = dark and {white=0.15, alpha=0.95} or {white=1, alpha=0.95}
  local tCol = dark and {white=1}               or {white=0}

  local function dismiss()
    if onDismiss then onDismiss() end
    M.dismiss(obj)
  end

  for _,s in ipairs(hs.screen.allScreens()) do
    local c = hs.canvas.new(s:fullFrame())
      :level("popUpMenu"):clickActivating(true)
      :canvasMouseEvents(true,false)
      :mouseCallback(function(_,m) if m=="mouseDown" then dismiss() end end)
      :appendElements(
        {type="rectangle",action="fill",fillColor={alpha=0.4,red=0,green=0,blue=0}},
        {type="rectangle",action="fill",fillColor=pCol,
         roundedRectRadii={xRadius=10,yRadius=10},
         frame={x="20%",y="35%",w="60%",h="30%"},trackMouseDown=true},
        {type="text",text=msg,textColor=tCol,textSize=36,textAlignment="center",
         frame={x="20%",y="42%",w="60%",h="16%"}}
      ):show()
    table.insert(obj.canvases,c)
  end
  obj.idleTimer = hs.timer.doEvery(5,function()
      if hs.host.idleTime()>=60 then dismiss() end
    end)
  return obj
end
function M.showOverlay(minutes,onDismiss) return buildOverlay(minutes,onDismiss) end

-- Dismiss ---------------------------------------------------------
function M.dismiss(h)
  if not h then return end
  if h.idleTimer then h.idleTimer:stop() end
  if h.canvases then for _,c in ipairs(h.canvases) do pcall(function() c:delete() end) end
  elseif h.withdraw then pcall(function() h:withdraw() end) end
end
return M