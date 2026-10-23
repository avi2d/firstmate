#!/usr/bin/env bash
# fm-merge-hold.sh holds one pull request for the captain across every merge path.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

VERSION=fm-merge-hold-v1

usage() {
  cat <<'EOF'
Usage: fm-merge-hold.sh hold <pr-url> --reason <text>
       fm-merge-hold.sh release <pr-url>
       fm-merge-hold.sh open <pr-url>

hold writes state/merge-holds/<provider>/<host>/<path>/<number>.hold with
the format version, the parsed pull request identity, the UTC epoch, and the
cleaned reason, and repeating it keeps the existing record. release deletes
the record and succeeds when none exists. open exits 0 when a readable hold
names this pull request, 1 when none exists, and 2 when the answer could not
be established. A hold blocks the automatic merge and the manual merge until
it is released.
EOF
  exit 2
}

state_device() {
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  fm_pr_file_device "$STATE"
}

record_path() {
  local dir seg
  local -a segs
  case "$FM_PR_PROVIDER" in github|gitlab|gerrit|forgejo) ;; *) return 1 ;; esac
  case "$FM_PR_HOST" in ''|*/*|.*|*.|*..*) return 1 ;; esac
  case "$FM_PR_NUMBER" in ''|*[!0-9]*) return 1 ;; esac
  dir="$STATE/merge-holds/$FM_PR_PROVIDER/$FM_PR_HOST"
  IFS=/ read -ra segs <<< "$FM_PR_PATH"
  [ "${#segs[@]}" -ge 1 ] || return 1
  for seg in "${segs[@]}"; do
    case "$seg" in ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;; esac
    dir="$dir/$seg"
  done
  printf '%s/%s.hold' "$dir" "$FM_PR_NUMBER"
}

record_matches() {
  local record=$1 device=$2 version provider host path number _epoch _reason
  fm_pr_private_file_valid "$record" 600 "$device" || return 1
  exec 8< "$record" || return 1
  IFS= read -r version <&8 || { exec 8<&-; return 1; }
  IFS= read -r provider <&8 || { exec 8<&-; return 1; }
  IFS= read -r host <&8 || { exec 8<&-; return 1; }
  IFS= read -r path <&8 || { exec 8<&-; return 1; }
  IFS= read -r number <&8 || { exec 8<&-; return 1; }
  IFS= read -r _epoch <&8 || { exec 8<&-; return 1; }
  IFS= read -r _reason <&8 || { exec 8<&-; return 1; }
  if IFS= read -r _extra <&8; then
    exec 8<&-
    return 1
  fi
  exec 8<&-
  [ "$version" = "$VERSION" ] || return 1
  case "$_epoch" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$_reason" ] || return 1
  [ "$provider" = "$FM_PR_PROVIDER" ] \
    && [ "$host" = "$FM_PR_HOST" ] \
    && [ "$path" = "$FM_PR_PATH" ] \
    && [ "$number" = "$FM_PR_NUMBER" ]
}

parse_url() {
  fm_pr_url_parse "$1" 2>/dev/null || {
    echo "error: not a canonical pull request URL: $1" >&2
    return 1
  }
}

cmd_open() {
  local record device
  [ "$#" -eq 1 ] || usage
  parse_url "$1" || exit 2
  device=$(state_device) || exit 2
  record=$(record_path) || exit 2
  [ -e "$record" ] || [ -L "$record" ] || exit 1
  record_matches "$record" "$device" || exit 2
}

cmd_hold() {
  local url=$1 reason=$2 record device tmp now parent
  parse_url "$url" || exit 2
  case "$reason" in '') echo "error: a merge hold needs a reason" >&2; exit 2 ;; esac
  reason=$(printf '%s' "$reason" | fm_wake_clean_field)
  case "$reason" in ''|*[!\ ]*) ;; *) echo "error: a merge hold needs a reason" >&2; exit 2 ;; esac
  [ "${#reason}" -le 1024 ] || { echo "error: the reason is longer than 1024 characters" >&2; exit 2; }
  device=$(state_device) || { echo "error: the home state cannot be read" >&2; exit 1; }
  record=$(record_path) || { echo "error: the pull request identity cannot name a hold" >&2; exit 1; }
  if [ -e "$record" ] || [ -L "$record" ]; then
    record_matches "$record" "$device" || { echo "error: a hold is recorded but cannot be read; refusing to overwrite it" >&2; exit 1; }
    printf 'already held: %s\n' "$FM_PR_URL"
    return 0
  fi
  parent=${record%/*}
  mkdir -p -- "$parent" || { echo "error: the hold directory cannot be created" >&2; exit 1; }
  fm_pr_regular_destination_on_device_or_absent "$record" "$device" \
    || { echo "error: the hold destination is not a regular file" >&2; exit 1; }
  umask 077
  tmp=$(mktemp "$STATE/.fm-merge-hold.XXXXXX") || { echo "error: the hold cannot be staged" >&2; exit 1; }
  now=$(date +%s)
  if ! printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
      "$VERSION" "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" "$now" "$reason" > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! record_matches "$tmp" "$device" \
    || ! fm_pr_regular_destination_on_device_or_absent "$record" "$device" \
    || ! mv -f -- "$tmp" "$record" \
    || ! record_matches "$record" "$device"; then
    rm -f -- "$tmp"
    echo "error: the hold cannot be published" >&2
    return 1
  fi
  printf 'held: %s\n' "$FM_PR_URL"
}

cmd_release() {
  local record device
  [ "$#" -eq 1 ] || usage
  parse_url "$1" || exit 2
  device=$(state_device) || { echo "error: the home state cannot be read" >&2; exit 1; }
  record=$(record_path) || { echo "error: the pull request identity cannot name a hold" >&2; exit 1; }
  if [ -e "$record" ] || [ -L "$record" ]; then
    [ -f "$record" ] && [ ! -L "$record" ] || { echo "error: the hold destination is not a regular file" >&2; exit 1; }
    rm -f -- "$record" || { echo "error: the hold cannot be removed" >&2; exit 1; }
    printf 'released: %s\n' "$FM_PR_URL"
  else
    printf 'no hold recorded for %s\n' "$FM_PR_URL"
  fi
}

[ "$#" -ge 1 ] || usage
cmd=$1
shift
case "$cmd" in
  open) cmd_open "$@" ;;
  hold)
    [ "$#" -ge 3 ] || usage
    url=$1
    shift
    [ "${1:-}" = --reason ] || usage
    shift
    cmd_hold "$url" "$*"
    ;;
  release) cmd_release "$@" ;;
  *) usage ;;
esac
