# Moose

> The wheel was invented 5000 years ago. This is just a reminder.

Fixes scroll wheel behavior for non-Apple mice on macOS. Replaces Apple's erratic acceleration curve with linear momentum scrolling — each tick travels a consistent distance and glides to a smooth stop. Trackpad behavior is untouched.

- **Zero CPU at idle** — the event tap is fully disabled when no external mouse is connected
- **Auto-detects USB and Bluetooth mice** — tap enables on plug-in, disables on unplug
- **Momentum scrolling** — glides to a smooth stop after each wheel spin
- **No leaking** — momentum cancels on app switch and CMD+Tab
- **Live config** — edit `~/Library/Application Support/moose/config.json` and changes apply instantly, no restart needed
- **Debug overlay** — floating HUD with live velocity, config values, and cancel-radius circle

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

Moose reads its config from:

```
~/Library/Application Support/moose/config.json
```

The file is created automatically with defaults on first run. Edit it with any text editor — changes apply instantly, no restart needed.

```json
{
  "pixelsPerClick": 200,
  "friction": 3.5,
  "maxVelocity": 3000,
  "minVelocity": 25,
  "cancelOnMouseMove": false,
  "cancelOnMouseMoveThreshold": 50,
  "reverseScroll": false,
  "debug": false
}
```

| Key | Default | Description |
|---|---|---|
| `pixelsPerClick` | `200` | Velocity impulse per wheel tick (px/sec). Higher = faster scroll per detent. |
| `friction` | `3.5` | Deceleration rate. Half-life = `ln(2) / friction` sec. Higher = stops sooner. |
| `maxVelocity` | `3000` | Speed cap in px/sec. Prevents runaway on fast spins. |
| `minVelocity` | `25` | Cutoff threshold. Momentum stops below this. Higher = cleaner stop, less tail. |
| `cancelOnMouseMove` | `false` | Cancel momentum if the cursor moves beyond the threshold during a glide. |
| `cancelOnMouseMoveThreshold` | `50` | Radius in px before momentum cancels (only used when `cancelOnMouseMove` is `true`). |
| `reverseScroll` | `false` | Flip scroll direction for the mouse wheel only. Trackpad unaffected. |
| `debug` | `false` | Show a live debug overlay with current velocity and config values. When `cancelOnMouseMove` is enabled, a circle is drawn at the scroll origin showing the cancel radius — green at low velocity, red near max. |

**Friction reference:**
- `1.0` — very long glide (~700 ms half-life), floaty
- `2.5` — Apple trackpad feel (~280 ms half-life)
- `3.5` — default, snappier than trackpad
- `5.0` — short snap (~140 ms half-life)

## Troubleshooting

**Moose is running but scroll feels unchanged**
Accessibility was revoked — happens after every recompile. Re-add `~/.local/bin/Moose` in:
`System Settings → Privacy & Security → Accessibility`
Then restart: `make restart`

**A config value seems ignored**
Out-of-range values are clamped to safe limits when the config loads — for example, `friction` is floored at `0.1` to prevent a divide-by-zero in the momentum math. When this happens the log records a `Config: … out of range — clamped` warning.

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
