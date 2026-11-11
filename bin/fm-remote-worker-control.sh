#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_HOME=${FM_HOME:?FM_HOME is required}

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-pane-hash-lib.sh
. "$SCRIPT_DIR/fm-pane-hash-lib.sh"
# shellcheck source=bin/fm-mac-load-lib.sh
. "$SCRIPT_DIR/fm-mac-load-lib.sh"
# shellcheck source=bin/fm-project-capacity-lib.sh
. "$SCRIPT_DIR/fm-project-capacity-lib.sh"
# shellcheck source=bin/fm-worker-account-lib.sh
. "$SCRIPT_DIR/fm-worker-account-lib.sh"
# bin/fm-task-inbox-lib.sh creates $FM_HOME/state when sourced, so the two
# verbs that write steering records source it lazily only after the worker
# record they write beside is proven to exist.

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
validate_home() {
  [ -d "$TARGET_HOME" ] && [ ! -L "$TARGET_HOME" ] || die "execution home is unavailable or unsafe"
  [ -f "$TARGET_HOME/.fm-exec-home" ] && [ ! -L "$TARGET_HOME/.fm-exec-home" ] || die "home is not a seeded execution home"
}

execution_session() {
  local session=fm-remote
  if [ -e "$TARGET_HOME/config/herdr-session" ] || [ -L "$TARGET_HOME/config/herdr-session" ]; then
    [ -f "$TARGET_HOME/config/herdr-session" ] && [ ! -L "$TARGET_HOME/config/herdr-session" ] || die "unsafe execution home session"
    session=$(tr -d '[:space:]' < "$TARGET_HOME/config/herdr-session")
  fi
  case "$session" in ''|*[!A-Za-z0-9._-]*) die "invalid execution home session" ;; esac
  printf '%s\n' "$session"
}

endpoint() {
  local id=$1 session
  fm_backend_validate_task_endpoint "$TARGET_HOME/state/$id.meta" "$id" || die "invalid worker endpoint"
  if [ "$FM_BACKEND_VALIDATED_BACKEND" = herdr ]; then
    session=$(execution_session)
    case "$FM_BACKEND_VALIDATED_TARGET" in "$session":?*) ;; *) die "worker endpoint is outside the execution home session" ;; esac
  fi
}

worker_endpoint_require() {  # <id>; sets WORKER_BACKEND/WORKER_TARGET
  local id=$1
  case "$id" in ''|*[!A-Za-z0-9._-]*|*..*) die "invalid task id" ;; esac
  validate_home
  [ -f "$TARGET_HOME/state/$id.meta" ] && [ ! -L "$TARGET_HOME/state/$id.meta" ] || die "no worker $id in execution home"
  [ -z "$(fm_meta_get "$TARGET_HOME/state/$id.meta" remote_host)" ] && [ -z "$(fm_meta_get "$TARGET_HOME/state/$id.meta" remote_route)" ] \
    || die "worker $id is itself remotely placed; refusing a nested hop"
  endpoint "$id"
  WORKER_BACKEND=$FM_BACKEND_VALIDATED_BACKEND
  WORKER_TARGET=$FM_BACKEND_VALIDATED_TARGET
}

worker_send_stdin() {  # <id> [fire-and-forget]; message on stdin
  local id=$1 delivery_mode=${2:-} message rec ring_rc=0 meta meta_lock
  [ -z "$delivery_mode" ] || [ "$delivery_mode" = fire-and-forget ] || die "invalid send delivery mode"
  meta="$TARGET_HOME/state/$id.meta"
  worker_endpoint_require "$id"
  IFS= read -r -d '' message < /dev/stdin || :
  [ -n "${message//[[:space:]]/}" ] || die "remote steer message must be nonempty"
  # shellcheck source=bin/fm-task-inbox-lib.sh
  . "$SCRIPT_DIR/fm-task-inbox-lib.sh"
  meta_lock=$(fm_meta_lock_path "$meta") || die "worker metadata lock path is invalid"
  fm_task_inbox_lock_acquire "$meta_lock" \
    || die "worker endpoint metadata could not be locked for final delivery validation"
  if ! endpoint "$id"; then
    fm_lock_release "$meta_lock"
    die "invalid worker endpoint"
  fi
  if ! rec=$(fm_task_inbox_write_idempotent "$TARGET_HOME/state" "$id" "$message" "$delivery_mode"); then
    fm_lock_release "$meta_lock"
    die "steering-inbox record could not be written under $TARGET_HOME/state/$id.inbox"
  fi
  fm_lock_release "$meta_lock"
  case "$rec" in
    */handled/*)
      printf 'notice: this steer was already delivered and acknowledged at %s; nothing re-rung\n' "$rec" >&2
      return 0
      ;;
  esac
  fm_task_inbox_ring "$WORKER_BACKEND" "$WORKER_TARGET" "$rec" "fm-$id" || ring_rc=$?
  case "$ring_rc" in
    1) printf 'notice: doorbell skipped (composer visibly holds pending text); the steer is durably recorded at %s\n' "$rec" >&2 ;;
    2) printf 'notice: doorbell did not reach %s; the steer is durably recorded at %s\n' "$WORKER_TARGET" "$rec" >&2 ;;
    3) printf 'notice: doorbell not typed because the agent in %s has exited; the steer is durably recorded at %s for recovery\n' "$WORKER_TARGET" "$rec" >&2 ;;
  esac
}

worker_key() {  # <id> <key>
  worker_endpoint_require "$1"
  FM_HOME="$TARGET_HOME" "$SCRIPT_DIR/fm-send.sh" "$1" --key "$2"
}

worker_ring() {  # <id> [expected-label]; doorbell line on stdin; prints ring=<rc>
  local id=$1 label=${2:-} line ring_rc=0
  meta="$TARGET_HOME/state/$id.meta"
  worker_endpoint_require "$id"
  IFS= read -r -d '' line < /dev/stdin || :
  [ -n "${line//[[:space:]]/}" ] || die "ring doorbell line must be nonempty"
  # shellcheck source=bin/fm-task-inbox-lib.sh
  . "$SCRIPT_DIR/fm-task-inbox-lib.sh"
  fm_task_inbox_ring_line "$WORKER_BACKEND" "$WORKER_TARGET" "$line" "$label" || ring_rc=$?
  printf 'ring=%s\n' "$ring_rc"
}

worker_control_hop() {  # <id> <verb> [control args]
  local id=$1 verb=$2 session
  shift 2
  worker_endpoint_require "$id"
  if [ "$WORKER_BACKEND" = herdr ]; then
    session=$(execution_session)
    HERDR_SESSION="$session" FM_HOME="$TARGET_HOME" "$SCRIPT_DIR/fm-control.sh" "$id" "$verb" "$@"
  else
    FM_HOME="$TARGET_HOME" "$SCRIPT_DIR/fm-control.sh" "$id" "$verb" "$@"
  fi
  route "$id"
}

# A missing record answers teardown=absent, so a rerun after a lost reply converges.
worker_teardown() {  # <id> [--force]
  local id=$1 force=${2:-} rc=0
  local -a args
  case "$id" in ''|*[!A-Za-z0-9._-]*|*..*) die "invalid task id" ;; esac
  validate_home
  if [ ! -e "$TARGET_HOME/state/$id.meta" ] && [ ! -L "$TARGET_HOME/state/$id.meta" ]; then
    printf 'teardown=absent\n'
    return 0
  fi
  worker_endpoint_require "$id"
  args=("$id")
  [ -z "$force" ] || args+=(--force)
  if [ "$WORKER_BACKEND" = herdr ]; then
    HERDR_SESSION="$(execution_session)" FM_HOME="$TARGET_HOME" "$SCRIPT_DIR/fm-teardown.sh" "${args[@]}" >&2 || rc=$?
  else
    FM_HOME="$TARGET_HOME" "$SCRIPT_DIR/fm-teardown.sh" "${args[@]}" >&2 || rc=$?
  fi
  case "$rc" in
    0|4) printf 'teardown=done rc=%s\n' "$rc" ;;
  esac
  return "$rc"
}

worker_crew_state() {  # <id>
  worker_endpoint_require "$1"
  FM_HOME="$TARGET_HOME" "$SCRIPT_DIR/fm-crew-state.sh" "$1"
}

worker_fleet() {
  local meta id backend target harness tail busy hash agent_state
  validate_home
  for meta in "$TARGET_HOME/state/"*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=$(basename "$meta" .meta)
    case "$id" in ''|*[!A-Za-z0-9._-]*|*..*) continue ;; esac
    if ! fm_backend_validate_task_endpoint "$meta" "$id" 2>/dev/null; then
      printf '%s\tunknown\tunknown\t-\n' "$id"
      continue
    fi
    backend=$FM_BACKEND_VALIDATED_BACKEND
    target=$FM_BACKEND_VALIDATED_TARGET
    harness=$(fm_meta_get "$meta" harness)
    agent_state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || true)
    case "$agent_state" in alive|dead|missing|ambiguous|unreadable|unverified) ;; *) agent_state=unknown ;; esac
    if tail=$(fm_backend_capture "$backend" "$target" 40 "fm-$id" 2>/dev/null | head -c 65536); then
      [ "${PIPESTATUS[0]}" -eq 0 ] || tail=
    else
      tail=
    fi
    busy=$(fm_busy_classify_meta "$meta" "$id" "$TARGET_HOME/state" "$tail" 2>/dev/null || true)
    busy=${busy%% *}
    case "$busy" in busy|idle) ;; *) busy=unknown ;; esac
    if [ -n "$tail" ]; then
      hash=$(fm_pane_stale_hash "$backend" "$harness" "$target" "fm-$id" "$tail" 2>/dev/null || true)
      case "$hash" in ''|*[!0-9a-f]*) hash=- ;; esac
    else
      hash=-
    fi
    printf '%s\t%s\t%s\t%s\n' "$id" "$agent_state" "$busy" "$hash"
  done
}

worker_done_gate() {  # <id> <done line>
  local id=$1 line=$2 meta state wt project kind mode
  [ -n "${line//[[:space:]]/}" ] || die "done line must be nonempty"
  worker_endpoint_require "$id"
  state="$TARGET_HOME/state"
  meta="$state/$id.meta"
  wt=$(fm_meta_get "$meta" worktree)
  project=$(fm_meta_get "$meta" project)
  kind=$(fm_meta_get "$meta" kind)
  mode=$(fm_meta_get "$meta" mode)
  if refusal=$(fm_dod_accept_ship_done "$kind" "$mode" "$wt" "$project" "$line" "$state" "$id" "$meta"); then
    printf 'ok\n'
  else
    [ -n "$refusal" ] || refusal='ship done gates did not pass'
    printf 'refused: %s\n' "$refusal"
    return 1
  fi
}

# Defers on every heavy-worker gate the host-local fm-spawn.sh applies, because
# a deferral met only at launch arrives after the parent published its record.
admit_heavy_gates() {  # <id>
  local id=$1 config loadavg
  # shellcheck source=bin/fm-secondmate-registry-lib.sh
  . "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  config=$(fm_project_capacity_config_dir "$TARGET_HOME" "$TARGET_HOME/config") || die "the root home that declares host limits cannot be resolved"
  if fm_mac_load_gate_active; then
    fm_mac_load_config "$config" || die "host load declaration is unreadable ($FM_MAC_LOAD_ERROR)"
    fm_mac_heavy_count "$TARGET_HOME/state" "$id" || die "host task records cannot all be read to count heavy workers ($FM_MAC_LOAD_ERROR)"
    if [ "$FM_MAC_HEAVY_COUNT" -ge "$FM_MAC_HEAVY_LIMIT" ]; then
      printf 'defer: host already runs %s heavy worker(s) at its limit %s (%s)\n' "$FM_MAC_HEAVY_COUNT" "$FM_MAC_HEAVY_LIMIT" "$FM_MAC_HEAVY_IDS"
      return "$FM_MAC_LOAD_DEFER_EXIT"
    fi
  fi
  if fm_linux_load_gate_active "$config"; then
    fm_linux_load_config "$config" || die "host load declaration is unreadable ($FM_LINUX_LOAD_ERROR)"
    loadavg=$(fm_mac_loadavg_5min) || die "host five-minute load average cannot be read; refusing a heavy start rather than guessing it"
    if fm_linux_load_high "$loadavg"; then
      printf 'defer: host five-minute load average is %s (limit %s)\n' "$loadavg" "$FM_LINUX_LOAD_LIMIT"
      return "$FM_LINUX_LOAD_DEFER_EXIT"
    fi
    fm_linux_heavy_count "$TARGET_HOME/state" "$id" "$config" || die "host task records cannot all be read to count heavy workers ($FM_LINUX_LOAD_ERROR)"
    if [ "$FM_LINUX_HEAVY_COUNT" -ge "$FM_LINUX_HEAVY_LIMIT" ]; then
      printf 'defer: host already runs %s heavy worker(s) at its limit %s (%s)\n' "$FM_LINUX_HEAVY_COUNT" "$FM_LINUX_HEAVY_LIMIT" "$FM_LINUX_HEAVY_IDS"
      return "$FM_LINUX_LOAD_DEFER_EXIT"
    fi
  fi
}

worker_admit() {  # <id> <project>
  local id=$1 project=$2 config room_config holders limit loadavg state meta kind pname sib
  local -a states
  case "$id" in ''|*[!A-Za-z0-9._-]*|*..*) die "invalid task id" ;; esac
  case "$project" in ''|.|-*|*[!A-Za-z0-9._-]*|*..*) die "invalid project name" ;; esac
  validate_home
  config="$TARGET_HOME/config"
  if fm_project_capacity_lookup "$config" "$project"; then
    limit=$FM_PROJECT_CAPACITY
  else
    [ -z "${FM_PROJECT_CAPACITY_ERROR:-}" ] || die "host capacity declaration is unreadable ($FM_PROJECT_CAPACITY_ERROR)"
    limit=
  fi
  states=("$TARGET_HOME/state")
  if ! fm_linux_sibling_homes "$config"; then
    die "host sibling declaration is unreadable ($FM_LINUX_SIBLING_ERROR)"
  fi
  for sib in ${FM_LINUX_SIBLINGS[@]+"${FM_LINUX_SIBLINGS[@]}"}; do
    states+=("$sib/state")
  done
  holders=0
  for state in "${states[@]}"; do
    [ -d "$state" ] || [ ! -e "$state" ] || die "host sibling state is unavailable: $state"
    [ -d "$state" ] || continue
    for meta in "$state/"*.meta; do
      [ -f "$meta" ] && [ ! -L "$meta" ] || continue
      [ "$meta" != "$state/$id.meta" ] || continue
      kind=$(fm_meta_get "$meta" kind 2>/dev/null || true)
      [ "$kind" != secondmate ] || continue
      [ -z "$(fm_meta_get "$meta" pr 2>/dev/null || true)" ] || continue
      pname=$(fm_meta_get "$meta" project 2>/dev/null || true)
      pname=${pname##*/}
      [ "$pname" = "$project" ] || continue
      holders=$((holders + 1))
    done
  done
  if [ -n "$limit" ] && [ "$holders" -ge "$limit" ]; then
    printf 'defer: host already holds %s %s worker(s) at its declared limit %s\n' "$holders" "$project" "$limit"
    return "$FM_PROJECT_CAPACITY_DEFER_EXIT"
  fi
  if ! fm_mac_load_config "$config"; then
    die "host load declaration is unreadable ($FM_MAC_LOAD_ERROR)"
  fi
  if ! loadavg=$(fm_mac_loadavg_5min); then
    die "host five-minute load average cannot be read; refusing a heavy start rather than guessing it"
  fi
  if fm_mac_load_high "$loadavg"; then
    printf 'defer: host five-minute load average is %s (limit %s)\n' "$loadavg" "$FM_MAC_LOAD_LIMIT"
    return "$FM_MAC_LOAD_DEFER_EXIT"
  fi
  admit_heavy_gates "$id" || return $?
  room_config=$(fm_project_capacity_config_dir "$TARGET_HOME" "$config") || die "the root home that declares host limits cannot be resolved"
  fm_host_room "$TARGET_HOME/state" "$id" "$room_config" || die "host room cannot be read ($FM_HOST_ROOM_ERROR)"
  printf 'admit project=%s holders=%s load=%s load_limit=%s heavy_free=%s\n' "$project" "${holders}${limit:+/$limit}" "$loadavg" "$FM_HOST_ROOM_LOAD_LIMIT" "$FM_HOST_ROOM_FREE"
}

route() {
  local id=$1 meta="$TARGET_HOME/state/$1.meta" key value
  validate_home
  endpoint "$id"
  printf 'schema=fm-remote-worker-control.v1\nbackend=%s\ntarget=%s\n' "$FM_BACKEND_VALIDATED_BACKEND" "$FM_BACKEND_VALIDATED_TARGET"
  for key in kind harness model effort claude_account worktree project herdr_session; do
    value=$(fm_meta_get "$meta" "$key")
    [ -z "$value" ] || printf '%s=%s\n' "$key" "$value"
  done
}

# Mutates nothing, so the parent asks before it publishes a task record.
claude_account_check() {  # <harness> <model|-> <account>
  local harness=$1 model=$2 account=$3
  validate_home
  [ "$model" != - ] || model=
  fm_claude_account_select "$harness" "$TARGET_HOME/config" "$model" "$account" >/dev/null || exit 1
  printf 'claude_account=%s\n' "$account"
}

launch() {
  local id=$1 project=$2 kind=$3 mode=$4 yolo=$5 prefix=$6 base=$7 harness=$8 model=$9
  shift 9
  local effort=$1 backend=$2 account=${3:-} temp session out rc contract token forge=none shape='' pr=auto data_existed=0
  local -a brief_args spawn_args contract_fields
  validate_home
  case "$id" in ''|.|-*|*[!A-Za-z0-9._-]*|*..*) die "invalid task or project id" ;; esac
  case "$project" in ''|.|-*|*[!A-Za-z0-9._-]*|*..*) die "invalid task or project id" ;; esac
  [ -d "$TARGET_HOME/projects/$project" ] && [ ! -L "$TARGET_HOME/projects/$project" ] || die "project is unavailable in execution home"
  [ ! -e "$TARGET_HOME/data/$id/brief.md" ] && [ ! -L "$TARGET_HOME/data/$id/brief.md" ] || die "task brief already exists"
  case "$backend" in herdr|rex) ;; *) die "unsupported remote backend" ;; esac
  case "$kind:$mode:$yolo" in scout:-:-|ship:no-mistakes:on|ship:no-mistakes:off|ship:direct-PR:on|ship:direct-PR:off|ship:local-only:on|ship:local-only:off) ;; *) die "invalid task delivery contract" ;; esac
  temp=$(mktemp -d "${TMPDIR:-/tmp}/fm-remote-worker.XXXXXX") || die "cannot create launch scratch"
  REMOTE_WORKER_TEMP=$temp
  trap 'rm -rf -- "$REMOTE_WORKER_TEMP"' EXIT
  head -c 1048577 > "$temp/input"
  [ "$(wc -c < "$temp/input")" -le 1048576 ] || die "brief exceeds size limit"
  fm_brief_task_content_valid "$temp/input" || die "brief task sections are invalid"
  fm_brief_task_placeholders_present "$temp/input" && die "brief contains unfilled task placeholders"
  fm_brief_task_heading_body "$temp/input" "## Captain's intent" > "$temp/intent"
  fm_brief_task_heading_body "$temp/input" '## Firstmate spec' > "$temp/spec"
  [ -s "$temp/intent" ] && [ -s "$temp/spec" ] || die "both task sections are required"
  brief_args=("$id" "$project")
  spawn_args=("$id" "$TARGET_HOME/projects/$project" --local)
  if [ "$kind" = scout ]; then
    brief_args+=(--scout)
    spawn_args+=(--scout)
  else
    contract=$(grep '^Delivery contract: mode=' "$temp/input" || true)
    case "$contract" in *$'\n'*|'') die "brief delivery contract is missing or ambiguous" ;; esac
    read -r -a contract_fields <<< "$contract"
    [ "${contract_fields[2]:-}" = "mode=$mode" ] || die "brief delivery mode does not match launch"
    for token in "${contract_fields[@]:3}"; do
      case "$token" in forge=*) forge=${token#forge=} ;; shape=*) shape=${token#shape=} ;; pr=*) pr=${token#pr=} ;; *) die "unsupported brief delivery field" ;; esac
    done
    brief_args+=(--mode "$mode" --branch-prefix "$prefix" --forge "$forge" --pr "$pr")
    [ -z "$shape" ] || brief_args+=(--shape "$shape")
    spawn_args+=(--mode "$mode" --yolo "$yolo" --branch-prefix "$prefix")
  fi
  if grep -Fqx '# Herdr isolation - HARD SAFETY CONTRACT' "$temp/input"; then brief_args+=(--herdr-lab); fi
  if [ "$base" != - ]; then brief_args+=(--base-branch "$base"); spawn_args+=(--base-branch "$base"); fi
  spawn_args+=(--harness "$harness" --backend "$backend" --dispatch-override 'selected by the parent home')
  [ "$model" = - ] || spawn_args+=(--model "$model")
  [ "$effort" = - ] || spawn_args+=(--effort "$effort")
  [ -z "$account" ] || spawn_args+=(--claude-account "$account")
  [ ! -e "$TARGET_HOME/data/$id" ] && [ ! -L "$TARGET_HOME/data/$id" ] || data_existed=1
  FM_HOME="$TARGET_HOME" "$SCRIPT_DIR/fm-brief.sh" "${brief_args[@]}" >&2 || die "host-local scaffold failed"
  awk -v intent="$temp/intent" -v spec="$temp/spec" '
    $0 == "{TASK}" { while ((getline line < intent) > 0) print line; close(intent); next }
    $0 == "{FIRSTMATE_SPEC}" { while ((getline line < spec) > 0) print line; close(spec); next }
    { print }
  ' "$TARGET_HOME/data/$id/brief.md" > "$temp/brief"
  mv "$temp/brief" "$TARGET_HOME/data/$id/brief.md"
  if [ -f "$TARGET_HOME/config/crew-dispatch.json" ]; then
    FM_HOME="$TARGET_HOME" "$SCRIPT_DIR/fm-dispatch-resolve.sh" "$TARGET_HOME/data/$id/brief.md" --project "$project" >/dev/null || die "host-local dispatch resolution failed"
  fi
  session=$(execution_session)
  rc=0
  out=$(FM_HOME="$TARGET_HOME" HERDR_SESSION="$session" "$SCRIPT_DIR/fm-spawn.sh" "${spawn_args[@]}" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" >&2
    if [ "$rc" -eq 75 ]; then
      if [ "$data_existed" -eq 1 ]; then
        rm -f -- "$TARGET_HOME/data/$id/brief.md" "$TARGET_HOME/data/$id/dispatch-resolution.json"
      else
        rm -rf -- "${TARGET_HOME:?}/data/$id"
      fi
      exit 75
    fi
    die "host-local worker launch failed"
  fi
  route "$id"
}

case "${1:-}" in
  capabilities)
    [ "$#" -eq 1 ] || die "capabilities takes no arguments"
    validate_home
    printf '%s\n' 'fm-remote-worker-control.v2'
    ;;
  route)
    [ "$#" -eq 2 ] || die "route requires a task id"
    route "$2"
    ;;
  state)
    [ "$#" -eq 2 ] || die "state requires a task id"
    validate_home
    case "$2" in ''|*[!A-Za-z0-9._-]*|*..*) die "invalid task id" ;; esac
    if [ ! -e "$TARGET_HOME/state/$2.meta" ] && [ ! -L "$TARGET_HOME/state/$2.meta" ]; then printf 'missing\n'; exit 0; fi
    endpoint "$2"
    fm_backend_agent_state "$FM_BACKEND_VALIDATED_BACKEND" "$FM_BACKEND_VALIDATED_TARGET"
    printf '\n'
    ;;
  capture)
    [ "$#" -ge 2 ] && [ "$#" -le 3 ] || die "capture requires a task id and optional line count"
    validate_home
    lines=${3:-20}
    case "$lines" in ''|*[!0-9]*|0) die "invalid capture line count" ;; esac
    [ "$lines" -le 100 ] || die "capture line count exceeds 100"
    endpoint "$2"
    fm_backend_capture "$FM_BACKEND_VALIDATED_BACKEND" "$FM_BACKEND_VALIDATED_TARGET" "$lines" "fm-$2" | head -c 65536
    ;;
  launch)
    [ "$#" -eq 12 ] || [ "$#" -eq 13 ] || die "launch requires task, project, delivery and runtime arguments"
    shift
    launch "$@"
    ;;
  claude-account-check)
    [ "$#" -eq 4 ] || die "claude-account-check requires a harness, model and account"
    claude_account_check "$2" "$3" "$4"
    ;;
  send-stdin)
    [ "$#" -ge 2 ] && [ "$#" -le 3 ] || die "send-stdin requires a task id and optional delivery mode"
    worker_send_stdin "$2" "${3:-}"
    ;;
  key)
    [ "$#" -eq 3 ] || die "key requires a task id and key"
    worker_key "$2" "$3"
    ;;
  ring)
    [ "$#" -ge 2 ] && [ "$#" -le 3 ] || die "ring requires a task id and optional label"
    worker_ring "$2" "${3:-}"
    ;;
  interrupt|exit)
    [ "$#" -eq 2 ] || die "$1 requires a task id"
    worker_control_hop "$2" "$1"
    ;;
  relaunch)
    [ "$#" -ge 2 ] || die "relaunch requires a task id"
    worker_control_hop "$2" relaunch "${@:3}"
    ;;
  teardown)
    [ "$#" -eq 2 ] || { [ "$#" -eq 3 ] && [ "$3" = --force ]; } || die "teardown requires a task id and optional --force"
    worker_teardown "$2" "${3:-}"
    ;;
  crew-state)
    [ "$#" -eq 2 ] || die "crew-state requires a task id"
    worker_crew_state "$2"
    ;;
  fleet)
    [ "$#" -eq 1 ] || die "fleet takes no arguments"
    worker_fleet
    ;;
  done-gate)
    [ "$#" -eq 3 ] || die "done-gate requires a task id and done line"
    worker_done_gate "$2" "$3"
    ;;
  admit)
    [ "$#" -eq 3 ] || die "admit requires a task id and project"
    worker_admit "$2" "$3"
    ;;
  *) die "unknown remote worker command" ;;
esac
