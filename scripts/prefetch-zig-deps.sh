#!/bin/bash
# Puts ghostty's Codeberg-hosted Zig dependencies into the global Zig cache through git.
# Codeberg's archive endpoint (the `.url` ghostty pins) hangs or times out often enough to
# break builds, while a git fetch of the same commit yields the same package hash. Once the
# hash is in the cache, the libghostty-vt build (crates/ghostty-sys) never downloads it.
# Usage: prefetch-zig-deps.sh
set -euo pipefail

if [[ $# -ne 0 ]]; then
    echo "Usage: $0" >&2
    exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
ghostty_dir="$repo_root/ghostty"

if [[ ! -f "$ghostty_dir/build.zig" ]]; then
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
if ! zig_env="$("$zig" env 2>/dev/null)"; then
    echo "Building libghostty-vt requires Zig 0.16 (brew install zig@0.16, or set ZIG)." >&2
    exit 1
fi
global_cache="$(
    printf '%s\n' "$zig_env" \
        | sed -n 's/^[[:space:]]*\.global_cache_dir = "\(.*\)",$/\1/p'
)"
# ZON escapes backslashes in Windows paths (C:\\Users\\…); Git Bash reads C:/Users/… too.
global_cache="${global_cache//\\\\//}"
if [[ "$global_cache" != /* && ! "$global_cache" =~ ^[A-Za-z]:/ ]]; then
    echo "Could not read the global cache directory from '$zig env'." >&2
    exit 1
fi

archive_pattern='^https://codeberg\.org/([^/]+)/([^/]+)/archive/([0-9a-f]{40})\.tar\.gz$'
fetched=0

while IFS= read -r -d '' manifest; do
    pending_url=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*\.url[[:space:]]*=[[:space:]]*\"([^\"]*)\" ]]; then
            pending_url="${BASH_REMATCH[1]}"
            continue
        fi
        if [[ -z "$pending_url" ]] \
            || [[ ! "$line" =~ ^[[:space:]]*\.hash[[:space:]]*=[[:space:]]*\"([^\"]*)\" ]]; then
            continue
        fi
        hash="${BASH_REMATCH[1]}"
        url="$pending_url"
        pending_url=""

        if [[ ! "$url" =~ $archive_pattern ]]; then
            continue
        fi
        git_url="git+https://codeberg.org/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}.git#${BASH_REMATCH[3]}"

        # Zig 0.16 keeps packages as p/<hash>.tar.gz; older releases unpacked them to p/<hash>.
        if [[ -e "$global_cache/p/$hash.tar.gz" || -d "$global_cache/p/$hash" ]]; then
            echo "Zig cache already has $hash"
            continue
        fi

        echo "Fetching $git_url"
        # zig fetch needs a build.zig in the working directory.
        fetched_hash="$(cd "$ghostty_dir" && "$zig" fetch "$git_url")"
        fetched_hash="${fetched_hash%$'\r'}"
        if [[ "$fetched_hash" != "$hash" ]]; then
            echo "$git_url hashed to $fetched_hash, but ${manifest#"$repo_root/"} pins $hash." >&2
            exit 1
        fi
        fetched=$((fetched + 1))
    done < "$manifest"
done < <(
    find "$ghostty_dir" \
        \( -name zig-pkg -o -name .zig-cache -o -name zig-out -o -name .git \) -prune \
        -o -name build.zig.zon -type f -print0
)

echo "Prefetched $fetched Codeberg Zig package(s)."
