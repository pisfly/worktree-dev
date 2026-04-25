#!/usr/bin/env bash
# dev.sh — multi-worktree dev orchestrator for monorepos.
#
# Lets you run multiple git worktrees side by side (e.g. one per coding agent
# or feature branch) without port collisions or tooling clashes. Each worktree
# gets its own backend + web dev server on per-worktree ports; React Native's
# Metro is shared as a single-owner resource because the native build bakes
# the Metro port at compile time.
#
# Assumes a monorepo layout with three top-level dirs (override via the
# CONFIG block below):
#   backend/   — backend server  (this template assumes Scala + Play / sbt)
#   web/       — web app         (this template assumes Next.js)
#   mobile/    — mobile app      (this template assumes React Native)
#
# Adapt the actual dev-server commands at the bottom of the file to your
# stack (search for "DEV SERVER COMMANDS").
#
# Backend and web get per-worktree ports so they don't clash across worktrees.
# Metro always runs on 8081 — multiple Metros is an antipattern and makes the
# native build's baked-in port unusable. Only one worktree "owns" Metro at a
# time; other worktrees' dev.sh detect port 8081 is busy and skip Metro
# (backend + web still start so agents can keep working on those).
#
# Usage:
#   ./dev.sh                       # servers only; banner shows build commands
#   ./dev.sh ios                   # + run-ios on simulator ($IOS_SIM or default)
#   ./dev.sh ios "iPhone 15 Pro"   # + run-ios on a specific simulator
#   ./dev.sh device                # + run-ios on attached physical device
#   ./dev.sh android               # + run-android on attached emulator/device
#   --force / -f                   # add to any of the above: nuke mobile
#                                  #   node_modules, ios/Pods, ios/Podfile.lock,
#                                  #   and this project's DerivedData, then
#                                  #   reinstall and rebuild from scratch.
#
# Environment:
#   IOS_SIM           default simulator name for `ios` mode. Set in your shell rc:
#                     export IOS_SIM="iPhone 17 Pro"
#   XCODE_WORKSPACE   absolute path to .xcworkspace if auto-detection picks
#                     the wrong one (only relevant if you have multiple).
#
# Filter logs: ./dev.sh 2>&1 | grep '^\[backend\]'

set -euo pipefail

# ============================================================================
# CONFIGURATION — adjust for your project
# ============================================================================
DEFAULT_IOS_SIM="iPhone 17 Pro"
BACKEND_DIR="backend"
WEB_DIR="web"
MOBILE_DIR="mobile"
# Path inside MOBILE_DIR where this script writes the auto-generated host/port
# config that your mobile app imports at runtime. Adjust to your project's
# config layout. The file is gitignored.
DEV_PORTS_REL_PATH="src/config/devPorts.local.ts"
# Port ranges. Each worktree gets a deterministic offset (0..19) hashed from
# its name, so multiple worktrees never collide.
BACKEND_PORT_BASE=9000
WEB_PORT_BASE=3000
METRO_PORT=8081
# ============================================================================

usage() {
  sed -n '2,38p' "$0"
  exit "${1:-0}"
}

MODE=""
SIM_NAME=""
FORCE=0

# Strip --force / -f from anywhere in args; leave positionals for mode parsing.
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --force|-f) FORCE=1 ;;
    *) POSITIONAL+=("$arg") ;;
  esac
done
set -- "${POSITIONAL[@]:-}"

case "${1:-}" in
  "") ;;
  ios)     MODE="ios";     SIM_NAME="${2:-${IOS_SIM:-$DEFAULT_IOS_SIM}}" ;;
  device)  MODE="device" ;;
  android) MODE="android" ;;
  -h|--help|help) usage 0 ;;
  *) printf 'Unknown mode: %s\n\n' "$1" >&2; usage 2 ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

WORKTREE="$(basename "$REPO_ROOT")"

OFFSET="$(printf '%s' "$WORKTREE" | cksum | cut -d' ' -f1)"
SLOT=$((OFFSET % 20))

BACKEND_PORT=$((BACKEND_PORT_BASE + SLOT))
WEB_PORT=$((WEB_PORT_BASE + SLOT))

# Auto-detect the iOS .xcworkspace — used to find this worktree's Xcode
# DerivedData folder during --force clean. If your repo has multiple
# .xcworkspace files, set XCODE_WORKSPACE explicitly.
detect_xcworkspace() {
  local ios_dir="$REPO_ROOT/$MOBILE_DIR/ios"
  if [[ ! -d "$ios_dir" ]]; then
    return
  fi
  local ws
  ws="$(ls -d "$ios_dir"/*.xcworkspace 2>/dev/null | head -n1)"
  if [[ -n "$ws" ]]; then
    printf '%s' "$ws"
  fi
}

XCODE_WORKSPACE_PATH="${XCODE_WORKSPACE:-$(detect_xcworkspace)}"
XCODE_WORKSPACE_NAME=""
if [[ -n "$XCODE_WORKSPACE_PATH" ]]; then
  XCODE_WORKSPACE_NAME="$(basename "$XCODE_WORKSPACE_PATH" .xcworkspace)"
fi

detect_lan_ip() {
  local ip
  for iface in en0 en1 en2; do
    ip="$(ipconfig getifaddr "$iface" 2>/dev/null || true)"
    if [[ -n "$ip" ]]; then
      printf '%s' "$ip"
      return
    fi
  done
  printf '127.0.0.1'
}

LAN_IP="$(detect_lan_ip)"

# Write per-worktree values into the gitignored devPorts.local file. Your
# mobile app should import from this file (with a committed devPorts.ts as
# fallback default for fresh checkouts).
DEV_PORTS_FILE="$REPO_ROOT/$MOBILE_DIR/$DEV_PORTS_REL_PATH"
DEV_PORTS_DIR="$(dirname "$DEV_PORTS_FILE")"
if [[ -d "$DEV_PORTS_DIR" ]]; then
  cat > "$DEV_PORTS_FILE" <<EOF
// AUTO-GENERATED by dev.sh — do not edit by hand. Gitignored.
export const DEV_HOST = '${LAN_IP}';
export const DEV_API_PORT = ${BACKEND_PORT};
export const DEV_WEB_PORT = ${WEB_PORT};
EOF
fi

metro_already_running() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$METRO_PORT" -sTCP:LISTEN >/dev/null 2>&1
  else
    nc -z localhost "$METRO_PORT" >/dev/null 2>&1
  fi
}

METRO_ACTIVE=0
if metro_already_running; then
  METRO_ACTIVE=1
fi

# Refuse to build mobile against someone else's Metro — it would load their JS.
if (( METRO_ACTIVE )) && [[ -n "$MODE" ]]; then
  printf 'Refusing to build %s: Metro on 8081 is owned by another worktree.\n' "$MODE" >&2
  printf 'Building from here would make the app load the OTHER worktree'\''s JS.\n' >&2
  printf 'Stop that dev.sh first, then rerun this one.\n' >&2
  exit 1
fi

printf '\n'
printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
printf '  Worktree: %s  (slot %d)\n' "$WORKTREE" "$SLOT"
printf '  LAN IP:   %s\n' "$LAN_IP"
printf '  Backend:  http://localhost:%d  (LAN: http://%s:%d)\n' "$BACKEND_PORT" "$LAN_IP" "$BACKEND_PORT"
printf '  Web:      http://localhost:%d\n' "$WEB_PORT"
if (( METRO_ACTIVE )); then
  printf '  Metro:    ALREADY RUNNING on 8081 — skipping here.\n'
  printf '            Another worktree owns Metro and is serving ITS JS on 8081,\n'
  printf '            so do not build the iOS app from this worktree — it would\n'
  printf '            load the other worktree'\''s JS bundle. Stop that dev.sh\n'
  printf '            first to reclaim mobile work here.\n'
else
  printf '  Metro:    http://localhost:%d (this worktree owns it)\n' "$METRO_PORT"
  case "$MODE" in
    ios)     printf '  Mobile:   building iOS simulator → %s\n' "$SIM_NAME" ;;
    device)  printf '  Mobile:   building for attached iOS device\n' ;;
    android) printf '  Mobile:   running Android build\n' ;;
    *)
      printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
      printf '  Build iOS sim:   ./dev.sh ios [simulator-name]   (default: %s)\n' "${IOS_SIM:-$DEFAULT_IOS_SIM}"
      printf '  Build iOS dev:   ./dev.sh device\n'
      printf '  Build Android:   ./dev.sh android\n'
      ;;
  esac
fi
printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n'

GIT_COMMON_DIR="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
MAIN_REPO="$(dirname "$GIT_COMMON_DIR")"
IN_MAIN=0
if [[ "$REPO_ROOT" == "$MAIN_REPO" ]]; then
  IN_MAIN=1
fi

# node_modules strategy differs per app:
#   web    → symlink from main (Next.js handles symlinks cleanly; saves disk).
#   mobile → real `npm install` per worktree. CocoaPods + Xcode generate
#            broken Pods and header symlinks when node_modules is a symlink
#            (the "Create Symlinks to Header Folders" phase ends up dangling
#            and React-debug headers aren't findable). The ~1GB/worktree cost
#            is worth it for reliable iOS builds.

install_node_modules_local() {
  local rel_path="$1"
  local label="$2"
  local worktree_dir="$REPO_ROOT/$rel_path"
  if [[ -d "$worktree_dir/node_modules" && ! -L "$worktree_dir/node_modules" ]]; then
    return
  fi
  if [[ -L "$worktree_dir/node_modules" ]]; then
    printf '[%s]   replacing node_modules symlink with a real install (required for Xcode builds)…\n' "$label"
    rm "$worktree_dir/node_modules"
  fi
  # Reproducible install: `npm ci` installs exactly what package-lock.json
  # specifies rather than re-resolving against the live registry. This is
  # what every clean-slate clone (and every new dev's first run) gets.
  # `--legacy-peer-deps` skips peer-dep validation but does NOT re-resolve,
  # so the resulting tree is still bit-identical to the lockfile.
  if [[ ! -f "$worktree_dir/package-lock.json" ]]; then
    printf '[%s]   WARNING: no package-lock.json — falling back to npm install (not reproducible)\n' "$label"
    (cd "$worktree_dir" && npm install --legacy-peer-deps) 2>&1 | sed -u "s/^/[${label}-install] /"
    return
  fi

  printf '[%s]   installing via npm ci --legacy-peer-deps (locked tree, reproducible)…\n' "$label"
  if ! (cd "$worktree_dir" && npm ci --legacy-peer-deps) 2>&1 | sed -u "s/^/[${label}-install] /"; then
    printf '[%s]   npm ci failed — package-lock.json likely out of sync with package.json; regenerating via npm install…\n' "$label"
    (cd "$worktree_dir" && npm install --legacy-peer-deps) 2>&1 | sed -u "s/^/[${label}-install] /"
  fi
}

link_node_modules_from_main() {
  local rel_path="$1"
  local label="$2"
  local worktree_dir="$REPO_ROOT/$rel_path"
  local main_dir="$MAIN_REPO/$rel_path"
  local main_nm="$main_dir/node_modules"

  if (( IN_MAIN )); then
    if [[ ! -d "$worktree_dir/node_modules" ]]; then
      printf '[%s]   node_modules missing in main — installing…\n' "$label"
      if [[ -f "$worktree_dir/package-lock.json" ]]; then
        (cd "$worktree_dir" && npm ci --legacy-peer-deps) 2>&1 | sed -u "s/^/[${label}-install] /"
      else
        (cd "$worktree_dir" && npm install --legacy-peer-deps) 2>&1 | sed -u "s/^/[${label}-install] /"
      fi
    fi
    return
  fi

  if [[ -e "$worktree_dir/node_modules" || -L "$worktree_dir/node_modules" ]]; then
    return
  fi

  if [[ ! -d "$main_nm" ]]; then
    printf '[%s]   main checkout has no node_modules — installing there once so worktrees can share it…\n' "$label"
    if [[ -f "$main_dir/package-lock.json" ]]; then
      (cd "$main_dir" && npm ci --legacy-peer-deps) 2>&1 | sed -u "s/^/[${label}-install] /"
    else
      (cd "$main_dir" && npm install --legacy-peer-deps) 2>&1 | sed -u "s/^/[${label}-install] /"
    fi
  fi

  ln -s "$main_nm" "$worktree_dir/node_modules"
  printf '[%s]   linked %s/node_modules -> %s\n' "$label" "$rel_path" "$main_nm"
}

# --force: wipe mobile caches before reinstalling. Only targets THIS worktree's
# DerivedData (Xcode keys it by workspace path hash). Safe to re-run.
force_clean_mobile() {
  local mobile_dir="$REPO_ROOT/$MOBILE_DIR"
  printf '[force-clean] wiping %s/node_modules, ios/Pods, ios/Podfile.lock, ios/build, Metro caches\n' "$MOBILE_DIR"
  rm -rf "$mobile_dir/node_modules" \
         "$mobile_dir/ios/Pods" \
         "$mobile_dir/ios/Podfile.lock" \
         "$mobile_dir/ios/build" 2>/dev/null || true
  # Metro caches haste-map against file inodes; they go stale when
  # node_modules flips between symlink and real dir. Wipe them too.
  local tmpdir="${TMPDIR:-/tmp}"
  rm -rf "$tmpdir"/metro-* "$tmpdir"/haste-map-* "$tmpdir"/metro-cache 2>/dev/null || true
  # Watchman tracks its own filesystem state separately and can miss a
  # mass dir swap (e.g. the node_modules wipe+reinstall above), leading to
  # phantom "Unable to resolve module" errors on files that actually exist.
  if command -v watchman >/dev/null 2>&1; then
    watchman watch-del-all >/dev/null 2>&1 || true
    watchman shutdown-server >/dev/null 2>&1 || true
  fi

  # Find and remove the DerivedData dir for THIS workspace specifically.
  if [[ -z "$XCODE_WORKSPACE_NAME" || -z "$XCODE_WORKSPACE_PATH" ]]; then
    printf '[force-clean] no .xcworkspace found under %s/ios — skipping DerivedData clean\n' "$MOBILE_DIR" >&2
    return
  fi
  local dd_root="$HOME/Library/Developer/Xcode/DerivedData"
  if [[ -d "$dd_root" && -e "$XCODE_WORKSPACE_PATH" ]]; then
    for d in "$dd_root"/"$XCODE_WORKSPACE_NAME"-*; do
      [[ -d "$d" ]] || continue
      local wp
      wp="$(/usr/libexec/PlistBuddy -c 'Print :WorkspacePath' "$d/info.plist" 2>/dev/null || true)"
      if [[ "$wp" == "$XCODE_WORKSPACE_PATH" ]]; then
        printf '[force-clean] removing DerivedData: %s\n' "$d"
        # Best-effort: Xcode/SourceKit indexing may hold files open, which
        # makes rm fail with "Directory not empty". Not fatal — Xcode will
        # rebuild DerivedData on next build regardless.
        if ! rm -rf "$d" 2>/dev/null; then
          printf '[force-clean] partial: could not fully remove %s (Xcode may be holding files; close Xcode if iOS builds misbehave)\n' "$d" >&2
        fi
      fi
    done
  fi
}

if (( FORCE )); then
  force_clean_mobile
fi

link_node_modules_from_main "$WEB_DIR" "web"
if (( ! METRO_ACTIVE )); then
  install_node_modules_local "$MOBILE_DIR" "mobile"
fi

# CocoaPods can't be shared from main — the generated xcconfig references
# worktree-absolute paths, so each worktree needs its own `pod install`.
# Only runs when an iOS build is actually requested, and only if Pods is
# missing. Takes 1-2 min the first time per worktree, skipped thereafter.
ensure_ios_pods() {
  local ios_dir="$REPO_ROOT/$MOBILE_DIR/ios"
  if [[ ! -d "$ios_dir" || -d "$ios_dir/Pods" ]]; then
    return
  fi
  if ! command -v pod >/dev/null 2>&1; then
    printf 'cocoapods not found on PATH. Install with: sudo gem install cocoapods\n' >&2
    exit 1
  fi
  printf '[mobile-pod] Pods/ missing in this worktree — running pod install (one-time, ~1-2 min)…\n'
  (cd "$ios_dir" && pod install) 2>&1 | sed -u 's/^/[mobile-pod] /'
}

case "$MODE" in
  ios|device) ensure_ios_pods ;;
esac

pids=()

cleanup() {
  trap - INT TERM EXIT
  # Only signal the processes we launched. Avoid `kill 0` (signals the whole
  # process group), which can take down a parent wrapper script or terminal
  # session that sourced/launched dev.sh.
  for pid in "${pids[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}
trap cleanup INT TERM EXIT

# ============================================================================
# DEV SERVER COMMANDS — adapt these to your stack
# ============================================================================

# Backend (default: Scala + Play via sbt). Replace with your backend's dev
# command and pass $BACKEND_PORT however your stack consumes it.
(
  cd "$REPO_ROOT/$BACKEND_DIR"
  exec sbt -Dplay.server.http.port="$BACKEND_PORT" run
) 2>&1 | sed -u 's/^/[backend] /' &
pids+=($!)

# Web (default: Next.js). Replace with your web framework's dev command.
(
  cd "$REPO_ROOT/$WEB_DIR"
  exec npx --no-install next dev --port "$WEB_PORT"
) 2>&1 | sed -u 's/^/[web]     /' &
pids+=($!)

# Metro (React Native). Only this worktree runs it; others skip.
if (( ! METRO_ACTIVE )); then
  metro_extra=()
  if (( FORCE )); then
    metro_extra+=(--reset-cache)
  fi
  (
    cd "$REPO_ROOT/$MOBILE_DIR"
    exec npx --no-install react-native start --port "$METRO_PORT" "${metro_extra[@]}"
  ) 2>&1 | sed -u 's/^/[mobile]  /' &
  pids+=($!)
fi

# Fire off the native build in background once Metro is up. react-native
# run-{ios,android} will either detect Metro and skip launching a new one, or
# briefly wait for it. Either way, this stream is non-blocking.
if [[ -n "$MODE" ]] && (( ! METRO_ACTIVE )); then
  (
    cd "$REPO_ROOT/$MOBILE_DIR"
    case "$MODE" in
      ios)     exec npx --no-install react-native run-ios --simulator "$SIM_NAME" ;;
      device)  exec npx --no-install react-native run-ios --device ;;
      android) exec npx --no-install react-native run-android ;;
    esac
  ) 2>&1 | sed -u 's/^/[build]   /' &
  pids+=($!)
fi

wait
