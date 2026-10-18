#!/usr/bin/env bash
# fm-sandbox-quiet.sh: stop nono's per-session debug system-log stream.
set -u

# nono 0.80.0 spawns one /usr/bin/log stream child per run to attribute
# macOS Seatbelt denials to the session. Each stream holds a system-wide
# debug subscription, so every sandboxed worker adds a share of diagnosticd
# load while enforcement itself stays in the kernel profile. Killing the
# stream keeps the sandbox: denials are still denied, but the post-run
# footer can no longer attribute them and falls back to its no-denials
# text. This helper only stops streams it can prove belong to a nono
# session under one of the given root pids; anything else is left running.

FM_SANDBOX_QUIET_WAIT_DEFAULT=30
FM_SANDBOX_QUIET_POLL=2
FM_SANDBOX_QUIET_KILL_GRACE=3

fm_sandbox_quiet_help() {
  printf '%s\n' "Usage: fm-sandbox-quiet.sh [--wait <secs>] <root-pid>..."
  printf '%s\n' "       Stop nono sandbox log-stream processes under the given roots."
  printf '%s\n' "       Waits up to --wait seconds (default $FM_SANDBOX_QUIET_WAIT_DEFAULT) for one to appear."
}

fm_sandbox_quiet_ps() {
  LC_ALL=C ps -axo pid=,ppid=,command= 2>/dev/null || return 1
}

fm_sandbox_quiet_ancestor_has_root() {
  local pid=$1 root=$2 depth=0 ppid
  while [ "$pid" -gt 1 ] && [ "$depth" -lt 64 ]; do
    [ "$pid" = "$root" ] && return 0
    ppid=$(LC_ALL=C ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]') || return 1
    case "$ppid" in ''|*[!0-9]*) return 1 ;; esac
    pid=$ppid
    depth=$((depth + 1))
  done
  [ "$pid" = "$root" ]
}

fm_sandbox_quiet_wait_gone() {
  local pid=$1 waited=0 stat
  while kill -0 "$pid" 2>/dev/null; do
    stat=$(LC_ALL=C ps -o stat= -p "$pid" 2>/dev/null | tr -d "[:space:]") || return 0
    case "$stat" in *Z*) return 0 ;; esac
    [ "$waited" -lt "$FM_SANDBOX_QUIET_KILL_GRACE" ] || kill -9 "$pid" 2>/dev/null || true
    [ "$waited" -lt $((FM_SANDBOX_QUIET_KILL_GRACE + 2)) ] || return 1
    sleep 1
    waited=$((waited + 1))
  done
  return 0
}

fm_sandbox_quiet_pass_once() {
  local root=$1 killed=0 line pid ppid args parent_args parent_base stat
  while IFS= read -r line; do
    read -r pid ppid args <<< "$line" || continue
    [ -n "${args:-}" ] || continue
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    case "$ppid" in ''|*[!0-9]*|0|1) continue ;; esac
    case "$args" in
    *"/usr/bin/log stream"*'senderImagePath CONTAINS "/Sandbox"'*) ;;
    *) continue ;;
    esac
    [ "$pid" != "$$" ] || continue
    parent_args=$(LC_ALL=C ps -o command= -p "$ppid" 2>/dev/null) || continue
    read -r parent_base _ <<< "$parent_args" || continue
    parent_base=${parent_base##*/}
    [ "$parent_base" = nono ] || continue
    stat=$(LC_ALL=C ps -o stat= -p "$pid" 2>/dev/null | tr -d "[:space:]") || continue
    case "$stat" in *Z*) continue ;; esac
    fm_sandbox_quiet_ancestor_has_root "$ppid" "$root" || continue
    kill "$pid" 2>/dev/null || continue
    if fm_sandbox_quiet_wait_gone "$pid"; then
      printf 'quieted %s (nono %s under root %s)\n' "$pid" "$ppid" "$root"
      killed=$((killed + 1))
    fi
  done <<EOF
$(fm_sandbox_quiet_ps)
EOF
  [ "$killed" -gt 0 ]
}

WAIT=$FM_SANDBOX_QUIET_WAIT_DEFAULT
ROOTS=
while [ $# -gt 0 ]; do
  case "${1:-}" in
  -h|--help) fm_sandbox_quiet_help; exit 0 ;;
  --wait)
    WAIT=${2:-}
    case "$WAIT" in ''|*[!0-9]*) echo "error: --wait needs a non-negative integer" >&2; exit 2 ;; esac
    shift 2 ;;
  --) shift; break ;;
  -*) echo "error: unknown flag $1" >&2; exit 2 ;;
  *) ROOTS="$ROOTS $1"; shift ;;
  esac
done
[ -n "$ROOTS" ] || { echo "error: needs at least one root pid" >&2; exit 2; }
for R in $ROOTS; do
  case "$R" in ''|*[!0-9]*|0|1) echo "error: refusing root pid '$R'" >&2; exit 2 ;; esac
  if [ "$R" = "$$" ]; then echo "error: refusing own pid as root" >&2; exit 2; fi
done
command -v ps >/dev/null 2>&1 || { echo "error: ps not found" >&2; exit 2; }

deadline=$(( $(date +%s) + WAIT ))
while :; do
  for R in $ROOTS; do
    if fm_sandbox_quiet_pass_once "$R"; then exit 0; fi
  done
  [ "$(date +%s)" -lt "$deadline" ] || break
  sleep "$FM_SANDBOX_QUIET_POLL"
done
exit 0
