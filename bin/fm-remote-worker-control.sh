#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_HOME=${FM_HOME:?FM_HOME is required}

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"

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

route() {
  local id=$1 meta="$TARGET_HOME/state/$1.meta" key value
  validate_home
  endpoint "$id"
  printf 'schema=fm-remote-worker-control.v1\nbackend=%s\ntarget=%s\n' "$FM_BACKEND_VALIDATED_BACKEND" "$FM_BACKEND_VALIDATED_TARGET"
  for key in kind harness model effort worktree project herdr_session; do
    value=$(fm_meta_get "$meta" "$key")
    [ -z "$value" ] || printf '%s=%s\n' "$key" "$value"
  done
}

launch() {
  local id=$1 project=$2 kind=$3 mode=$4 yolo=$5 prefix=$6 base=$7 harness=$8 model=$9
  shift 9
  local effort=$1 backend=$2 temp session out contract token forge=none shape='' pr=auto
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
  if ! out=$(FM_HOME="$TARGET_HOME" HERDR_SESSION="$session" "$SCRIPT_DIR/fm-spawn.sh" "${spawn_args[@]}" 2>&1); then
    printf '%s\n' "$out" >&2
    die "host-local worker launch failed"
  fi
  route "$id"
}

case "${1:-}" in
  capabilities)
    [ "$#" -eq 1 ] || die "capabilities takes no arguments"
    validate_home
    printf '%s\n' 'fm-remote-worker-control.v1'
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
    [ "$#" -eq 12 ] || die "launch requires task, project, delivery and runtime arguments"
    shift
    launch "$@"
    ;;
  *) die "unknown remote worker command" ;;
esac
