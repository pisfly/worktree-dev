#!/usr/bin/env bash
# Per-worktree dev stack — backend (Play), web (Next.js), mobile (Metro) — with
# compose-style lifecycle verbs, deterministic per-worktree ports, and state
# that autonomous agents can query. Zero dependencies beyond stock macOS.
#
# Directory layout, port bases, health-probe path, and default simulator live
# in the CONFIG block below; the dev-server commands themselves are in
# start_service() — adapt both to your stack.
#
# Usage:
#   ./dev.sh up [ios|device|android] [sim-name]   # start/converge stack (idempotent, health-gated)
#   ./dev.sh status [--json]    # per-service state; exit 0 healthy / 1 down / 2 partial / 3 conflict
#   ./dev.sh stop [--force]     # tear down this worktree's stack (--force: reap by port, ignores state)
#   ./dev.sh logs <svc> [-f]    # svc: backend | web | metro | mobile | build
#                               #   mobile = the app's own console.log output
#   ./dev.sh                    # up + follow combined logs (Ctrl+C detaches — does NOT stop the stack)
#   ./dev.sh ios [sim-name]     # shorthand for: up ios
#
# Flags:
#   --force / -f      with up: nuke mobile node_modules/Pods/DerivedData, reinstall, rebuild
#   --timeout <sec>   with up: health-gate timeout (default 300)
#   --own-sim         with up ios: build onto a per-worktree simulator clone (side-by-side worktrees)
#   --json            with status: machine-readable output
#
# Environment:
#   IOS_SIM   default simulator name for `ios` mode (default: iPhone 17 Pro)
#
# Services detach into their own process groups and log to .dev/logs/<svc>.log —
# they keep running after this script (and the shell that ran it) exits.
# Filter logs: ./dev.sh logs backend -f

set -euo pipefail

# Rosetta guard: agent/CI shells sometimes run x86_64 (e.g. an Intel-homebrew
# bash in PATH), and child processes inherit the translated arch — a universal
# Node then runs its x64 slice and can't load arm64 native bindings
# (lightningcss et al). Re-exec natively via the universal system bash.
if [[ "$(sysctl -n sysctl.proc_translated 2>/dev/null || printf 0)" == "1" ]]; then
  exec arch -arm64 /bin/bash "$0" "$@"
fi

# ============================================================================
# CONFIGURATION — adjust for your project
# ============================================================================
# Top-level monorepo directories (relative to this script).
BACKEND_DIR="backend"
WEB_DIR="web"
MOBILE_DIR="mobile"
# Health probe path the backend must answer before `up` reports healthy.
BACKEND_HEALTH_PATH="/api/health"
# Path inside MOBILE_DIR where dev.sh writes the auto-generated host/port
# config the mobile app imports at runtime. Gitignored; keep a committed
# default alongside it as fallback for fresh checkouts.
DEV_PORTS_REL_PATH="src/config/devPorts.local.ts"
# Port bases. Each worktree gets a deterministic slot (0..SLOT_COUNT-1) hashed
# from its name; keep base+slot ranges non-overlapping.
BACKEND_PORT_BASE=9000
WEB_PORT_BASE=3000
METRO_PORT_BASE=8081
SLOT_COUNT=20
DEFAULT_IOS_SIM="iPhone 17 Pro"
# ============================================================================

usage() {
  # Print the header comment block (everything after the shebang up to the
  # first non-comment line) — no hardcoded line range to drift.
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
  exit "${1:-0}"
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

WORKTREE="$(basename "$REPO_ROOT")"

OFFSET="$(printf '%s' "$WORKTREE" | cksum | cut -d' ' -f1)"
SLOT=$((OFFSET % SLOT_COUNT))

BACKEND_PORT=$((BACKEND_PORT_BASE + SLOT))
WEB_PORT=$((WEB_PORT_BASE + SLOT))
# Metro is per-worktree too. The port is baked into the native app at build
# time (RCT_METRO_PORT → RCTBundleURLProvider / react_native_dev_server_port),
# so each worktree's app talks to its own Metro. Metro's base+slot range must
# not overlap the web or backend ranges.
METRO_PORT=$((METRO_PORT_BASE + SLOT))

DEV_DIR="$REPO_ROOT/.dev"
STATE_FILE="$DEV_DIR/state.env"
LOG_DIR="$DEV_DIR/logs"
STACK_LOCK="$DEV_DIR/lock"
BUILD_LOCK="$DEV_DIR/build-lock"

SERVICES="backend web metro"

# ─────────────────────────────── arg parsing ───────────────────────────────

VERB=""
MODE=""
SIM_NAME=""
LOGS_SVC=""
FOLLOW=0
FORCE=0
JSON=0
OWN_SIM=0
TIMEOUT=300

FIRST="${1:-}"
case "$FIRST" in
  up)              VERB="up" ;;
  status)          VERB="status" ;;
  stop)            VERB="stop" ;;
  logs)            VERB="logs" ;;
  ios|device|android) VERB="up"; MODE="$FIRST" ;;
  ""|--force|-f|--timeout|--own-sim) VERB="up-tail" ;;   # bare invocation (flags only)
  -h|--help|help)  usage 0 ;;
  *) printf 'Unknown command: %s\n\n' "$FIRST" >&2; usage 2 ;;
esac

# Consume the verb token (not for bare invocations, where $1 is already a flag).
if [[ "$VERB" != "up-tail" && $# -gt 0 ]]; then shift; fi
[[ "$VERB" == "up-tail" ]] && VERB="up" && TAIL_AFTER_UP=1 || TAIL_AFTER_UP="${TAIL_AFTER_UP:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1 ;;
    -f)
      # -f is follow for `logs`, force for explicit up modes — but on a bare
      # invocation it is ambiguous (follow? force-clean?) and force is
      # destructive (wipes node_modules/Pods/DerivedData), so require --force.
      if [[ "$VERB" == "logs" ]]; then FOLLOW=1
      elif (( TAIL_AFTER_UP )); then
        printf -- '-f is ambiguous here. Use --force for the destructive clean, or "logs <svc> -f" to follow logs.\n' >&2
        exit 2
      else FORCE=1; fi ;;
    --follow) FOLLOW=1 ;;
    --json) JSON=1 ;;
    --own-sim) OWN_SIM=1 ;;
    --timeout)
      shift
      case "${1:-}" in
        ''|*[!0-9]*) printf -- '--timeout needs a positive integer number of seconds (got "%s")\n' "${1:-}" >&2; exit 2 ;;
      esac
      TIMEOUT="$1" ;;
    ios|device|android)
      if [[ "$VERB" == "up" && -z "$MODE" ]]; then MODE="$1"
      else printf 'Unexpected argument: %s\n' "$1" >&2; usage 2; fi ;;
    backend|web|metro|build|mobile)
      if [[ "$VERB" == "logs" && -z "$LOGS_SVC" ]]; then LOGS_SVC="$1"
      else printf 'Unexpected argument: %s\n' "$1" >&2; usage 2; fi ;;
    *)
      if [[ "$VERB" == "up" && "$MODE" == "ios" && -z "$SIM_NAME" ]]; then SIM_NAME="$1"
      else printf 'Unexpected argument: %s\n' "$1" >&2; usage 2; fi ;;
  esac
  shift
done

if [[ "$MODE" == "ios" && -z "$SIM_NAME" ]]; then
  SIM_NAME="${IOS_SIM:-$DEFAULT_IOS_SIM}"
fi

# ─────────────────────────────── small helpers ───────────────────────────────

upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

svc_port() {
  case "$1" in
    backend) printf '%s' "$BACKEND_PORT" ;;
    web)     printf '%s' "$WEB_PORT" ;;
    metro)   printf '%s' "$METRO_PORT" ;;
  esac
}

svc_url() {
  case "$1" in
    backend) printf 'http://localhost:%s' "$BACKEND_PORT" ;;
    web)     printf 'http://localhost:%s' "$WEB_PORT" ;;
    metro)   printf 'http://localhost:%s' "$METRO_PORT" ;;
  esac
}

svc_probe_url() {
  case "$1" in
    backend) printf 'http://localhost:%s%s' "$BACKEND_PORT" "$BACKEND_HEALTH_PATH" ;;
    web)     printf 'http://localhost:%s/' "$WEB_PORT" ;;
    metro)   printf 'http://localhost:%s/status' "$METRO_PORT" ;;
  esac
}

listener_pid() {
  # First PID listening on the given port, empty if none.
  lsof -t -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | head -1 || true
}

pid_lstart() {
  # LC_ALL=C is load-bearing: `ps -o lstart=` renders a LOCALE-DEPENDENT string
  # ("Sun Sep 13 …" vs "Paz 13 Eyl …"). Recording it in one locale and checking
  # it in another (agent session vs a Turkish terminal) made healthy services
  # look `stale` — and `up` then reaped and restarted working servers.
  LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//;s/ *$//' || true
}

pid_pgid() {
  ps -o pgid= -p "$1" 2>/dev/null | tr -d '[:space:]' || true
}

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

# ─────────────────────────────── state file ───────────────────────────────
# .dev/state.env is KEY=VALUE, bash-parseable — the durable record. JSON is
# only ever computed live by `status --json`, never stored.

state_get() {
  [[ -f "$STATE_FILE" ]] || return 0
  sed -n "s/^$1=//p" "$STATE_FILE" | head -1 | sed 's/^"//;s/"$//' || true
}

state_strip() {
  # Remove all keys with the given prefix; used before re-adding or on clear.
  [[ -f "$STATE_FILE" ]] || return 0
  local tmp="$STATE_FILE.tmp.$$"
  grep -v "^$1" "$STATE_FILE" > "$tmp" 2>/dev/null || true
  mv "$tmp" "$STATE_FILE"
}

state_set_kv() {
  mkdir -p "$DEV_DIR"
  touch "$STATE_FILE"
  state_strip "$1="
  printf '%s="%s"\n' "$1" "$2" >> "$STATE_FILE"
}

state_record_service() {
  local svc="$1" pid="$2" pgid="$3" port="$4" lstart="$5" started="$6"
  local U; U="$(upper "$svc")"
  mkdir -p "$DEV_DIR"
  touch "$STATE_FILE"
  state_strip "${U}_"
  {
    printf '%s_PID="%s"\n'        "$U" "$pid"
    printf '%s_PGID="%s"\n'       "$U" "$pgid"
    printf '%s_PORT="%s"\n'       "$U" "$port"
    printf '%s_LSTART="%s"\n'     "$U" "$lstart"
    printf '%s_STARTED_AT="%s"\n' "$U" "$started"
  } >> "$STATE_FILE"
}

state_clear_service() {
  state_strip "$(upper "$1")_"
}

# ─────────────────────────────── liveness ladder ───────────────────────────────
# Sets SVC_STATE (stopped|stale|conflict|starting|healthy), SVC_PID, SVC_PGID,
# SVC_STARTED_AT, SVC_SQUATTER. Never trusts the state file without validating
# process identity (lstart beats PID reuse) and port ownership (lsof beats
# everything). See design D4.

# Can we introspect processes at all? Under a restricted sandbox `ps` and
# `kill -0` are denied (EPERM) for processes we did not spawn, while `lsof` and
# `curl` still work. Without this check the ladder would read a perfectly
# healthy stack as `stale`/`stopped` — a FALSE "nothing running" that invites
# the very duplicate-spawn this script exists to prevent.
PROC_INTROSPECTION=""
proc_introspection_ok() {
  if [[ -z "$PROC_INTROSPECTION" ]]; then
    if ps -o pid= -p $$ >/dev/null 2>&1 && kill -0 $$ 2>/dev/null; then
      PROC_INTROSPECTION="full"
    else
      PROC_INTROSPECTION="limited"
    fi
  fi
  [[ "$PROC_INTROSPECTION" == "full" ]]
}

compute_svc_state() {
  local svc="$1"
  local port; port="$(svc_port "$svc")"
  local U; U="$(upper "$svc")"
  SVC_PID="$(state_get "${U}_PID")"
  SVC_PGID="$(state_get "${U}_PGID")"
  SVC_STARTED_AT="$(state_get "${U}_STARTED_AT")"
  SVC_SQUATTER=""
  local rec_lstart; rec_lstart="$(state_get "${U}_LSTART")"
  local lp; lp="$(listener_pid "$port")"

  if [[ -z "$SVC_PID" ]]; then
    if [[ -n "$lp" ]]; then SVC_STATE="conflict"; SVC_SQUATTER="$lp"
    else SVC_STATE="stopped"; fi
    return 0
  fi

  if ! proc_introspection_ok; then
    # Degraded mode: no process identity available, so judge by what still
    # works — who holds the port, and does it answer. Never claim `stale` while
    # something is serving on our port.
    if [[ -z "$lp" ]]; then SVC_STATE="stale"; return 0; fi
    if curl -fsS --max-time 3 "$(svc_probe_url "$svc")" >/dev/null 2>&1; then
      SVC_STATE="healthy"
    else
      SVC_STATE="starting"
    fi
    return 0
  fi

  local cur_lstart; cur_lstart="$(pid_lstart "$SVC_PID")"
  if [[ -z "$cur_lstart" ]]; then SVC_STATE="stale"; return 0; fi
  if [[ "$cur_lstart" != "$rec_lstart" ]]; then
    # Identity string disagrees. Before condemning a possibly-healthy service,
    # ask reality: does this live PID own our port and answer the probe? A
    # recycled PID that also owns this exact port and serves this exact health
    # endpoint is not a real scenario — but a stale-looking record for a
    # working service is, and reaping it destroys a good stack.
    if [[ -n "$lp" ]] && pid_is_ours "$lp" "$SVC_PID" "$SVC_PGID" \
       && curl -fsS --max-time 3 "$(svc_probe_url "$svc")" >/dev/null 2>&1; then
      SVC_STATE="healthy"; return 0
    fi
    SVC_STATE="stale"; return 0
  fi
  if [[ -z "$lp" ]]; then SVC_STATE="starting"; return 0; fi   # alive, not bound yet
  if ! pid_is_ours "$lp" "$SVC_PID" "$SVC_PGID"; then
    SVC_STATE="conflict"; SVC_SQUATTER="$lp"; return 0
  fi
  if curl -fsS --max-time 3 "$(svc_probe_url "$svc")" >/dev/null 2>&1; then
    SVC_STATE="healthy"
  else
    SVC_STATE="starting"
  fi
  return 0
}

pid_is_ours() {
  # Is candidate PID the recorded process, in its group, or a descendant?
  local cand="$1" rpid="$2" rpgid="$3"
  [[ "$cand" == "$rpid" ]] && return 0
  local cpg; cpg="$(pid_pgid "$cand")"
  [[ -n "$cpg" && -n "$rpgid" && "$cpg" == "$rpgid" ]] && return 0
  local p="$cand" i=0
  while [[ -n "$p" && "$p" != "0" && "$p" != "1" && "$i" -lt 15 ]]; do
    [[ "$p" == "$rpid" ]] && return 0
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d '[:space:]' || true)"
    i=$((i + 1))
  done
  return 1
}

# ─────────────────────────────── locks ───────────────────────────────
# `mkdir` is the atomic primitive (macOS has no flock, and /usr/bin/shlock
# does NOT break stale locks here — verified: it refuses even a lock it wrote
# itself once that pid is dead, which would make a crashed dev.sh block every
# later run). So we own staleness ourselves, and break it race-free:
# stealers serialize on a second lock and remove only the exact inode they
# verified as dead — closing the classic "A deletes the lock B just took"
# window of a naive check-then-remove.
#
# Two locks: the stack lock serializes converge/teardown mutations; the build
# lock serializes native builds separately, so a long xcodebuild never blocks
# another agent's server-only `up`. Held only during mutations, never while
# the stack runs.

LOCKS_HELD=""

release_locks() {
  local d
  for d in $LOCKS_HELD; do
    rm -rf "$d" 2>/dev/null || true
  done
  LOCKS_HELD=""
}

release_lock_file() {
  rm -rf "$1" 2>/dev/null || true
  LOCKS_HELD="$(printf '%s' "$LOCKS_HELD" | tr ' ' '\n' | grep -vxF "$1" | tr '\n' ' ')"
}

lock_holder_pid() { tr -dc '0-9' < "$1/pid" 2>/dev/null || true; }

lock_is_stale() {
  # Stale iff the recorded holder is gone, or the lock has sat >60s with no
  # readable pid (acquirer died between mkdir and the pid write).
  local d="$1" holder mtime
  holder="$(lock_holder_pid "$d")"
  if [[ -n "$holder" ]]; then
    kill -0 "$holder" 2>/dev/null && return 1
    return 0
  fi
  mtime="$(stat -f %m "$d" 2>/dev/null || printf 0)"
  (( $(date +%s) - mtime > 60 ))
}

break_stale_lock() {
  # Serialized + inode-verified steal. Only one stealer runs at a time, and it
  # removes the lock only if the inode it verified as dead is still the one at
  # that path — so a lock another process legitimately acquired meanwhile can
  # never be deleted.
  local d="$1" label="$2" steal="$1.steal"
  if ! mkdir "$steal" 2>/dev/null; then
    # Another stealer is mid-steal (or died mid-steal: it holds this for
    # milliseconds, so >30s means crashed).
    local m; m="$(stat -f %m "$steal" 2>/dev/null || printf 0)"
    (( $(date +%s) - m > 30 )) && rm -rf "$steal" 2>/dev/null
    return 0
  fi
  local ino1 ino2 holder
  ino1="$(stat -f %i "$d" 2>/dev/null || true)"
  holder="$(lock_holder_pid "$d")"
  if [[ -n "$ino1" ]] && lock_is_stale "$d"; then
    ino2="$(stat -f %i "$d" 2>/dev/null || true)"
    if [[ "$ino1" == "$ino2" ]]; then
      printf '[dev.sh] breaking stale %s lock (holder %s is gone)\n' "$label" "${holder:-unknown}" >&2
      rm -rf "$d" 2>/dev/null || true
    fi
  fi
  rmdir "$steal" 2>/dev/null || true
}

acquire_lock_file() {
  local lock="$1" wait_s="$2" label="$3"
  mkdir -p "$DEV_DIR"
  local waited=0 announced=0
  until mkdir "$lock" 2>/dev/null; do
    if lock_is_stale "$lock"; then
      break_stale_lock "$lock" "$label"
      continue
    fi
    # Never wait silently — a queued command is indistinguishable from a hang.
    if (( announced == 0 )); then
      local h; h="$(lock_holder_pid "$lock")"
      printf '[dev.sh] waiting for the %s lock held by pid %s: %s\n' \
        "$label" "${h:-?}" "$(ps -o command= -p "${h:-0}" 2>/dev/null | cut -c1-60 || printf 'unknown')" >&2
      printf '[dev.sh] (it will proceed as soon as that finishes; Ctrl+C is safe — it changes nothing)\n' >&2
      announced=1
    elif (( waited % 15 == 0 )); then
      printf '[dev.sh] still waiting for the %s lock (%ss)…\n' "$label" "$waited" >&2
    fi
    if (( waited >= wait_s )); then
      printf '[dev.sh] Timed out after %ss waiting for the %s lock (held by pid %s).\n' \
        "$wait_s" "$label" "$(lock_holder_pid "$lock")" >&2
      exit 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  printf '%s\n' "$$" > "$lock/pid"
  LOCKS_HELD="$LOCKS_HELD $lock"
  trap release_locks EXIT INT TERM
}

acquire_lock() { acquire_lock_file "$STACK_LOCK" 1800 "stack"; }
release_lock() { release_lock_file "$STACK_LOCK"; }

# ─────────────────────────────── status ───────────────────────────────

STATUS_BACKEND=""
STATUS_WEB=""
STATUS_METRO=""

collect_status() {
  # Read-only: status runs UNLOCKED, so it must never rewrite state.env —
  # a clean here could race a locked `up` appending fresh records and lose
  # them. Stale records are reported as `stale` and cleaned by the locked
  # converge/stop paths.
  local svc
  for svc in $SERVICES; do
    compute_svc_state "$svc"
    case "$svc" in
      backend) STATUS_BACKEND="$SVC_STATE|$SVC_PID|$SVC_PGID|$SVC_STARTED_AT|$SVC_SQUATTER" ;;
      web)     STATUS_WEB="$SVC_STATE|$SVC_PID|$SVC_PGID|$SVC_STARTED_AT|$SVC_SQUATTER" ;;
      metro)   STATUS_METRO="$SVC_STATE|$SVC_PID|$SVC_PGID|$SVC_STARTED_AT|$SVC_SQUATTER" ;;
    esac
  done
}

status_field() { printf '%s' "$1" | cut -d'|' -f"$2"; }

overall_state() {
  local states="$1"
  # stale ≙ stopped for the overall verdict (record is dead either way).
  local norm="${states//stale/stopped}"
  case "$states" in
    *conflict*) printf 'conflict' ;;
    *) if [[ "$norm" == "healthy healthy healthy" ]]; then printf 'healthy'
       elif [[ "$norm" == "stopped stopped stopped" ]]; then printf 'stopped'
       else printf 'partial'; fi ;;
  esac
}

overall_exit_code() {
  case "$1" in
    healthy) return 0 ;;
    stopped) return 1 ;;
    conflict) return 3 ;;
    *) return 2 ;;
  esac
}

json_service() {
  # svc, packed-status → one JSON object (no trailing comma)
  local svc="$1" packed="$2"
  local st pid pgid started squatter
  st="$(status_field "$packed" 1)"; pid="$(status_field "$packed" 2)"
  pgid="$(status_field "$packed" 3)"; started="$(status_field "$packed" 4)"
  squatter="$(status_field "$packed" 5)"
  printf '    "%s": {"state": "%s", "port": %s, "pid": %s, "pgid": %s, "url": "%s", "log": "%s", "started_at": %s%s}' \
    "$svc" "$st" "$(svc_port "$svc")" \
    "${pid:-null}" "${pgid:-null}" \
    "$(svc_url "$svc")" ".dev/logs/$svc.log" \
    "$([[ -n "$started" ]] && printf '"%s"' "$started" || printf 'null')" \
    "$([[ -n "$squatter" ]] && printf ', "squatter_pid": %s' "$squatter" || true)"
}

cmd_status() {
  collect_status
  local states
  states="$(status_field "$STATUS_BACKEND" 1) $(status_field "$STATUS_WEB" 1) $(status_field "$STATUS_METRO" 1)"
  local overall; overall="$(overall_state "$states")"
  local sim_udid; sim_udid="$(state_get SIM_UDID)"

  if (( JSON )); then
    printf '{\n'
    printf '  "worktree": "%s",\n  "slot": %s,\n  "overall": "%s",\n' "$(json_escape "$WORKTREE")" "$SLOT" "$overall"
    printf '  "services": {\n'
    json_service backend "$STATUS_BACKEND"; printf ',\n'
    json_service web "$STATUS_WEB"; printf ',\n'
    json_service metro "$STATUS_METRO"; printf '\n'
    printf '  },\n'
    printf '  "introspection": "%s",\n' "$(proc_introspection_ok && printf full || printf limited)"
    printf '  "simulator": %s,\n' "$([[ -n "$sim_udid" ]] && printf '{"udid": "%s", "name": "%s"}' "$sim_udid" "$(json_escape "$(state_get SIM_NAME)")" || printf 'null')"
  printf '  "app": %s\n' "$([[ -n "$(state_get APP_BUNDLE_ID)" ]] && printf '{"bundle_id": "%s"}' "$(state_get APP_BUNDLE_ID)" || printf 'null')"
    printf '}\n'
  else
    printf 'Worktree: %s (slot %d)  —  overall: %s\n' "$WORKTREE" "$SLOT" "$overall"
    local svc packed
    for svc in $SERVICES; do
      case "$svc" in
        backend) packed="$STATUS_BACKEND" ;;
        web) packed="$STATUS_WEB" ;;
        metro) packed="$STATUS_METRO" ;;
      esac
      local st pid squatter
      st="$(status_field "$packed" 1)"; pid="$(status_field "$packed" 2)"
      squatter="$(status_field "$packed" 5)"
      printf '  %-8s %-9s :%-5s %s %s\n' "$svc" "$st" "$(svc_port "$svc")" \
        "${pid:+pid $pid}" \
        "${squatter:+(FOREIGN pid $squatter holds this port — ./dev.sh stop --force to reclaim)}"
    done
    [[ -n "$sim_udid" ]] && printf '  %-8s %s  %s  app %s\n' "sim" "$sim_udid" "$(state_get SIM_NAME)" "$(state_get APP_BUNDLE_ID)"
    local mlpid; mlpid="$(state_get MOBILELOG_PID)"
    if [[ -n "$mlpid" ]] && kill -0 "$mlpid" 2>/dev/null; then
      printf '  %-8s %-9s (app console.log -> .dev/logs/mobile.log)\n' "mobile" "watching"
    fi
    proc_introspection_ok || printf '  note: limited process introspection (sandboxed): state inferred from port only. Re-run unsandboxed for an authoritative answer; do NOT treat this as 'not running'.\n'
    printf '  logs: .dev/logs/{backend,web,metro,mobile}.log\n'
  fi

  overall_exit_code "$overall"
}

# ─────────────────────────────── spawn ───────────────────────────────
# Each service becomes its own process-group leader (set -m), detached from
# us (disown), logging to files. NOTE: Play's dev server stops on stdin EOF,
# so the backend gets a never-EOF stdin via `tail -f /dev/null`.

start_service() {
  local svc="$1"
  mkdir -p "$LOG_DIR"
  local log="$LOG_DIR/$svc.log"
  local pid script extra=""

  # Each service runs in its OWN SESSION (POSIX setsid via stock perl — macOS
  # has no setsid(1)). A process *group* (what `set -m` gives) only isolates
  # from Ctrl+C; it does NOT detach from the controlling terminal, so a
  # terminal hangup could still reach the tree. For the backend that was fatal
  # in a subtle way: it killed the `tail -f /dev/null` that holds sbt's stdin
  # open, Play saw stdin EOF and shut itself down gracefully seconds after
  # starting ("Server started, use Enter to stop" → "Stopping Pekko HTTP
  # server"), leaving the health gate waiting on a corpse.
  #
  # ABSOLUTE system binaries are mandatory here: PATH `perl`/`bash` on this
  # machine are Intel-only (MacPorts), and anything they exec inherits x86_64 —
  # node then loads its x64 slice and fails on arm64-only native bindings
  # (lightningcss → web 500). /usr/bin/perl and /bin/bash are universal.
  #
  # setsid() requires the caller NOT already be a process-group leader, which
  # is why job control (`set -m`) must stay OFF here: a plain `&` child
  # inherits our pgid, so setsid() succeeds and the service becomes leader of
  # a fresh session AND group (pgid == pid, keeping `kill -- -PGID` teardown
  # intact). stdin is /dev/null for everything; the backend re-opens a
  # never-EOF stdin from `tail` INSIDE its own session.
  case "$svc" in
    backend)
      script="cd $(printf '%q' "$REPO_ROOT/$BACKEND_DIR") && tail -f /dev/null | exec sbt -Dplay.server.http.port=$BACKEND_PORT run" ;;
    web)
      script="cd $(printf '%q' "$REPO_ROOT/$WEB_DIR") && exec npx --no-install next dev --port $WEB_PORT" ;;
    metro)
      (( FORCE )) && extra=" --reset-cache"
      script="cd $(printf '%q' "$REPO_ROOT/$MOBILE_DIR") && exec npx --no-install react-native start --port $METRO_PORT$extra" ;;
  esac

  /usr/bin/perl -MPOSIX -e 'POSIX::setsid() or die "setsid failed: $!\n"; exec @ARGV or die "exec failed: $!\n"' \
    -- /bin/bash -c "$script" < /dev/null >> "$log" 2>&1 &
  pid=$!
  disown "$pid" 2>/dev/null || true

  local pgid lstart started
  pgid="$(pid_pgid "$pid")"
  lstart="$(pid_lstart "$pid")"
  started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  state_record_service "$svc" "$pid" "${pgid:-$pid}" "$(svc_port "$svc")" "$lstart" "$started"
}

# ─────────────────────────────── stop ───────────────────────────────

# The app's console.log does not reach Metro's output (RN 0.76 moved JS logs to
# React Native DevTools) nor the iOS system log — both verified. dev.sh runs a
# small subscriber against Metro's inspector proxy so those logs land in
# .dev/logs/mobile.log like every other service's. Auxiliary: never health-gated
# (no app running is normal), stopped with the stack.
start_mobile_log_tail() {
  local helper="$REPO_ROOT/$MOBILE_DIR/scripts/metro-console-tail.js"
  [[ -f "$helper" ]] || return 0
  command -v node >/dev/null 2>&1 || return 0
  local pid; pid="$(state_get MOBILELOG_PID)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    return 0   # already watching
  fi
  mkdir -p "$LOG_DIR"
  # Own session, like the services — a terminal hangup must not silently stop
  # app-log capture. It polls for the JS runtime, so it is safe to start before
  # Metro is healthy.
  /usr/bin/perl -MPOSIX -e 'POSIX::setsid() or die "setsid failed: $!\n"; exec @ARGV or die "exec failed: $!\n"' \
    -- node "$helper" "$METRO_PORT" "$LOG_DIR/mobile.log" < /dev/null >> "$LOG_DIR/mobile.log" 2>&1 &
  pid=$!
  disown "$pid" 2>/dev/null || true
  state_set_kv MOBILELOG_PID "$pid"
  state_set_kv MOBILELOG_PGID "$(pid_pgid "$pid")"
}

stop_mobile_log_tail() {
  local pid pgid
  pid="$(state_get MOBILELOG_PID)"; pgid="$(state_get MOBILELOG_PGID)"
  if [[ -n "$pgid" ]]; then kill -TERM -- "-$pgid" 2>/dev/null || true; fi
  if [[ -n "$pid" ]]; then kill -TERM "$pid" 2>/dev/null || true; fi
  state_strip "MOBILELOG_"
}

reap_port() {
  # SIGKILL anything still listening on the port. The ancestry-independent
  # backstop: forked JVMs and friends can leave the process group.
  local port="$1" p
  for p in $(lsof -t -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true); do
    kill -KILL "$p" 2>/dev/null || true
  done
}

reap_port_graceful() {
  # TERM listeners, give them a moment, then KILL survivors.
  local port="$1" p
  local had=0
  for p in $(lsof -t -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true); do
    kill -TERM "$p" 2>/dev/null || true
    had=1
  done
  (( had )) && sleep 2
  reap_port "$port"
}

stop_service() {
  local svc="$1"
  local U; U="$(upper "$svc")"
  local pid pgid port
  pid="$(state_get "${U}_PID")"
  pgid="$(state_get "${U}_PGID")"
  port="$(svc_port "$svc")"
  local grace=5
  [[ "$svc" == "backend" ]] && grace=15   # JVMs need a real grace period

  if [[ -z "$pid" && -z "$pgid" ]]; then
    # No record — nothing to signal by group; reclaim the port politely.
    reap_port_graceful "$port"
    state_clear_service "$svc"
    printf '[dev.sh] stopped %s (port %s free)\n' "$svc" "$port"
    return
  fi

  if [[ -n "$pgid" ]]; then
    kill -TERM -- "-$pgid" 2>/dev/null || true
  else
    kill -TERM "$pid" 2>/dev/null || true
  fi

  # Grace: watch the PORT's listener, not just the recorded PID — sbt's java
  # child can outlive its wrapper subshell, and killing it mid-TERM-shutdown
  # because the wrapper died first would defeat the JVM grace period.
  local i=0
  while (( i < grace * 2 )); do
    if [[ -z "$(listener_pid "$port")" ]] && ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 0.5
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    [[ -n "$pgid" ]] && kill -KILL -- "-$pgid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  fi

  reap_port "$port"
  state_clear_service "$svc"
  printf '[dev.sh] stopped %s (port %s free)\n' "$svc" "$port"
}

cmd_stop() {
  acquire_lock
  stop_mobile_log_tail
  local svc
  if (( FORCE )); then
    # No-state reclaim: TERM whatever holds our deterministic ports, then KILL.
    for svc in $SERVICES; do
      reap_port_graceful "$(svc_port "$svc")"
      state_clear_service "$svc"
      printf '[dev.sh] reclaimed port %s\n' "$(svc_port "$svc")"
    done
  else
    for svc in $SERVICES; do
      stop_service "$svc"
    done
  fi
  release_lock
}

# ─────────────────────────────── node_modules / pods prep ───────────────────────────────
# node_modules strategy differs per app:
#   web    → symlink from main (Next.js handles symlinks cleanly; saves disk).
#   mobile → real `npm ci` per worktree. CocoaPods + Xcode generate broken
#            Pods and header symlinks when node_modules is a symlink.

GIT_COMMON_DIR="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
MAIN_REPO="$(dirname "$GIT_COMMON_DIR")"
IN_MAIN=0
if [[ "$REPO_ROOT" == "$MAIN_REPO" ]]; then
  IN_MAIN=1
fi

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
  # `npm ci` installs exactly what package-lock.json specifies; --legacy-peer-deps
  # skips peer-dep validation but does NOT re-resolve, so the tree stays locked.
  if [[ ! -f "$worktree_dir/package-lock.json" ]]; then
    printf '[%s]   WARNING: no package-lock.json — falling back to npm install (not reproducible)\n' "$label"
    (cd "$worktree_dir" && npm install --legacy-peer-deps) 2>&1 | sed -u "s/^/[${label}-install] /"
    return
  fi
  printf '[%s]   installing via npm ci --legacy-peer-deps (locked tree, reproducible)…\n' "$label"
  if ! (cd "$worktree_dir" && npm ci --legacy-peer-deps) 2>&1 | sed -u "s/^/[${label}-install] /"; then
    printf '[%s]   npm ci failed — package-lock.json likely out of sync; regenerating via npm install…\n' "$label"
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
  # Auto-detect the workspace; DerivedData dirs are named <workspace>-<hash>.
  local ws_path ws_name
  ws_path="$(ls -d "$mobile_dir/ios"/*.xcworkspace 2>/dev/null | head -n1 || true)"
  ws_name=""
  [[ -n "$ws_path" ]] && ws_name="$(basename "$ws_path" .xcworkspace)"
  printf '[force-clean] wiping %s/node_modules, ios/Pods, ios/Podfile.lock, ios/build (this worktree only)\n' "$MOBILE_DIR"
  rm -rf "$mobile_dir/node_modules" \
         "$mobile_dir/ios/Pods" \
         "$mobile_dir/ios/Podfile.lock" \
         "$mobile_dir/ios/build" 2>/dev/null || true
  # Metro's haste map goes stale when node_modules flips between symlink and
  # real dir. Handled by starting Metro with --reset-cache under --force
  # (see start_service) — NOT by wiping $TMPDIR/metro-*, which is shared with
  # every other worktree's Metro.
  #
  # Watchman is ONE daemon for the whole machine, with a watch root per Metro.
  # `watch-del-all` / `shutdown-server` would tear down other worktrees' watch
  # roots too: their Metro keeps running and still answers /status, so the
  # health gate stays green while it silently serves stale JS. Scope the
  # invalidation to this worktree's root only.
  if command -v watchman >/dev/null 2>&1; then
    watchman watch-del "$mobile_dir" >/dev/null 2>&1 || true
  fi

  local dd_root="$HOME/Library/Developer/Xcode/DerivedData"
  if [[ -d "$dd_root" && -n "$ws_name" && -e "$ws_path" ]]; then
    for d in "$dd_root/$ws_name"-*; do
      [[ -d "$d" ]] || continue
      local wp
      wp="$(/usr/libexec/PlistBuddy -c 'Print :WorkspacePath' "$d/info.plist" 2>/dev/null || true)"
      if [[ "$wp" == "$ws_path" ]]; then
        printf '[force-clean] removing DerivedData: %s\n' "$d"
        if ! rm -rf "$d" 2>/dev/null; then
          printf '[force-clean] partial: could not fully remove %s (close Xcode if iOS builds misbehave)\n' "$d" >&2
        fi
      fi
    done
  fi
}

# CocoaPods can't be shared from main — generated xcconfig has worktree-absolute
# paths. Only runs when an iOS build is requested and Pods is missing.
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

# ─────────────────────────────── simulator ───────────────────────────────

# The app's bundle id is a build setting, not a runtime discovery problem.
# Recording it means agents never need `xcrun simctl listapps booted` (which is
# ambiguous with two simulators booted, i.e. exactly the --own-sim case).
record_app_identity() {
  local pbx
  pbx="$(ls "$REPO_ROOT/$MOBILE_DIR/ios"/*.xcodeproj/project.pbxproj 2>/dev/null | head -n1 || true)"
  [[ -n "$pbx" && -f "$pbx" ]] || return 0
  local bid
  bid="$(grep -o 'PRODUCT_BUNDLE_IDENTIFIER = [A-Za-z0-9._-]*;' "$pbx" | sed 's/.*= //;s/;//' | grep -v '^org\.reactjs' | head -1)"
  [[ -n "$bid" ]] && state_set_kv APP_BUNDLE_ID "$bid"
}


sim_udid_by_name() {
  # Newest runtime wins (sections are listed oldest→newest); match exact name.
  xcrun simctl list devices available 2>/dev/null \
    | grep -F "$1 (" | tail -1 | grep -oE '[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}' || true
}

ensure_own_sim() {
  local clone_name="wt-$WORKTREE"
  SIM_UDID="$(sim_udid_by_name "$clone_name")"
  if [[ -z "$SIM_UDID" ]]; then
    # simctl cannot clone a Booted device — prefer a Shutdown device with the
    # base name (newest runtime last), else create a fresh one from the
    # device type + newest iOS runtime instead of disturbing the booted sim.
    local base_udid
    base_udid="$(xcrun simctl list devices available 2>/dev/null \
      | grep -F "$SIM_NAME (" | grep -v Booted | tail -1 \
      | grep -oE '[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}' || true)"
    if [[ -n "$base_udid" ]]; then
      printf '[dev.sh] Cloning simulator "%s" → "%s" (one-time, ~30s)…\n' "$SIM_NAME" "$clone_name"
      SIM_UDID="$(xcrun simctl clone "$base_udid" "$clone_name")"
    else
      local devtype runtime
      devtype="com.apple.CoreSimulator.SimDeviceType.$(printf '%s' "$SIM_NAME" | tr ' ' '-')"
      runtime="$(xcrun simctl list runtimes available 2>/dev/null \
        | grep -oE 'com\.apple\.CoreSimulator\.SimRuntime\.iOS[A-Za-z0-9.-]*' | tail -1 || true)"
      if [[ -z "$runtime" ]]; then
        printf '[dev.sh] No simulator named "%s" to clone and no iOS runtime found.\n' "$SIM_NAME" >&2
        exit 1
      fi
      printf '[dev.sh] All "%s" sims are booted — creating fresh "%s" (%s)…\n' "$SIM_NAME" "$clone_name" "$runtime"
      SIM_UDID="$(xcrun simctl create "$clone_name" "$devtype" "$runtime")"
    fi
  fi
  if ! xcrun simctl list devices 2>/dev/null | grep -F "$SIM_UDID" | grep -q Booted; then
    xcrun simctl boot "$SIM_UDID" 2>/dev/null || true
  fi
  state_set_kv SIM_UDID "$SIM_UDID"
  state_set_kv SIM_NAME "$clone_name"
  printf '[dev.sh] Worktree simulator: %s (%s)\n' "$clone_name" "$SIM_UDID"
}

# ─────────────────────────────── up ───────────────────────────────

health_gate() {
  # Block until every service answers its probe; the docker `--wait` contract:
  # returning success means the stack is USABLE (first Play compile included).
  local deadline=$(( $(date +%s) + TIMEOUT ))
  local svc pending
  while true; do
    pending=""
    for svc in $SERVICES; do
      if ! curl -fsS --max-time 3 "$(svc_probe_url "$svc")" >/dev/null 2>&1; then
        pending="$pending $svc"
      fi
    done
    [[ -z "$pending" ]] && return 0

    # A pending service whose process has died will never become healthy —
    # say so now instead of waiting out the whole timeout on a corpse.
    if proc_introspection_ok; then
      for svc in $pending; do
        local spid; spid="$(state_get "$(upper "$svc")_PID")"
        if [[ -n "$spid" ]] && ! kill -0 "$spid" 2>/dev/null; then
          printf '[dev.sh] %s DIED while starting (pid %s is gone). Last log lines:\n' "$svc" "$spid" >&2
          tail -n 12 "$LOG_DIR/$svc.log" 2>/dev/null | sed 's/^/    /' >&2
          printf '[dev.sh] Full log: ./dev.sh logs %s   Retry: ./dev.sh up\n' "$svc" >&2
          return 1
        fi
      done
    fi

    if (( $(date +%s) >= deadline )); then
      local first; first="$(printf '%s' "$pending" | awk '{print $1}')"
      printf '[dev.sh] TIMEOUT after %ss waiting for:%s\n' "$TIMEOUT" "$pending" >&2
      printf '[dev.sh] Check .dev/logs/%s.log — the stack may still finish warming; ./dev.sh status to re-check.\n' "$first" >&2
      return 1
    fi
    sleep 2
  done
}

cmd_up() {
  acquire_lock

  local LAN_IP; LAN_IP="$(detect_lan_ip)"

  # Per-worktree values for the mobile app (gitignored; keep committed
  # defaults alongside as fallback for fresh checkouts).
  local DEV_PORTS_FILE="$REPO_ROOT/$MOBILE_DIR/$DEV_PORTS_REL_PATH"
  if [[ -d "$(dirname "$DEV_PORTS_FILE")" ]]; then
    cat > "$DEV_PORTS_FILE" <<EOF
// AUTO-GENERATED by dev.sh — do not edit by hand. Gitignored.
export const DEV_HOST = '${LAN_IP}';
export const DEV_API_PORT = ${BACKEND_PORT};
export const DEV_WEB_PORT = ${WEB_PORT};
EOF
  fi

  if (( FORCE )); then
    force_clean_mobile
  fi

  link_node_modules_from_main "$WEB_DIR" "web"
  install_node_modules_local "$MOBILE_DIR" "mobile"
  case "$MODE" in
    ios|device) ensure_ios_pods ;;
  esac

  # Converge each service: attach if ours-and-alive, clean+start if stale,
  # start if stopped, hard-stop on conflict (foreign process on our port).
  local svc started_any=0
  for svc in $SERVICES; do
    compute_svc_state "$svc"
    case "$SVC_STATE" in
      healthy)
        printf '[dev.sh] %-8s already running (pid %s, port %s) — attached\n' "$svc" "$SVC_PID" "$(svc_port "$svc")" ;;
      starting)
        printf '[dev.sh] %-8s already starting (pid %s) — waiting\n' "$svc" "$SVC_PID" ;;
      stale)
        # Dead record. If something still listens on OUR port it is almost
        # certainly an orphaned piece of our old tree (e.g. the npx wrapper
        # died but its node child kept serving) — reap it before restarting,
        # or the new instance can never bind.
        state_clear_service "$svc"
        local lp; lp="$(listener_pid "$(svc_port "$svc")")"
        if [[ -n "$lp" ]]; then
          printf '[dev.sh] %-8s stale record; orphaned listener pid %s on port %s — reaping first\n' \
            "$svc" "$lp" "$(svc_port "$svc")"
          reap_port_graceful "$(svc_port "$svc")"
        fi
        start_service "$svc"
        started_any=1
        printf '[dev.sh] %-8s restarted (pid %s → port %s, log .dev/logs/%s.log)\n' \
          "$svc" "$(state_get "$(upper "$svc")_PID")" "$(svc_port "$svc")" "$svc" ;;
      stopped)
        start_service "$svc"
        started_any=1
        printf '[dev.sh] %-8s started (pid %s → port %s, log .dev/logs/%s.log)\n' \
          "$svc" "$(state_get "$(upper "$svc")_PID")" "$(svc_port "$svc")" "$svc" ;;
      conflict)
        printf '[dev.sh] %-8s CONFLICT: foreign pid %s holds port %s (not started by this dev.sh).\n' \
          "$svc" "$SVC_SQUATTER" "$(svc_port "$svc")" >&2
        printf '[dev.sh] Inspect: lsof -nP -iTCP:%s -sTCP:LISTEN   Reclaim: ./dev.sh stop --force\n' \
          "$(svc_port "$svc")" >&2
        printf '[dev.sh] (If these are leftovers of THIS worktree'\''s previous stack — e.g. .dev/ was deleted —\n' >&2
        printf '[dev.sh]  stop --force is the expected recovery: it reaps only this worktree'\''s slot ports.)\n' >&2
        exit 3 ;;
    esac
  done
  state_set_kv MODE "${MODE:-servers}"

  printf '\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
  printf '  Worktree: %s  (slot %d)\n' "$WORKTREE" "$SLOT"
  printf '  Backend:  http://localhost:%d  (LAN: http://%s:%d)\n' "$BACKEND_PORT" "$LAN_IP" "$BACKEND_PORT"
  printf '  Web:      http://localhost:%d\n' "$WEB_PORT"
  printf '  Metro:    http://localhost:%d  (per-worktree; baked into native builds)\n' "$METRO_PORT"
  printf '  Logs:     .dev/logs/{backend,web,metro,mobile}.log   Stop: ./dev.sh stop\n'
  printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n'

  # Independent of the gate: the app-log subscriber only needs Metro, and must
  # exist even if another service is slow or the gate times out.
  start_mobile_log_tail

  printf '[dev.sh] health-gating (timeout %ss)…\n' "$TIMEOUT"
  if ! health_gate; then
    exit 1
  fi
  printf '[dev.sh] all services healthy.\n'

  # Servers are converged — release the stack lock BEFORE any native build,
  # so a long xcodebuild never starves a concurrent server-only `up` into a
  # lock timeout. Builds serialize among themselves via the build lock.
  release_lock

  # One-shot native build, after the servers are provably up. RCT_METRO_PORT
  # must be exported by US: with --no-packager the RN CLI does NOT forward
  # --port into the xcodebuild env (verified spike, see design.md), and the
  # Pods xcconfig resolves ${RCT_METRO_PORT} from the environment.
  if [[ -n "$MODE" ]]; then
    acquire_lock_file "$BUILD_LOCK" 3600 "build"
    export RCT_METRO_PORT="$METRO_PORT"
    mkdir -p "$LOG_DIR"
    local build_rc=0
    case "$MODE" in
      ios)
        record_app_identity
        if (( OWN_SIM )); then
          ensure_own_sim
          (cd "$REPO_ROOT/$MOBILE_DIR" && npx --no-install react-native run-ios --no-packager \
            --port "$METRO_PORT" --udid "$SIM_UDID") 2>&1 | tee -a "$LOG_DIR/build.log" || build_rc=$?
        else
          # Resolve and record the shared simulator we are about to build onto,
          # so `status --json` can name it and nobody has to guess with `booted`.
          local shared_udid; shared_udid="$(sim_udid_by_name "$SIM_NAME")"
          [[ -n "$shared_udid" ]] && { state_set_kv SIM_UDID "$shared_udid"; state_set_kv SIM_NAME "$SIM_NAME"; }
          (cd "$REPO_ROOT/$MOBILE_DIR" && npx --no-install react-native run-ios --no-packager \
            --port "$METRO_PORT" --simulator "$SIM_NAME") 2>&1 | tee -a "$LOG_DIR/build.log" || build_rc=$?
        fi ;;
      device)
        (cd "$REPO_ROOT/$MOBILE_DIR" && npx --no-install react-native run-ios --no-packager \
          --port "$METRO_PORT" --device) 2>&1 | tee -a "$LOG_DIR/build.log" || build_rc=$?
        ;;
      android)
        # run-android handles both -PreactNativeDevServerPort and adb reverse.
        (cd "$REPO_ROOT/$MOBILE_DIR" && npx --no-install react-native run-android --no-packager \
          --port "$METRO_PORT") 2>&1 | tee -a "$LOG_DIR/build.log" || build_rc=$?
        ;;
    esac
    if (( build_rc != 0 )); then
      printf '[dev.sh] %s build FAILED (exit %s) — see .dev/logs/build.log\n' "$MODE" "$build_rc" >&2
      exit "$build_rc"
    fi
    release_lock_file "$BUILD_LOCK"
  fi

  if (( TAIL_AFTER_UP )); then
    printf '[dev.sh] Following logs — Ctrl+C detaches (stack keeps running; ./dev.sh stop stops it).\n'
    exec tail -n 20 -F "$LOG_DIR/backend.log" "$LOG_DIR/web.log" "$LOG_DIR/metro.log"
  fi
}

# ─────────────────────────────── logs ───────────────────────────────

cmd_logs() {
  if [[ -z "$LOGS_SVC" ]]; then
    printf 'Which log? ./dev.sh logs <backend|web|metro|mobile|build> [-f]\n' >&2
    printf '  mobile = the app'\''s own console.log output (RN 0.76 keeps JS logs\n' >&2
    printf '           out of Metro; dev.sh streams them from Metro'\''s inspector)\n' >&2
    exit 2
  fi
  local f="$LOG_DIR/$LOGS_SVC.log"
  if [[ ! -f "$f" ]]; then
    printf 'No log yet: %s\n' "$f" >&2
    exit 1
  fi
  if (( FOLLOW )); then
    exec tail -n 100 -F "$f"
  fi
  exec tail -n 200 "$f"
}

# ─────────────────────────────── dispatch ───────────────────────────────

case "$VERB" in
  up)     cmd_up ;;
  status) cmd_status ;;
  stop)   cmd_stop ;;
  logs)   cmd_logs ;;
esac
