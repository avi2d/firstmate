#!/usr/bin/env bash
# Behavior tests for the single simulator boot path.
# A fake xcrun stands in for simctl so no real simulator ever boots.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/bin/fm-sim-boot.sh"
TMP_ROOT=$(fm_test_tmproot fm-sim-boot)
DEFER_EXIT=75

UDID_A="AAAAAAAA-1111-4111-8111-AAAAAAAAAAAA"
UDID_C="CCCCCCCC-3333-4333-8333-CCCCCCCCCCCC"
UDID_PAD="DDDDDDDD-4444-4444-8444-DDDDDDDDDDDD"
UDID_NEVER="EEEEEEEE-5555-4555-8555-EEEEEEEEEEEE"
UDID_GONE="FFFFFFFF-6666-4666-8666-FFFFFFFFFFFF"

write_json() {  # <file> <booted-udid-or-empty>
  local file=$1 booted=$2 state_a=Shutdown state_c=Shutdown
  [ "$booted" = "$UDID_A" ] && state_a=Booted
  [ "$booted" = "$UDID_C" ] && state_c=Booted
  cat > "$file" <<JSON
{
  "devices" : {
    "com.apple.CoreSimulator.SimRuntime.iOS-27-0" : [
      {
        "udid" : "$UDID_A",
        "state" : "$state_a",
        "isAvailable" : true,
        "name" : "iPhone 18 Pro",
        "lastUsedAt" : "2026-10-17T09:00:00Z"
      },
      {
        "udid" : "$UDID_PAD",
        "state" : "Shutdown",
        "isAvailable" : true,
        "name" : "iPad Pro 13-inch",
        "lastUsedAt" : "2026-10-17T10:00:00Z"
      },
      {
        "udid" : "$UDID_GONE",
        "state" : "Shutdown",
        "isAvailable" : false,
        "name" : "iPhone 18",
        "lastUsedAt" : "2026-10-17T11:00:00Z"
      }
    ],
    "com.apple.CoreSimulator.SimRuntime.iOS-26-1" : [
      {
        "udid" : "$UDID_C",
        "state" : "$state_c",
        "isAvailable" : true,
        "name" : "iPhone 17",
        "lastUsedAt" : "2026-10-17T08:00:00Z"
      },
      {
        "udid" : "$UDID_NEVER",
        "state" : "Shutdown",
        "isAvailable" : true,
        "name" : "iPhone 17 Pro"
      }
    ]
  }
}
JSON
}

make_case() {  # <name>
  local case_dir=$1 fakebin
  case_dir="$TMP_ROOT/$1"
  mkdir -p "$case_dir"
  fakebin=$(fm_fakebin "$case_dir")
  cat > "$fakebin/xcrun" <<'SH'
#!/usr/bin/env bash
log="$FM_SIM_BOOT_FAKE_LOG"
json="$FM_SIM_BOOT_FAKE_JSON"
case "$1 $2" in
  "simctl list")
    cat "$json"
    ;;
  "simctl boot")
    printf 'boot %s\n' "$3" >> "$log"
    ;;
  "simctl create")
    printf 'create %s %s %s\n' "$3" "$4" "${5:-}" >> "$log"
    printf 'NEW-UDID-0000\n'
    ;;
  "simctl shutdown")
    printf 'shutdown-all\n' >> "$log"
    ;;
  *)
    printf 'unexpected simctl call: %s\n' "$*" >&2
    exit 1
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/xcrun"
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf 'Darwin\n'
SH
  chmod +x "$fakebin/uname"
  : > "$case_dir/calls.log"
  printf '%s\n' "$case_dir"
}

run_helper() {  # <case-dir> <load> <args...>
  local case_dir=$1 load=$2
  shift 2
  PATH="$case_dir/fakebin:$PATH" \
    FM_SIM_BOOT_XCRUN="$case_dir/fakebin/xcrun" \
    FM_SIM_BOOT_DIR="$case_dir/gate" \
    FM_SIM_BOOT_FORCE=1 \
    FM_SIM_BOOT_FAKE_LOG="$case_dir/calls.log" \
    FM_SIM_BOOT_FAKE_JSON="$case_dir/devices.json" \
    FM_MAC_LOAD_MOCK_5MIN="$load" \
    "$HELPER" "$@" 2>&1
}

test_refuses_while_another_is_booted_then_boots_once_clear() {
  local case_dir out rc=0
  case_dir=$(make_case booted)
  write_json "$case_dir/devices.json" "$UDID_C"
  out=$(run_helper "$case_dir" 1.0 boot) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a boot alongside a booted device was not refused: $out"
  assert_contains "$out" "already booted ($UDID_C)" "the refusal did not name the booted device"
  assert_absent "$case_dir/gate/holder" "the refused boot recorded a holder"
  [ -s "$case_dir/calls.log" ] && fail "the refused boot called simctl: $(cat "$case_dir/calls.log")"
  write_json "$case_dir/devices.json" ""
  rc=0
  out=$(run_helper "$case_dir" 1.0 boot) || rc=$?
  expect_code 0 "$rc" "the same boot was refused after the device shut down: $out"
  assert_contains "$out" "$UDID_A booted" "the boot did not take the preferred existing device"
  assert_contains "$(cat "$case_dir/calls.log")" "boot $UDID_A" "simctl did not boot the preferred device"
  pass "a boot refuses while another device is booted, then boots once clear"
}

test_boots_preferred_existing_device_without_creating() {
  local case_dir out rc=0
  case_dir=$(make_case preferred)
  write_json "$case_dir/devices.json" ""
  out=$(run_helper "$case_dir" 1.0 boot) || rc=$?
  expect_code 0 "$rc" "a boot with devices free failed: $out"
  assert_contains "$out" "$UDID_A booted" "the boot did not pick the warm iPhone on the newest runtime"
  [ -s "$case_dir/calls.log" ] || fail "the boot called nothing"
  assert_not_contains "$(cat "$case_dir/calls.log")" "create" "the boot created a device instead of reusing one"
  pass "a boot reuses the warm newest-runtime iPhone and never creates one unasked"
}

test_create_is_gated_and_never_implicit() {
  local case_dir out rc=0
  case_dir=$(make_case create)
  write_json "$case_dir/devices.json" "$UDID_A"
  out=$(run_helper "$case_dir" 1.0 boot --create Fresh "iPhone 18 Pro") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a create alongside a booted device was not refused: $out"
  assert_not_contains "$(cat "$case_dir/calls.log")" "create" "the refused create still ran simctl"
  write_json "$case_dir/devices.json" ""
  rc=0
  out=$(run_helper "$case_dir" 1.0 boot --create Fresh "iPhone 18 Pro") || rc=$?
  expect_code 0 "$rc" "an explicit create with devices free failed: $out"
  assert_contains "$(cat "$case_dir/calls.log")" "create Fresh iPhone 18 Pro" "simctl did not create the named device"
  pass "an explicit create is gated like a boot and never happens implicitly"
}

test_high_load_refuses_then_clear_boots() {
  local case_dir out rc=0
  case_dir=$(make_case load)
  write_json "$case_dir/devices.json" ""
  out=$(run_helper "$case_dir" 10.0 boot) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a boot on a high average was not refused: $out"
  assert_contains "$out" "five-minute load average is 10.0 (limit 10)" "the refusal did not name the average and the limit"
  [ -s "$case_dir/calls.log" ] && fail "the refused boot called simctl: $(cat "$case_dir/calls.log")"
  rc=0
  out=$(run_helper "$case_dir" 1.0 boot) || rc=$?
  expect_code 0 "$rc" "the same boot was refused after the average cleared: $out"
  assert_contains "$out" "$UDID_A booted" "the cleared boot did not launch the device"
  pass "a high five-minute average refuses a boot, and the same boot launches once it clears"
}

test_device_selector_and_first_boot_note() {
  local case_dir out rc=0
  case_dir=$(make_case selector)
  write_json "$case_dir/devices.json" ""
  out=$(run_helper "$case_dir" 1.0 boot --device "$UDID_NEVER") || rc=$?
  expect_code 0 "$rc" "a boot of the named device failed: $out"
  assert_contains "$out" "never booted; its first boot compiles and takes minutes" "the boot did not warn about the first-boot cost"
  out=$(run_helper "$case_dir" 1.0 boot --device "No Such Phone") || rc=$?
  expect_code 2 "$rc" "an unknown device did not fail: $out"
  pass "a named device boots with a first-boot warning, and an unknown one fails"
}

test_status_and_shutdown() {
  local case_dir out rc=0
  case_dir=$(make_case status)
  write_json "$case_dir/devices.json" "$UDID_C"
  out=$(run_helper "$case_dir" 3.5 status) || rc=$?
  expect_code 0 "$rc" "status failed: $out"
  assert_contains "$out" "five-minute load average is 3.5 (limit 10)" "status did not report the average and the limit"
  assert_contains "$out" "$UDID_C" "status did not list the booted device"
  out=$(run_helper "$case_dir" 1.0 shutdown) || rc=$?
  expect_code 0 "$rc" "shutdown failed: $out"
  assert_contains "$(cat "$case_dir/calls.log")" "shutdown-all" "shutdown did not shut devices down"
  pass "status reports the average and the booted set, and shutdown clears them"
}

test_refuses_while_another_is_booted_then_boots_once_clear
test_boots_preferred_existing_device_without_creating
test_create_is_gated_and_never_implicit
test_high_load_refuses_then_clear_boots
test_device_selector_and_first_boot_note
test_status_and_shutdown
