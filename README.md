# Moose

> The wheel was invented 5000 years ago. This is just a reminder.

Fixes scroll wheel behavior for non-Apple mice on macOS. Replaces Apple's erratic acceleration curve with linear momentum scrolling — each tick travels a consistent distance and glides to a smooth stop. Trackpad behavior is untouched.

- **Zero CPU at idle** — the event tap is fully disabled when no external mouse is connected
- **Auto-detects USB and Bluetooth mice** — tap enables on plug-in, disables on unplug
- **Momentum scrolling** — glides to a smooth stop after each wheel spin
- **No leaking** — momentum cancels on app switch, CMD+Tab, or moving the cursor to another window

## Requirements

- macOS
- Xcode Command Line Tools: `xcode-select --install`

## Build & Install

```bash
# 1. Compile
make

# 2. Install as login agent
make install
```

`make install` will:
- Copy the binary to `~/.local/bin/Moose`
- Register it as a launchd agent (starts at login, restarts on crash)
- Open System Settings → Accessibility automatically

```bash
# 3. In Accessibility settings: click + and add ~/.local/bin/Moose, toggle it ON
```

Moose detects the permission grant automatically — no restart needed. Once running, it enables itself when an external mouse is connected and disables itself when disconnected.

## Uninstall

```bash
make uninstall
```

## Restart

```bash
make restart
```

## Tuning

All settings are at the top of `Moose.swift`. Edit then `make uninstall && make clean && make && make install`.

```swift
let PIXELS_PER_CLICK: Double = 300.0
```
Velocity impulse added per wheel tick, in pixels/sec. Think of this as how hard each tick "kicks" the scroll.
- `150` — light, short flicks
- `300` — default, Apple-like feel
- `500` — heavy, each tick sends you flying

```swift
let FRICTION: Double = 2.5
```
Deceleration rate. The glide half-life is `ln(2) / FRICTION` seconds — how long it takes to lose half its speed.
- `1.0` — very long glide (~700 ms half-life), floaty
- `2.5` — default, matches Apple trackpad momentum
- `5.0` — snappy, stops quickly (~140 ms half-life)

```swift
let MAX_VELOCITY: Double = 4000.0
```
Speed cap in pixels/sec. Prevents runaway scrolling when spinning the wheel rapidly.

```swift
let CANCEL_ON_MOUSE_MOVE: Bool = false
```
When `true`, moving the cursor during a glide cancels the momentum immediately. Default is `false` — momentum continues even if you move the mouse, which avoids side effects when nudging the mouse while reading.

```swift
let REVERSE_MOUSE_SCROLL: Bool = false
```
Flip scroll direction for the mouse wheel only. Trackpad direction is unaffected.

## Troubleshooting

**Moose is running but scroll feels unchanged**
Accessibility was revoked — happens after every recompile. Re-add `~/.local/bin/Moose` in:
`System Settings → Privacy & Security → Accessibility`
Then restart: `make restart`

**Check recent logs**
```bash
log show --predicate 'subsystem == "com.studiowebux.moose"' --last 5m
```

**Live log stream**
```bash
log stream --predicate 'subsystem == "com.studiowebux.moose"' --level debug
```

Shows all events including device detection (plug/unplug), tap enable/disable, and momentum activity.

---

## Security

**Frameworks used:** `Cocoa`, `CoreGraphics`, `IOKit`, `OSLog`, `QuartzCore` — no third-party code, no network access, no file access.

**Event tap scope:** intercepts scroll wheel events only. The event mask is hardcoded — it cannot see keyboard input, mouse clicks, or pointer movement. The tap is fully disabled when no external mouse is connected.

**Why Accessibility is required:** `CGEventTap` is the same mechanism keyloggers use. macOS gates it behind a user-granted Accessibility permission regardless of what events you actually watch. You grant it explicitly, it is not automatic.

**Source is auditable:** you compile from source yourself. Trust the code, not the binary.

---

© 2026 Studio Webux — GPL v3
