#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$script_dir/.." && pwd)"
support="$HOME/Library/Application Support/Soprano Desktop"
config="$HOME/.config/soprano-desktop"
app="/Applications/Soprano Desktop.app"
uid="$(id -u)"
if [[ "${1:-}" != --skip-build ]]; then
    "$script_dir/build-desktop.sh"
fi
"$script_dir/install-desktop-tools.sh"
mkdir -p "$support/assets" "$config/plugins" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/Soprano Desktop"
/usr/bin/ditto "$root/.build/desktop/Soprano Desktop.app" "$app"
/usr/bin/codesign --verify --deep --strict "$app"
cp "$root/Desktop/sketchybarrc" "$root/Desktop/bordersrc" "$config/"
cp "$root/Desktop/plugins/"*.sh "$config/plugins/"
chmod +x "$config/sketchybarrc" "$config/bordersrc" "$config/plugins/"*.sh
binary="$app/Contents/MacOS/SopranoDesktop"
"$binary" render-assets "$support/assets"

# Styled launchers are separate bundles. Original signed application bundles
# and the user's existing Dock tiles are never rewritten.
launchers="$HOME/Desktop/Mission Control"
staging="$root/.build/desktop/launchers"
mkdir -p "$launchers" "$staging"
for entry in "com.soprano.app:Soprano" "com.apple.finder:Finder" "com.apple.Safari:Safari" "com.google.Chrome:Chrome" "dev.zed.Zed:Zed"; do
    id="${entry%%:*}"
    name="${entry#*:}"
    [[ -f "$support/assets/$id.png" ]] || continue
    launcher="$staging/$name.app"
    mkdir -p "$launcher/Contents/MacOS" "$launcher/Contents/Resources"
    cp "$binary" "$launcher/Contents/MacOS/SopranoDesktop"
    cp "$app/Contents/Info.plist" "$launcher/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.soprano.desktop.launcher.$id" "$launcher/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $name" "$launcher/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $name" "$launcher/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SopranoLauncherTarget string $id" "$launcher/Contents/Info.plist"
    iconset="$root/.build/desktop/Launcher.iconset"
    mkdir -p "$iconset"
    for size in 16 32 128 256 512; do
        /opt/homebrew/bin/magick "$support/assets/$id.png" -resize "${size}x${size}" "$iconset/icon_${size}x${size}.png"
        double=$((size * 2))
        /opt/homebrew/bin/magick "$support/assets/$id.png" -resize "${double}x${double}" "$iconset/icon_${size}x${size}@2x.png"
    done
    /usr/bin/iconutil -c icns "$iconset" -o "$launcher/Contents/Resources/AppIcon.icns"
    "$script_dir/sign-app.sh" "$launcher"
    /usr/bin/ditto --noextattr --norsrc "$launcher" "$launchers/$name.app"
done

# Keep the original preference snapshot across repeated installs.
theme_status=0
"$binary" apply-theme || theme_status=$?

export SOPRANO_DESKTOP_HOME="$HOME"
export SOPRANO_DESKTOP_SUPPORT="$support"
export SOPRANO_DESKTOP_APP="$app"
/usr/bin/env /opt/homebrew/bin/bun "$root/Desktop/install-launch-agents.ts"
for label in com.soprano.desktop com.soprano.desktop.statusbar com.soprano.desktop.borders; do
    plist="$HOME/Library/LaunchAgents/$label.plist"
    if /bin/launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
        /bin/launchctl bootout "gui/$uid/$label"
    fi
    /bin/launchctl bootstrap "gui/$uid" "$plist"
done
printf '\nInstalled Soprano Desktop. Shortcuts: Ctrl–Option–Space; Ctrl–Option–D.\n'
printf 'Original preferences: %s/original-settings.plist\n' "$support"
if [[ "$theme_status" -ne 0 ]]; then
    echo "Desktop modules are installed; the protected setting reported above still needs approval in System Settings." >&2
fi
exit "$theme_status"
