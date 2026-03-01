#!/bin/bash
set -e

# Clear any stale window position
defaults delete "com.apple.SwiftUI" 2>/dev/null || true
defaults delete -g "SopranoMainWindow" 2>/dev/null || true

export PATH="/opt/homebrew/opt/swift/bin:$PATH"

echo "Building Soprano..."
swift build 2>&1 | grep -E "^(Build|error:|warning:.*error)" || true

echo "Launching Soprano..."
exec .build/debug/Soprano
