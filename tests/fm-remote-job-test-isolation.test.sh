#!/usr/bin/env bash
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-remote-job-isolation)
mkdir -p "$TMP_ROOT/account"
out=$(FM_REMOTE_JOB_PLATFORM_OVERRIDE=Darwin FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/job-state" bash -c '
  . "$1/bin/fm-remote-job-lib.sh"
  fm_remote_job_gui_available() { return 0; }
  fm_remote_job_ensure_launchagent() { printf "launchagent-called\\n"; return 0; }
  fm_remote_job_ensure_worker "$1" "$2"
' _ "$ROOT" "$TMP_ROOT/account" 2>&1) && fail "private job state was permitted to alter the account launch agent: $out"
printf '%s\n' "$out" | grep -F 'launchagent-called' >/dev/null && fail "private job state reached the launch agent" || :
pass "private remote job state cannot select the account launch agent"
