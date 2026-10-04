#!/usr/bin/env bash
# Report what a worker changed in the harness config homes under $HOME; --help owns the contract.
set -euo pipefail

FM_HOME_WRITE_ROOTS=(.claude .pi/agent)
FM_HOME_WRITE_SKIP=(
  .claude/projects .claude/session-env .claude/sessions .claude/jobs
  .claude/shell-snapshots .claude/debug .claude/cache .claude/paste-cache
  .claude/backups .claude/daemon .claude/todos .claude/statsig
  .claude/file-history .claude/ide .claude/telemetry
  .claude/plugins/marketplaces .claude/plugins/cache
  .claude/plugins/.last_inuse_sweep .claude/plugins/plugin-catalog-cache.json
  .claude/history.jsonl .claude/.last-cleanup .claude/.session-stats.json
  .pi/agent/sessions .pi/agent/npm/node_modules .pi/agent/git
  .pi/agent/fff .pi/agent/cc-cli-logs .pi/agent/web-search-cache
  .pi/agent/models-store.json
)
FM_HOME_WRITE_HEADER='# fm-home-write-diff v1'

usage() {
  cat <<'EOF'
Usage:
  fm-home-write-diff.sh snapshot <snapshot-file> <worktree>
      Write a manifest of $HOME/.claude and $HOME/.pi/agent to <snapshot-file>,
      replacing it atomically. <worktree> is the task's isolated copy; its
      path, as given and resolved, is kept so the report can name a link
      pointing into it.
  fm-home-write-diff.sh report <snapshot-file>
      Compare the home recorded in <snapshot-file> with the same roots now and
      print one line per difference, nothing when there is none:
        created <path> (<kind>)
        removed <path> (<kind>)
        changed <path>
        relinked <path>: <old target> -> <new target>
        retyped <path>: <old kind> -> <new kind>
      A link whose target lies inside the recorded worktree gains the suffix
      " (into the task's worktree)". Exits 0 whether or not anything changed,
      non-zero when the snapshot is missing or unreadable.

bin/fm-spawn.sh takes the snapshot for every fresh ship and scout spawn into
state/<id>.home-snapshot before the worker launches. bin/fm-teardown.sh runs
the report once the endpoint is closed, prints any difference as a warning,
keeps a copy at data/<id>/home-writes.txt, and removes the snapshot with the
task's other volatile state.

Both modes only read the home: no file content is opened and nothing is
reverted. A file is compared by size and modification time, a link by its
target, a directory by existence. Other sessions share the home, so a
difference is a change since spawn, not proof that this worker made it.
The trees each harness rewrites in every ordinary session - transcripts,
caches, logs, session environments, installed packages - are skipped so they
do not bury configuration writes. Names holding a tab or newline are skipped because
the manifest is tab- and line-delimited.
EOF
}

# Prints "<kind>\t<path>\t<value>" per entry under the roots, relative to the
# home and sorted by path.
home_manifest() {
  local home=$1 root nl=$'\n' tab=$'\t' skip_args=() file_format roots=()
  for root in "${FM_HOME_WRITE_ROOTS[@]}"; do
    if [ -e "$home/$root" ]; then roots+=("$root"); fi
  done
  [ "${#roots[@]}" -gt 0 ] || return 0
  for root in "${FM_HOME_WRITE_SKIP[@]}"; do
    skip_args+=(-o -path "$root")
  done
  # GNU stat -f is filesystem stat and still exits 0, so the platform is
  # chosen up front rather than by falling back.
  if [ "$(uname)" = Darwin ]; then
    file_format=(/usr/bin/stat -f "f${tab}%N${tab}%z:%Fm")
  else
    file_format=(stat -c "f${tab}%n${tab}%s:%y")
  fi
  (
    cd "$home" || exit 1
    find -H "${roots[@]}" \( -name "*${nl}*" -o -name "*${tab}*" -o -name '*.log' "${skip_args[@]}" \) -prune -o \
      \( -type d -exec sh -c 'for p; do printf "d\t%s\t-\n" "$p"; done' sh {} + \) -o \
      \( -type l -exec sh -c 'for p; do printf "l\t%s\t%s\n" "$p" "$(readlink "$p")"; done' sh {} + \) -o \
      \( -type f -exec "${file_format[@]}" {} + \) 2>/dev/null || true
  ) | LC_ALL=C sort -t "$tab" -k2,2
}

snapshot() {
  local file=$1 worktree=$2 tmp worktree_real
  worktree_real=$(cd "$worktree" 2>/dev/null && pwd -P) || worktree_real=$worktree
  tmp="$file.tmp.${BASHPID:-$$}"
  if ! {
    printf '%s\n' "$FM_HOME_WRITE_HEADER"
    printf 'home=%s\n' "$HOME"
    printf 'worktree=%s\n' "$worktree"
    printf 'worktree_real=%s\n' "$worktree_real"
    home_manifest "$HOME"
  } >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$file"
}

report() {
  local file=$1 home worktree worktree_real
  [ -f "$file" ] || { echo "error: no home snapshot at $file" >&2; return 1; }
  [ "$(head -n 1 "$file")" = "$FM_HOME_WRITE_HEADER" ] ||
    { echo "error: $file is not a home snapshot" >&2; return 1; }
  home=$(sed -n '2s/^home=//p' "$file")
  worktree=$(sed -n '3s/^worktree=//p' "$file")
  worktree_real=$(sed -n '4s/^worktree_real=//p' "$file")
  [ -n "$home" ] || { echo "error: $file names no home" >&2; return 1; }
  home_manifest "$home" | awk -F '\t' -v worktree="$worktree" -v worktree_real="$worktree_real" '
    function kind(k) { return k == "d" ? "directory" : k == "l" ? "link" : "file" }
    function inside(target, dir) { return dir != "" && (target == dir || index(target, dir "/") == 1) }
    function into(target) {
      if (inside(target, worktree) || inside(target, worktree_real)) return " (into the task" sprintf("%c", 39) "s worktree)"
      return ""
    }
    NR == FNR {
      if (FNR > 4) { was_kind[$2] = $1; was_value[$2] = $3; order[++n] = $2 }
      next
    }
    {
      seen[$2] = 1
      if (!($2 in was_kind)) {
        line = "created " $2 " (" kind($1) ")"
        if ($1 == "l") line = line " -> " $3 into($3)
        print line
      } else if (was_kind[$2] != $1) {
        print "retyped " $2 ": " kind(was_kind[$2]) " -> " kind($1) ($1 == "l" ? into($3) : "")
      } else if (was_value[$2] != $3) {
        if ($1 == "l") print "relinked " $2 ": " was_value[$2] " -> " $3 into($3)
        else print "changed " $2
      }
    }
    END {
      for (i = 1; i <= n; i++) if (!(order[i] in seen)) print "removed " order[i] " (" kind(was_kind[order[i]]) ")"
    }
  ' "$file" -
}

case "${1:-}" in
  snapshot) [ "$#" -eq 3 ] || { usage >&2; exit 2; }; snapshot "$2" "$3" ;;
  report) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; report "$2" ;;
  -h | --help) usage ;;
  *) usage >&2; exit 2 ;;
esac
