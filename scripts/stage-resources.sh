#!/bin/bash
# Fills a Soprano resource directory, the tree every OS ships beside the app binary
# (macOS: Soprano.app/Contents/Resources, Linux: <prefix>/share/soprano):
#
#   Soprano_Soprano.bundle/ AgentHooks/ bin/omp fonts/ icons/   from resources/
#   web/                         the built omp web app (scripts/build-web.sh)
#   ghostty/shell-integration/   from the ghostty submodule
#   terminfo/                    Ghostty's terminfo compiled with tic
#   LICENSE LICENSE-ghostty      (font and icon notices ship inside fonts/ and icons/)
#
# The caller adds bin/soprano, which points at the platform's app binary.
# Usage: stage-resources.sh <macos|linux> <absolute-empty-or-missing-dir>
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <macos|linux> <absolute-resources-dir>" >&2
    exit 2
fi

platform="$1"
destination="$2"

if [[ "$platform" != "macos" && "$platform" != "linux" ]]; then
    echo "Unsupported platform: $platform" >&2
    exit 2
fi
if [[ "$destination" != /* || "$destination" == "/" ]]; then
    echo "The resources directory must be an absolute path other than /: $destination" >&2
    exit 2
fi
if [[ -e "$destination" && -n "$(ls -A "$destination")" ]]; then
    echo "The resources directory must be empty or missing: $destination" >&2
    exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

repo_resources="$repo_root/resources"
soprano_license="$repo_root/LICENSE"
ghostty_license="$repo_root/Support/Licenses/LICENSE-ghostty"
shell_integration="$repo_root/ghostty/src/shell-integration"
terminfo_module="$repo_root/ghostty/src/terminfo/main.zig"
terminfo_emitter="$repo_root/packaging/terminfo/emit.zig"
web_source="$repo_root/web"

for required_path in "$repo_resources/Soprano_Soprano.bundle" "$repo_resources/AgentHooks" \
    "$repo_resources/bin/omp" "$repo_resources/fonts" "$repo_resources/icons" \
    "$soprano_license" "$ghostty_license" "$terminfo_emitter" \
    "$web_source/package-lock.json"; do
    if [[ ! -e "$required_path" ]]; then
        echo "Missing packaging input: $required_path" >&2
        exit 1
    fi
done
if [[ ! -d "$shell_integration" || ! -f "$terminfo_module" ]]; then
    echo "The ghostty submodule is not checked out. Run: git submodule update --init ghostty" >&2
    exit 1
fi

# The Zig that builds the pinned ghostty, found the way crates/ghostty-sys/build.rs finds it.
zig="${ZIG:-}"
if [[ -z "$zig" ]]; then
    for candidate in /opt/homebrew/opt/zig@0.16/bin/zig /usr/local/opt/zig@0.16/bin/zig; do
        if [[ -x "$candidate" ]]; then
            zig="$candidate"
            break
        fi
    done
fi
zig="${zig:-zig}"
if ! zig_version="$("$zig" version 2>/dev/null)"; then
    echo "Compiling Ghostty's terminfo requires Zig 0.16 (brew install zig@0.16, or set ZIG)." >&2
    exit 1
fi
if [[ "$zig_version" != 0.16.* ]]; then
    echo "Compiling Ghostty's terminfo requires Zig 0.16; $zig is $zig_version." >&2
    exit 1
fi
if ! command -v tic >/dev/null 2>&1; then
    echo "Compiling Ghostty's terminfo requires tic (ncurses)." >&2
    exit 1
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/soprano-resources.XXXXXX")"
cleanup() {
    rm -rf "$work_dir"
}
trap cleanup EXIT

# Build our editable web fork, never download an upstream app at command runtime.
"$script_dir/build-web.sh"
web_standalone="$web_source/.next/standalone"
if [[ ! -f "$web_standalone/server.js" ]]; then
    echo "Missing standalone omp web server: $web_standalone/server.js" >&2
    exit 1
fi

mkdir -p "$destination"

tar -C "$repo_resources" --exclude '.DS_Store' -cf - \
    Soprano_Soprano.bundle AgentHooks bin fonts icons \
    | tar -C "$destination" -xf -
chmod +x "$destination/bin/omp"

web_destination="$destination/web"
mkdir -p "$web_destination/.next/static" "$web_destination/scripts"
# Standalone tracing may already include these directories. Merge their contents,
# and leave development tests and Windows executables out of the bundle.
tar -C "$web_standalone" --exclude '*.test.mjs' --exclude '*.exe' -cf - . \
    | tar -C "$web_destination" -xf -
tar -C "$web_source/.next/static" -cf - . | tar -C "$web_destination/.next/static" -xf -
tar -C "$web_source" --exclude '*.test.mjs' --exclude '*.exe' -cf - bin lib public \
    | tar -C "$web_destination" -xf -
if [[ "$platform" == "macos" ]]; then
    cp "$web_source/scripts/macos-launchd.mts" "$web_destination/scripts/"
fi
cp "$web_source/package.json" "$web_source/package-lock.json" "$web_source/LICENSE" \
    "$web_destination/"

mkdir -p "$destination/ghostty"
tar -C "$repo_root/ghostty/src" --exclude '*.md' -cf - shell-integration \
    | tar -C "$destination/ghostty" -xf -

terminfo_source="$work_dir/ghostty.terminfo"
"$zig" run \
    --cache-dir "$work_dir/zig-cache" \
    --dep terminfo \
    "-Mroot=$terminfo_emitter" \
    "-Mterminfo=$terminfo_module" \
    > "$terminfo_source"
mkdir -p "$destination/terminfo"
# tic warns that older versions may read the description field as an alias; Ghostty's own
# build discards that stderr too.
tic -x -o "$destination/terminfo" "$terminfo_source" 2>/dev/null
if [[ ! -f "$destination/terminfo/78/xterm-ghostty" && ! -f "$destination/terminfo/x/xterm-ghostty" ]]; then
    echo "tic did not produce an xterm-ghostty entry in $destination/terminfo" >&2
    exit 1
fi

cp "$soprano_license" "$destination/LICENSE"
cp "$ghostty_license" "$destination/LICENSE-ghostty"
