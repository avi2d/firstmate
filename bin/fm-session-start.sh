#!/usr/bin/env bash
# fm-session-start.sh [--reemit] [--source <source>] - print the session-start digest.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
COMPLETION_FILE="$STATE/.session-start-complete"
AGENTS_BASELINE_FILE="$STATE/.session-start-agents-baseline"

REEMIT=0
SESSION_SOURCE=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --reemit)
      REEMIT=1
      shift
      ;;
    --source)
      SESSION_SOURCE=${2:-}
      if [ "$#" -ge 2 ]; then shift 2; else shift; fi
      ;;
    --source=*)
      SESSION_SOURCE=${1#--source=}
      shift
      ;;
    -h|--help)
      sed -n '2,/^set -u$/p' "$SCRIPT_DIR/fm-session-start.sh" | sed 's/^# \{0,1\}//; $d'
      exit 0
      ;;
    *)
      printf 'fm-session-start: unknown argument: %s\n' "$1" >&2
      printf 'usage: fm-session-start.sh [--reemit] [--source <source>]\n' >&2
      exit 2
      ;;
  esac
done

# --- 0. runtime bound ---------------------------------------------------------
# The ordered stage list is the contract behind the truncation banner: the child
# names the stage it is entering, and the parent reports every stage at or after
# that one as never emitted. Keep it in the exact order the digest prints.
SESSION_START_STAGES='lock role bootstrap wake-queue supervision-instructions read-once fleet-state network-checks context next-step'

stage() {  # <stage-name>: breadcrumb for the parent's truncation banner
  [ -n "${FM_SESSION_START_STAGE_FILE:-}" ] || return 0
  printf '%s\n' "$1" > "$FM_SESSION_START_STAGE_FILE" 2>/dev/null || true
}

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

if [ -z "${FM_SESSION_START_STAGE_FILE:-}" ]; then
  SESSION_START_BUDGET=${FM_SESSION_START_TIMEOUT:-120}
  # A non-positive or non-numeric budget is not a budget (`timeout 0` disables
  # the deadline outright), so an unusable value falls back to the default
  # rather than silently removing the bound.
  case "$SESSION_START_BUDGET" in ''|*[!0-9]*) SESSION_START_BUDGET=120 ;; esac
  [ "$SESSION_START_BUDGET" -gt 0 ] 2>/dev/null || SESSION_START_BUDGET=120
  SESSION_START_STAGE_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-session-start-stage.XXXXXX" 2>/dev/null) || SESSION_START_STAGE_FILE=
  if [ -z "$SESSION_START_STAGE_FILE" ]; then
    # Without a breadcrumb the bound still holds; only the banner's precision
    # is lost, so the child still runs bounded.
    SESSION_START_STAGE_FILE=/dev/null
  fi
  if [ "$REEMIT" -eq 1 ]; then
    if [ -n "$SESSION_SOURCE" ]; then
      fm_run_timed "$SESSION_START_BUDGET" \
        env FM_SESSION_START_STAGE_FILE="$SESSION_START_STAGE_FILE" \
        "$SCRIPT_DIR/fm-session-start.sh" --reemit --source "$SESSION_SOURCE"
    else
      fm_run_timed "$SESSION_START_BUDGET" \
        env FM_SESSION_START_STAGE_FILE="$SESSION_START_STAGE_FILE" \
        "$SCRIPT_DIR/fm-session-start.sh" --reemit
    fi
  elif [ -n "$SESSION_SOURCE" ]; then
    fm_run_timed "$SESSION_START_BUDGET" \
      env FM_SESSION_START_STAGE_FILE="$SESSION_START_STAGE_FILE" \
      "$SCRIPT_DIR/fm-session-start.sh" --source "$SESSION_SOURCE"
  else
    fm_run_timed "$SESSION_START_BUDGET" \
      env FM_SESSION_START_STAGE_FILE="$SESSION_START_STAGE_FILE" \
      "$SCRIPT_DIR/fm-session-start.sh"
  fi
  SESSION_START_RC=$?
  # ANY nonzero child exit is a truncation: the banner contract promises that
  # a stage that cannot print is named. Exit 124 is the bound firing; any
  # other status means the child died or was killed mid-stage, which truncates
  # silently when unbanned - the parent must banner it, never exit 0 around it.
  if [ "$SESSION_START_RC" -ne 0 ]; then
    SESSION_START_LAST_STAGE=$(cat "$SESSION_START_STAGE_FILE" 2>/dev/null) || SESSION_START_LAST_STAGE=
    [ -n "$SESSION_START_LAST_STAGE" ] || SESSION_START_LAST_STAGE=unknown
    SESSION_START_PENDING=$(
      printf '%s\n' "$SESSION_START_STAGES" | tr ' ' '\n' |
        awk -v from="$SESSION_START_LAST_STAGE" '$0 == from {seen = 1} seen' | tr '\n' ' '
    )
    [ -n "${SESSION_START_PENDING# }" ] || SESSION_START_PENDING='(unknown - the digest may be incomplete anywhere)'
    BAR='●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
    printf '\n%s\n' "$BAR"
    if [ "$SESSION_START_RC" -eq 124 ]; then
      printf '●  STARTUP TRUNCATED - SESSION START HIT ITS %ss RUNTIME BOUND\n' "$SESSION_START_BUDGET"
    else
      printf '●  STARTUP TRUNCATED - SESSION START DIED UNEXPECTEDLY (exit %s, not its runtime bound)\n' "$SESSION_START_RC"
    fi
    printf '●  It stopped during the "%s" stage, so everything above is COMPLETE\n' "$SESSION_START_LAST_STAGE"
    printf '●  only up to that point.\n'
    printf '●  RECONCILE these stages before acting on anything they would have shown:\n'
    printf '●    %s\n' "${SESSION_START_PENDING% }"
    printf '●  Rerun bin/fm-session-start.sh now to finish taking the helm. If it truncates\n'
    if [ "$SESSION_START_RC" -eq 124 ]; then
      printf '●  again, raise FM_SESSION_START_TIMEOUT and report the slow stage - a stage that\n'
      printf '●  cannot finish inside the bound is a fleet problem, not a reporting detail.\n'
    else
      printf '●  again, report the exit status and the stage - raising the runtime bound\n'
      printf '●  cannot help a digest that died, and a stage that dies is a fleet problem.\n'
    fi
    printf '%s\n' "$BAR"
  fi
  rm -f "$SESSION_START_STAGE_FILE" 2>/dev/null || true
  exit 0
fi

PRIMARY_HARNESS=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf unknown)

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-trace-context-lib.sh
. "$SCRIPT_DIR/fm-trace-context-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-hold-reason-lib.sh
. "$SCRIPT_DIR/fm-hold-reason-lib.sh"
# shellcheck source=bin/fm-project-tiers-lib.sh
. "$SCRIPT_DIR/fm-project-tiers-lib.sh"

# One tasks-axi compatibility verdict per session start. The probe costs three
# tasks-axi subprocesses and this digest needs the same answer twice - here for
# the backlog listing and again inside the fm-bootstrap.sh child, which reports
# an incompatible build as OUTDATED. Computing it once and handing it, with the
# reason behind it, to that child collapses six subprocesses to three; the reason
# travels too so the child's OUTDATED requirement text names a missing capability
# without running the child's own `--help` probes over again. fm-tasks-axi-lib.sh
# owns both reuse layers and the one-hop consumption rule that keeps them out of
# any agent's environment.
if fm_tasks_axi_compatible; then TASKS_AXI_COMPATIBLE=1; else TASKS_AXI_COMPATIBLE=0; fi
TASKS_AXI_CHECK_REASON=$(fm_tasks_axi_check_reason)

QUEUED_LIMIT=${FM_SESSION_START_QUEUED_LIMIT:-10}
case "$QUEUED_LIMIT" in ''|*[!0-9]*|0) QUEUED_LIMIT=10 ;; esac
# One per-task endpoint read may never outlive this bound: a hung backend CLI
# becomes that task's endpoint: error line instead of the digest's whole
# runtime budget.
ENDPOINT_TIMEOUT=${FM_SESSION_START_ENDPOINT_TIMEOUT:-10}
case "$ENDPOINT_TIMEOUT" in ''|*[!0-9]*) ENDPOINT_TIMEOUT=10 ;; esac
[ "$ENDPOINT_TIMEOUT" -gt 0 ] 2>/dev/null || ENDPOINT_TIMEOUT=10
BACKLOG_FIELDS=blocked_by,hold_kind,hold_reason

RULE='================================================================================'
SUBRULE='--------------------------------------------------------------------------------'

section() { printf '\n%s\n%s\n%s\n' "$RULE" "$1" "$RULE"; }
subsection() { printf '\n%s\n%s\n' "$1" "$SUBRULE"; }

print_context_manifest_line() {
  local path=$1 bytes digest
  if [ ! -f "$path" ]; then
    printf 'ABSENT\n'
    return
  fi
  if [ ! -s "$path" ]; then
    printf '(present, empty)\n'
    return
  fi
  bytes=$(wc -c < "$path" 2>/dev/null | tr -d ' ' || true)
  digest=$(hash_file_sha256 "$path" 2>/dev/null || true)
  printf 'present, %s bytes%s (body omitted on context re-emit; read the file when this turn needs its content)\n' \
    "${bytes:-unknown}" "${digest:+, $digest}"
}
# print_file_or_absent <path> <label>: full contents under a labeled
# subsection, or an explicit ABSENT marker. Absence is semantically
# meaningful for every one of these files (captain.md absent = firstmate
# repo built-in defaults, projects.md absent = rebuild from clones, etc. -
# AGENTS.md section 3) and must never be confused with an empty-but-present
# file, so the two cases print differently.
print_file_or_absent() {
  local path=$1 label=$2
  subsection "$label"
  if [ "$REEMIT" -eq 1 ]; then
    print_context_manifest_line "$path"
    return
  fi
  if [ -f "$path" ]; then
    if [ -s "$path" ]; then
      cat "$path"
    else
      printf '(present, empty)\n'
    fi
  else
    printf 'ABSENT\n'
  fi
}

print_backlog_pointer() {
  printf 'Full task bodies remain available on demand: bin/fm-tasks-axi.sh show <id> --full when compatible tasks-axi is available, or data/backlog.md.\n'
}

# A queued title line whose own text already marks it held or blocked. The
# manual renderer has no task model, so this is the only signal it gets, and it
# is the one tasks-axi's markdown backend writes: "(hold: ...)", "(hold-kind:
# ...)", and "blocked-by: ...". Bracket expressions rather than backslashes,
# because awk's -v applies escape processing before the regex is ever compiled.
MANUAL_KEEP_RE='[(]hold|blocked-by:'

print_backlog_manual_compact() {
  local path=$1 reason=$2
  if [ "$REEMIT" -eq 1 ]; then
    printf 'context re-emit backlog summary (%s; done rows omitted; held and blocked title lines counted, not listed; other queued bounded to %s; indented task bodies omitted)\n' \
      "$reason" "$QUEUED_LIMIT"
  else
    printf 'compact backlog listing (%s; done rows omitted; every in-flight, held, and blocked title line kept; other queued bounded to %s; indented task bodies omitted)\n' \
      "$reason" "$QUEUED_LIMIT"
  fi
  awk -v max="$QUEUED_LIMIT" -v keep_re="$MANUAL_KEEP_RE" -v list_gated="$((1 - REEMIT))" '
    function state_for_heading(line, heading) {
      heading = line
      sub(/^##[[:space:]]+/, "", heading)
      sub(/[[:space:]]+$/, "", heading)
      if (heading == "In flight") return "in_flight"
      if (heading == "Queued") return "queued"
      if (heading == "Done") return "done"
      return ""
    }
    /^##[[:space:]]+/ {
      state = state_for_heading($0)
      # The Done heading is recognized so its items are skipped, never printed.
      if (state != "" && state != "done") print $0
      next
    }
    state == "in_flight" && /^[-*][[:space:]]+/ {
      in_flight++
      if ($0 ~ keep_re) in_flight_gated++
      if (list_gated || $0 !~ keep_re) print $0
      next
    }
    state == "done" && /^[-*][[:space:]]+/ { done_total++; next }
    state == "queued" && /^[-*][[:space:]]+/ {
      queued_total++
      if ($0 ~ keep_re) { gated++; if (list_gated) print $0; next }
      if (plain_shown < max) { plain_shown++; print $0 }
      next
    }
    END {
      plain_total = queued_total - gated
      if (in_flight + queued_total + done_total == 0) {
        print "(no backlog item title lines found)"
      } else {
        if (list_gated) {
          printf "(shown %d in-flight, %d held or blocked queued, %d of %d other queued title line(s); %d done row(s) omitted)\n", \
            in_flight, gated, plain_shown, plain_total, done_total
        } else {
          printf "(counts: %d in-flight, %d of them held or blocked and not listed; %d held or blocked queued, not listed; shown %d of %d other queued title line(s); %d done row(s) omitted)\n", \
            in_flight, in_flight_gated, gated, plain_shown, plain_total, done_total
        }
        if (plain_total > plain_shown) {
          printf "(%d more queued - raise FM_SESSION_START_QUEUED_LIMIT or read data/backlog.md for the rest)\n", plain_total - plain_shown
        }
      }
    }
  ' "$path" | fm_hold_reason_decode_stream markdown
}

# tasks-axi closes every listing with its own help block. This section composes
# four listings, so keeping them would repeat the same pointers four times, once
# per group, each carrying this home's full backlog path. The section prints one
# equivalent pointer of its own (print_backlog_pointer), so the per-group help
# blocks stop at their `help[` header instead.
strip_axi_help() {
  awk '/^help\[/ { exit } { print }'
}

# Rows are the indented lines under a tasks-axi <name>[N]{...} header. Every
# other line passes through, and whatever is cut is disclosed exactly.
print_listing_bounded() {  # <listing> <noun> <rest-command>
  printf '%s\n' "$1" | awk -v max="$QUEUED_LIMIT" -v noun="$2" -v rest="$3" '
    function note() {
      if (!noted && total > shown)
        printf "(shown %d of %d %s; %d more - %s)\n", shown, total, noun, total - shown, rest
      noted = 1
    }
    /^help\[/ { exit }
    /^count: / { next }
    /^[a-z_]+\[[0-9]+\]/ { rows = 1; print; next }
    rows && /^[[:space:]]/ {
      total++
      if (shown < max) { print; shown++ }
      next
    }
    { if (rows) note(); rows = 0; print }
    END { note() }
  '
}

print_ready_queued_bounded() {
  print_listing_bounded "$1" "ready queued item(s)" "bin/fm-tasks-axi.sh ready"
}

# The work-under-way lines name every task with a worker record, so only an
# in-flight row with no state/<id>.meta needs listing here.
print_in_flight_without_meta() {  # <in-flight listing>
  local row id
  while IFS= read -r row; do
    case "$row" in [[:space:]]*) ;; *) continue ;; esac
    id=${row#"${row%%[![:space:]]*}"}
    id=${id%%,*}
    [ -f "$STATE/$id.meta" ] || printf '%s\n' "$row"
  done < <(printf '%s\n' "$1" | strip_axi_help)
}

# tasks-axi listing header: count: <n>
listing_count() {
  printf '%s\n' "$1" | sed -n 's/^count: //p' | head -n 1
}

# <in-flight listing with --fields held>: the rows whose trailing held field is no.
print_in_flight_not_held() {
  printf '%s\n' "$1" | strip_axi_help | awk '/^[[:space:]]/ && /,no$/ { sub(/,no$/, ""); print }'
}

print_backlog_reemit_groups() {
  local in_flight=$1 held=$2 blocked=$3 open_rows
  open_rows=$(print_in_flight_not_held "$in_flight")
  printf 'context re-emit backlog summary (tasks-axi; done rows omitted; held and blocked rows counted, not listed; ready queued bounded to %s; task bodies omitted)\n' \
    "$QUEUED_LIMIT"
  printf 'counts: in flight %s, held %s (in-flight items included), blocked queued %s; list them with bin/fm-tasks-axi.sh list --state held, or --state queued --blocked\n' \
    "$(listing_count "$in_flight")" "$(listing_count "$held")" "$(listing_count "$blocked")"
  printf '\nin flight, not held {id,state,kind,repo,title}:\n'
  if [ -n "$open_rows" ]; then
    printf '%s\n' "$open_rows"
  else
    printf '(none)\n'
  fi
}

print_backlog_summary_groups() {  # <in-flight> <held> <blocked> <ready>
  local in_flight=$1 held=$2 blocked=$3 unlisted
  printf 'backlog summary (tasks-axi; done rows omitted; held rows in full; blocked and ready queued bounded to %s; task bodies omitted)\n' \
    "$QUEUED_LIMIT"
  printf 'counts: in flight %s, held %s (in-flight items included), blocked queued %s, ready queued %s\n' \
    "$(listing_count "$in_flight")" "$(listing_count "$held")" "$(listing_count "$blocked")" "$(listing_count "$4")"
  if [ "$(listing_count "$held")" != 0 ]; then
    printf '\nheld (waiting on the captain or a date):\n'
    printf '%s\n' "$held" | fm_hold_reason_decode_stream | strip_axi_help | sed '/^count: /d'
  fi
  unlisted=$(print_in_flight_without_meta "$in_flight" | fm_hold_reason_decode_stream)
  if [ -n "$unlisted" ]; then
    printf '\nin flight with no state/*.meta record:\n%s\n' "$unlisted"
  fi
  if [ "$(listing_count "$blocked")" != 0 ]; then
    printf '\nblocked queued:\n'
    print_listing_bounded "$(printf '%s\n' "$blocked" | fm_hold_reason_decode_stream)" \
      "blocked queued item(s)" "bin/fm-tasks-axi.sh list --state queued --blocked"
  fi
}

print_backlog_tasks_axi_compact() {
  local path=$1 in_flight_fields=$BACKLOG_FIELDS in_flight held blocked ready err
  [ "$REEMIT" -eq 0 ] || in_flight_fields=held
  if ! in_flight=$(tasks-axi list --file "$path" --state in_flight --fields "$in_flight_fields" 2>&1); then
    err=$in_flight
  elif ! held=$(tasks-axi list --file "$path" --state held --fields "$BACKLOG_FIELDS" 2>&1); then
    err=$held
  elif ! blocked=$(tasks-axi list --file "$path" --state queued --blocked --fields "$BACKLOG_FIELDS" 2>&1); then
    err=$blocked
  elif ! ready=$(tasks-axi ready --file "$path" 2>&1); then
    err=$ready
  else
    if [ "$REEMIT" -eq 1 ]; then
      print_backlog_reemit_groups "$in_flight" "$held" "$blocked"
    else
      print_backlog_summary_groups "$in_flight" "$held" "$blocked" "$ready"
    fi
    printf '\nready queued (dispatchable now):\n'
    if fm_project_tiers_read "$CONFIG" 2>&1 && [ -n "$FM_PROJECT_TIERS" ]; then
      printf '(higher project tier first, per %s)\n' "$FM_PROJECT_TIERS_FILE"
      ready=$(printf '%s\n' "$ready" | fm_project_tiers_order_ready)
    fi
    print_ready_queued_bounded "$ready"
    return 0
  fi
  printf 'tasks-axi compact listing failed; falling back to title-line rendering.\n'
  printf '%s\n' "$err"
  print_backlog_manual_compact "$path" "fallback"
}

print_backlog_compact() {
  local path=$1 label=$2
  subsection "$label"
  if [ -f "$path" ]; then
    if [ -s "$path" ]; then
      if fm_tasks_axi_backend_available "$CONFIG"; then
        print_backlog_tasks_axi_compact "$path"
      elif fm_backlog_backend_manual "$CONFIG"; then
        print_backlog_manual_compact "$path" "manual backend"
      else
        print_backlog_manual_compact "$path" "tasks-axi unavailable or incompatible"
      fi
      print_backlog_pointer
    else
      printf '(present, empty)\n'
    fi
  else
    printf 'ABSENT\n'
  fi
}

last_status_line() {  # <status-file>
  awk 'NF { line = $0 } END { print line }' "$1" 2>/dev/null
}

# <id> [<kind> <mode>]: <last status line>, the whole line capped.
print_meta_reemit_line() {
  local meta=$1 id=$2 kind mode last
  kind=$(fm_meta_get "$meta" kind)
  mode=$(fm_meta_get "$meta" mode)
  last=$(last_status_line "$STATE/$id.status")
  fm_cap_line "$id [${kind:-unknown kind}${mode:+ $mode}]: ${last:-(no status yet)}"
}

# Only the status part is capped, so the endpoint verdict always survives.
print_meta_line() {  # <meta> <id> <endpoint-verdict>
  local meta=$1 id=$2 kind mode last
  kind=$(fm_meta_get "$meta" kind)
  mode=$(fm_meta_get "$meta" mode)
  last=$(last_status_line "$STATE/$id.status")
  fm_cap_line_var "${last:-(no status yet)}"
  printf '%s [%s] %s - latest: %s\n' "$id" "${kind:-unknown kind}${mode:+ $mode}" "$3" "$FM_LINE_CAP_LINE"
}

# fm_session_start_endpoint_read <backend> <target> [expected-label]: ONE
# bounded, crash-isolated endpoint-liveness read. The read runs in its own
# bash under fm_run_timed's bound instead of in this digest process, because
# a per-task backend liveness read that dies mid-read would otherwise take
# every later stage with it. Isolation turns any death, hang, or nonzero
# surprise in one task's read into that task's own endpoint line - never a
# silently missing rest of digest. The inner bash re-sources fm-backend.sh
# per read; that cost is a few milliseconds per task and buys the isolation.
fm_session_start_endpoint_read() {  # <backend> <target> [expected-label]
  local backend=$1 target=$2 label=${3:-}
  # shellcheck disable=SC2016  # Positional parameters expand inside the child bash, not here.
  fm_run_timed "$ENDPOINT_TIMEOUT" bash -c '
    . "$1"
    fm_backend_target_exists "$2" "$3" "$4"
  ' _ "$SCRIPT_DIR/fm-backend.sh" "$backend" "$target" "$label"
}

hash_file_sha256() {
  local file=$1 digest
  [ -f "$file" ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    digest=$(shasum -a 256 "$file" 2>/dev/null | awk '
      length($1) == 64 && $1 !~ /[^[:xdigit:]]/ { print "sha256:" $1; found=1; exit }
      END { if (!found) exit 1 }
    ') && [ -n "$digest" ] && { printf '%s\n' "$digest"; return 0; }
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    digest=$(sha256sum "$file" 2>/dev/null | awk '
      length($1) == 64 && $1 !~ /[^[:xdigit:]]/ { print "sha256:" $1; found=1; exit }
      END { if (!found) exit 1 }
    ') && [ -n "$digest" ] && { printf '%s\n' "$digest"; return 0; }
  fi
  return 1
}

# The baseline describes instructions this true session started with, not the
# most recently emitted instructions. It is intentionally immutable for this
# lock owner: every later stale-context rebuild needs the current file again.
write_agents_baseline() {  # <lock-pid> <agents-hash>
  local lock_pid=$1 agents_hash=$2 tmp
  [ -n "$lock_pid" ] && [ -n "$agents_hash" ] || return 1
  tmp=$(mktemp "$STATE/.session-start-agents-baseline.XXXXXX" 2>/dev/null) || return 1
  if printf '%s\n%s\n' "$lock_pid" "$agents_hash" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$AGENTS_BASELINE_FILE" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

agents_baseline_drifted() {  # <rebuilding-session-pid>
  local lock_pid=$1 baseline_pid baseline_hash current_hash
  [ -f "$AGENTS_BASELINE_FILE" ] && [ ! -L "$AGENTS_BASELINE_FILE" ] || return 0
  baseline_pid=$(sed -n '1p' "$AGENTS_BASELINE_FILE" 2>/dev/null || true)
  baseline_hash=$(sed -n '2p' "$AGENTS_BASELINE_FILE" 2>/dev/null || true)
  current_hash=$(hash_file_sha256 "$FM_ROOT/AGENTS.md" 2>/dev/null || true)
  [ -n "$current_hash" ] || return 0
  [ "$baseline_pid" = "$lock_pid" ] && [ "$baseline_hash" = "$current_hash" ] && return 1
  return 0
}

# Only run-tier source pairs with both a stale native instruction cache and a
# working Firstmate delivery path arrive here. Claude fresh-reads on reset, and
# Codex has no tracked interactive reset delivery path.
agents_refresh_required() {  # <rebuilding-session-pid>
  local lock_pid=$1
  case "$PRIMARY_HARNESS:$SESSION_SOURCE" in
    pi:compact|pi-signed:compact) ;;
    *) return 1 ;;
  esac
  agents_baseline_drifted "$lock_pid"
}

print_agents_refresh_if_required() {  # <rebuilding-session-pid>
  local lock_pid=$1
  agents_refresh_required "$lock_pid" || return 0
  section "CURRENT AGENTS.md - INSTRUCTION REFRESH"
  if [ -f "$FM_ROOT/AGENTS.md" ]; then
    cat <<'EOF'
The complete on-disk AGENTS.md below supersedes the instruction copy this session
started with. Apply it as the current Firstmate instruction contract.

EOF
    cat "$FM_ROOT/AGENTS.md"
  else
    printf 'The original AGENTS.md baseline no longer matches, but the current file is absent.\n'
  fi
}

AGENTS_START_HASH=
if [ "$REEMIT" -eq 0 ] && [ "$SESSION_SOURCE" = startup ]; then
  AGENTS_START_HASH=$(hash_file_sha256 "$FM_ROOT/AGENTS.md" 2>/dev/null || true)
fi

if [ "$REEMIT" -eq 1 ]; then
  # First in the output on purpose: a harness that spills a large hook output
  # delivers only a short head inline (Claude: about 2,000 characters), and
  # CONTEXT prints last, so this cue is the part that must survive the spill.
  printf 'RE-EMIT CUE: if this output ends with "Output too large ... Full output saved to <path>",\n'
  printf 'read that whole file now, before acting. The CONTEXT section below is a manifest (path, size,\n'
  printf 'hash), not full bodies: read a file under %s only when this turn needs its content.\n' "$DATA"
  section "SESSION START (CONTEXT RE-EMIT) - $FM_HOME"
  printf 'This session already took the helm at its own startup and has only lost its\n'
  printf 'context. Lock ownership is re-verified and the durable records below are\n'
  printf 'reprinted, but the sweeps startup already reconciled - project clone refresh,\n'
  printf 'retry, X-mode artifact writes, and stale Herdr child cleanup - are NOT repeated.\n'
  printf 'Queued wakes ARE still drained: they arrived after startup and are this turn work.\n'
else
  section "SESSION START - $FM_HOME"
fi
# --- 1. lock -----------------------------------------------------------
stage lock
subsection "LOCK"
LOCK_OUT=$("$SCRIPT_DIR/fm-lock.sh" 2>&1)
LOCK_RC=$?
printf '%s\n' "$LOCK_OUT"
READ_ONLY=0
if [ "$LOCK_RC" -ne 0 ]; then
  READ_ONLY=1
  BAR='●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '%s\n' "$BAR"
    printf '●  READ-ONLY SESSION - FLEET LOCK OWNERSHIP WAS NOT VERIFIED\n'
    printf '●  %s\n' "$LOCK_OUT"
    printf '●  Skipping every mutating step: stale Herdr child cleanup,\n'
    printf '●  project clone refresh,\n'
    printf '●  X-mode artifacts, fleet sync, and wake-queue drain. Detect-only bootstrap\n'
    printf '●  diagnostics and the rest of this read-only-safe digest still ran below.\n'
    printf '●  Operate read-only until this resolves - do not spawn, steer, merge, or\n'
    printf '●  otherwise mutate fleet state from this session.\n'
    printf '%s\n' "$BAR"
  }
fi
REBUILDING_SESSION_PID=$(fm_harness_ancestry_pid 2>/dev/null || true)
print_agents_refresh_if_required "$REBUILDING_SESSION_PID"

# --- 1b. home role -------------------------------------------------------
# This home's firstmate-repository role: user/operator unless an explicit
# local or receipt-proven inherited grant says otherwise (bin/fm-role-lib.sh).
# Purely local resolution - no network, no gh call.
stage role
subsection "HOME ROLE"
FM_HOME="$FM_HOME" FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-role.sh" report 2>/dev/null \
  || printf 'fm-role: unknown (bin/fm-role.sh report failed)\n'

if [ "$READ_ONLY" -eq 0 ]; then
  if [ "$REEMIT" -eq 0 ]; then
    rm -f "$COMPLETION_FILE" 2>/dev/null || true
  fi
  fm_trace_context_session_start "$CONFIG" "$STATE/.trace-context-effective"
  # Every network call and the potentially slow inactive-outcome startup scan
  # are launched HERE, detached and bounded, so they run concurrently with the
  # whole digest below instead of in front of it. Step 7 harvests whatever has
  # finished, without ever waiting.
  # --reemit passes --locked 0 for the same reason it runs bootstrap detect-only:
  # this process already ran the mutating sweeps at its own startup, so only the
  # read-only GitHub-auth probe is owed. A read-only session starts nothing at
  # all: it holds no mutation authority for the sweeps, and it must not spawn,
  # steer, or merge anyway, so it has no action left for an auth verdict to gate.
  NETWORK_STAGE_LOCKED=1
  [ "$REEMIT" -eq 0 ] || NETWORK_STAGE_LOCKED=0
  "$SCRIPT_DIR/fm-startup-network.sh" start \
    --locked "$NETWORK_STAGE_LOCKED" --harvest-pid $$ >/dev/null 2>&1 || true
fi

# --- 2. bootstrap --------------------------------------------------------
# FM_BOOTSTRAP_NETWORK=skip on every path: bootstrap's own network half is what
# the deferred stage above is running right now, and running it twice would both
# re-block this digest and race the worker's sweeps against themselves.
stage bootstrap
subsection "BOOTSTRAP"
if [ "$READ_ONLY" -eq 1 ]; then
  BOOT_OUT=$(FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip \
    FM_TASKS_AXI_COMPATIBLE="$TASKS_AXI_COMPATIBLE" \
    FM_TASKS_AXI_CHECK_REASON="$TASKS_AXI_CHECK_REASON" "$SCRIPT_DIR/fm-bootstrap.sh" 2>&1)
elif [ "$REEMIT" -eq 1 ]; then
  BOOT_OUT=$(FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_LOCKED=1 FM_BOOTSTRAP_NETWORK=skip \
    FM_TASKS_AXI_COMPATIBLE="$TASKS_AXI_COMPATIBLE" \
    FM_TASKS_AXI_CHECK_REASON="$TASKS_AXI_CHECK_REASON" "$SCRIPT_DIR/fm-bootstrap.sh" 2>&1)
else
  BOOT_OUT=$(
    "$SCRIPT_DIR/fm-herdr-session-cleanup.sh" 2>&1 || true
    FM_BOOTSTRAP_NETWORK=skip FM_TASKS_AXI_COMPATIBLE="$TASKS_AXI_COMPATIBLE" \
      FM_TASKS_AXI_CHECK_REASON="$TASKS_AXI_CHECK_REASON" \
      "$SCRIPT_DIR/fm-bootstrap.sh" 2>&1
  )
fi
if [ -n "$BOOT_OUT" ]; then
  printf '%s\n' "$BOOT_OUT"
else
  printf '(silent - all good)\n'
fi

# --- 3. wake-drain ---------------------------------------------------------
# The inactive-outcome startup scan runs in the deferred worker launched above,
# where its potentially slow current-state reads cannot block this digest. It
# publishes findings through the same durable queue drained here; the watcher's
# separate 900-second cadence remains unchanged.
# Presented records are this turn's first work queue and remain durable until
# post-handling acknowledgement. The drain's separate OPEN DECISIONS section
# remains actionable even when that queue is empty (AGENTS.md sections 3 and 8).
# The drain also runs fm-guard.sh internally on the locked path, so the
# tangle/watcher-liveness alarms land right here too, ahead of the bulk digest
# below. The read-only path never touches the queue because it lacks mutation
# authority, and another session may be actively handling it. It still runs
# fm-guard.sh directly with non-mutating advisory text, so the same alarms
# surface without repair commands.
stage wake-queue
subsection "WAKE QUEUE"
if [ "$READ_ONLY" -eq 1 ]; then
  QLEN=0
  [ -s "$STATE/.wake-queue" ] && QLEN=$(grep -c . "$STATE/.wake-queue" 2>/dev/null || printf '0')
  printf 'skipped (read-only session) - %s record(s) remain queued because this session lacks verified fleet-lock ownership.\n' "$QLEN"
  GUARD_OUT=$(FM_GUARD_READ_ONLY=1 "$SCRIPT_DIR/fm-guard.sh" 2>&1)
  [ -n "$GUARD_OUT" ] && printf '%s\n' "$GUARD_OUT"
else
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-branch-outcome.sh" seed-tail >/dev/null 2>&1 || true
  # Pi supervision-branch recovery, locked path only: clear leases whose
  # supervising session died, and surface outcomes the branch stored durably
  # that never reached main (docs/pi-supervision-branch.md). Gated to the
  # pi/pi-signed primary so a non-Pi home runs neither step - homes on any
  # other harness stay entirely untouched (captain-decided criterion).
  if [ "$PRIMARY_HARNESS" = pi ] || [ "$PRIMARY_HARNESS" = pi-signed ]; then
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-lease.sh" sweep 2>/dev/null || true
    BRANCH_REPLAY_OUT=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      "$SCRIPT_DIR/fm-branch-outcome.sh" startup-replay 2>&1) || BRANCH_REPLAY_OUT=
    if [ -n "$BRANCH_REPLAY_OUT" ]; then
      printf '%s\n' "$BRANCH_REPLAY_OUT"
    fi
  fi
  DRAIN_OUT=$("$SCRIPT_DIR/fm-wake-drain.sh" 2>&1)
  if [ -n "$DRAIN_OUT" ]; then
    while IFS= read -r drain_line; do
      if [[ $drain_line =~ ^[0-9]+$'\t'[0-9]+$'\t' ]]; then
        fm_cap_line_var "$drain_line"
        printf '%s\n' "$FM_LINE_CAP_LINE"
      else
        printf '%s\n' "$drain_line"
      fi
    done <<EOF
$DRAIN_OUT
EOF
  else
    printf '(no queued wakes)\n'
  fi
fi

# --- 4. supervision operating instructions ----------------------------------
stage supervision-instructions
X_MODE_PRESENT=0
[ -f "$CONFIG/x-mode.env" ] && X_MODE_PRESENT=1

if [ "$PRIMARY_HARNESS" = pi ] || [ "$PRIMARY_HARNESS" = pi-signed ]; then
  PI_EXT="$FM_ROOT/.pi/extensions/fm-primary-pi-watch.ts"
  PI_TURNEND_EXT="$FM_ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
  PI_WATCH_MARKER="$STATE/.pi-watch-extension-loaded"
  PI_TURNEND_MARKER="$STATE/.pi-turnend-extension-loaded"
  PI_LOCK="$STATE/.lock"
  PI_RESTART_COMMAND=$PRIMARY_HARNESS
  [ "$PRIMARY_HARNESS" != pi ] || PI_RESTART_COMMAND='plain pi'
  PI_WATCH_VERSION=$(fm_pi_extension_version "$PI_EXT" || printf '')
  PI_TURNEND_VERSION=$(fm_pi_extension_version "$PI_TURNEND_EXT" || printf '')
  if ! fm_pi_extension_loaded "$PI_WATCH_MARKER" "$PI_WATCH_VERSION" "$PI_LOCK" active \
    || ! fm_pi_extension_loaded "$PI_TURNEND_MARKER" "$PI_TURNEND_VERSION" "$PI_LOCK"; then
    printf 'PI_WATCH_EXTENSION: not loaded - approve Pi project trust once per clone, then restart %s so %s and %s auto-load for turn-end guard and background wake coverage; use -e %s -e %s only if project hooks are not trusted\n' "$PI_RESTART_COMMAND" "$PI_TURNEND_EXT" "$PI_EXT" "$PI_TURNEND_EXT" "$PI_EXT"
  fi
fi
# omp (Oh My Pi) has no project-trust gate: it auto-discovers <cwd>/.omp/extensions
# with no dialog, so the only ways both tracked primary extensions fail to load
# are a session started outside this home, an extension disabled in the omp
# config, or a build older than the tracked file. The markers carry the loaded
# build plus the loading pid, exactly as the Pi ones do (bin/fm-wake-lib.sh).
if [ "$PRIMARY_HARNESS" = omp ]; then
  OMP_EXT="$FM_ROOT/.omp/extensions/fm-primary-omp-watch.ts"
  OMP_TURNEND_EXT="$FM_ROOT/.omp/extensions/fm-primary-turnend-guard.ts"
  OMP_WATCH_MARKER="$STATE/.omp-watch-extension-loaded"
  OMP_TURNEND_MARKER="$STATE/.omp-turnend-extension-loaded"
  OMP_LOCK="$STATE/.lock"
  OMP_WATCH_VERSION=$(fm_pi_extension_version "$OMP_EXT" || printf '')
  OMP_TURNEND_VERSION=$(fm_pi_extension_version "$OMP_TURNEND_EXT" || printf '')
  if ! fm_pi_extension_loaded "$OMP_WATCH_MARKER" "$OMP_WATCH_VERSION" "$OMP_LOCK" \
    || ! fm_pi_extension_loaded "$OMP_TURNEND_MARKER" "$OMP_TURNEND_VERSION" "$OMP_LOCK"; then
    OMP_HOME_PHYS=$(cd -P "$FM_HOME" 2>/dev/null && pwd -P || printf '%s' "$FM_HOME")
    OMP_ROOT_PHYS=$(cd -P "$FM_ROOT" 2>/dev/null && pwd -P || printf '%s' "$FM_ROOT")
    if [ "$OMP_HOME_PHYS" = "$OMP_ROOT_PHYS" ]; then
      printf 'OMP_WATCH_EXTENSION: not loaded - restart omp with this home as its working directory so %s and %s auto-load from .omp/extensions/ for turn-end guard and background wake coverage; pass -e %s -e %s only when omp must start from another directory, never together with auto-discovery (omp loads a file named both ways twice)\n' "$OMP_TURNEND_EXT" "$OMP_EXT" "$OMP_TURNEND_EXT" "$OMP_EXT"
    else
      # shellcheck disable=SC2016  # backticks are literal text in the diagnostic
      printf 'OMP_WATCH_EXTENSION: not loaded - exit omp and relaunch through `fm <project>` (the launcher sets FM_HOME and --cwd) so %s and %s auto-load for this home; a bare omp or /resume from the firstmate checkout does not register the extensions for this home\n' "$OMP_TURNEND_EXT" "$OMP_EXT"
    fi
    # Warning only: name the cause when existing facts establish it.
    OMP_MARKER_PID=$(sed -n '2p' "$OMP_WATCH_MARKER" 2>/dev/null || true)
    OMP_CURRENT_PID=${REBUILDING_SESSION_PID:-$(sed -n '1p' "$OMP_LOCK" 2>/dev/null || true)}
    if [ -n "$OMP_MARKER_PID" ] && [ -n "$OMP_CURRENT_PID" ] && [ "$OMP_MARKER_PID" != "$OMP_CURRENT_PID" ]; then
      printf 'OMP_WATCH_CAUSE: the extension marker %s names pid %s, which is not this session (pid %s)\n' "$OMP_WATCH_MARKER" "$OMP_MARKER_PID" "$OMP_CURRENT_PID"
    fi
  fi
fi
"$SCRIPT_DIR/fm-supervision-instructions.sh" \
  --harness "$PRIMARY_HARNESS" \
  --read-only "$READ_ONLY" \
  --x-mode "$X_MODE_PRESENT"

# --- 5. read-once contract -------------------------------------------------
# Ahead of the two digests it governs, not after them: a truncated tail is
# exactly what drops a closing reminder, and this contract is what stops the
# next turn from re-reading everything the digest just printed. Because it now
# arrives BEFORE its subject, it also names the one condition that voids it -
# a stage that never ran, which the truncation banner names by stage.
stage read-once
section "READ-ONCE CONTRACT"
cat <<'EOF'
Below is a summary of data/backlog.md, one line per state/*.meta task with
its latest state/*.status line, and data/projects.md, data/captain.md, and
data/learnings.md in full.
Do NOT re-read any of them after reading this digest, and do NOT bulk-read
data/backlog.md, state/*.meta, or state/*.status.

Read one source only when:
  - this digest flagged it ABSENT or it looked corrupt,
  - one task's worktree, branch, or harness is needed (state/<id>.meta), or its
    older status lines are (state/<id>.status),
  - a full task body or an omitted row is needed (bin/fm-tasks-axi.sh show <id>
    --full, or the command printed with the omission),
  - NETWORK CHECKS reported IN PROGRESS and this turn needs the verdict
    (bin/fm-startup-network.sh report),
  - or a STARTUP TRUNCATED banner or a re-emit read cue says a stage never
    printed.
EOF

if [ "$REEMIT" -eq 1 ]; then
  cat <<'EOF'

On this context re-emit CONTEXT is a manifest (path, byte size, hash) rather
than full bodies, the backlog shows counts, the in-flight rows that are not
held, and the bounded ready queue, but not held or blocked rows, and work
under way skips the endpoint check.
EOF
fi

# --- 6. fleet-state digest ---------------------------------------------
# Before CONTEXT: a harness cuts an oversized digest from the tail, and live
# fleet identity is what that cut must never take.
stage fleet-state
section "FLEET STATE"
print_backlog_compact "$DATA/backlog.md" "data/backlog.md"

subsection "Work under way (state/*.meta; one line per task with its latest status line, an event rather than current state)"
META_FOUND=0
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  META_FOUND=1
  id=$(basename "$meta" .meta)
  if [ "$REEMIT" -eq 1 ]; then
    print_meta_reemit_line "$meta" "$id"
    continue
  fi
  window=$(fm_meta_get "$meta" window)
  target=$(fm_backend_target_of_meta "$meta")
  if [ -n "$window" ]; then
    backend=$(fm_backend_of_meta "$meta")
    endpoint_rc=0
    fm_session_start_endpoint_read "$backend" "${target:-$window}" "fm-$id" || endpoint_rc=$?
    # Only the timeout owner's own statuses mean the read itself failed: 124 is
    # the bound firing and >=128 is a signal death. Every other nonzero status
    # is the probe's own verdict that the endpoint is gone.
    if [ "$endpoint_rc" -eq 0 ]; then
      endpoint="endpoint: alive (backend=$backend window=$window)"
    elif [ "$endpoint_rc" -eq 124 ] || [ "$endpoint_rc" -ge 128 ]; then
      endpoint="endpoint: error (backend=$backend window=$window - the endpoint read died or hit its ${ENDPOINT_TIMEOUT}s bound; the digest continued past it)"
    else
      endpoint="endpoint: dead (backend=$backend window=$window)"
    fi
  else
    endpoint='endpoint: unknown (no window recorded)'
  fi
  print_meta_line "$meta" "$id" "$endpoint"
done
[ "$META_FOUND" -eq 1 ] || printf '(none)\n'

subsection "Orphan status logs (state/*.status without matching .meta)"
ORPHAN_STATUS_FOUND=0
for status in "$STATE"/*.status; do
  [ -f "$status" ] || continue
  id=$(basename "$status" .status)
  [ -f "$STATE/$id.meta" ] && continue
  ORPHAN_STATUS_FOUND=1
  fm_cap_line_var "$(last_status_line "$status")"
  printf '%s (%s) - latest: %s\n' "$id" "$status" "$FM_LINE_CAP_LINE"
done
[ "$ORPHAN_STATUS_FOUND" -eq 1 ] || printf '(none)\n'


# --- 7. network checks ------------------------------------------------------
# Deliberately here and not later: these lines are actionable (a stuck clone, a
# secondmate that could not be relaunched, broken GitHub auth), and the section
# after this one is the curated memory a truncated tail is meant to take first.
# Deliberately here and not earlier: this is the last point in the digest, so the
# worker started at step 1 has had the whole composition above to finish in. It
# is a NON-BLOCKING read either way - whatever the worker has published by now is
# printed, and whatever it has not is named as not yet confirmed.
stage network-checks
section "NETWORK CHECKS"
if [ "$READ_ONLY" -eq 1 ]; then
  printf 'skipped (read-only session) - GitHub authentication, project clone refresh,\n'
  printf 'They need the fleet lock, and this session must not spawn, steer, or merge, so it\n'
  printf 'has no action they would gate. The session holding the lock runs them.\n'
else
  "$SCRIPT_DIR/fm-startup-network.sh" harvest --pid $$ 2>&1 || true
fi

# --- 8. context digest -----------------------------------------------------
# Last of the bulk sections: curated memory is stable session to session and
# recoverable with one read, so it is the cheapest thing for a tail cut to take.
stage context
section "CONTEXT"
if [ -f "$DATA/backlog/decisions/.fm-memory" ]; then
  subsection "Current decisions"
  if CURRENT_DECISIONS=$(node "$SCRIPT_DIR/fm-backlog-md/decisions.cjs" render "$DATA/backlog/decisions" 2>&1); then
    if [ "$READ_ONLY" -eq 1 ]; then
      printf '%s\n' "$CURRENT_DECISIONS"
    else
      CURRENT_FILE=$(mktemp "$DATA/.decision-current.XXXXXX") || exit 1
      if printf '%s\n' "$CURRENT_DECISIONS" > "$CURRENT_FILE" && mv -f "$CURRENT_FILE" "$DATA/decision-current.md"; then
        print_file_or_absent "$DATA/decision-current.md" "data/decision-current.md"
      else
        rm -f "$CURRENT_FILE"
        printf '%s\n' 'Decision memory unavailable: could not write current view'
      fi
    fi
  else
    printf 'Decision memory unavailable: %s\n' "$CURRENT_DECISIONS"
  fi
else
  print_file_or_absent "$DATA/projects.md" "data/projects.md"
  print_file_or_absent "$DATA/captain.md" "data/captain.md"
  print_file_or_absent "$DATA/learnings.md" "data/learnings.md"
  if DECISIONS_UNFILED_OUT=$("$SCRIPT_DIR/fm-decisions-unfiled.sh" --captain "$DATA/captain.md" 2>&1); then
    if [ -n "$DECISIONS_UNFILED_OUT" ]; then
      subsection "Unfiled rulings (decisions harvest)"
      printf '%s\n' "$DECISIONS_UNFILED_OUT"
    fi
  else
    subsection "Unfiled rulings (decisions harvest)"
    printf 'check unavailable (exit %s)\n' "$?"
  fi
fi

# --- 9. closing reminder -----------------------------------------------
stage next-step
section "NEXT STEP"
if [ "$READ_ONLY" -eq 1 ]; then
  cat <<'EOF'
This session did not acquire the fleet lock. Stay read-only: do not arm,
drain, spawn, steer, merge, or repair fleet state from here. Only a session
with verified fleet-lock ownership may perform mutable follow-up.

EOF
else
cat <<EOF
Follow the supervision operating instructions block above for harness '$PRIMARY_HARNESS'.
This script never starts supervision itself.

EOF
fi
cat <<'EOF'
The digest above is complete for this session start. The READ-ONCE CONTRACT
section near the top of it governs what may still be read from disk.
EOF

if [ "$READ_ONLY" -eq 0 ] && [ "$REEMIT" -eq 0 ]; then
  COMPLETION_RECORDED=0
  COMPLETION_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
  fm_session_pid_valid "$COMPLETION_PID" || COMPLETION_PID=
  COMPLETION_TMP=$(mktemp "$STATE/.session-start-complete.XXXXXX" 2>/dev/null || true)
  if [ -n "$COMPLETION_PID" ] && [ -n "$COMPLETION_TMP" ] \
    && printf '%s\n' "$COMPLETION_PID" > "$COMPLETION_TMP" 2>/dev/null \
    && mv -f "$COMPLETION_TMP" "$COMPLETION_FILE" 2>/dev/null; then
    COMPLETION_RECORDED=1
  else
    [ -z "$COMPLETION_TMP" ] || rm -f "$COMPLETION_TMP" 2>/dev/null || true
    printf '\nSESSION_START_COMPLETION: not recorded - the next clear or compact will run a full startup.\n'
  fi
  if [ "$SESSION_SOURCE" = startup ] && [ "$COMPLETION_RECORDED" -eq 1 ] && [ -n "$AGENTS_START_HASH" ]; then
    if ! write_agents_baseline "$COMPLETION_PID" "$AGENTS_START_HASH"; then
      printf '\nSESSION_START_AGENTS_BASELINE: not recorded - a later supported rebuild will re-emit AGENTS.md.\n'
    fi
  fi
fi

exit 0
