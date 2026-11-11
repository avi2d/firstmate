#!/usr/bin/env bash
# Remote secondmate retirement through the host-side entry point,
# fm-remote-secondmate-control.sh retire, against fixture homes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/remote-herdr-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-herdr-fixture.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-secondmate-retire)
CONTROL="$ROOT/bin/fm-remote-secondmate-control.sh"
CLAIMS="$TMP_ROOT/claims"
FAKE="$TMP_ROOT/fake"
HERDR_STATE="$TMP_ROOT/herdr.state"
mkdir -p "$CLAIMS" "$FAKE"
export FM_PROCEVENT_CLAIM_ROOT="$CLAIMS"
install_remote_herdr_fixture "$FAKE" "$HERDR_STATE" "$TMP_ROOT/herdr.log" "$TMP_ROOT/herdr-send-fail" "$TMP_ROOT/herdr.sock"
cleanup_retire_fixture() {
  [ ! -f "$HERDR_STATE.shell-pid" ] || kill "$(cat "$HERDR_STATE.shell-pid")" 2>/dev/null || true
}
trap 'cleanup_retire_fixture; fm_test_cleanup' EXIT

# A seeded remote secondmate home whose parent-route record names a Herdr pane
# that is already gone. Echoes the home.
make_home() {  # <name>
  local name=$1 home route
  home="$TMP_ROOT/$name/home"
  route="$home/state/parent-route"
  mkdir -p "$route" "$home/data/.parent-route" "$home/config" "$home/projects" "$home/state/procevent"
  cp -R "$ROOT/bin" "$home/bin"
  printf '# fixture\n' > "$home/AGENTS.md"
  printf 'sm1\n' > "$home/.fm-secondmate-home"
  fm_write_meta "$route/sm1.meta" \
    "window=fm-remote:w1:p2" \
    "endpoint_task_id=sm1" \
    "backend=herdr" \
    "herdr_session=fm-remote" \
    "herdr_workspace_id=w1" \
    "herdr_tab_id=w1:t2" \
    "herdr_pane_id=w1:p2" \
    "worktree=$home" \
    "home=$home" \
    "project=$home" \
    "kind=secondmate" \
    "mode=local-only" \
    "spawn_gen=retire-test-sm1"
  chmod -R go-w "$TMP_ROOT/$name"
  printf '%s\n' "$home"
}

add_home_source() {  # <home> <source-id>
  cat > "$1/state/procevent/$2.source" <<EOF
adapter=lavish
kind=persistent
argc=2
argv:
$ROOT/bin/fm-procevent-lavish.sh
poll
EOF
}

retire() {  # <home> [--force]
  PATH="$FAKE/bin:$PATH" FM_HOME="$1" "$CONTROL" retire sm1 ${2:+"$2"}
}

test_retire_sweeps_the_home_process_events_not_the_parent_route() {
  local home rc=0 out
  home=$(make_home sweep-own-state)
  add_home_source "$home" board-review
  chmod g+w "$home/state/parent-route"
  out=$(retire "$home" 2>&1) || rc=$?
  expect_code 0 "$rc" "retirement refused a home whose only process event is its own: $out"
  assert_contains "$out" "swept: attempted=1" "the sweep did not reach the home's own source"
  assert_absent "$home" "retirement kept the home"
  pass "retirement sweeps the home's own process events instead of the group-writable parent-route folder"
}

test_unprivate_state_root_refusal_names_the_folder() {
  local home rc=0 out
  home=$(make_home unprivate-state)
  add_home_source "$home" board-review
  chmod g+w "$home/state"
  out=$(retire "$home" 2>&1) || rc=$?
  expect_code 1 "$rc" "retirement accepted a group-writable process-event state folder"
  assert_contains "$out" "not a private directory: $home/state" "the refusal did not name the folder"
  assert_present "$home/state/procevent/board-review.source" "a refused retirement dropped the source"
  pass "a non-private process-event state folder refuses with its path instead of an unnamed folder"
}

test_retire_sweeps_the_home_process_events_not_the_parent_route
test_unprivate_state_root_refusal_names_the_folder
