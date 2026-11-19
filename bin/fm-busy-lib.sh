#!/usr/bin/env bash
# fm-busy-lib.sh - the ONE owner of firstmate's semantic busy-state contract.
#
# Missing, malformed, stale, or untrusted semantic data is UNKNOWN, never idle.
# Endpoint death is the only process-level override and yields dead, never busy.
# state/<id>.turn-ended files are wake notifications owned by the watcher, not
# current-state truth.
#
# Record file: state/<id>.busy-state - exactly one line, atomically replaced
# by bin/fm-busy-event.sh (the only writer):
#
#   v1 gen=<token> seq=<uint> state=<busy|idle|unknown> source=<token> event=<token> ts=<epoch>
#
# Gen sidecar: state/<id>.busy-gen - one token minted when the task's busy
# wiring is armed (fm-spawn, or a documented recovery re-arm). Every event
# must present the current gen; an event or record carrying any other gen is
# a stale incarnation and is rejected (written events) or classified unknown
# (read records). seq strictly increases per gen under the writer's lock.
#
# Trusted sources (fm_busy_sources_for_harness):
#   pi-ext           Pi/pi-signed per-task extension (agent_start/agent_settled)
#   fm-spawn         the launch-brief turn seeded at spawn
#   fm-interrupt     the unknown invalidation fm-control writes after an interrupt
#   fm-recovery      a documented recovery reset after relaunch
# Classifier-only sources (never written into a record):
#   endpoint-gone, herdr-native, missing, malformed, gen-mismatch,
#   source-mismatch, no-target, launch-prompt, launch-exec-failed
#
# Classification (fm_busy_classify): busy | idle | unknown | paused | dead,
# always with the producing source as the second token. Precedence:
#   1. dead endpoint (fm_busy_classify_live only) -> dead endpoint-gone
#   2. a valid, gen-matching, source-trusted record -> its state and source,
#      unless it is still the fm-spawn seed and the supplied tail shows the
#      shell's exec failure or Pi's project-trust dialog, which read unknown
#   3. no record at all: a native herdr busy verdict reads busy; native idle
#      is narrower than turn state and stays unknown missing
#   4. malformed, stale, or untrusted records -> unknown, never a fallback
#
# Sourcing: set -u and set -e safe; no subshell-unfriendly globals.

FM_BUSY_LIB_VERSION=v1

fm_busy_record_path() {  # <state-dir> <id>
  printf '%s/%s.busy-state' "$1" "$2"
}

fm_busy_gen_path() {  # <state-dir> <id>
  printf '%s/%s.busy-gen' "$1" "$2"
}

# Optional Pi model-stream contract. The busy writer owns every mutation under
# its incarnation lock. model-stream is active evidence; model-stream-order
# retains the latest request and active/closed phase after the marker is cleared.
#   order: v1 gen=<token> request=<positive uint> phase=<active|closed>
#   stream / model-progress: v1 gen=<token> request=<uint> rev=<uint> ts=<epoch>
# Requests strictly increase within a generation. Progress/close must match the
# open request; closed and older requests cannot reopen or refresh evidence.
# model-progress is separate from native progress and is read ONLY by opted-in
# watchers. Missing, malformed, locked, idle, foreign, or stale evidence conveys
# no model-phase observation, leaving the general busy bound applicable.
fm_busy_pi_stream_version_supported() {
  [ "${1:-}" = 1.2.0 ]
}

fm_busy_stream_seconds() {  # <configured seconds>; off/invalid prints 0
  local value=${1:-}
  case "$value" in ''|*[!0-9]*) printf '0'; return ;; esac
  [ "${#value}" -le 9 ] || { printf '0'; return; }
  printf '%s' "$((10#$value))"
}

fm_busy_stream_uint_valid() {
  case "${1:-}" in ''|0*|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 15 ]
}

fm_busy_stream_order_read() {  # <state-dir> <id>
  local line version gen request phase extra
  line=$(cat "$1/$2.model-stream-order" 2>/dev/null) || return 1
  read -r version gen request phase extra <<< "$line"
  [ "$version" = v1 ] && [ -z "$extra" ] || return 1
  gen=${gen#gen=} request=${request#request=} phase=${phase#phase=}
  fm_busy_token_valid "$gen" && fm_busy_stream_uint_valid "$request" || return 1
  case "$phase" in active|closed) : ;; *) return 1 ;; esac
  [ "$line" = "v1 gen=$gen request=$request phase=$phase" ] || return 1
  printf '%s %s %s' "$gen" "$request" "$phase"
}

fm_busy_stream_record_read() {  # <record path>
  local line version gen request rev ts extra
  line=$(cat "$1" 2>/dev/null) || return 1
  read -r version gen request rev ts extra <<< "$line"
  [ "$version" = v1 ] && [ -z "$extra" ] || return 1
  gen=${gen#gen=} request=${request#request=} rev=${rev#rev=} ts=${ts#ts=}
  fm_busy_token_valid "$gen" && fm_busy_stream_uint_valid "$request" &&
    fm_busy_stream_uint_valid "$rev" && fm_busy_stream_uint_valid "$ts" || return 1
  [ "$line" = "v1 gen=$gen request=$request rev=$rev ts=$ts" ] || return 1
  printf '%s %s %s %s' "$gen" "$request" "$rev" "$ts"
}

fm_busy_stream_read() {  # <state-dir> <id> <harness>; gen request rev ts
  local state=$1 id=$2 harness=$3 snapshot gen request rev ts order current
  case "$harness" in pi|pi-signed) : ;; *) return 1 ;; esac
  [ ! -e "$state/$id.busy-state.lock" ] || return 1
  current=$(fm_busy_current_gen "$state" "$id") || return 1
  order=$(fm_busy_stream_order_read "$state" "$id") || return 1
  snapshot=$(fm_busy_stream_record_read "$state/$id.model-stream") || return 1
  read -r gen request rev ts <<< "$snapshot"
  [ "$gen" = "$current" ] && [ "$order" = "$gen $request active" ] || return 1
  case "$(fm_busy_record_read "$state" "$id")" in 'busy pi-ext '*) : ;; *) return 1 ;; esac
  [ ! -e "$state/$id.busy-state.lock" ] &&
    [ "$(fm_busy_current_gen "$state" "$id")" = "$current" ] &&
    [ "$(fm_busy_stream_order_read "$state" "$id")" = "$order" ] &&
    [ "$(fm_busy_stream_record_read "$state/$id.model-stream")" = "$snapshot" ] || return 1
  printf '%s' "$snapshot"
}

fm_busy_model_progress_ts() {  # <state-dir> <id> <harness>
  local snapshot gen request rev ts current
  case "$3" in pi|pi-signed) : ;; *) return 1 ;; esac
  [ ! -e "$1/$2.busy-state.lock" ] || return 1
  current=$(fm_busy_current_gen "$1" "$2") || return 1
  snapshot=$(fm_busy_stream_record_read "$1/$2.model-progress") || return 1
  read -r gen request rev ts <<< "$snapshot"
  [ "$gen" = "$current" ] && [ ! -e "$1/$2.busy-state.lock" ] &&
    [ "$(fm_busy_current_gen "$1" "$2")" = "$current" ] || return 1
  printf '%s' "$ts"
}

# fm_busy_token_valid: conservative token charset shared by gen, source, and
# event fields. Anything else is malformed.
fm_busy_token_valid() {  # <value>
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# fm_busy_current_gen: the task's armed gen token, or failure when the busy
# contract has never been armed for this task.
fm_busy_current_gen() {  # <state-dir> <id>
  local gen_file gen
  gen_file=$(fm_busy_gen_path "$1" "$2")
  [ -f "$gen_file" ] || return 1
  IFS= read -r gen < "$gen_file" 2>/dev/null || gen=
  fm_busy_token_valid "$gen" || return 1
  printf '%s' "$gen"
}

# fm_busy_sources_for_harness: the semantic sources trusted to classify a
# task recorded with <harness>. One line, space-separated, possibly empty.
# A source listed here without a writer that can clear it would seed a busy
# record nothing could ever settle.
fm_busy_sources_for_harness() {  # <harness>
  case "${1:-}" in
    pi|pi-signed) printf 'pi-ext fm-spawn fm-interrupt fm-recovery' ;;
    *) printf '' ;;
  esac
}

fm_busy_source_trusted() {  # <harness> <source>
  local trusted
  trusted=$(fm_busy_sources_for_harness "$1")
  case " $trusted " in
    *" $2 "*) return 0 ;;
  esac
  return 1
}

# fm_busy_record_read: parse and validate state/<id>.busy-state against the
# armed gen. Prints "<state> <source> <event> <seq> <reset> <ts>" for a valid record.
# Non-zero returns name the reason on stdout instead:
#   missing      no record file (or no armed gen and no record)
#   malformed    unparseable line, bad tokens, or a missing armed gen for an
#                existing record
#   gen-mismatch a record from a stale incarnation
fm_busy_record_read() {  # <state-dir> <id>
  local state=$1 id=$2 rec gen line extra ver f
  local r_gen='' r_seq='' r_state='' r_source='' r_event='' r_ts='' r_reset=0
  rec=$(fm_busy_record_path "$state" "$id")
  if [ ! -f "$rec" ]; then
    printf 'missing'
    return 1
  fi
  if ! gen=$(fm_busy_current_gen "$state" "$id"); then
    # A record without an armed gen has no incarnation to bind to.
    printf 'malformed'
    return 1
  fi
  # shellcheck disable=SC2034 # extra exists only to prove the record is one line
  { IFS= read -r line && ! IFS= read -r extra; } < "$rec" 2>/dev/null || {
    printf 'malformed'
    return 1
  }
  # `read -a` rather than `set --`: it never glob-expands a field and never
  # touches the caller's positional parameters or shell options.
  local -a fields
  IFS=' ' read -r -a fields <<< "$line"
  ver=${fields[0]:-}
  [ "$ver" = "$FM_BUSY_LIB_VERSION" ] || { printf 'malformed'; return 1; }
  for f in "${fields[@]:1}"; do
    case "$f" in
      gen=*) r_gen=${f#gen=} ;;
      seq=*) r_seq=${f#seq=} ;;
      state=*) r_state=${f#state=} ;;
      source=*) r_source=${f#source=} ;;
      event=*) r_event=${f#event=} ;;
      ts=*) r_ts=${f#ts=} ;;
      reset=*) r_reset=${f#reset=} ;;
      *) printf 'malformed'; return 1 ;;
    esac
  done
  fm_busy_token_valid "$r_gen" || { printf 'malformed'; return 1; }
  fm_busy_token_valid "$r_source" || { printf 'malformed'; return 1; }
  fm_busy_token_valid "$r_event" || { printf 'malformed'; return 1; }
  case "$r_seq" in ''|*[!0-9]*) printf 'malformed'; return 1 ;; esac
  case "$r_ts" in ''|*[!0-9]*) printf 'malformed'; return 1 ;; esac
  case "$r_reset" in ''|*[!0-9]*) printf 'malformed'; return 1 ;; esac
  case "$r_state" in busy|idle|unknown) : ;; *) printf 'malformed'; return 1 ;; esac
  if [ "$r_gen" != "$gen" ]; then
    printf 'gen-mismatch'
    return 1
  fi
  printf '%s %s %s %s %s %s' "$r_state" "$r_source" "$r_event" "$r_seq" "$r_reset" "$r_ts"
}

# fm_busy_pi_launch_prompt_tail: Pi's project-trust dialog. Live-verified on
# pi 0.86.1 (2026-09-22) in a fresh untrusted worktree carrying a project-local
# .pi/extensions/ file (the shape a real ship/scout spawn always launches
# into): the rendered heading is "Trust project folder?" and its declining
# option is literally "Do not trust". An initial guess sourced only from the
# installed binary's UI strings ("Project trust", the internal panel-title
# component name, not this dialog's own rendered heading) was proven wrong by
# that live run and never matched the real screen - which is exactly why this
# class of check must be proven end to end rather than read off strings or a
# name. Matching BOTH the heading and "Do not trust" keeps this from firing on
# a worker's own prose that happens to use the common word "trust" alone.
fm_busy_pi_launch_prompt_tail() {
  local buf
  buf=$(cat)
  printf '%s' "$buf" | grep -qiE "${FM_BUSY_PI_LAUNCH_PROMPT_REGEX:-Trust project folder\\?}" \
    && printf '%s' "$buf" | grep -qiE 'Do not trust'
}

fm_busy_launch_prompt_parked() {  # <harness>, tail on stdin
  case "${1:-}" in
    pi | pi-signed) fm_busy_pi_launch_prompt_tail ;;
    *) return 1 ;;
  esac
}

# The shell printed its own exec failure naming this harness, so no agent runs behind the seed.
fm_busy_launch_exec_failed() {  # <harness>, tail on stdin
  local harness=${1-} buf
  [ -n "$harness" ] || return 1
  buf=$(cat)
  printf '%s' "$buf" | grep -Fq -- "$harness" || return 1
  printf '%s' "$buf" | grep -qiE 'command not found|No such file or directory|Unknown command'
}

fm_busy_provider_wait_until() {  # <state-dir> <id> -> active wait's clearing epoch
  local record state source event reset ts until now
  record=$(fm_busy_record_read "$1" "$2") || return 1
  IFS=' ' read -r state source event _ reset ts <<EOF
$record
EOF
  [ "$state" = idle ] && [ "$source" = pi-ext ] && [ "$event" = provider-limit ] || return 1
  if [ "$reset" -gt 0 ]; then until=$reset; else until=$((ts + 1800)); fi
  now=$(date +%s)
  [ "$now" -lt "$until" ] || return 1
  printf '%s' "$until"
}

# fm_busy_classify: semantic classification for a task whose endpoint the
# caller has already established as present. Prints "<verdict> <source>".
# Never probes process state. <tail40> is optional pre-captured plain output
# for the launch-prompt backstop, which is skipped without it.
fm_busy_classify() {  # <backend> <target> <harness> <id> <state-dir> [tail40]
  local backend=$1 target=$2 harness=$3 id=$4 state=$5 tail40=${6-}
  local out rc r_state r_source r_event native
  out=$(fm_busy_record_read "$state" "$id") && rc=0 || rc=$?
  if [ "$rc" = 0 ]; then
    r_state=${out%% *}
    out=${out#* }
    r_source=${out%% *}
    out=${out#* }
    r_event=${out%% *}
    if ! fm_busy_source_trusted "$harness" "$r_source"; then
      printf 'unknown source-mismatch'
    elif [ "$r_event" = provider-limit ] && fm_busy_provider_wait_until "$state" "$id" >/dev/null; then
      printf 'paused %s' "$r_source"
    elif [ "$r_state" = busy ] && [ "$r_source" = fm-spawn ] && [ -n "$tail40" ] \
      && printf '%s' "$tail40" | fm_busy_launch_exec_failed "$harness"; then
      printf 'unknown launch-exec-failed'
    elif [ "$r_state" = busy ] && [ "$r_source" = fm-spawn ] && [ -n "$tail40" ] \
      && printf '%s' "$tail40" | fm_busy_launch_prompt_parked "$harness"; then
      printf 'unknown launch-prompt'
    else
      printf '%s %s' "$r_state" "$r_source"
    fi
    return 0
  fi
  case "$out" in
    malformed|gen-mismatch)
      printf 'unknown %s' "$out"
      return 0
      ;;
  esac
  if [ "$backend" = herdr ] && command -v fm_backend_busy_state >/dev/null 2>&1; then
    native=$(fm_backend_busy_state "$backend" "$target" 2>/dev/null || true)
    if [ "$native" = busy ]; then
      printf 'busy herdr-native'
      return 0
    fi
  fi
  printf 'unknown missing'
}

# fm_busy_classify_live: fm_busy_classify behind the one process-level
# override - a gone endpoint is dead, never busy. Requires fm-backend.sh to
# be sourced for fm_backend_target_exists.
fm_busy_classify_live() {  # <backend> <target> <harness> <id> <state-dir> [expected-label]
  local backend=$1 target=$2 harness=$3 id=$4 state=$5 label=${6-}
  if [ -z "$target" ]; then
    printf 'unknown no-target'
    return 0
  fi
  if ! fm_backend_target_exists "$backend" "$target" "$label" 2>/dev/null; then
    printf 'dead endpoint-gone'
    return 0
  fi
  fm_busy_classify "$backend" "$target" "$harness" "$id" "$state"
}

# fm_busy_classify_meta: classify a task from its recorded metadata, so every
# consumer resolves backend, target, and harness the same way instead of
# re-deriving them. Requires fm-backend.sh to be sourced. <tail40> is
# optional pre-captured plain output for the launch-prompt backstop.
fm_busy_classify_meta() {  # <meta-file> <id> <state-dir> [tail40]
  local meta=$1 id=$2 state=$3 tail40=${4-} backend target harness
  [ -f "$meta" ] || { printf 'unknown missing'; return 0; }
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  harness=$(fm_meta_get "$meta" harness)
  if [ -z "$target" ]; then
    printf 'unknown no-target'
    return 0
  fi
  fm_busy_classify "$backend" "$target" "$harness" "$id" "$state" "$tail40"
}

# fm_busy_is_busy: boolean activity guard. Unknown, idle, paused, and dead
# return 1.
fm_busy_is_busy() {  # <backend> <target> <harness> <id> <state-dir> [tail40]
  local verdict
  verdict=$(fm_busy_classify "$@")
  case "$verdict" in
    busy\ *) return 0 ;;
    *) return 1 ;;
  esac
}
