#!/bin/bash
set -euo pipefail
SUPPORT="$HOME/Library/Application Support/Soprano Desktop"
source "$SUPPORT/assets/palette.sh"
SB="$SUPPORT/bin/sketchybar"
"$SB" --set "$NAME" label="${INFO:-desktop}" background.drawing=on background.color="$RAISED"
"$SB" --animate tanh 12 --set "$NAME" background.color="$BASE" label.color="$TEXT"
