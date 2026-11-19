#!/usr/bin/env bash
# Usage: fm-remote-home-provision.sh < manifest
# Run on the execution host through the fixed remote entrypoint.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME=${FM_HOME:?FM_HOME is required}
MAX_MANIFEST_BYTES=1048576

# shellcheck source=bin/fm-project-origin-lib.sh
. "$SCRIPT_DIR/fm-project-origin-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

base64_decode_to() {
  if printf '%s' "$1" | base64 --decode > "$2" 2>/dev/null; then return 0; fi
  if printf '%s' "$1" | base64 -D > "$2" 2>/dev/null; then return 0; fi
  return 1
}

manifest_value() { # <file> <key>
  local count
  count=$(grep -c "^$2=" "$1" 2>/dev/null || true)
  [ "$count" -eq 1 ] || return 1
  grep "^$2=" "$1" | cut -d= -f2-
}

safe_id() { case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-remote-provision.XXXXXX") || die "cannot create provisioning state"
CREATED_HOME=0
CREATED_BACKLOG=0
EXISTING_HOME=0
PUBLISHED=0
PROVISION_LOCK=
PROVISION_LOCK_HELD=0
STAGE_HOME=
CREATED_PROJECTS="$TMP/created-projects"
: > "$CREATED_PROJECTS"
release_provision_lock() {
  if [ "$PROVISION_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$PROVISION_LOCK"
    PROVISION_LOCK_HELD=0
  fi
}
restore_owned_file() { # <relative-path>
  local rel=$1 dest="$FM_HOME/$1" backup="$TMP/before/$1"
  if [ -f "$backup.present" ]; then
    mkdir -p "$(dirname "$dest")" || return 1
    cp -p -- "$backup" "$dest.tmp.rollback.$$" || return 1
    mv -f -- "$dest.tmp.rollback.$$" "$dest"
  else
    rm -f -- "$dest"
  fi
}
rollback() {
  local status=$? project
  if [ "$status" -ne 0 ] && [ "$PUBLISHED" -eq 0 ]; then
    [ -z "$STAGE_HOME" ] || rm -rf -- "$STAGE_HOME"
    if [ "$CREATED_HOME" -eq 1 ]; then
      rm -rf -- "$FM_HOME"
    elif [ "$EXISTING_HOME" -eq 1 ]; then
      while IFS= read -r project; do
        [ -n "$project" ] && rm -rf -- "$FM_HOME/projects/$project"
      done < "$CREATED_PROJECTS"
      restore_owned_file .fm-exec-home || true
      restore_owned_file config/backlog-backend || true
      restore_owned_file config/herdr-session || true
      restore_owned_file data/projects.md || true
      [ "$CREATED_BACKLOG" -eq 0 ] || rm -f -- "$FM_HOME/data/backlog.md"
    fi
  fi
  release_provision_lock
  rm -rf -- "$TMP"
  exit "$status"
}
trap rollback EXIT
trap 'exit 1' HUP INT TERM
head -c "$((MAX_MANIFEST_BYTES + 1))" > "$TMP/manifest" || die "cannot read provisioning manifest"
MANIFEST_BYTES=$(LC_ALL=C wc -c < "$TMP/manifest" | tr -d ' ')
[ "$MANIFEST_BYTES" -le "$MAX_MANIFEST_BYTES" ] || die "provisioning manifest exceeds its byte bound"
SCHEMA=$(manifest_value "$TMP/manifest" schema || true)
[ "$SCHEMA" = fm-remote-exec-home-provision.v1 ] || die "incompatible provisioning manifest"
MARKER=.fm-exec-home
ID_B64=$(manifest_value "$TMP/manifest" id_b64 || true)
CHARTER_B64=$(manifest_value "$TMP/manifest" charter_b64 || true)
SESSION_B64=$(manifest_value "$TMP/manifest" session_b64 || true)
COUNT=$(manifest_value "$TMP/manifest" project_count || true)
base64_decode_to "$ID_B64" "$TMP/id" || die "manifest id is not valid base64"
[ -z "$CHARTER_B64" ] || die "execution-home manifest must not carry a charter"
SESSION=fm-remote
if [ -n "$SESSION_B64" ]; then
  base64_decode_to "$SESSION_B64" "$TMP/session" || die "manifest session is not valid base64"
  SESSION=$(cat "$TMP/session")
  case "$SESSION" in ''|*[!A-Za-z0-9._-]*) die "manifest carries an unsafe Herdr session name" ;; esac
fi
ID=$(cat "$TMP/id")
safe_id "$ID" || die "manifest carries an unsafe route id"
case "$COUNT" in ''|*[!0-9]*) die "manifest project count is invalid" ;; esac
RECORDS=$(grep -c '^project=' "$TMP/manifest" 2>/dev/null || true)
[ "$RECORDS" -eq "$COUNT" ] || die "manifest project count does not match its records"

HOME_PARENT=$(dirname "$FM_HOME")
HOME_PARENT_REAL=$(CDPATH='' cd -- "$HOME_PARENT" 2>/dev/null && pwd -P) \
  || die "remote home parent is unavailable"
[ "$HOME_PARENT_REAL" = "$HOME_PARENT" ] || die "remote home parent is not canonical"
PROVISION_LOCK_STATE="$HOME_PARENT/.firstmate-provision-locks"
if [ -e "$PROVISION_LOCK_STATE" ] || [ -L "$PROVISION_LOCK_STATE" ]; then
  [ -d "$PROVISION_LOCK_STATE" ] && [ ! -L "$PROVISION_LOCK_STATE" ] \
    || die "remote provisioning lock root is unsafe"
else
  mkdir "$PROVISION_LOCK_STATE" 2>/dev/null || true
  [ -d "$PROVISION_LOCK_STATE" ] && [ ! -L "$PROVISION_LOCK_STATE" ] \
    || die "cannot create remote provisioning lock root"
fi
if command -v shasum >/dev/null 2>&1; then
  HOME_LOCK_KEY=$(printf '%s' "$FM_HOME" | shasum -a 256 | awk '{print $1}')
elif command -v sha256sum >/dev/null 2>&1; then
  HOME_LOCK_KEY=$(printf '%s' "$FM_HOME" | sha256sum | awk '{print $1}')
else
  die "no SHA-256 tool is available for provisioning serialization"
fi
FM_STATE_OVERRIDE="$PROVISION_LOCK_STATE"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
PROVISION_LOCK="$STATE/.remote-home-provision-$HOME_LOCK_KEY.lock"
fm_lock_acquire_wait "$PROVISION_LOCK"
PROVISION_LOCK_HELD=1

if [ -e "$FM_HOME" ] || [ -L "$FM_HOME" ]; then
  [ -d "$FM_HOME" ] && [ ! -L "$FM_HOME" ] || die "remote home exists but is not a safe directory"
  [ -f "$FM_HOME/AGENTS.md" ] && [ ! -L "$FM_HOME/AGENTS.md" ] \
    && [ -d "$FM_HOME/bin" ] && [ ! -L "$FM_HOME/bin" ] || die "existing remote home is not a safe Firstmate checkout"
  for operational_dir in data state config projects; do
    operational_path="$FM_HOME/$operational_dir"
    if [ -e "$operational_path" ] || [ -L "$operational_path" ]; then
      [ -d "$operational_path" ] && [ ! -L "$operational_path" ] \
        || die "remote home has unsafe operational directory: $operational_dir"
    fi
  done
  mkdir -p "$TMP/before/data"
  mkdir -p "$TMP/before/config"
  owned_files=(data/projects.md .fm-exec-home config/backlog-backend config/herdr-session)
  for rel in "${owned_files[@]}"; do
    existing="$FM_HOME/$rel"
    if [ -e "$existing" ] || [ -L "$existing" ]; then
      [ -f "$existing" ] && [ ! -L "$existing" ] || die "existing remote home has unsafe owned file: $rel"
      mkdir -p "$(dirname "$TMP/before/$rel")"
      cp -p -- "$existing" "$TMP/before/$rel" || die "cannot snapshot existing remote home file: $rel"
      : > "$TMP/before/$rel.present"
    fi
  done
  EXISTING_HOME=1
  [ -f "$FM_HOME/$MARKER" ] || die "refusing to provision over an unmarked home"
  [ "$(cat "$FM_HOME/$MARKER")" = "$ID" ] || die "existing home belongs to a different execution route"
else
  # Clone into a staging path this attempt owns, then publish by rename: a
  # competing cleanup or rollback aimed at the absent public home cannot
  # remove a directory a live clone is still writing. Verify the sentinel
  # after mv: if the destination appeared meanwhile, mv may nest our stage
  # inside it instead of publishing, so rollback must remove only that stage.
  STAGE_HOME=$(mktemp -d "$HOME_PARENT/.fm-home-provisioning.XXXXXX") \
    || die "cannot create remote home staging directory"
  # A local clone copies loose objects into the new repo. Git 2.55 on the CI
  # image does that copy before the destination shard directory exists, so the
  # clone dies intermittently with "failed to copy file to .../objects/xx/hash".
  # --no-local uses the normal transport and writes a pack instead.
  git clone --no-local --quiet -- "$FM_ROOT" "$STAGE_HOME" || die "could not clone the remote Firstmate home"
  STAGE_SENTINEL="${STAGE_HOME##*/}.owner"
  : > "$STAGE_HOME/$STAGE_SENTINEL" || die "cannot mark the remote home staging directory"
  mv -- "$STAGE_HOME" "$FM_HOME" || die "cannot install the remote home"
  if [ ! -f "$FM_HOME/$STAGE_SENTINEL" ] || [ -L "$FM_HOME/$STAGE_SENTINEL" ]; then
    STAGE_HOME="$FM_HOME/${STAGE_HOME##*/}"
    die "remote home appeared while it was being provisioned"
  fi
  STAGE_HOME=
  CREATED_HOME=1
  rm -f -- "$FM_HOME/$STAGE_SENTINEL" || die "cannot clear the remote home staging sentinel"
fi
for operational_dir in data state config projects; do
  operational_path="$FM_HOME/$operational_dir"
  if [ -e "$operational_path" ] || [ -L "$operational_path" ]; then
    [ -d "$operational_path" ] && [ ! -L "$operational_path" ] \
      || die "remote home has unsafe operational directory: $operational_dir"
  else
    mkdir "$operational_path" || die "cannot create remote operational directory: $operational_dir"
  fi
done
if [ -e "$FM_HOME/data/backlog.md" ] || [ -L "$FM_HOME/data/backlog.md" ]; then
  [ -f "$FM_HOME/data/backlog.md" ] && [ ! -L "$FM_HOME/data/backlog.md" ] \
    || die "remote backlog is not a safe regular file"
else
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$FM_HOME/data/backlog.md"
  CREATED_BACKLOG=1
fi

PROJECT_REG="$TMP/projects.md"
: > "$PROJECT_REG"
while IFS= read -r record; do
  [ -n "$record" ] || continue
  encoded=${record#project=}
  old_ifs=$IFS
  IFS='|'
  read -r NAME_B64 ORIGIN_B64 REGISTRY_B64 MODE_B64 <<EOF
$encoded
EOF
  IFS=$old_ifs
  for field in NAME_B64 ORIGIN_B64 REGISTRY_B64 MODE_B64; do
    eval "value=\${$field}"
    [ -n "$value" ] || die "project manifest record is incomplete"
  done
  base64_decode_to "$NAME_B64" "$TMP/name" || die "project name is not valid base64"
  base64_decode_to "$ORIGIN_B64" "$TMP/origin" || die "project origin is not valid base64"
  base64_decode_to "$REGISTRY_B64" "$TMP/registry" || die "project registry line is not valid base64"
  base64_decode_to "$MODE_B64" "$TMP/mode" || die "project mode is not valid base64"
  NAME=$(cat "$TMP/name")
  ORIGIN=$(cat "$TMP/origin")
  REGISTRY_LINE=$(cat "$TMP/registry")
  MODE=$(cat "$TMP/mode")
  safe_id "$NAME" || die "project name is unsafe: $NAME"
  [ -n "$ORIGIN" ] || die "project $NAME has no origin"
  fm_project_origin_safe "$ORIGIN" || die "project $NAME origin is not an accepted clone URL: $ORIGIN"
  case "$MODE" in no-mistakes|direct-PR) ;; *) die "project $NAME has unsupported remote mode: $MODE" ;; esac
  case "$REGISTRY_LINE" in "- $NAME "*) ;; *) die "project $NAME registry line is malformed" ;; esac
  DEST="$FM_HOME/projects/$NAME"
  if [ -e "$DEST" ] || [ -L "$DEST" ]; then
    [ -d "$DEST" ] && [ ! -L "$DEST" ] && [ -d "$DEST/.git" ] \
      || die "project destination exists but is not a safe clone: $DEST"
    EXISTING_ORIGIN=$(git -C "$DEST" remote get-url origin 2>/dev/null || true)
    [ "$EXISTING_ORIGIN" = "$ORIGIN" ] || die "project $NAME origin differs from the requested route"
  else
    printf '%s\n' "$NAME" >> "$CREATED_PROJECTS"
    git clone --no-local --quiet -- "$ORIGIN" "$DEST" || die "could not clone project $NAME on the remote host"
    if [ "$MODE" = no-mistakes ]; then
      command -v no-mistakes >/dev/null 2>&1 || die "no-mistakes is unavailable for project $NAME"
      (cd "$DEST" && no-mistakes init >/dev/null && no-mistakes doctor >/dev/null) \
        || die "no-mistakes initialization failed for project $NAME"
    fi
  fi
  printf '%s\n' "$REGISTRY_LINE" >> "$PROJECT_REG"
done < <(grep '^project=' "$TMP/manifest")

printf 'manual\n' > "$FM_HOME/config/backlog-backend.tmp.$$"
mv -f -- "$FM_HOME/config/backlog-backend.tmp.$$" "$FM_HOME/config/backlog-backend"
printf '%s\n' "$SESSION" > "$FM_HOME/config/herdr-session.tmp.$$"
mv -f -- "$FM_HOME/config/herdr-session.tmp.$$" "$FM_HOME/config/herdr-session"
cp "$PROJECT_REG" "$FM_HOME/data/projects.md.tmp.$$"
mv -f -- "$FM_HOME/data/projects.md.tmp.$$" "$FM_HOME/data/projects.md"
printf '%s\n' "$ID" > "$FM_HOME/$MARKER.tmp.$$"
mv -f -- "$FM_HOME/$MARKER.tmp.$$" "$FM_HOME/$MARKER"
PUBLISHED=1
release_provision_lock
trap - EXIT
rm -rf -- "$TMP"
printf 'provisioned: %s projects=%s\n' "$FM_HOME" "$COUNT"
