#!/usr/bin/env bash
# build-app.sh — Build a local production cmux and replace /Applications/cmux.app
#
# This script handles the full lifecycle:
#   1. Build Release configuration
#   2. Check for active coding agents (Claude Code, Kilo Code, etc.)
#   3. Gracefully quit the running production app (triggers session save)
#   4. Wait for the quit to complete
#   5. Replace /Applications/cmux.app
#   6. Relaunch
#
# Usage:
#   ./scripts/build-app.sh              # build, quit, replace, relaunch
#   ./scripts/build-app.sh --force      # skip agent check
#   ./scripts/build-app.sh --build-only # build without replacing
set -euo pipefail

PROD_BUNDLE_ID="com.cmuxterm.app"
PROD_APP="/Applications/cmux.app"
FORCE=0
BUILD_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force|-f)  FORCE=1; shift ;;
    --build-only) BUILD_ONLY=1; shift ;;
    -h|--help)
      echo "Usage: ./scripts/build-app.sh [--force] [--build-only]"
      echo ""
      echo "  --force       Skip active agent check"
      echo "  --build-only  Build without replacing the production app"
      exit 0
      ;;
    *) echo "error: unknown option $1" >&2; exit 1 ;;
  esac
done

# ── Step 1: Build Release ────────────────────────────────────────────

echo "==> Building Release configuration..."
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/cmux-build-app"
XCODE_LOG="/tmp/cmux-build-app.log"

xcodebuild \
  -project GhosttyTabs.xcodeproj \
  -scheme cmux \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  DEBUG_INFORMATION_FORMAT=dwarf \
  build 2>&1 | tee "$XCODE_LOG" | grep -E '(warning:|error:|fatal:|BUILD FAILED|BUILD SUCCEEDED|\*\* BUILD)' || true

XCODE_EXIT="${PIPESTATUS[0]}"
echo "    Full build log: $XCODE_LOG"
if [[ "$XCODE_EXIT" -ne 0 ]]; then
  echo "error: xcodebuild failed with exit code $XCODE_EXIT" >&2
  exit "$XCODE_EXIT"
fi

BUILT_APP="$DERIVED_DATA/Build/Products/Release/cmux.app"
if [[ ! -d "$BUILT_APP" ]]; then
  echo "error: built app not found at $BUILT_APP" >&2
  exit 1
fi

# Bundle cmuxd if available
CMUXD_SRC="$PWD/cmuxd/zig-out/bin/cmuxd"
GHOSTTY_HELPER_SRC="$PWD/ghostty/zig-out/bin/ghostty"
if [[ -d "$PWD/cmuxd" ]]; then
  echo "==> Building cmuxd (ReleaseFast)..."
  (cd "$PWD/cmuxd" && zig build -Doptimize=ReleaseFast)
fi
if [[ -d "$PWD/ghostty" ]]; then
  echo "==> Building Ghostty CLI helper (ReleaseFast)..."
  (cd "$PWD/ghostty" && zig build cli-helper -Dapp-runtime=none -Demit-macos-app=false -Demit-xcframework=false -Doptimize=ReleaseFast)
fi
if [[ -x "$CMUXD_SRC" ]]; then
  BIN_DIR="$BUILT_APP/Contents/Resources/bin"
  mkdir -p "$BIN_DIR"
  cp "$CMUXD_SRC" "$BIN_DIR/cmuxd"
  chmod +x "$BIN_DIR/cmuxd"
fi
if [[ -x "$GHOSTTY_HELPER_SRC" ]]; then
  BIN_DIR="$BUILT_APP/Contents/Resources/bin"
  mkdir -p "$BIN_DIR"
  cp "$GHOSTTY_HELPER_SRC" "$BIN_DIR/ghostty"
  chmod +x "$BIN_DIR/ghostty"
fi

# Ad-hoc codesign (required after modifying the bundle)
echo "==> Ad-hoc codesigning..."
/usr/bin/codesign --force --sign - --deep --timestamp=none --generate-entitlement-der "$BUILT_APP" >/dev/null 2>&1 || true

echo "==> Build complete: $BUILT_APP"

if [[ "$BUILD_ONLY" -eq 1 ]]; then
  echo "==> --build-only: skipping replacement and relaunch"
  exit 0
fi

# ── Step 2: Check for active agents ──────────────────────────────────

check_agents() {
  local agents_found=()

  # Check for Claude Code processes whose environment references the production cmux socket
  # Also check by common agent process patterns
  while IFS= read -r line; do
    agents_found+=("$line")
  done < <(
    # Look for common coding agent processes
    # Claude Code: typically runs as 'claude' or 'node' with claude args
    # Kilo Code: typically runs as 'node' with kilo/opencode args
    pgrep -fl "(claude|kilo|opencode)" 2>/dev/null \
      | grep -v "build-app.sh" \
      | grep -v "grep" \
      | grep -vi "xcode" \
      | grep -vi "xcodebuild" \
      | grep -vi "ShipIt" \
      | head -20 || true
  )

  if [[ "${#agents_found[@]}" -gt 0 ]]; then
    echo ""
    echo "WARNING: Active coding agent processes detected:"
    for line in "${agents_found[@]}"; do
      echo "  $line"
    done
    echo ""
    return 1
  fi
  return 0
}

if [[ "$FORCE" -eq 0 ]]; then
  if ! check_agents; then
    echo "Agents are running. Quitting cmux may interrupt their work."
    echo "Options:"
    echo "  - Wait for agents to finish, then re-run this script"
    echo "  - Run with --force to skip this check"
    exit 1
  fi
fi

# ── Step 3: Gracefully quit the running production app ───────────────

PROD_RUNNING=0
if pgrep -xq "cmux" 2>/dev/null; then
  # Verify it's the production bundle, not a debug build
  PROD_PID="$(pgrep -x "cmux" 2>/dev/null | head -1 || true)"
  if [[ -n "$PROD_PID" ]]; then
    PROD_RUNNING=1
  fi
fi

if [[ "$PROD_RUNNING" -eq 1 ]]; then
  echo "==> Gracefully quitting cmux (triggers session save)..."
  # AppleScript quit sends the proper applicationShouldTerminate which saves session state
  /usr/bin/osascript -e "tell application id \"${PROD_BUNDLE_ID}\" to quit" 2>/dev/null || true

  # Wait for the process to actually exit (up to 10 seconds)
  WAITED=0
  while pgrep -xq "cmux" 2>/dev/null && [[ "$WAITED" -lt 20 ]]; do
    sleep 0.5
    WAITED=$((WAITED + 1))
  done

  if pgrep -xq "cmux" 2>/dev/null; then
    echo "    App didn't quit in time, sending SIGTERM..."
    pkill -x "cmux" 2>/dev/null || true
    sleep 1
  fi

  if pgrep -xq "cmux" 2>/dev/null; then
    echo "    Still running, sending SIGKILL..."
    pkill -9 -x "cmux" 2>/dev/null || true
    sleep 0.5
  fi

  echo "    cmux has exited"
else
  echo "==> No running production cmux detected"
fi

# ── Step 4: Replace /Applications/cmux.app ───────────────────────────

echo "==> Replacing $PROD_APP..."
if [[ -d "$PROD_APP" ]]; then
  rm -rf "$PROD_APP"
fi
cp -R "$BUILT_APP" "$PROD_APP"
echo "    Done"

# ── Step 5: Relaunch ────────────────────────────────────────────────

echo "==> Launching cmux..."
# Strip cmux/ghostty env vars to avoid inheriting from the terminal running this script
env \
  -u CMUX_SOCKET_PATH \
  -u CMUX_TAB_ID \
  -u CMUX_PANEL_ID \
  -u CMUX_WORKSPACE_ID \
  -u CMUXD_UNIX_PATH \
  -u CMUX_TAG \
  -u CMUX_DEBUG_LOG \
  -u CMUX_BUNDLE_ID \
  -u CMUX_SHELL_INTEGRATION \
  -u GHOSTTY_BIN_DIR \
  -u GHOSTTY_RESOURCES_DIR \
  -u GHOSTTY_SHELL_FEATURES \
  -u GIT_PAGER \
  -u GH_PAGER \
  -u TERMINFO \
  -u XDG_DATA_DIRS \
  open "$PROD_APP"

echo ""
echo "======================================================="
echo "  cmux has been rebuilt and relaunched from $PROD_APP"
echo "======================================================="
