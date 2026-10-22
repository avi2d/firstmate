#!/usr/bin/env bash
# Rolling hourly core budget shared by the Mac gate and the winbox gate.
# Sparse samples carry the last value forward, so thin history overstates the burn.

# shellcheck disable=SC2034 # read by bin/fm-spawn.sh after sourcing.
FM_CORE_BUDGET_DEFER_EXIT=75
FM_CORE_BUDGET_WINDOW_SECS=3600

fm_machine_core_budget_samples_file() { # <home> <home-state>
  local home=$1 state=$2 root home_real
  root=$(fm_firstmate_root_home "$home") || return 1
  home_real=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) || return 1
  if [ "$root" = "$home_real" ]; then
    printf '%s/core-budget-samples\n' "$state"
  else
    printf '%s/state/core-budget-samples\n' "$root"
  fi
}

fm_machine_core_budget_held_dir() { # <home> <home-state>
  local home=$1 state=$2 root home_real
  root=$(fm_firstmate_root_home "$home") || return 1
  home_real=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) || return 1
  if [ "$root" = "$home_real" ]; then
    printf '%s/core-budget-held\n' "$state"
  else
    printf '%s/state/core-budget-held\n' "$root"
  fi
}

fm_machine_core_budget_cores_now() {
  local mock=${FM_CORE_BUDGET_MOCK_CORES:-}
  local total
  if [ -n "$mock" ]; then
    printf '%s\n' "$mock"
    return 0
  fi
  total=$(ps -A -o %cpu 2>/dev/null | awk 'NR>1 {s+=$1} END {printf "%.2f", s+0}') || return 1
  awk -v t="$total" 'BEGIN {printf "%.2f", t/100}'
}

fm_machine_core_budget_record() { # <samples-file>
  local file=$1 now cores
  now=${FM_CORE_BUDGET_MOCK_NOW:-}
  [ -n "$now" ] || now=$(date +%s) || return 1
  cores=$(fm_machine_core_budget_cores_now) || return 1
  mkdir -p "${file%/*}" || return 1
  printf '%s %s\n' "$now" "$cores" >>"$file" || return 1
}

fm_machine_core_budget_usage() { # <samples-file>
  local file=$1 mock=${FM_CORE_BUDGET_MOCK_USAGE:-}
  local now cutoff
  if [ -n "$mock" ]; then
    printf '%s\n' "$mock"
    return 0
  fi
  FM_MACHINE_CORE_BUDGET_ERROR=
  now=${FM_CORE_BUDGET_MOCK_NOW:-}
  [ -n "$now" ] || now=$(date +%s) || return 1
  cutoff=$((now - FM_CORE_BUDGET_WINDOW_SECS))
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    printf '0\n'
    return 0
  fi
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    FM_MACHINE_CORE_BUDGET_ERROR="core budget sample log $file cannot be read"
    return 1
  fi
  sort -n -k1,1 "$file" 2>/dev/null | awk -v now="$now" -v cutoff="$cutoff" '
    BEGIN {prev_t=cutoff}
    NF < 2 {next}
    $1+0 < cutoff {prev_c=$2+0; next}
    {
      t=$1+0; c=$2+0
      if (prev_c == "") prev_c=c
      if (t > now) t=now
      if (t > prev_t) total+=prev_c*(t-prev_t)
      prev_t=t; prev_c=c
    }
    END {
      if (prev_c == "") {print 0; exit}
      if (now > prev_t) total+=prev_c*(now-prev_t)
      printf "%.2f\n", total/3600
    }' || {
    FM_MACHINE_CORE_BUDGET_ERROR="core budget sample log $file cannot be read"
    return 1
  }
}

fm_machine_core_budget_over() { # <usage> <budget>
  awk -v u="$1" -v b="$2" 'BEGIN {exit !(u+0 >= b+0)}'
}
