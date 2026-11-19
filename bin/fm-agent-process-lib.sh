#!/usr/bin/env bash
# Backend-neutral harness-process identity, sourced by bin/backends/herdr.sh.
# This file is sourced by scripts and has no side effects on source.

_FM_AGENT_PROCESS_LIB_DIR=${BASH_SOURCE[0]%/*}
[ "$_FM_AGENT_PROCESS_LIB_DIR" != "${BASH_SOURCE[0]}" ] || _FM_AGENT_PROCESS_LIB_DIR=.
# shellcheck source=bin/fm-session-lock-lib.sh
. "${_FM_AGENT_PROCESS_LIB_DIR:-/}/fm-session-lock-lib.sh"
unset _FM_AGENT_PROCESS_LIB_DIR

# fm_agent_process_classify_name: the single owner of the process-name
# vocabulary shared by every liveness signal - `agent` for a verified harness,
# `shell` for an idle login/interactive shell, `other` for anything else.
# Keeping one classifier means independent name sources (a kernel process
# name, an argv[0], a rendered pane title) can never drift into disagreeing
# about what a given name means.
fm_agent_process_classify_name() {  # <path> [argv0] -> agent|shell|other
  local path=$1 argv0=${2:-} base
  base=${path##*/}
  base=${base#-}
  case "$base" in
    pi|pi-signed|pi-launcher|Pi) printf 'agent' ;;
    zsh|bash|sh|dash|ash|ksh|mksh|tcsh|csh|fish) printf 'shell' ;;
    *)
      if fm_harness_path_name "$path" >/dev/null || fm_harness_path_name "$argv0" >/dev/null; then
        printf 'agent'
      else
        printf 'other'
      fi
      ;;
  esac
}

# fm_agent_process_classify: one process, from every identity surface a
# backend can hand over, as agent|shell|other. Any single surface naming a
# verified harness carries `agent`, because a false negative is the one outcome
# that launches a duplicate agent onto a live worktree; `shell` needs every
# readable surface to agree the process is a shell; anything else is `other`.
#
#   <name>   the kernel process name (ps comm, or Herdr's process-info .name):
#            on Linux the exec name, on macOS argv[0] truncated to 16 bytes.
#   <argv0>  argv[0] as the process reports it - a bare name or an install
#            path, whichever the launcher used (empty when unknown).
fm_agent_process_classify() {  # <name> <argv0> [args] [pid] -> agent|shell|other
  local name=${1:-} argv0=${2:-} by_name by_argv0
  by_name=$(fm_agent_process_classify_name "$name" "$argv0")
  [ "$by_name" != agent ] || { printf 'agent'; return 0; }
  if [ -n "$argv0" ]; then
    # argv[0] is classified as a path in its own right, so a bare `pi` or a
    # `-zsh` login name reads by basename and an install path by component.
    by_argv0=$(fm_agent_process_classify_name "$argv0" "$argv0")
    [ "$by_argv0" != agent ] || { printf 'agent'; return 0; }
  else
    by_argv0=$by_name
  fi
  if [ "$by_name" = shell ] && [ "$by_argv0" = shell ]; then
    printf 'shell'
  else
    printf 'other'
  fi
}

# fm_agent_process_harness_below: the first verified harness strictly below any
# <root-pid>, read from the live process table, printed as
# "<pid>\t<name>\t<argv0>". Returns 1 when there is none, and 2 when the table
# cannot be read or holds none of the roots.
#
# A pane's foreground group cannot answer this alone: the nono sandbox holds
# the pane terminal and runs its harness on a terminal of its own, in a session
# of its own, so the live agent is never in the pane's foreground group or on
# its tty. Only the parent links reach it.
fm_agent_process_harness_below() {  # <ps-bin> <root-pid>...
  local ps_bin=$1 rows pid name args argv0
  shift
  command -v "$ps_bin" >/dev/null 2>&1 || return 2
  rows=$(LC_ALL=C "$ps_bin" -axo pid=,ppid=,comm= 2>/dev/null) || return 2
  printf '%s\n' "$rows" | awk -v roots="$*" '
    BEGIN { n = split(roots, r, " "); for (i = 1; i <= n; i++) want[r[i]] = 1 }
    ($1 in want) { found = 1 }
    END { exit(found ? 0 : 1) }' || return 2
  while IFS=$'\t' read -r pid name; do
    [ -n "$pid" ] || continue
    args=$(LC_ALL=C "$ps_bin" -p "$pid" -o args= 2>/dev/null) || continue
    args=${args#"${args%%[![:space:]]*}"}
    argv0=${args%%[[:space:]]*}
    if [ "$(fm_agent_process_classify "$name" "$argv0" "$args" "$pid")" = agent ]; then
      printf '%s\t%s\t%s' "$pid" "$name" "$argv0"
      return 0
    fi
  done <<EOF
$(printf '%s\n' "$rows" | awk -v roots="$*" '
  {
    pid[NR] = $1; ppid[NR] = $2
    line = $0
    sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+/, "", line)
    comm[NR] = line
  }
  END {
    n = split(roots, r, " ")
    for (i = 1; i <= n; i++) { want[r[i]] = 1; root[r[i]] = 1 }
    changed = 1
    while (changed) {
      changed = 0
      for (k = 1; k <= NR; k++) {
        if ((ppid[k] in want) && !(pid[k] in want)) { want[pid[k]] = 1; changed = 1 }
      }
    }
    for (k = 1; k <= NR; k++) {
      if ((pid[k] in want) && !(pid[k] in root)) printf "%s\t%s\n", pid[k], comm[k]
    }
  }')
EOF
  return 1
}

# fm_agent_process_is_pi: whether one harness identity is the Pi family, whose
# composer only a live identity can prove.
fm_agent_process_is_pi() {  # <name> <argv0>
  local n
  for n in "${1##*/}" "${2##*/}"; do
    case "$n" in
      pi|pi-signed|pi-launcher|Pi) return 0 ;;
    esac
  done
  return 1
}

# A launch's working directory and task marker are read from the kernel, never
# from the pane, because a multiplexer reports the pane shell's directory rather
# than the agent's.
fm_agent_process_proc_root() {
  printf '%s' "${FM_AGENT_PROCESS_PROC_ROOT:-/proc}"
}

fm_agent_process_cwd() {  # <pid>
  local pid=$1 root cwd
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  root=$(fm_agent_process_proc_root)
  if [ -d "$root/$pid" ]; then
    cwd=$(readlink "$root/$pid/cwd" 2>/dev/null) || return 1
  else
    command -v lsof >/dev/null 2>&1 || return 1
    cwd=$(LC_ALL=C lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
  fi
  case "$cwd" in /*) printf '%s' "$cwd" ;; *) return 1 ;; esac
}

# Prints the FM_TASK_ID the process was started with, or nothing when it had
# none. macOS keeps a process's environment in the argument block that a node
# harness overwrites with its title, so only a /proc environ is evidence.
fm_agent_process_task_marker() {  # <pid>
  local pid=$1 environ
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  environ="$(fm_agent_process_proc_root)/$pid/environ"
  [ -r "$environ" ] || return 1
  tr '\0' '\n' < "$environ" 2>/dev/null | sed -n 's/^FM_TASK_ID=//p' | tail -1
}

# Prints exactly one of:
#   isolated             runs at or under <worktree>, with this task's marker
#                        or with no readable environment to contradict it
#   outside <cwd>        runs anywhere else
#   unmarked             its readable environment has no task marker
#   mismarked <task-id>  its readable environment names another task
#   unreadable           its working directory cannot be read
fm_agent_process_launch_isolation() {  # <pid> <worktree> <task-id>
  local pid=$1 worktree=$2 id=$3 cwd want marker
  cwd=$(fm_agent_process_cwd "$pid") || { printf 'unreadable'; return 0; }
  want=$(cd "$worktree" 2>/dev/null && pwd -P) || { printf 'unreadable'; return 0; }
  cwd=$(cd "$cwd" 2>/dev/null && pwd -P) || { printf 'unreadable'; return 0; }
  case "$cwd/" in
    "$want"/*) ;;
    *) printf 'outside %s' "$cwd"; return 0 ;;
  esac
  marker=$(fm_agent_process_task_marker "$pid") || { printf 'isolated'; return 0; }
  if [ -z "$marker" ]; then
    printf 'unmarked'
  elif [ "$marker" != "$id" ]; then
    printf 'mismarked %s' "$marker"
  else
    printf 'isolated'
  fi
}
