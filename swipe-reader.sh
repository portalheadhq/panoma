#!/usr/bin/env bash
# Streams the touchpad's swipe gestures for Panoma, one libinput event per
# line. Exits (and the shell retries later) when there is no touchpad it can
# read, or no `libinput` tool: see README for the one-time permission setup.
set -u
command -v libinput >/dev/null 2>&1 || exit 3
for dev in /dev/input/event*; do
  udevadm info --query=property --name="$dev" 2>/dev/null | grep -qx 'ID_INPUT_TOUCHPAD=1' || continue
  [[ -r $dev ]] || continue
  # Line-buffered, or the swipe arrives in lumps.
  exec stdbuf -oL libinput debug-events --device "$dev"
done
exit 3
