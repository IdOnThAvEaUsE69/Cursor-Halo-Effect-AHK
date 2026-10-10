# Cursor Halo

A smooth, click-through ring and dot that trail your mouse cursor on Windows. The ring **inverts whatever is on screen beneath it** (black over white, white over black, half and half over a split background), grows when the cursor changes to something other than the normal arrow, and "breathes" while Windows is busy.

Written in [AutoHotkey v2](https://www.autohotkey.com/). A single script, no dependencies.

<!-- Add a GIF or screenshot here, e.g. ![Cursor Halo demo](docs/demo.gif) -->

## Features

- **Inverted-color ring and dot.** Each frame samples the pixels under the overlay and draws the ring and dot with them inverted, so they stay visible on any background.
- **Smooth trailing.** The ring lags behind the cursor with a soft ease, and the small center dot follows with a shorter delay. Motion is frame-rate independent and updates at 144 Hz by default.
- **Reacts to cursor state.**
  - Normal arrow: idle size.
  - Anything else (hand, text I-beam, resize, move, crosshair, help, unavailable, and so on): the ring expands.
  - Busy / working in background: the ring breathes in and out.
- **Hides with the cursor.** When the cursor is hidden (typing auto-hide, video players, touch input), the ring and dot fade out.
- **Click-through and no-focus.** The overlay never blocks clicks or steals focus.
- **Low idle cost.** Drawing slows to a very low refresh rate a few seconds after you stop moving.
- **Tray menu and hotkeys** for pause, exit and restart.

## Requirements

- Windows 10 (2004+) or Windows 11
- [AutoHotkey v2](https://www.autohotkey.com/) (installed, not portable, if you want UI access)

## Installation

1. Install AutoHotkey v2.
2. Download `CursorHalo.ahk` from this repository.
3. Double-click it. The ring appears around your cursor and an icon is added to the tray.

### Drawing above the taskbar, tray and context menus (recommended)

Windows keeps the taskbar and menus in a layer that normal windows can't stay above. To put the overlay over them, run the script with **UI access**:

1. AutoHotkey must be installed in `C:\Program Files\AutoHotkey`.
2. Right-click `CursorHalo.ahk` and choose **Run with UI access**.

### Start with Windows

1. Press `Win+R`, type `shell:startup` and press Enter.
2. Create a new shortcut in that folder with this target (adjust both paths to match your install):

   ```
   "C:\Program Files\AutoHotkey\v2\AutoHotkey64_UIA.exe" "C:\path\to\CursorHalo.ahk"
   ```

If the shortcut does nothing, check that `AutoHotkey64_UIA.exe` exists at that path. The folder name differs between versions.

## Hotkeys and tray menu

| Action | Hotkey | Tray menu |
|---|---|---|
| Pause / resume | `Ctrl+Alt+H` | Pause / Resume |
| Exit | `Ctrl+Alt+Q` | Exit |
| Restart | `Ctrl+Alt+R` | Restart |

## Configuration

All settings are at the top of the script.

| Setting | Default | What it does |
|---|---|---|
| `BaseRadius` | `40` | Idle outer radius of the ring (px) |
| `ExpandedRadius` | `80` | Ring radius when the cursor is not the normal arrow |
| `RingWidth` | `2` | Ring thickness (px) |
| `DotRadius` | `5` | Center dot radius (px) |
| `PosTau` | `0.12` | Ring trail delay in seconds (larger = lazier) |
| `DotTau` | `0.06` | Dot trail delay in seconds |
| `SizeTau` | `0.09` | How smoothly the ring grows and shrinks |
| `BreathAmp` | `0.20` | Busy breathing strength (±20% radius) |
| `BreathPeriod` | `1.8` | Seconds per breath |
| `TargetHz` | `144` | Update rate. Match your monitor's refresh rate |
| `ActiveRefreshMs` | `0` | Redraw interval during the grace period after movement (`0` = every frame) |
| `IdleDelayMs` | `5000` | How long after the last movement before going idle |
| `IdleRefreshMs` | `10000` | Redraw interval once idle |

## How it works

- A layered, click-through (`WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE`) topmost window follows the cursor.
- Each frame, the screen area under the window is copied with a NOT-source raster operation (inverted), used as a GDI+ texture brush, and the ring and dot are drawn with that brush. The overlay is excluded from screen capture so it never samples itself.
- Pixels and position are pushed in a single `UpdateLayeredWindow` call per frame.
- Cursor state comes from `GetCursorInfo`, which returns the live cursor handle. It is compared against the system arrow, wait and app-starting cursors. (`A_Cursor` in AutoHotkey has no "Hand" value, so it can't be used for this.)
- Smoothing uses `1 - e^(-dt/tau)`, a LERP whose factor adapts to real frame time, so the trail feels the same regardless of timer jitter.

## Known limitations

- **Exclusive-fullscreen games** can't be overlaid. Borderless-windowed mode works.
- **Mid-gray backgrounds:** pure inversion of ~50% gray is nearly the same gray, so the ring is faint there.
- **Custom cursors:** apps that draw their own arrow instead of using the system arrow keep the ring expanded.
- **Cursor flicker in some apps:** in some Chromium-based apps (for example WhatsApp) and while selecting text in File Explorer, the cursor can flicker between arrow and hand/I-beam while the overlay is running. This is believed to be caused by the overlay moving under the pointer, which makes Windows re-check the cursor. It is cosmetic, and the ring follows the flicker.
- **Typing auto-hide:** the overlay was adjusted to stay out of the way of "hide pointer while typing". If the pointer reappears while you type, pause the script with `Ctrl+Alt+H` to check whether the overlay is involved.
- **GPU use:** sampling the screen every frame has a cost while the ring is moving. If it's too heavy, lower `TargetHz` or set `ActiveRefreshMs` to `16`.

## Troubleshooting

| Problem | Try |
|---|---|
| Nothing appears | Make sure AutoHotkey **v2** is installed and the script was started from the `.ahk` file |
| Ring goes behind the taskbar or menus | Run with UI access (see above) |
| Choppy motion | Set `TargetHz` to your monitor's refresh rate, or try 120 or 90 |
| High GPU usage | Lower `TargetHz`, or raise `ActiveRefreshMs` |
| Frame drops in a game | Pause the script with `Ctrl+Alt+H` while playing |

## Support

If you find this useful, you can support more small tools like this:

**[Donate on Playto](https://playto.so/Rance_Sama)**

<!-- Replace the link above with your page URL. -->
