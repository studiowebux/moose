# Moose

> The wheel was invented 5000 years ago. This is just a reminder.

Fixes scroll wheel behavior for non-Apple mice on macOS. Replaces Apple's erratic acceleration curve with linear momentum scrolling — each tick travels a consistent distance and glides to a smooth stop, the same way a trackpad does. Trackpad behavior is untouched.

## Requirements

- macOS
- Xcode Command Line Tools: `xcode-select --install`
- Apple Developer account (for signing + notarization only)

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

# 4. Restart Moose to pick up the permission
launchctl unload ~/Library/LaunchAgents/com.studiowebux.moose.plist && launchctl load ~/Library/LaunchAgents/com.studiowebux.moose.plist
```

That's it. Moose runs silently in the background from now on.

## Uninstall

```bash
make uninstall
```

## Tuning

All settings are at the top of `Moose.swift`. Edit them, then `make uninstall && make clean && make && make install`.

```swift
let PIXELS_PER_CLICK: Double = 20.0
```
How far the page moves per wheel tick, in pixels.
- `10` — slow, precise
- `20` — default, comfortable
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
Accessibility was revoked — happens after every recompile. Re-add `~/.local/bin/Moose` in System Settings → Privacy & Security → Accessibility, then restart:
```bash
launchctl unload ~/Library/LaunchAgents/com.studiowebux.moose.plist && launchctl load ~/Library/LaunchAgents/com.studiowebux.moose.plist
```

**Check logs**
```bash
log show --predicate 'subsystem == "com.studiowebux.moose"' --last 5m
```

**Live log stream**
```bash
log stream --predicate 'subsystem == "com.studiowebux.moose"'
```

---

## Security

**Only Apple frameworks used:** `Cocoa`, `CoreGraphics`, `OSLog` — no third-party code, no network access, no file access.

**Event tap scope:** intercepts scroll wheel and mouse movement events only. The event mask is hardcoded — it cannot see keyboard input or mouse clicks.

**Why Accessibility is required:** `CGEventTap` is the same mechanism keyloggers use. macOS gates it behind a user-granted Accessibility permission regardless of what events you actually watch. You grant it explicitly, it is not automatic.

**Signing + Hardened Runtime:** the binary is signed with your Developer ID and notarized by Apple. Hardened Runtime locks it — no code injection, no library substitution. Tampering breaks the signature and macOS will refuse to run it.

**Source is auditable:** you compile from source yourself. Trust the code, not the binary.

---

© 2026 Studio Webux — GPL v3
