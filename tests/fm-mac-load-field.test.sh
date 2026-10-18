#!/usr/bin/env bash
# The macOS reader returns the middle vm.loadavg field, the five-minute average.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-mac-load-field)

test_sysctl_stub_yields_five_minute_average() {
  local case_dir="$TMP_ROOT/field" fakebin got
  mkdir -p "$case_dir"
  fakebin=$(fm_fakebin "$case_dir")
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf 'Darwin\n'
SH
  cat > "$fakebin/sysctl" <<'SH'
#!/usr/bin/env bash
printf '{ 3.79 9.14 26.84 }\n'
SH
  chmod +x "$fakebin/uname" "$fakebin/sysctl"
  got=$(env -u FM_MAC_LOAD_MOCK_5MIN PATH="$fakebin:$PATH" bash -c '. "$0" && fm_mac_loadavg_5min' "$ROOT/bin/fm-mac-load-lib.sh")
  assert_equals "9.14" "$got" "the macOS reader did not return the middle vm.loadavg field"
  pass "a sysctl stub printing the 1, 5 and 15 minute averages yields the five-minute value"
}

test_sysctl_stub_yields_five_minute_average
