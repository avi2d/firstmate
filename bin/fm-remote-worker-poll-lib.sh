#!/usr/bin/env bash
# fm-remote-worker-poll-lib.sh - the watcher's per-poll remote-worker sweep.

# Sourced by bin/fm-watch.sh, never executed. Defines functions only; the
# sourcing watcher provides STATE, SCRIPT_DIR, POLL, and every helper the
# functions call.

# Print the fleet cache path for <route>, refreshing it with one bounded
# batched probe per FM_REMOTE_FLEET_CACHE_SECS. A failed probe leaves the
# previous cache untouched and fails, so a transport blip never reads as an
# empty fleet (an empty fleet would misreport every worker on the host
# missing). Only remote-worker fleet lines are consumed here; remote
# secondmates keep their own recovery path.
remote_worker_fleet() {  # <route>
  local route=$1 safe cache age
  [ -n "$route" ] || return 1
  FM_REMOTE_FLEET_BUDGET=${FM_REMOTE_FLEET_BUDGET:-60}
  case "$FM_REMOTE_FLEET_BUDGET" in ''|*[!0-9]*|0)
    echo "watcher: FM_REMOTE_FLEET_BUDGET must be a positive integer: $FM_REMOTE_FLEET_BUDGET" >&2; return 1 ;;
  esac
  FM_REMOTE_FLEET_CACHE_SECS=${FM_REMOTE_FLEET_CACHE_SECS:-${POLL:-30}}
  case "$FM_REMOTE_FLEET_CACHE_SECS" in ''|*[!0-9]*)
    echo "watcher: FM_REMOTE_FLEET_CACHE_SECS must be a non-negative integer: $FM_REMOTE_FLEET_CACHE_SECS" >&2; return 1 ;;
  esac
  safe=$(printf '%s' "$route" | tr -c 'A-Za-z0-9_.-' '_')
  [ -n "$safe" ] || return 1
  cache="$STATE/.fleet-$safe"
  if [ -f "$cache" ]; then
    age=$(age_of "$cache") || age=0
    case "$age" in ''|*[!0-9]*) age=0 ;; esac
    if [ "$age" -lt "$FM_REMOTE_FLEET_CACHE_SECS" ]; then printf '%s' "$cache"; return 0; fi
  fi
  if ! fm_run_timed "$FM_REMOTE_FLEET_BUDGET" "$SCRIPT_DIR/fm-on.sh" "$route" \
    fm-remote-worker-control.sh fleet < /dev/null > "$cache.tmp" 2>/dev/null; then
    rm -f -- "$cache.tmp"
    return 1
  fi
  mv -f -- "$cache.tmp" "$cache" || return 1
  printf '%s' "$cache"
}

# Print the oldest delivered epoch among <task>'s open pending-reply
# expectations, or fail when there is none. The host-side acknowledgement move
# is the only delivery signal, and these records are its observable main-side
# shadow, so an open delivered expectation is an unacked steer.
remote_worker_oldest_unacked() {  # <state-dir> <task>
  local state_dir=$1 task=$2 dir rec tid phase delivered oldest=
  dir=$(fm_pending_reply_dir "$state_dir") || return 1
  [ -d "$dir" ] || return 1
  for rec in "$dir"/*; do
    [ -f "$rec" ] || continue
    tid=$(fm_pending_reply_get "$rec" task_id)
    [ "$tid" = "$task" ] || continue
    phase=$(fm_pending_reply_get "$rec" phase)
    [ "$phase" != resolved ] || continue
    delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
    case "$delivered" in ''|*[!0-9]*) continue ;; esac
    if [ -z "$oldest" ] || [ "$delivered" -lt "$oldest" ]; then oldest=$delivered; fi
  done
  [ -n "$oldest" ] || return 1
  printf '%s' "$oldest"
}

# Edge-triggered endpoint-death surfacing for one remote worker. The host's
# own dead/missing verdict is positive evidence the endpoint is gone - unlike
# unknown, which never is - so its first appearance wakes firstmate once, and
# while it persists the marker holds the silence. Transport failure never
# reaches here: the caller continues without touching the marker.
remote_worker_note_agent() {  # <id> <host> <agent>
  local id=$1 host=$2 agent=$3 marker prev reason
  marker="$STATE/.remote-agent-$id"
  prev=$(cat "$marker" 2>/dev/null || true)
  [ "$agent" = "$prev" ] || printf '%s' "$agent" > "$marker"
  [ "$agent" = "$prev" ] && return 0
  case "$agent" in
    dead|missing)
      reason="stale: remote:$id (remote endpoint $agent on $host: the host reports the endpoint is gone - drive recovery on that host, or relaunch the worker through fm-control)"
      fm_wake_append stale "remote:$id" "$reason" || exit 1
      wake "$reason"
      ;;
  esac
  return 0
}

# Doorbell re-ring for one remote worker's unacked steers. Ring bookkeeping
# is main-side (.remote-ring-<id>); the host-side acknowledgement move clears
# the expectations this reads, which clears the bookkeeping on the next poll.
# FM_REMOTE_RING_MAX unacked rings escalate once, mirroring the local ladder.
remote_worker_rering() {  # <id> <host> <route> <now>
  local id=$1 host=$2 route=$3 now=$4 oldest ringf escf rings last doorbell ring_rc reason
  oldest=$(remote_worker_oldest_unacked "$STATE" "$id") || {
    rm -f -- "$STATE/.remote-ring-$id" "$STATE/.remote-ring-escalated-$id"
    return 0
  }
  FM_REMOTE_RING_GRACE=${FM_REMOTE_RING_GRACE:-90}
  case "$FM_REMOTE_RING_GRACE" in ''|*[!0-9]*|0)
    echo "watcher: FM_REMOTE_RING_GRACE must be a positive integer: $FM_REMOTE_RING_GRACE" >&2; return 1 ;;
  esac
  [ "$((now - oldest))" -ge "$FM_REMOTE_RING_GRACE" ] || return 0
  escf="$STATE/.remote-ring-escalated-$id"
  [ -e "$escf" ] && return 0
  FM_REMOTE_RING_MAX=${FM_REMOTE_RING_MAX:-3}
  case "$FM_REMOTE_RING_MAX" in ''|*[!0-9]*|0)
    echo "watcher: FM_REMOTE_RING_MAX must be a positive integer: $FM_REMOTE_RING_MAX" >&2; return 1 ;;
  esac
  ringf="$STATE/.remote-ring-$id"
  rings=$(sed -n 's/^rings=//p' "$ringf" 2>/dev/null | head -1)
  case "$rings" in ''|*[!0-9]*) rings=0 ;; esac
  last=$(sed -n 's/^last=//p' "$ringf" 2>/dev/null | head -1)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ "$((now - last))" -ge "$FM_REMOTE_RING_GRACE" ] || return 0
  doorbell=$(fm_task_inbox_doorbell_for "$id.inbox") || return 0
  FM_REMOTE_RING_BUDGET=${FM_REMOTE_RING_BUDGET:-60}
  case "$FM_REMOTE_RING_BUDGET" in ''|*[!0-9]*|0)
    echo "watcher: FM_REMOTE_RING_BUDGET must be a positive integer: $FM_REMOTE_RING_BUDGET" >&2; return 1 ;;
  esac
  ring_rc=0
  printf '%s' "$doorbell" | fm_run_timed "$FM_REMOTE_RING_BUDGET" "$SCRIPT_DIR/fm-on.sh" --stdin "$route" \
    fm-remote-worker-control.sh ring "$id" >/dev/null 2>&1 || ring_rc=$?
  case "$ring_rc" in
    0|1) rings=$((rings + 1)); printf 'rings=%s\nlast=%s\n' "$rings" "$now" > "$ringf" ;;
    3) remote_worker_note_agent "$id" "$host" dead; return 0 ;;
    *) return 0 ;;
  esac
  [ "$rings" -ge "$FM_REMOTE_RING_MAX" ] || return 0
  reason="stale: remote:$id (unread firstmate instruction: $rings doorbell delivery attempts to the worker on $host with no correlated report; inspect the worker)"
  fm_wake_append stale "remote:$id" "$reason" || exit 1
  printf 'rings=%s\nlast=%s\n' "$rings" "$now" > "$escf" || exit 1
  wake "$reason"
}

# One remote-worker sweep per poll: fleet agent-state edges plus doorbell
# re-rings for delivered-but-unacked steers, for every worker this home
# placed on another host. Unknown transport stays silent by design.
remote_worker_poll() {
  local meta id kind host route fleet line agent now lock
  now=$(date +%s) || return 0
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    kind=$(grep '^kind=' "$meta" 2>/dev/null | cut -d= -f2- || true)
    [ "$kind" != secondmate ] || continue
    host=$(grep '^remote_host=' "$meta" 2>/dev/null | cut -d= -f2- || true)
    [ -n "$host" ] || continue
    route=$(grep '^remote_route=' "$meta" 2>/dev/null | cut -d= -f2- || true)
    [ -n "$route" ] || continue
    id=${meta##*/}; id=${id%.meta}
    fleet=$(remote_worker_fleet "$route") || continue
    line=$(awk -F '	' -v id="$id" '$1 == id { line=$0 } END { if (line != "") print line }' "$fleet" 2>/dev/null || true)
    if [ -z "$line" ]; then agent=missing;
    else
      agent=$(printf '%s' "$line" | cut -f2)
      [ -n "$agent" ] || continue
    fi
    lock=$(fm_meta_lock_path "$meta") || continue
    fm_lock_try_acquire "$lock" || continue
    remote_worker_note_agent "$id" "$host" "$agent" || true
    case "$agent" in dead|missing) ;; *) remote_worker_rering "$id" "$host" "$route" "$now" || true ;; esac
    fm_lock_release "$lock"
  done
}
