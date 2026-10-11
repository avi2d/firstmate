#!/usr/bin/env bash
# Socket-owner discovery and Aqua-birth classification for one Herdr session.

fm_remote_herdr_socket_owner() { # <socket-path>
  local socket=$1 real pid='' line candidates='' candidate cmd
  [ -n "$socket" ] || return 1
  # pgrep -f cannot see the herdr server's argv on macOS, so lsof is the owner source.
  command -v lsof >/dev/null 2>&1 || return 2
  real=$(CDPATH='' cd -- "$(dirname "$socket")" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$(basename "$socket")") || real=$socket
  while IFS= read -r line; do
    case "$line" in
      p*) pid=${line#p} ;;
      n*)
        [ -n "$pid" ] || continue
        case "${line#n}" in
          "$socket"|"$real") candidates="${candidates}${pid}"$'\n' ;;
        esac
        ;;
    esac
  done < <(lsof -U -a -c herdr -F pn 2>/dev/null)
  [ -n "$candidates" ] || return 0
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    cmd=$(ps -o command= -p "$candidate" 2>/dev/null || true)
    case " $cmd " in *' server '*) printf '%s\n' "$candidate"; return 0 ;; esac
  done <<EOF2
$candidates
EOF2
  printf '%s\n' "${candidates%%$'\n'*}"
}

fm_remote_herdr_process_env() { # <pid>
  local pid=$1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -r "/proc/$pid/environ" ]; then
    tr '\0' '\n' < "/proc/$pid/environ"
    return 0
  fi
  ps -Eww -o command= -p "$pid" 2>/dev/null | tr ' ' '\n' | grep -E '^[A-Za-z_][A-Za-z0-9_]*=' || true
}

fm_remote_herdr_process_ancestry() { # <pid>
  local pid=$1 depth=0 line ppid
  while [ "$depth" -lt 64 ]; do
    case "$pid" in ''|*[!0-9]*) return 0 ;; esac
    [ "$pid" -gt 0 ] || return 0
    line=$(ps -o ppid=,command= -p "$pid" 2>/dev/null) || return 0
    [ -n "$line" ] || return 0
    ppid=$(printf '%s' "$line" | awk '{print $1}')
    printf '%s %s\n' "$pid" "$(printf '%s' "$line" | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//')"
    [ "$pid" -ne 1 ] || return 0
    pid=$ppid
    depth=$((depth + 1))
  done
}

fm_remote_herdr_gui_job_pid() { # <uid> <label>
  local uid=$1 label=$2
  [ -n "$label" ] && [ "$label" != 0 ] || return 1
  launchctl print "gui/$uid/$label" 2>/dev/null | awk '
    $1 == "pid" && $2 == "=" && $3 ~ /^[0-9]+$/ { print $3; found = 1; exit }
    END { exit found ? 0 : 1 }
  '
}

fm_remote_herdr_pid_descends_from() { # <pid> <ancestor>
  local pid=$1 ancestor=$2 depth=0 line
  case "$pid$ancestor" in ''|*[!0-9]*) return 1 ;; esac
  while [ "$depth" -lt 64 ]; do
    [ "$pid" = "$ancestor" ] && return 0
    [ "$pid" -gt 1 ] || return 1
    line=$(ps -o ppid= -p "$pid" 2>/dev/null) || return 1
    pid=$(printf '%s' "$line" | tr -d ' \t\r\n')
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    depth=$((depth + 1))
  done
  return 1
}

fm_remote_herdr_gui_job_is_exclusive() { # <uid> <label>
  local uid=$1 label=$2
  launchctl print "gui/$uid/$label" >/dev/null 2>&1 \
    && ! launchctl print "user/$uid/$label" >/dev/null 2>&1
}

# macOS 26 hides one process's environment from another, so birth is proven
# through launchd's own job-to-pid record instead of ps -E markers.
fm_remote_herdr_owner_birth() { # <pid> [<aqua-agent-label>]
  local pid=$1 aqua_label=${2:-dev.firstmate.herdr.fm-remote}
  local env uid xpc_line env_label label job_pid worker_pid
  env=$(fm_remote_herdr_process_env "$pid") || env=
  if printf '%s\n' "$env" | grep -q -E '^SSH_(CONNECTION|CLIENT|TTY)='; then
    printf 'ssh\n'
    return 0
  fi
  uid=$(id -u 2>/dev/null) || uid=
  if [ -n "$uid" ]; then
    xpc_line=$(printf '%s\n' "$env" | grep -E '^XPC_SERVICE_NAME=' | head -1 || true)
    env_label=${xpc_line#XPC_SERVICE_NAME=}
    for label in "$aqua_label" "$env_label"; do
      [ -n "$label" ] && [ "$label" != 0 ] || continue
      job_pid=$(fm_remote_herdr_gui_job_pid "$uid" "$label") || continue
      if [ "$job_pid" = "$pid" ]; then
        printf 'launchd\n'
        return 0
      fi
    done
    if fm_remote_herdr_gui_job_is_exclusive "$uid" dev.firstmate.remote-job; then
      if printf '%s\n' "$env" | grep -q -E '^FM_REMOTE_JOB_ACTIVE=1$'; then
        printf 'worker\n'
        return 0
      fi
      worker_pid=$(fm_remote_herdr_gui_job_pid "$uid" dev.firstmate.remote-job) || worker_pid=
      if [ -n "$worker_pid" ] && fm_remote_herdr_pid_descends_from "$pid" "$worker_pid"; then
        printf 'worker\n'
        return 0
      fi
    fi
  fi
  if fm_remote_herdr_process_ancestry "$pid" | fm_remote_herdr_ancestry_has_ssh_origin; then
    printf 'ssh\n'
    return 0
  fi
  printf 'unknown\n'
}

# Reads "<pid> <command>" ancestry lines on stdin and succeeds when one of
# them IS sshd (argv[0] sshd or sshd-session, including the "sshd-session:
# user@notty" process title) or IS herdr's SSH remote attach (argv[0] herdr
# with the whole-word argument remote-client-bridge). Only argv[0] and whole
# arguments are matched: an ancestor whose free-text arguments merely mention
# those words, such as an agent carrying a brief, must not count.
fm_remote_herdr_ancestry_has_ssh_origin() {
  awk '
    {
      argv0 = $2
      sub(/.*\//, "", argv0)
      sub(/:$/, "", argv0)
      if (argv0 == "sshd" || argv0 == "sshd-session") { found = 1; exit }
      if (argv0 == "herdr") {
        for (i = 3; i <= NF; i++) if ($i == "remote-client-bridge") { found = 1; exit }
      }
    }
    END { exit found ? 0 : 1 }
  '
}

# Unproven birth is not Aqua: trusting it reproduces the keychain failure.
fm_remote_herdr_birth_is_aqua() { # <birth>
  case "$1" in launchd|worker) return 0 ;; esac
  return 1
}
