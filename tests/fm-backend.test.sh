#!/usr/bin/env bash
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$ROOT/bin/fm-backend.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend)
export FM_HOME="$TMP_ROOT/home"
export FM_BACKEND_CONFIG_DIR="$FM_HOME/config"
mkdir -p "$FM_BACKEND_CONFIG_DIR"

test_backend_refuses_unknown_config_instead_of_falling_back() {
  local out rc=0
  [ "$(FM_BACKEND= fm_backend_name)" = herdr ] || fail "missing backend config must select Herdr"
  printf 'unsupported\n' > "$FM_BACKEND_CONFIG_DIR/backend"
  [ "$(FM_BACKEND= fm_backend_name)" = unsupported ] || fail "explicit config was silently replaced"
  out=$(fm_backend_validate "$(FM_BACKEND= fm_backend_name)" 2>&1) || rc=$?
  expect_code 1 "$rc" "unsupported backend must stop before touching an endpoint"
  assert_contains "$out" "unknown backend 'unsupported' (known: herdr)" "refusal did not name the supported backend"
  [ "$(FM_BACKEND=herdr fm_backend_name)" = herdr ] || fail "explicit Herdr override did not win"
  pass "backend resolution does not silently replace an invalid configured backend"
}

_backend_source_adapter_condition() {  # missing|unreadable
  local dir adapter exit_status continuation out rc condition test_bash
  condition=$1
  dir="$TMP_ROOT/adapter-precheck"
  adapter="$dir/backends/herdr.sh"
  test_bash=${FM_TEST_BASH:-${BASH:-bash}}
  mkdir -p "$dir/backends"

  if [ "$condition" = unreadable ]; then
    printf ':\n' > "$adapter"
    chmod 000 "$adapter"
    if [ -r "$adapter" ]; then
      pass "fm_backend_source: unreadable adapter case skipped (this user can read mode-000 files)"
      return 0
    fi
  fi
  exit_status="$dir/$condition.exit"
  continuation="$dir/$condition.continued"
  # shellcheck disable=SC2016 # The child Bash expands $1..$4 and $? at runtime.
  out=$("$test_bash" -c '
    . "$1"
    FM_BACKEND_LIB_DIR=$2
    trap '\''printf "%s\n" "$?" > "$3"'\'' EXIT
    set -e
    fm_backend_source herdr
    : > "$4"
  ' _ "$ROOT/bin/fm-backend.sh" "$dir" "$exit_status" "$continuation" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "fm_backend_source returned success for a $condition adapter: $out"
  [ -f "$exit_status" ] || fail "fm_backend_source did not record the $condition adapter exit status"
  [ "$(cat "$exit_status")" -ne 0 ] || fail "fm_backend_source lost the $condition adapter failure at EXIT"
  [ ! -e "$continuation" ] || fail "fm_backend_source continued the lifecycle after a $condition adapter"
  pass "fm_backend_source: $condition adapter fails before lifecycle continuation"
}

test_backend_source_requires_missing_adapter_file() {
  _backend_source_adapter_condition missing
}

test_backend_source_requires_unreadable_adapter_file() {
  _backend_source_adapter_condition unreadable
}

test_meta_get_and_backend_of_meta() {
  local meta=$TMP_ROOT/meta-get.meta edge=$TMP_ROOT/meta-get-edge.meta
  fm_write_meta "$meta" "window=firstmate:pane:1" "harness=pi"
  [ "$(fm_meta_get "$meta" window)" = "firstmate:pane:1" ] || fail "fm_meta_get did not read window="
  [ "$(fm_meta_get "$meta" missing)" = "" ] || fail "fm_meta_get should print nothing for an absent key"
  [ "$(fm_backend_of_meta "$meta")" = unknown ] || fail "an unbound record must not become a Herdr target"

  printf 'backend=herdr\n' >> "$meta"
  [ "$(fm_backend_of_meta "$meta")" = herdr ] || fail "fm_backend_of_meta should read an explicit backend=herdr"

  printf 'token=first\ntoken=last=value' > "$edge"
  [ "$(fm_meta_get "$edge" token)" = "last=value" ] \
    || fail "fm_meta_get did not preserve last-value or no-final-newline semantics"

  pass "fm_meta_get / fm_backend_of_meta: reads exact keys and never infers an absent backend"
}

test_backend_refuses_unknown_config_instead_of_falling_back
test_backend_source_requires_missing_adapter_file
test_backend_source_requires_unreadable_adapter_file
test_meta_get_and_backend_of_meta
