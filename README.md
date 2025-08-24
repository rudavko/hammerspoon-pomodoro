# Hammerspoon Pomodoro Timer

A smart, automatic Pomodoro timer for macOS that tracks your work sessions without manual intervention.

## Features

- **Automatic Tracking**: Monitors your activity and tracks work/idle time automatically
- **Smart States**: Fresh → Work → Idle transitions based on computer usage
- **Persistent Sessions**: Survives computer sleep/restart (within limits)
- **Two-Stage Notifications**: Banner notification at 25 minutes, overlay at 27+ minutes
- **Zero Manual Control**: No start/stop buttons - just work and the timer tracks you

## Installation

```bash
git clone https://github.com/rudavko/hammerspoon-pomodoro.git ~/.hammerspoon/pomodoro && echo "require('pomodoro')" >> ~/.hammerspoon/init.lua
```

Reload Hammerspoon (⌘⌥⌃R or click Hammerspoon menubar icon → Reload Config).

## Updates

```bash
cd ~/.hammerspoon/pomodoro && git pull
```

Then reload Hammerspoon (⌘⌥⌃R or click Hammerspoon menubar icon → Reload Config).

## How It Works

The timer automatically detects your activity:

- **Fresh**: No recent work activity 
- **Work**: Active typing/clicking (displays `work 1m`, `work 2m`, etc.)
- **Idle**: Inactive for 2+ minutes (displays `idle 1m`, `idle 2m`, etc.)

### Notifications

- **25 minutes**: Banner notification appears
- **27+ minutes**: Full-screen overlay every 2 minutes if not acknowledged
- **Auto-dismiss**: Overlay disappears when you go idle for 1+ minute

### State Transitions

- Work → Idle: After 2 minutes of inactivity
- Idle → Fresh: After 5 minutes of inactivity  
- Any state → Work: Resume activity

## Menu Features

Click the menubar item for:
- Reset timer
- View current state and idle time
- See notification acknowledgment status

## Requirements

- [Hammerspoon](http://www.hammerspoon.org/)
- macOS notification permissions

---

Automatic Pomodoro tracking that works with your natural workflow. 🍅
