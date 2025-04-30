# Pomodoro‑Style Timer – Functional Specification (v1.0)
*Date: 30 Apr 2025*

---

## 1 Purpose
A minimal macOS menu‑bar utility that tracks **focused work time** versus **idle time** automatically, surfaces gentle reminders, and requires zero manual interaction.

---

## 2 State Model

| State  | Definition | Display | Persisted **minutes** value | Exit Conditions |
|--------|------------|---------|-----------------------------|-----------------|
| **Fresh** | No recent work activity (≥ 5 min idle **or** no persisted record) | `fresh` | `0` | ⮕ **Work** on any HID event |
| **Work** | Active HID events within the most recent 60 s | `work: Ns` (0–59 s) → `work: Nm` (1 m+) | Incremented & persisted every whole minute (0 → 1 → 2 …) | ⮕ **Idle** after 60 s no HID<br/>⮕ **Fresh** after sleep/hibernate ≥ 5 min |
| **Idle** | No HID events for 60 s but < 5 min | `idle: Ns` (0–59 s of idle) → `idle: Nm` (1–4 m) | *unchanged* | ⮕ **Work** on HID if idle < 5 min<br/>⮕ **Fresh** at idle = 5 min |

```
                     ┌─────────────┐
       (≥5 min idle) │   Fresh     │<───┐
     (sleep ≥5 min)  └─────┬───────┘    │
                        HID │          │
                            ▼          │
                  ┌─────────────────┐   │
                  │     Work        │───┤
                  └─────┬───────┬───┘   │
              no HID 60s │       │persist m++ each full min
                          │HID    │
                          ▼       │
                      ┌────────┐  │
                      │ Idle   │──┘
                      └────────┘
                             (idle reaches 5 min)
```

* Sleep, hibernate, or reboot are treated identically: on launch resume logic (section 3) decides whether to restore **Work**/**Idle** or reset to **Fresh**.

---

## 3 Launch / Resume Logic
1. **Load persisted record**: `{ minutes_worked, last_timestamp }`.
2. **No record** **or** `|now – last_timestamp| > 5 min` → reset `minutes_worked = 0` and start in **Fresh**.
3. Else, compute `delta = (now – last_timestamp)`.
   * If `delta < 60 s`: enter **Work**, resume seconds at `0 s`.
   * If `60 s ≤ delta < 5 min`: enter **Idle** with seconds counter `0 s`.

> Seconds are **always restarted at 0** on app launch; we never attempt to replay the exact second count.

---

## 4 Display Rules (menu‑bar title)
* **Work** 0–59 s → `work: Ns`
* **Work** ≥ 1 min → `work: Nm`
* **Idle** 0–59 s → `idle: Ns`
* **Idle** ≥ 1 min → `idle: Nm`
* **Fresh**     → `fresh`

Formatting notes:
* Fixed prefix (`work:`/`idle:`) + non‑breaking space + value + unit (`s` or `m`).
* The string length is stable within each order of magnitude to reduce menu‑bar jitter.

---

## 5 Notifications (macOS Alerts)
| Milestone | Condition | Behaviour |
|-----------|-----------|-----------|
| **First alert** | Reaches **25 min** in **Work** state | Display an **Alert** with title *“25 minutes of focused work 🎉”* and a single button **“Start break”*. |
| **Subsequent alerts** | Still in **Work** *and* last alert acknowledged or dismissed | Fire **each minute** at 27 m, 28 m, 29 m, … |
| **Suppression** | If an alert window is still open, **do not** spawn another. Maximum one outstanding alert. |
| **Break button** | Merely records *acknowledged_at = timestamp*. **Does not** force a state change; true break = 5 min **Idle**. |

All alerts are dismissible standard *Alert*‑style notifications (not transient banners) and persist until dismissed.

---

## 6 Persistence
* Persist **integer minutes_worked** plus **last_timestamp** *once per minute* while in **Work**.
* Storage medium/format is implementation‑specific and out of scope.
* Never write negative minutes.

---

## 7 Non‑Goals & Exclusions
* No manual start/stop/reset controls.
* No sound or haptic cues (future work).
* No enforcement of 5 min break—purely advisory.
* No multi‑user coordination beyond macOS single‑user session semantics.

---

## 8 Open for Future Extension (non‑binding)
* Configurable work/break durations.
* Optional sound for alerts.
* Stats export (CSV, JSON).
* Dark‑mode‑aware coloured menu‑bar icon.

---

**End of v1.0 spec**

