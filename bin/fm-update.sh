#!/usr/bin/env bash
# Fast-forward this copy to its configured update source.
#
# Usage: fm-update.sh [--help]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

usage() {
  cat >&2 <<'EOF'
usage: fm-update.sh [--reconcile-redundant-root] [--help]
  --reconcile-redundant-root  move this firstmate repo off a diverged line with
                              reset --keep when a content merge into origin's
                              default branch is clean and equals its tree, as on
                              a remote code root whose mirror was rewritten
EOF
}

reconcile_redundant_root=no
case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --reconcile-redundant-root) reconcile_redundant_root=yes; shift ;;
esac
[ $# -eq 0 ] || { usage; exit 1; }

# --- self-update source ----------------------------------------------------

SELF_UPDATE_SOURCE_FILE="$FM_HOME/config/self-update-source"
SELF_UPDATE_REMOTE=""
SELF_UPDATE_BRANCH=""

self_update_source_refuse() {  # <reason>
  echo "error: $SELF_UPDATE_SOURCE_FILE: $1; fix it or remove it to update from origin" >&2
  exit 1
}

# Parse config/self-update-source into SELF_UPDATE_REMOTE and SELF_UPDATE_BRANCH.
# Absent leaves both empty (the origin path); anything present but unusable exits.
read_self_update_source() {
  local content remote branch extra lines
  [ -e "$SELF_UPDATE_SOURCE_FILE" ] || [ -L "$SELF_UPDATE_SOURCE_FILE" ] || return 0
  if [ -L "$SELF_UPDATE_SOURCE_FILE" ] || [ ! -f "$SELF_UPDATE_SOURCE_FILE" ] \
    || [ ! -r "$SELF_UPDATE_SOURCE_FILE" ]; then
    self_update_source_refuse "not a readable regular file"
  fi
  content=$(cat "$SELF_UPDATE_SOURCE_FILE") || self_update_source_refuse "cannot be read"
  lines=$(printf '%s\n' "$content" | grep -c '')
  [ "$lines" -eq 1 ] || self_update_source_refuse "expected exactly one line \"<remote> <branch>\""
  case "$content" in
    *[[:cntrl:]]*) self_update_source_refuse "contains a control character" ;;
  esac
  read -r remote branch extra <<EOF
$content
EOF
  if [ -z "$remote" ] || [ -z "$branch" ] || [ -n "$extra" ]; then
    self_update_source_refuse "expected exactly one line \"<remote> <branch>\""
  fi
  case "$remote" in
    -*|*/*) self_update_source_refuse "invalid remote name '$remote'" ;;
  esac
  git -C "$FM_ROOT" remote get-url "$remote" >/dev/null 2>&1 \
    || self_update_source_refuse "remote '$remote' does not exist in $FM_ROOT"
  case "$branch" in
    -*) self_update_source_refuse "invalid branch name '$branch'" ;;
  esac
  git check-ref-format "refs/heads/$branch" >/dev/null 2>&1 \
    || self_update_source_refuse "invalid branch name '$branch'"
  SELF_UPDATE_REMOTE=$remote
  SELF_UPDATE_BRANCH=$branch
}

read_self_update_source

# --- main firstmate repo ---------------------------------------------------

if [ -n "$SELF_UPDATE_REMOTE" ]; then
  echo "self-update source: $SELF_UPDATE_REMOTE $SELF_UPDATE_BRANCH (config/self-update-source)"
  primary_base="refs/remotes/$SELF_UPDATE_REMOTE/$SELF_UPDATE_BRANCH"
  if git -C "$FM_ROOT" fetch --quiet --no-tags "$SELF_UPDATE_REMOTE" \
    "+refs/heads/$SELF_UPDATE_BRANCH:$primary_base" 2>/dev/null; then
    ff_target "$FM_ROOT" "firstmate" "$primary_base" "$reconcile_redundant_root"
  else
    FF_STATUS="skipped"
    echo "firstmate: skipped: fetch of $SELF_UPDATE_REMOTE $SELF_UPDATE_BRANCH failed"
  fi
else
  ff_target "$FM_ROOT" "firstmate" origin "$reconcile_redundant_root"
fi
if ff_target_updated; then
  # A fast-forward changes bin/'s bytes out from under any locally armed
  # fm-procevent-when watch's trust binding, with no tampering involved; left
  # alone, the very next fire is refused and the watch dies silently. Refresh
  # every such watch now, right after the update that broke it. FM_ROOT_OVERRIDE
  # is passed explicitly rather than relying on the script's own location: this
  # process's own FM_ROOT is the repo that was just updated, which is not
  # always where this very script file happens to live (FM_ROOT_OVERRIDE, as
  # this test suite uses to point fm-update.sh at a fixture checkout).
  FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" "$SCRIPT_DIR/fm-procevent-when.sh" rebind-all || true
fi

if ff_target_instructions_changed; then
  echo "reread-firstmate: yes"
else
  echo "reread-firstmate: no"
fi
