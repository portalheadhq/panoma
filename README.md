# Panoma

![Panoma: live thumbnails of the workspace, the workspace strip and the app dock](docs/screenshot.png)

An overview for [Omarchy](https://omarchy.org): the desktop zooms out, every
window on the workspace shrinks out of its real place into a grid of live
thumbnails, the workspaces line up along the top and a dock of running apps
rises from the bottom edge. Pick a window and everything flies back, with that
one focused. A three-finger swipe drags it open and closed under your fingers.

> **Status: beta.** Panoma is a plugin for the Omarchy shell and builds on parts
> of it that may change between Omarchy releases. It has been used day to day on
> one setup so far (see [Requirements](#requirements)); reports from other
> setups are very welcome.

## Requirements

- **Omarchy** with its Quickshell-based shell and Hyprland's Lua config.
  Known to work with Omarchy 4.5.0, Hyprland 0.56.2 and Quickshell 0.3.2.
- **Optional**, to follow your fingers while swiping: `libinput-tools` and read
  access to the touchpad (one `sudo` step, [below](#following-the-fingers-optional)).
  Without it, swipes still open and close Panoma, just without tracking.

## Install

**1. Add the plugin**

```bash
omarchy plugin add https://github.com/portalheadhq/panoma.git --enable
```

Omarchy shows the repository, asks you to confirm and enables Panoma. Like
every shell plugin it runs inside the Omarchy shell without a sandbox, so read
the code first if you like.

**2. Let Hyprland load Panoma's shortcut and gestures**

Panoma writes its shortcut, its swipe gestures and one display rule to
`~/.config/hypr/panoma.lua`. Add this line to `~/.config/hypr/hyprland.lua`,
after the other `require(...)` lines:

```lua
pcall(require, "hypr.panoma")
```

Save the file; Hyprland reloads it on its own. `pcall` means Hyprland carries
on normally if Panoma is ever removed. Until this line is there, **Super+E**
and the swipes do nothing, and closing the overview can leave a brief ghost of
it on screen (Panoma's settings show a reminder).

Then press **Super+E**, or swipe up with three fingers.

## Following the fingers (optional)

Hyprland only reports that a gesture happened, not how far the fingers have
moved, so Panoma reads the touchpad itself with `libinput debug-events`. That
needs the libinput tools and read access to the touchpad. The rule below gives
the logged-in user the touchpad only, not the keyboard:

```bash
sudo pacman -S --needed libinput-tools
echo 'ACTION=="add|change", SUBSYSTEM=="input", KERNEL=="event*", ENV{ID_INPUT_TOUCHPAD}=="1", TAG+="uaccess"' \
  | sudo tee /etc/udev/rules.d/70-touchpad-uaccess.rules
sudo udevadm control --reload && sudo udevadm trigger --subsystem-match=input --action=change
```

Panoma notices within 15 seconds; `omarchy-shell panoma status | jq .swipeReader`
turns `true`.

## Using it

- **Open / close**: Super+E, or three fingers up / down. Esc closes.
- **Pick a window**: click it, press its number (`1–9`), or move with the
  arrows or `h j k l` and press Enter. `q` closes the selected window, as does
  a middle click.
- **Filter**: `/` and type; matches windows on every workspace.
- **Dock**: click an app to go to it (its last window, on its workspace);
  right-click it, or press Tab, to see all of its windows.
- **Workspaces** run along the top, each a small map of its windows. Click one
  to go there. Drag a window onto one (or press `Shift+1–9`) to send it there;
  drop it on `+` for a new workspace.
- **Three fingers sideways** inside Panoma slides to the next or previous
  workspace (Ctrl+←/→ or PageUp/PageDown from the keyboard). Closing leaves you
  where you ended up.

## Settings

The gear at the top right of the overview (or `,`) opens the settings over it;
every change shows live behind them.

- **Gestures**: 3 or 4 fingers, follow the fingers or just trigger, swipe
  distance (sensitivity), invert the sideways swipe.
- **Look**: background darkness, corners like your windows or square, space
  between windows, animation speed, dock icon size.
- **Show**: workspace strip, dock, key hints, window numbers, and what a click
  on a dock app does.
- **Keys**: the Hyprland shortcut that opens Panoma (click, then press the
  combination; one that is already taken asks first), the filter, close and
  settings keys, and the modifier that sends a window to a workspace.

Settings are stored on Panoma's entry in `~/.config/omarchy/shell.json`. Don't
edit `~/.config/hypr/panoma.lua` by hand: Panoma rewrites it from the settings
(and puts the previous one back if Hyprland rejects a change).

From a terminal:

```bash
omarchy-shell panoma toggle
omarchy-shell panoma get                       # all settings, as JSON
omarchy-shell panoma setting backdrop 0.6      # change one
omarchy-shell panoma settingsTab keys          # open the settings on a tab
```

## Update

```bash
omarchy plugin update panoma
omarchy restart shell
```

## Uninstall

```bash
omarchy plugin remove panoma
rm ~/.config/hypr/panoma.lua
```

Then delete the `pcall(require, "hypr.panoma")` line from
`~/.config/hypr/hyprland.lua` (harmless if left), and, if you set up finger
tracking and no longer want it:

```bash
sudo rm /etc/udev/rules.d/70-touchpad-uaccess.rules
sudo udevadm control --reload && sudo udevadm trigger --subsystem-match=input --action=change
```

## Known issues

- Only tested with a single monitor.
- At the very start of the motion the whole picture darkens very slightly
  (a few percent) before the overview's own dimming takes over.
- Like other sliders in the Omarchy shell, scrolling over one in the settings
  changes its value.

## Development

The logic that doesn't need the shell (layout, filtering, the motion, swipe
parsing, settings and the generated Hyprland file) lives in `Model.js`, with
tests in `test.js`:

```bash
node test.js
```

The QML is loaded straight from source by the Omarchy shell. Clone the
repository into `~/.config/omarchy/plugins/panoma`, enable it with
`omarchy plugin enable panoma`, and run `omarchy restart shell` after a change
(panels that stay loaded keep their old code until then). Logs:
`journalctl --user -t omarchy-shell -f`.

To try the motion without a touchpad:

```bash
omarchy-shell panoma scrub 0.4    # drag to 40%
omarchy-shell panoma release      # let go: it settles open or closed
omarchy-shell panoma status | jq
```

Text follows Omarchy's language through `i18n/<code>.json`; English is the
fallback for anything missing.

## License

[MIT](LICENSE) © Portalhead. Fork it, change it, ship it; keep the notice.
