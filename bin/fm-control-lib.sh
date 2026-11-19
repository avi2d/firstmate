#!/usr/bin/env bash
# Sourcing runs nothing; only fm_control_endpoint_absence_verdict reads a backend.

fm_control_verbs() {
  cat <<'EOF'
interrupt
exit
relaunch
EOF
}

fm_control_verb_allowed() {  # <verb>
  case "${1-}" in
    interrupt|exit|relaunch) return 0 ;;
  esac
  return 1
}

fm_control_harnesses() {
  printf '%s\n' pi pi-signed
}

fm_control_harness_supported() {  # <harness>
  case "${1-}" in
    pi|pi-signed) return 0 ;;
  esac
  return 1
}

# Exact names only: a pi* prefix would swallow the signed adapter.
fm_control_harness_family() {  # <recorded-harness>
  case "${1-}" in
    pi) printf 'pi' ;;
    pi-signed) printf 'pi-signed' ;;
    *) return 1 ;;
  esac
}

fm_control_harness_supports_kind() {  # <harness> <kind>
  fm_control_harness_supported "${1-}"
}

fm_control_interrupt_key() {  # <harness>
  fm_control_harness_supported "${1-}" || return 1
  printf 'Escape'
}

# Prints nothing: Pi leaves its composer empty after an interrupt.
fm_control_interrupt_clear_key() {  # <harness>
  fm_control_harness_supported "${1-}"
}

fm_control_exit_command() {  # <harness>
  fm_control_harness_supported "${1-}" || return 1
  printf '/quit'
}

fm_control_backend_supports_key() {  # <backend> <key>
  [ "${1-}" = herdr ] || return 1
  case "${2-}" in Escape|Enter|C-c|C-u) return 0 ;; esac
  return 1
}

fm_control_backend_state_verified() {  # <backend>
  [ "${1-}" = herdr ]
}

fm_control_backend_relaunch_supported() {  # <backend>
  [ "${1-}" = herdr ]
}

fm_control_absence_recheck_applies() {  # <backend> <raw-state>
  [ "${2-}" = missing ]
}

# A `missing` reading also covers an endpoint that is only unreachable from
# here, and an unreachable endpoint can still hold a live agent.
# Prints "<verdict>\t<reason>" with exactly one TAB. The verdict is gone, dead,
# alive, or unproven; the reason is empty except on unproven.
fm_control_endpoint_absence_verdict() {  # <backend> <target>
  local backend=${1-} target=${2-}
  fm_backend_source "$backend" \
    || { printf 'unproven\tbackend %s could not be loaded to prove anything about that endpoint' "'$backend'"; return 0; }
  case "$backend" in
    herdr)
      case "$(fm_backend_herdr_endpoint_absence_recheck "$target")" in
        dead) printf 'dead\t' ;;
        alive) printf 'alive\t' ;;
        missing) printf 'gone\t' ;;
        *) printf 'unproven\tthe recorded herdr session'"'"'s server could not be started, or its pane could not be classified once it was running' ;;
      esac
      ;;
    *)
      printf 'unproven\tbackend %s has no recovery-grade classifier, so absence cannot be proven on it at all' "'$backend'"
      ;;
  esac
}

# Prints only firstmate-owned per-task files, never a harness's own config.
fm_control_harness_wiring_paths() {  # <harness> <worktree> <state-dir> <id>
  local harness=${1-} wt=${2-} state=${3-} id=${4-}
  [ -n "$wt" ] && [ -n "$state" ] && [ -n "$id" ] || return 1
  case "$harness" in
    pi|pi-signed) printf '%s\n' "$state/$id.pi-ext.ts" ;;
  esac
}
