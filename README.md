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
let PIXELS_PER_CLICK: Double = 10.0
```
How far the page moves per wheel tick, in pixels.
- `10` — default, comfortable
- `20` — faster
- `40` — fast

```swift
let DECAY: Double = 0.80
```
How long the momentum glide lasts after you stop spinning.
- `0.70` — snappy, stops quickly
- `0.80` — default, natural feel
- `0.88` — floaty, long glide

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

**Frameworks used:** `Cocoa`, `CoreGraphics`, `IOKit`, `OSLog` — no third-party code, no network access, no file access.

**Event tap scope:** intercepts scroll wheel events only. The event mask is hardcoded — it cannot see keyboard input, mouse clicks, or pointer movement. The tap is fully disabled when no external mouse is connected.

**Why Accessibility is required:** `CGEventTap` is the same mechanism keyloggers use. macOS gates it behind a user-granted Accessibility permission regardless of what events you actually watch. You grant it explicitly, it is not automatic.

**Source is auditable:** you compile from source yourself. Trust the code, not the binary.

---

© 2026 Studio Webux — GPL v3
