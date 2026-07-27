#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <version> <dmg-sha256>" >&2
    exit 2
fi

version="${1#v}"
sha256="$2"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]]; then
    echo "Expected a semantic version, got: $1" >&2
    exit 2
fi
if [[ ! "$sha256" =~ ^[0-9a-f]{64}$ ]]; then
    echo "Expected a lowercase SHA-256 digest, got: $sha256" >&2
    exit 2
fi

cat <<EOF
cask "soprano" do
  version "$version"
  sha256 "$sha256"

  url "https://github.com/frknue/soprano/releases/download/v#{version}/Soprano-#{version}.dmg"
  name "Soprano"
  desc "Native macOS tiling terminal multiplexer for AI coding agents"
  homepage "https://github.com/frknue/soprano"

  depends_on macos: ">= :sonoma"

  app "Soprano.app"
end
EOF
