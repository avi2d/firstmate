#!/usr/bin/env bash
# Usage: fm-remote-home-seed.sh --exec [--summary TEXT] [--scope TEXT] [--session NAME]
#   <route> <ssh-alias> <remote-root> <remote-home> {<project>[=<origin-url>]...|--no-projects}
# Seeding writes nothing under projects/ and needs no fleet sync first.
#
# Known provisioning failure rolls the registry back. SSH status 255 preserves
# the route and any newly scaffolded brief because completion is unknown and a same-route rerun converges.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
REG="$DATA/remote-homes.md"
MAX_MANIFEST_BYTES=1048576

# shellcheck source=bin/fm-remote-registry-lib.sh
. "$SCRIPT_DIR/fm-remote-registry-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-remote-readiness-lib.sh
. "$SCRIPT_DIR/fm-remote-readiness-lib.sh"
# shellcheck source=bin/fm-project-origin-lib.sh
. "$SCRIPT_DIR/fm-project-origin-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,3p' "$0" | sed 's/^# //'; exit 2; }
encode() { base64 | tr -d '\n'; }
safe_id() { case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac; }

normalize_registry_text() {
  awk '
    {
      gsub(/[;()]/, " ")
      gsub(/[[:space:]]+/, " ")
      sub(/^ /, "")
      sub(/ $/, "")
      if ($0 != "") out = out (out == "" ? "" : " ") $0
    }
    END { print out }
  '
}

TMP=
REGISTRY_LOCK=
REGISTRY_LOCK_HELD=0
cleanup() {
  [ -z "$TMP" ] || rm -rf -- "$TMP"
  if [ "$REGISTRY_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$REGISTRY_LOCK"
    REGISTRY_LOCK_HELD=0
  fi
}
trap cleanup EXIT

EXEC_SUMMARY=
EXEC_SCOPE=
EXEC_SESSION=fm-remote
[ "${1:-}" = --exec ] || usage
shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    --summary|--scope|--session)
      [ "$#" -ge 2 ] || die "$1 needs a value"
      case "$1" in
        --summary) EXEC_SUMMARY=$2 ;;
        --scope) EXEC_SCOPE=$2 ;;
        --session) EXEC_SESSION=$2 ;;
      esac
      shift 2
      ;;
    --) shift; break ;;
    -*) die "unknown execution-home seed option: $1" ;;
    *) break ;;
  esac
done
[ "$#" -ge 5 ] || usage
ID=$1
HOST=$2
REMOTE_ROOT=$3
REMOTE_HOME=$4
shift 4
safe_id "$ID" || die "invalid route id: $ID"
case "$EXEC_SESSION" in ''|*[!A-Za-z0-9._-]*) die "invalid Herdr session name: $EXEC_SESSION" ;; esac
case "$HOST" in ''|-*|*[!A-Za-z0-9._-]*) die "invalid SSH config alias: $HOST" ;; esac
for path in "$REMOTE_ROOT" "$REMOTE_HOME"; do
  case "$path" in /*) ;; *) die "remote root and home must be absolute paths" ;; esac
  case "$path" in *';'*|*')'*|*$'\n'*|*$'\r'*|*$'\t'*) die "remote root or home contains a registry delimiter" ;; esac
  case "/$path/" in */../*|*/./*) die "remote root or home contains traversal components" ;; esac
  case "$path" in *'//'*) die "remote root or home contains an empty path component" ;; esac
done
[ "$REMOTE_ROOT" != "$REMOTE_HOME" ] || die "remote root and home must be separate"
case "$REMOTE_HOME/" in "$REMOTE_ROOT/"*) die "remote home must not be inside the remote code root" ;; esac
case "$REMOTE_ROOT/" in "$REMOTE_HOME/"*) die "remote code root must not be inside the remote home" ;; esac

NO_PROJECTS=0
PROJECT_NAMES=()
PROJECT_ORIGINS=()
for arg in "$@"; do
  if [ "$arg" = --no-projects ]; then
    NO_PROJECTS=1
  else
    name=${arg%%=*}
    origin=
    case "$arg" in *=*) origin=${arg#*=} ;; esac
    safe_id "$name" || die "invalid project name: $name"
    case "$arg" in
      *=*) fm_project_origin_safe "$origin" \
        || die "project $name origin is not an accepted clone URL: $origin" ;;
    esac
    PROJECT_NAMES+=("$name")
    PROJECT_ORIGINS+=("$origin")
  fi
done
if [ "$NO_PROJECTS" -eq 1 ]; then
  [ "${#PROJECT_NAMES[@]}" -eq 0 ] || die "--no-projects cannot be combined with project names"
else
  [ "${#PROJECT_NAMES[@]}" -gt 0 ] || die "at least one project or --no-projects is required"
fi

mkdir -p "$STATE" || die "cannot create parent state directory"
REGISTRY_LOCK=$(fm_remote_registry_lock_path "$STATE")
fm_lock_acquire_wait "$REGISTRY_LOCK" || die "cannot lock the execution-home registry"
REGISTRY_LOCK_HELD=1

if [ -e "$REG" ] || [ -L "$REG" ]; then
  [ -f "$REG" ] && [ ! -L "$REG" ] || die "execution-home registry is unavailable or unsafe: $REG"
  fm_remote_registry_validate_bindings "$REG" \
    || die "$(fm_remote_registry_error)"
  if fm_remote_registry_line_for_id "$REG" "$ID"; then
    [ "$FM_REMOTE_REGISTRY_HOST" = "$HOST" ] \
      && [ "$FM_REMOTE_REGISTRY_ROOT" = "$REMOTE_ROOT" ] \
      && [ "$FM_REMOTE_REGISTRY_HOME" = "$REMOTE_HOME" ] \
      || die "route $ID is already registered to a different execution home"
  fi
fi

mkdir -p "$DATA"
[ -n "$EXEC_SUMMARY" ] || EXEC_SUMMARY="Headless execution home $ID on $HOST."
[ -n "$EXEC_SCOPE" ] || EXEC_SCOPE="Headless execution of remote worker tasks."
SUMMARY=$(printf '%s' "$EXEC_SUMMARY" | normalize_registry_text)
SCOPE=$(printf '%s' "$EXEC_SCOPE" | normalize_registry_text)
[ -n "$SUMMARY" ] && [ -n "$SCOPE" ] || die "execution-home summary and routing scope must be nonempty"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-remote-home-seed.XXXXXX") || die "cannot create seed staging directory"
REG_EXISTED=0
[ -f "$REG" ] && { cp "$REG" "$TMP/registry.before"; REG_EXISTED=1; }


PROJECTS_CSV=
: > "$TMP/project.records"
PROJECT_INDEX=0
for project in "${PROJECT_NAMES[@]+"${PROJECT_NAMES[@]}"}"; do
  ORIGIN=${PROJECT_ORIGINS[$PROJECT_INDEX]}
  PROJECT_INDEX=$((PROJECT_INDEX + 1))
  MODE_LINE=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-project-mode.sh" "$project") ||
    die "project $project does not resolve to a delivery posture (see the refusal above)"
  read -r MODE _ <<EOF
$MODE_LINE
EOF
  case "$MODE" in
    no-mistakes|direct-PR) ;;
    local-only) die "project $project is local-only and cannot be provisioned remotely" ;;
    *) die "project $project has unsupported delivery mode: $MODE" ;;
  esac
  # An origin named on the command line is authoritative. Reading one from a
  # clone this home happens to have is only a convenience for the already-cloned
  # case; it is never a reason to create one.
  if [ -z "$ORIGIN" ] && [ -d "$PROJECTS/$project/.git" ]; then
    ORIGIN=$(git -C "$PROJECTS/$project" remote get-url origin 2>/dev/null || true)
  fi
  [ -n "$ORIGIN" ] \
    || die "project $project has no origin; pass $project=<origin-url> so the remote host can clone it"
  fm_project_origin_safe "$ORIGIN" \
    || die "project $project origin is not an accepted clone URL: $ORIGIN"
  REGISTRY_LINE=$(awk -v p="$project" '$1 == "-" && $2 == p { print; exit }' "$DATA/projects.md" 2>/dev/null || true)
  [ -n "$REGISTRY_LINE" ] || die "project $project has no registry record"
  NAME_B64=$(printf '%s' "$project" | encode)
  ORIGIN_B64=$(printf '%s' "$ORIGIN" | encode)
  PROJECT_REG_B64=$(printf '%s' "$REGISTRY_LINE" | encode)
  MODE_B64=$(printf '%s' "$MODE" | encode)
  printf 'project=%s|%s|%s|%s\n' "$NAME_B64" "$ORIGIN_B64" "$PROJECT_REG_B64" "$MODE_B64" >> "$TMP/project.records"
  PROJECTS_CSV="${PROJECTS_CSV}${PROJECTS_CSV:+, }$project"
done

{
  printf 'schema=fm-remote-exec-home-provision.v1\n'
  printf 'id_b64=%s\n' "$(printf '%s' "$ID" | encode)"
  printf 'session_b64=%s\n' "$(printf '%s' "$EXEC_SESSION" | encode)"
  printf 'project_count=%s\n' "${#PROJECT_NAMES[@]}"
  cat "$TMP/project.records"
} > "$TMP/manifest"
MANIFEST_BYTES=$(LC_ALL=C wc -c < "$TMP/manifest" | tr -d ' ')
[ "$MANIFEST_BYTES" -le "$MAX_MANIFEST_BYTES" ] \
  || die "remote provisioning manifest exceeds the $MAX_MANIFEST_BYTES-byte bound"

TODAY=$(date +%F)
REG_TMP="$TMP/remote-homes.next"
if [ -f "$REG" ]; then grep -vE "^- $ID( |$)" "$REG" > "$REG_TMP" || true; else : > "$REG_TMP"; fi
printf -- '- %s - %s (host: %s; root: %s; home: %s; session: %s; scope: %s; projects: %s; added %s)\n' \
  "$ID" "$SUMMARY" "$HOST" "$REMOTE_ROOT" "$REMOTE_HOME" "$EXEC_SESSION" "$SCOPE" "$PROJECTS_CSV" "$TODAY" >> "$REG_TMP"
mv -f -- "$REG_TMP" "$REG"
if ! fm_remote_registry_validate_bindings "$REG" "$ID" "$REMOTE_HOME"; then
  if [ "$REG_EXISTED" -eq 1 ]; then cp "$TMP/registry.before" "$REG"; else rm -f -- "$REG"; fi
  die "$(fm_remote_registry_error)"
fi

restore_registry() {
  if [ "$REG_EXISTED" -eq 1 ]; then cp "$TMP/registry.before" "$REG"; else rm -f -- "$REG"; fi
}

# Preflight and, where it can, repair the remote runtime before anything is
# created on that host. The doctor runs through the same fixed entrypoint as
# every later call, so it sees the exact PATH the remote home will run under.
set +e
fm_remote_readiness_ensure "$SCRIPT_DIR" "$ID"
PREFLIGHT_RC=$?
set -e
if [ "$PREFLIGHT_RC" -ne 0 ]; then
  if [ "$PREFLIGHT_RC" -ne 255 ]; then
    restore_registry
  fi
  [ -z "$FM_REMOTE_READINESS_OUT" ] || printf '%s\n' "$FM_REMOTE_READINESS_OUT" >&2
  if [ "$PREFLIGHT_RC" -eq 255 ]; then
    die "remote readiness completion is unknown; route preserved for same-host reconciliation"
  fi
  die "remote runtime preflight failed; nothing was provisioned. Close the gaps listed above, or update the remote code root if it predates the current fm-remote-doctor.sh"
fi

set +e
PROVISION_OUT=$("$SCRIPT_DIR/fm-on.sh" --stdin "$ID" fm-remote-home-provision.sh < "$TMP/manifest" 2>&1)
PROVISION_RC=$?
set -e
if [ "$PROVISION_RC" -ne 0 ]; then
  if [ "$PROVISION_RC" -ne 255 ]; then
    restore_registry
  fi
  [ -z "$PROVISION_OUT" ] || printf '%s\n' "$PROVISION_OUT" >&2
  if [ "$PROVISION_RC" -eq 255 ]; then
    die "remote provisioning completion is unknown; route preserved for same-host reconciliation"
  fi
  die "remote provisioning failed; registry restored"
fi
printf '%s\n' "$PROVISION_OUT"
printf 'home=%s:%s\n' "$HOST" "$REMOTE_HOME"
