#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
REG="$DATA/secondmates.md"
MAIN_BACKLOG="$DATA/backlog.md"
MAX_BYTES=1048576
OUTBOX_REL=state/handoff/reclaim.outbox.md

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  cat >&2 <<'EOF'
Move Queued items from a remote second mate's backlog into this home's backlog.

Usage:
  fm-backlog-reclaim.sh <secondmate-id> [--dry-run] --all
  fm-backlog-reclaim.sh <secondmate-id> [--dry-run] <item-key>...

--all selects every Queued item in the second mate's backlog. In-flight and
Done items are refused. A blocked-by edge whose blocker is Done in the second
mate's backlog or its done-archive.md is cleared there rather than stranding the
move. --dry-run reads the second mate's backlog, rehearses
the same move on scratch copies of both backlogs, and changes nothing.
Rerunning after an interrupted reclaim finishes the staged set.
EOF
  exit 2
}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}

backlog_key_section() { # <file> <key>
  [ -f "$1" ] || return 1
  awk -v key="$2" '
    BEGIN { section = "## Queued" }
    /^##[[:space:]]+/ { section=$0; sub(/^##[[:space:]]+/, "## ", section); sub(/[[:space:]]+$/, "", section); next }
    /^- \[[ x]\] / {
      rest=$0; sub(/^- \[[ x]\] +/, "", rest); id=rest; sub(/[ \t].*/, "", id)
      if (id == key) { print section; found=1; exit }
    }
    END { exit found ? 0 : 1 }
  ' "$1"
}

queued_keys() { # <file>
  awk '
    /^##[[:space:]]+/ { queued = ($0 ~ /^##[[:space:]]+Queued[[:space:]]*$/); next }
    queued && /^- \[[ x]\] / {
      rest=$0; sub(/^- \[[ x]\] +/, "", rest); id=rest; sub(/[ \t].*/, "", id)
      if (id != "" && !seen[id]++) print id
    }
  ' "$1"
}

held_count() { # <file> <keys...>
  local file=$1 key count=0
  shift
  for key in "$@"; do
    if grep -Eq "^- \[[ x]\] $key .*\(hold: " "$file"; then count=$((count + 1)); fi
  done
  printf '%s\n' "$count"
}

remote() { # <fm-command> [args...]
  "$SCRIPT_DIR/fm-on.sh" "$ID" "$@" </dev/null
}

# A 255 from fm-on means the remote step may or may not have run.
remote_failed() { # <rc> <step>
  if [ "$1" -eq 255 ]; then
    die "$2 on $ID was unavailable or its completion is unknown; rerun the reclaim to reconcile"
  fi
  die "$2 on $ID failed (exit $1)"
}

rehearse_move() { # <source-copy> <keys...>
  local source=$1 out
  shift
  if [ -f "$MAIN_BACKLOG" ]; then
    cp -p -- "$MAIN_BACKLOG" "$SCRATCH/main.md" || die "cannot copy this home's backlog for the rehearsal"
  else
    printf '## In flight\n\n## Queued\n\n## Done\n' > "$SCRATCH/main.md"
  fi
  if ! out=$(fm_tasks_axi_mv_past_done_blockers "$source" "$SCRATCH/archive.md" "$SCRATCH/main.md" "$@"); then
    printf '%s\n' "$out" >&2
    die "the move would be refused; nothing was staged"
  fi
}

[ "$#" -ge 2 ] || usage
ID=$1
shift
case "$ID" in ''|-*|*[!A-Za-z0-9._-]*) die "invalid secondmate id: $ID" ;; esac
DRY_RUN=0
ALL=0
KEYS=()
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --all) ALL=1 ;;
    -*) usage ;;
    *[!A-Za-z0-9._-]*) die "invalid item key: $arg" ;;
    *) KEYS+=("$arg") ;;
  esac
done
if [ "$ALL" -eq 1 ] && [ "${#KEYS[@]}" -gt 0 ]; then die "name the item keys or pass --all, not both"; fi
if [ "$ALL" -eq 0 ] && [ "${#KEYS[@]}" -eq 0 ]; then usage; fi
[ ! -L "$MAIN_BACKLOG" ] || die "this home's backlog must not be a symlink"
if [ -e "$MAIN_BACKLOG" ] && [ ! -f "$MAIN_BACKLOG" ]; then die "this home's backlog is not a regular file"; fi
fm_tasks_axi_compatible || die "a compatible tasks-axi is required for an atomic reclaim; run bin/fm-bootstrap.sh for the required version"

REGISTRY_LOCK=$(secondmate_registry_lock_path "$STATE")
HANDOFF_LOCK="$STATE/.backlog-handoff-$ID.lock"
SCRATCH=
release_all() {
  [ -z "$SCRATCH" ] || rm -rf -- "$SCRATCH"
  fm_lock_release "$HANDOFF_LOCK" 2>/dev/null || true
  fm_lock_release "$REGISTRY_LOCK" 2>/dev/null || true
}
fm_lock_acquire_wait "$REGISTRY_LOCK" || die "cannot lock the secondmate registry"
trap release_all EXIT
fm_lock_acquire_wait "$HANDOFF_LOCK" || die "cannot lock backlog transfers for $ID"
[ "$(secondmate_registry_field "$REG" "$ID" remote 2>/dev/null || true)" = 1 ] \
  || die "$ID is not a registered remote second mate; a local second mate's items move with tasks-axi mv directly"
SCRATCH=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-backlog-reclaim.XXXXXX") || die "cannot create reclaim scratch"

rc=0
STATUS=$(remote fm-backlog-receive.sh reclaim-status) || rc=$?
[ "$rc" -eq 0 ] || remote_failed "$rc" "reading the staged reclaim"
case "$STATUS" in
  none) STAGED_KEYS= ;;
  'staged bytes='*' sha256='*' keys='*) STAGED_KEYS=${STATUS##* keys=} ;;
  *) die "unexpected reclaim status from $ID: $STATUS" ;;
esac

if [ -z "$STAGED_KEYS" ]; then
  rc=0
  remote fm-remote-file.sh get data/backlog.md "$MAX_BYTES" > "$SCRATCH/source.md" || rc=$?
  [ "$rc" -eq 0 ] || remote_failed "$rc" "reading the backlog"
  rc=0
  remote fm-remote-file.sh get data/done-archive.md "$MAX_BYTES" > "$SCRATCH/archive.md" 2>/dev/null || rc=$?
  case "$rc" in
    0) ;;
    255) remote_failed "$rc" "reading the done archive" ;;
    *) : > "$SCRATCH/archive.md" ;;
  esac
  if [ "$ALL" -eq 1 ]; then
    while IFS= read -r key; do KEYS+=("$key"); done < <(queued_keys "$SCRATCH/source.md")
  fi
  REFUSED=()
  SELECTED=()
  ALREADY=()
  for key in ${KEYS[@]+"${KEYS[@]}"}; do
    if section=$(backlog_key_section "$SCRATCH/source.md" "$key"); then
      if [ "$section" != '## Queued' ]; then
        REFUSED+=("$key (${section#'## '})")
      elif backlog_key_section "$MAIN_BACKLOG" "$key" >/dev/null 2>&1; then
        REFUSED+=("$key (already in this home's backlog)")
      else
        SELECTED+=("$key")
      fi
    elif backlog_key_section "$MAIN_BACKLOG" "$key" >/dev/null 2>&1; then
      ALREADY+=("$key")
    else
      REFUSED+=("$key (missing)")
    fi
  done
  [ "${#REFUSED[@]}" -eq 0 ] || die "reclaim moves only Queued items this home does not hold; refusing: ${REFUSED[*]}"
  if [ "${#SELECTED[@]}" -eq 0 ]; then
    printf 'reclaim %s: nothing to move (already here: %s)\n' "$ID" "${#ALREADY[@]}"
    exit 0
  fi
  rehearse_move "$SCRATCH/source.md" "${SELECTED[@]}"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'reclaim %s (dry run): would move %s Queued item(s), %s held; %s already here\n' \
      "$ID" "${#SELECTED[@]}" "$(held_count "$SCRATCH/main.md" "${SELECTED[@]}")" "${#ALREADY[@]}"
    printf '  %s\n' "${SELECTED[@]}"
    exit 0
  fi
  rc=0
  STATUS=$(remote fm-backlog-receive.sh reclaim-stage "${SELECTED[@]}") || rc=$?
  [ "$rc" -eq 0 ] || remote_failed "$rc" "staging the reclaim"
else
  IFS=, read -r -a STAGED_ARRAY <<< "$STAGED_KEYS"
  if [ "$ALL" -eq 0 ] && [ "$(printf '%s\n' "${KEYS[@]}" | LC_ALL=C sort -u | paste -sd, -)" != "$(printf '%s\n' "${STAGED_ARRAY[@]}" | LC_ALL=C sort -u | paste -sd, -)" ]; then
    die "an earlier reclaim of $STAGED_KEYS is still staged on $ID; rerun with exactly those keys or --all to finish it"
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'reclaim %s (dry run): an earlier reclaim of %s is staged; rerun without --dry-run to finish it\n' "$ID" "$STAGED_KEYS"
    exit 0
  fi
fi

case "$STATUS" in 'staged bytes='*' sha256='*' keys='?*) ;; *) die "unexpected staging reply from $ID: $STATUS" ;; esac
BYTES=$(printf '%s\n' "$STATUS" | sed -n 's/^staged bytes=\([0-9][0-9]*\) .*/\1/p')
HASH=$(printf '%s\n' "$STATUS" | sed -n 's/.* sha256=\([0-9a-f]*\) .*/\1/p')
STAGED_KEYS=${STATUS##* keys=}
IFS=, read -r -a STAGED_ARRAY <<< "$STAGED_KEYS"
[ -n "$BYTES" ] && [ "${#HASH}" -eq 64 ] || die "malformed staging commitment from $ID: $STATUS"

rc=0
remote fm-remote-file.sh get "$OUTBOX_REL" "$MAX_BYTES" > "$SCRATCH/outbox.md" || rc=$?
[ "$rc" -eq 0 ] || remote_failed "$rc" "reading the staged reclaim"
[ "$(LC_ALL=C wc -c < "$SCRATCH/outbox.md" | tr -d ' ')" = "$BYTES" ] && [ "$(sha256_file "$SCRATCH/outbox.md")" = "$HASH" ] \
  || die "the staged reclaim read from $ID does not match its commitment; nothing local changed"

TO_INSERT=()
for key in "${STAGED_ARRAY[@]}"; do
  backlog_key_section "$MAIN_BACKLOG" "$key" >/dev/null 2>&1 || TO_INSERT+=("$key")
done
if [ "${#TO_INSERT[@]}" -gt 0 ]; then
  [ -f "$MAIN_BACKLOG" ] || { mkdir -p "$DATA"; printf '## In flight\n\n## Queued\n\n## Done\n' > "$MAIN_BACKLOG"; }
  if ! out=$(tasks-axi mv "${TO_INSERT[@]}" --file "$SCRATCH/outbox.md" --to "$MAIN_BACKLOG" --backend markdown 2>&1); then
    printf '%s\n' "$out" >&2
    die "inserting the reclaimed items failed; they stay staged on $ID, rerun to finish"
  fi
fi
for key in "${STAGED_ARRAY[@]}"; do
  backlog_key_section "$MAIN_BACKLOG" "$key" >/dev/null 2>&1 \
    || die "$key is not in this home's backlog after the insert; it stays staged on $ID"
done

rc=0
RELEASE=$(remote fm-backlog-receive.sh reclaim-release "$BYTES" "$HASH") || rc=$?
if [ "$rc" -eq 255 ]; then
  die "the items are in this home's backlog, but releasing them on $ID is unconfirmed; rerun the reclaim to release them"
elif [ "$rc" -ne 0 ]; then
  die "the items are in this home's backlog, but $ID refused to release its staged copy (exit $rc)"
fi
printf 'reclaimed %s: moved=%s already=%s (%s)\n' "$ID" "${#TO_INSERT[@]}" "$((${#STAGED_ARRAY[@]} - ${#TO_INSERT[@]}))" "$RELEASE"
