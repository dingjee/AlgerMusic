#!/bin/sh
# Only generated artifacts owned by this checkout are removable.
# Persistent applications and ALL user data are outside the cleanup scope.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
LSREGISTER="${ALGER_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
APPLY=1
case "${1:-}" in
  ''|--apply) ;;
  --dry-run) APPLY=0 ;;
  --help|-h)
    echo 'Usage: sh scripts/clean.sh [--apply|--dry-run]'
    echo 'Preserves dist/, source, tests, dependencies, tools and all user data.'
    exit 0 ;;
  *) echo "Unknown argument: $1" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo 'Too many arguments' >&2; exit 2; }

remove() {
  candidate="$1"
  [ -e "$candidate" ] || [ -L "$candidate" ] || return 0
  # A symlinked parent could point into dist/, source or another checkout.
  parent="$(cd "$(dirname "$candidate")" && pwd -P)"
  if [ "$parent" != "$(dirname "$candidate")" ] || [ -L "$candidate" ]; then
    echo "skipped (symlink): $candidate"
    return 0
  fi
  if [ "$APPLY" -eq 0 ]; then
    echo "[dry-run] would remove: $candidate"
  else
    # Deleting a bundle alone can leave its application registration behind.
    # Stay inside this proven generated path and never follow symlinks.
    if [ -x "$LSREGISTER" ]; then
      find "$candidate" -type d -name '*.app' -prune \
        -exec "$LSREGISTER" -u '{}' \; >/dev/null 2>&1 || true
    fi
    rm -rf -- "$candidate"
    echo "removed: $candidate"
  fi
}

# Exact generated paths. Keep generated Xcode source/configuration and tools.
for relative in src-tauri/target src-tauri/gen/schemas \
  src-tauri/gen/apple/DerivedData src-tauri/gen/apple/build \
  src-tauri/gen/apple/Externals src-tauri/gen/apple/Pods \
  crates/alger-core/target crates/alger-bridge/target \
  crates/.artifacts \
  native/macos/.build \
  frontend/dist .artifacts .DS_Store; do
  remove "$ROOT/$relative"
done

# Xcode records which workspace owns each DerivedData directory. A name alone
# is insufficient: another checkout can have the same project name.
DERIVED="$HOME/Library/Developer/Xcode/DerivedData"
if [ -d "$DERIVED" ]; then
  for directory in "$DERIVED"/*; do
    [ -f "$directory/info.plist" ] || continue
    workspace="$(/usr/libexec/PlistBuddy -c 'Print :WorkspacePath' "$directory/info.plist" 2>/dev/null || true)"
    case "$workspace" in
      "$ROOT/src-tauri/gen/apple/"*) remove "$directory" ;;
    esac
  done
fi

# Temporary profiles, logs, screenshots, sockets and staging bundles must carry
# a marker containing this checkout's canonical path. Never sweep by name alone.
for base in "${TMPDIR:-/tmp}" /tmp; do
  [ -d "$base" ] || continue
  base="$(cd "$base" && pwd -P)"
  for directory in "$base"/alger-*; do
    [ -d "$directory" ] && [ ! -L "$directory" ] || continue
    [ -f "$directory/.alger-project" ] && [ ! -L "$directory/.alger-project" ] || continue
    [ "$(cat "$directory/.alger-project")" = "$ROOT" ] || continue
    # Do not remove a staging directory still in use by its creating process.
    if [ -f "$directory/.alger-owner-pid" ]; then
      owner="$(cat "$directory/.alger-owner-pid")"
      case "$owner" in
        ''|*[!0-9]*) echo "skipped (invalid owner): $directory"; continue ;;
      esac
      if kill -0 "$owner" 2>/dev/null; then
        echo "skipped (active owner $owner): $directory"
        continue
      fi
    fi
    remove "$directory"
  done
done

# Keep one durable launch registration after retiring generated bundles.
# dist/ is the only long-term entry: register that bundle directly, without an
# /Applications shortcut.
TRIAL="$ROOT/dist/AlgerMusicPlayer.app"
if [ -x "$LSREGISTER" ] && [ -d "$TRIAL" ] && [ ! -L "$TRIAL" ] && \
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TRIAL/Contents/Info.plist" 2>/dev/null)" = com.alger.music.trial ]; then
  if [ "$APPLY" -eq 0 ]; then
    echo "[dry-run] would refresh application registration: $TRIAL"
  else
    "$LSREGISTER" -f "$TRIAL"
    mdimport "$TRIAL" 2>/dev/null || true
    echo "refreshed application registration: $TRIAL"
  fi
fi
echo 'Cleanup complete; dist/ and persistent user data preserved.'
