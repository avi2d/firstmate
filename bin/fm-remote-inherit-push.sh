#!/usr/bin/env bash
# Push the declared inherited-material allowlist to one remote secondmate route.
# Usage: fm-remote-inherit-push.sh <secondmate-id> <generation>
#
# The item set is derived from the ONE declared owner
# (FM_INHERITABLE_CONFIG in bin/fm-config-inherit-lib.sh), the same declaration
# the receiving bin/fm-remote-inherit.sh enforces, so the two implementations in
# one code revision cannot drift silently. Different local and remote revisions
# fail closed as documented by that owner. FM_CONFIG_INHERIT_LIVE=1 marks a live
# convergence push into an already-running home and skips session-scoped items,
# exactly as the local propagation path does.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}
file_link_count() {
  if [ "$(uname)" = Darwin ]; then /usr/bin/stat -f %l "$1" 2>/dev/null; else stat -c %h "$1" 2>/dev/null; fi
}
[ "$#" -eq 2 ] || { echo "usage: fm-remote-inherit-push.sh <secondmate-id> <generation>" >&2; exit 2; }
ID=$1
GENERATION=$2
case "$ID" in ''|*[!A-Za-z0-9._-]*) die "invalid secondmate id: $ID" ;; esac
case "$GENERATION" in ''|*[!0-9]*) die "generation must be a positive integer" ;; esac
[ "${#GENERATION}" -le 18 ] && [ "$GENERATION" -ge 1 ] || die "generation is outside the supported range"
REMOTE=$(secondmate_registry_field "$DATA/secondmates.md" "$ID" remote 2>/dev/null || true)
[ "$REMOTE" = 1 ] || die "secondmate $ID is not a remote route"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-remote-inherit-push.XXXXXX") || die "cannot create inheritance staging directory"
trap 'rm -rf -- "$TMP"' EXIT
EMPTY="$TMP/empty"
: > "$EMPTY"
EMPTY_HASH=$(sha256_file "$EMPTY") || die "cannot hash empty inheritance payload"

ITEMS=$(fm_config_inherit_items)
BATCH="$TMP/batch.in"
: > "$BATCH" || die "cannot stage batched inheritance"
BATCH_ITEMS=0
BATCH_FAILED=0
batch_item_error() {
  printf 'error: %s\n' "$1"
  BATCH_FAILED=1
}
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  if [ "${FM_CONFIG_INHERIT_LIVE:-0}" = 1 ]; then
    case "$rel" in
      config/*)
        if fm_config_inherit_item_session_scoped "${rel#config/}"; then
          printf 'unchanged: %s\n' "$rel"
          continue
        fi
        ;;
    esac
  fi
  case "$rel" in
    config/*) source="$CONFIG/${rel#config/}" ;;
    data/*) source="$DATA/${rel#data/}" ;;
  esac
  source_present=$(fm_config_source_present "$source") || exit 1
  if [ "$source_present" = 1 ]; then
    # A config item may be the captain's own symlink into one source of truth
    # (crew-dispatch.json into the skills repo); follow it to the target bytes.
    # `-f` still refuses a link that does not resolve to a regular file.
    if [ "$rel" = data/captain-shared.md ]; then
      if ! { [ -f "$source" ] && [ ! -L "$source" ]; }; then
        batch_item_error "inherited source is unsafe: $source"
        continue
      fi
    elif [ ! -f "$source" ]; then
      batch_item_error "inherited source is unsafe: $source"
      continue
    fi
    if [ "$(file_link_count "$source")" != 1 ]; then
      batch_item_error "inherited source is hardlinked: $source"
      continue
    fi
    if [ "$rel" = data/captain-shared.md ]; then
      if ! missing=$(shared_captain_header_valid "$source"); then
        reason="shared captain preferences have no valid primary-authoritative header"
        [ -z "$missing" ] || reason="$reason: missing \"$missing\""
        batch_item_error "$reason"
        continue
      fi
    fi
    snapshot="$TMP/$(printf '%s' "$rel" | tr '/' '_')"
    cp -p -- "$source" "$snapshot" || { batch_item_error "cannot snapshot inherited source: $source"; continue; }
    if ! { [ -f "$snapshot" ] && [ ! -L "$snapshot" ]; }; then
      batch_item_error "inherited source snapshot is unsafe: $source"
      continue
    fi
    bytes=$(LC_ALL=C wc -c < "$snapshot" | tr -d ' ')
    if ! hash=$(sha256_file "$snapshot"); then
      batch_item_error "cannot hash inherited source: $source"
      continue
    fi
    if [ "$bytes" -gt 1048576 ]; then
      batch_item_error "inherited source exceeds the byte bound: $source"
      continue
    fi
    printf 'put %s %s %s\n' "$rel" "$bytes" "$hash" >> "$BATCH" || exit 1
    printf 'content %s\n' "$(base64 < "$snapshot" | tr -d '\n')" >> "$BATCH" || exit 1
    BATCH_ITEMS=$((BATCH_ITEMS + 1))
  else
    printf 'absent %s 0 %s\n' "$rel" "$EMPTY_HASH" >> "$BATCH" || exit 1
    BATCH_ITEMS=$((BATCH_ITEMS + 1))
  fi
done <<EOF
$ITEMS
EOF
if [ "$BATCH_ITEMS" -gt 0 ]; then
  # One transport call carries every item; this loop's heredoc stays the
  # control stream because the remote call reads its own explicit redirect.
  if ! "$SCRIPT_DIR/fm-on.sh" --stdin "$ID" fm-remote-inherit.sh batch "$GENERATION" < "$BATCH"; then
    BATCH_FAILED=1
  fi
fi
[ "$BATCH_FAILED" -eq 0 ] || exit 1
