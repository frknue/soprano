#!/bin/bash
set -euo pipefail

support="$HOME/Library/Application Support/Soprano Desktop"
mkdir -p "$support/bin" "$support/licenses"
if [[ -x "$support/bin/sketchybar" && -x "$support/bin/borders" ]]; then
    exit 0
fi
build_dir="$(mktemp -d /tmp/soprano-desktop-tools.XXXXXX)"
cleanup() { rm -rf "$build_dir"; }
trap cleanup EXIT

# Use the upstream recipes directly. Homebrew currently rejects this Mac's CLT
# version even though its selected full-Xcode compiler builds these releases.
git clone --depth 1 --branch v2.24.1 https://github.com/FelixKratz/SketchyBar.git "$build_dir/SketchyBar"
git clone --depth 1 --branch v1.9.0 https://github.com/FelixKratz/JankyBorders.git "$build_dir/JankyBorders"
if [[ "$(uname -m)" == arm64 ]]; then
    make -C "$build_dir/SketchyBar" -j8 arm64
else
    make -C "$build_dir/SketchyBar" -j8 x86
fi
make -C "$build_dir/JankyBorders"
/usr/bin/codesign --force --sign - "$build_dir/SketchyBar/bin/sketchybar"
/usr/bin/codesign --force --sign - "$build_dir/JankyBorders/bin/borders"
/usr/bin/install -m 755 "$build_dir/SketchyBar/bin/sketchybar" "$support/bin/sketchybar"
/usr/bin/install -m 755 "$build_dir/JankyBorders/bin/borders" "$support/bin/borders"
cp "$build_dir/SketchyBar/LICENSE.md" "$support/licenses/SketchyBar-GPL-3.0.txt"
cp "$build_dir/JankyBorders/LICENSE" "$support/licenses/JankyBorders-GPL-3.0.txt"
