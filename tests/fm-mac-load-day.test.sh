#!/usr/bin/env bash
# The standing heavy cap follows the UTC hour on both machines, while a pinned
# @heavy-limit wins at any hour and the load caps stay put.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-mac-load-lib.sh
. "$ROOT/bin/fm-mac-load-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-mac-load-day)
BEFORE_DAY=1792389540
START_DAY=1792389600
END_DAY=1792443540
START_NIGHT=1792443600

DARWIN_BIN="$TMP_ROOT/fake-darwin"
LINUX_BIN="$TMP_ROOT/fake-linux"
mkdir -p "$DARWIN_BIN" "$LINUX_BIN"
printf '#!/usr/bin/env bash\nprintf "Darwin\\n"\n' > "$DARWIN_BIN/uname"
printf '#!/usr/bin/env bash\nprintf "Linux\\n"\n' > "$LINUX_BIN/uname"
chmod +x "$DARWIN_BIN/uname" "$LINUX_BIN/uname"

check_hour() {  # <epoch> <want-mac-heavy> <want-linux-heavy>
  FM_MAC_LOAD_MOCK_NOW=$1
  PATH="$DARWIN_BIN:$PATH" fm_mac_load_config "" || fail "the Mac config refused at mock hour $1"
  assert_equals "$2" "$FM_MAC_HEAVY_LIMIT" "the Mac heavy cap at mock hour $1 was not $2"
  fm_linux_load_config "" || fail "the linux config refused at mock hour $1"
  assert_equals "$3" "$FM_LINUX_HEAVY_LIMIT" "the linux heavy cap at mock hour $1 was not $3"
}

test_night_before_day_keeps_night_caps() {
  check_hour "$BEFORE_DAY" 4 6
  pass "05:59 UTC keeps the night caps of four on Mac and six on linux"
}

test_day_start_drops_to_day_caps() {
  check_hour "$START_DAY" 3 4
  pass "06:00 UTC drops to the day caps of three on Mac and four on linux"
}

test_day_end_keeps_day_caps() {
  check_hour "$END_DAY" 3 4
  pass "20:59 UTC keeps the day caps of three on Mac and four on linux"
}

test_night_start_restores_night_caps() {
  check_hour "$START_NIGHT" 4 6
  pass "21:00 UTC restores the night caps of four on Mac and six on linux"
}

check_linux_hour() {  # <epoch> <want-heavy>
  FM_MAC_LOAD_MOCK_NOW=$1
  PATH="$LINUX_BIN:$PATH" fm_mac_load_config "" || fail "the Linux config refused at mock hour $1"
  assert_equals 16 "$FM_MAC_LOAD_LIMIT" "the Linux load cap moved from 16 at mock hour $1"
  assert_equals "$2" "$FM_MAC_HEAVY_LIMIT" "the Linux heavy cap at mock hour $1 was not $2"
}

test_linux_night_keeps_linux_caps() {
  check_linux_hour "$BEFORE_DAY" 6
  pass "05:59 UTC keeps the linux caps of six heavy and 16 load on Linux"
}

test_linux_day_drops_to_linux_day_caps() {
  check_linux_hour "$START_DAY" 4
  pass "06:00 UTC drops to the linux day caps of four heavy and 16 load on Linux"
}

test_load_caps_stay_put_by_day() {
  FM_MAC_LOAD_MOCK_NOW=$START_DAY
  PATH="$DARWIN_BIN:$PATH" fm_mac_load_config "" || fail "the Mac config refused at mock hour $START_DAY"
  assert_equals 10 "$FM_MAC_LOAD_LIMIT" "the Mac load cap moved from 10"
  fm_linux_load_config "" || fail "the linux config refused at mock hour $START_DAY"
  assert_equals 16 "$FM_LINUX_LOAD_LIMIT" "the linux load cap moved from 16"
  pass "the load caps stay 10 on Mac and 16 on linux at a day hour"
}

test_pinned_heavy_limit_wins_by_day() {
  local dir="$TMP_ROOT/pinned"
  mkdir -p "$dir"
  printf '%s\n' '@heavy-limit 5' > "$dir/project-capacity"
  FM_MAC_LOAD_MOCK_NOW=$START_DAY
  fm_mac_load_config "$dir" || fail "the Mac config refused a pinned limit"
  assert_equals 5 "$FM_MAC_HEAVY_LIMIT" "a pinned @heavy-limit lost to the day cap on Mac"
  fm_linux_load_config "$dir" || fail "the linux config refused a pinned limit"
  assert_equals 5 "$FM_LINUX_HEAVY_LIMIT" "a pinned @heavy-limit lost to the day cap on linux"
  pass "a pinned @heavy-limit of 5 wins over both day caps"
}

test_night_before_day_keeps_night_caps
test_day_start_drops_to_day_caps
test_day_end_keeps_day_caps
test_night_start_restores_night_caps
test_linux_night_keeps_linux_caps
test_linux_day_drops_to_linux_day_caps
test_load_caps_stay_put_by_day
test_pinned_heavy_limit_wins_by_day
