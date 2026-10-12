#!/bin/bash
set -euo pipefail

binary="/Applications/Soprano Desktop.app/Contents/MacOS/SopranoDesktop"
uid="$(id -u)"
for label in com.soprano.desktop com.soprano.desktop.statusbar com.soprano.desktop.borders; do
    if /bin/launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
        /bin/launchctl bootout "gui/$uid/$label"
    fi
    plist="$HOME/Library/LaunchAgents/$label.plist"
    [[ ! -f "$plist" ]] || rm "$plist"
done
"$binary" restore-theme
printf 'Original appearance and wallpaper restored. Installed apps, launchers and backups were retained.\n'
