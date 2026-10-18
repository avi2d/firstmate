#!/usr/bin/env bash
# Behavior tests for bin/fm-lavish-board-handoff.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

HANDOFF="$ROOT/bin/fm-lavish-board-handoff.sh"
TMP_ROOT=$(fm_test_tmproot fm-lavish-board-handoff)

test_declared_board_handoff_needs_firstmate() {
  local dir line open expected
  dir="$TMP_ROOT/declared"; mkdir -p "$dir"
  line='needs-decision [key=board-handoff]: board ready for firstmate handoff: round-2.html'
  printf '%s\n' "$line" > "$dir/task.status"
  status_is_captain_relevant "$line" \
    || fail "declared board handoff is not captain-relevant: $line"
  open=$(status_open_decisions "$dir/task.status")
  expected=$(printf 'board-handoff\tneeds-decision\tboard ready for firstmate handoff: round-2.html\n')
  [ "$open" = "$expected" ] \
    || fail "declared board handoff did not fold open under board-handoff: got '$open'"
  pass "declared board handoff reaches firstmate as an open decision"
}

stub_lavish_axi() {  # <dir> <exit>
  local dir=$1 code=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/lavish-axi" <<SH
#!/usr/bin/env bash
set -u
: >> "${dir}/called"
exit $code
SH
  chmod +x "$fakebin/lavish-axi"
  printf '%s' "$fakebin"
}

test_refuses_page_without_queueprompt() {
  local dir fakebin out rc
  dir="$TMP_ROOT/refuse"; mkdir -p "$dir/home"
  fakebin=$(stub_lavish_axi "$dir" 0)
  printf '<html><body>no prompt here</body></html>\n' > "$dir/plain.html"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$dir/home" \
    "$HANDOFF" "$dir/plain.html" --for interview-1 2>&1); rc=$?
  printf '%s' "$out" > "$dir/out.txt"
  expect_code 1 "$rc" "handoff must refuse a page without queuePrompt"
  assert_grep 'queuePrompt' "$dir/out.txt" \
    "refusal did not name queuePrompt: $out"
  [ ! -e "$dir/called" ] \
    || fail "refusal opened lavish-axi before checking the page"
  pass "handoff refuses a page without queuePrompt without touching lavish-axi"
}

test_open_failure_stops_the_handoff() {
  local dir fakebin out rc
  dir="$TMP_ROOT/open-fails"; mkdir -p "$dir/home"
  fakebin=$(stub_lavish_axi "$dir" 1)
  printf '<html><body><script>window.lavish.queuePrompt({})</script></body></html>\n' > "$dir/board.html"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$dir/home" \
    "$HANDOFF" "$dir/board.html" --for interview-1 2>&1); rc=$?
  printf '%s' "$out" > "$dir/out.txt"
  expect_code 1 "$rc" "handoff must fail when lavish-axi cannot open the page"
  assert_grep 'cannot open' "$dir/out.txt" \
    "open failure did not report the page: $out"
  pass "handoff stops when lavish-axi cannot open the page"
}

test_declared_board_handoff_needs_firstmate
test_refuses_page_without_queueprompt
test_open_failure_stops_the_handoff
