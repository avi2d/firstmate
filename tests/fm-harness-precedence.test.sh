#!/usr/bin/env bash
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-harness-precedence)
HARNESS="$ROOT/bin/fm-harness.sh"
under_process() {
  local bin=$1
  shift
  env -u PI_CODING_AGENT -u FM_PI_HARNESS "$@" "$bin" -c '
    result=$("$1"); printf "%s" "$result"
  ' _ "$HARNESS"
}

named_bin() {  # <dir> <name>
  mkdir -p "$1"
  cp "$(command -v bash)" "$1/$2"
  printf '%s\n' "$1/$2"
}

test_pi_signed_survives_agreeing_ancestry() {
  local bin got
  bin=$(named_bin "$TMP_ROOT/pi-tree" pi)
  got=$(under_process "$bin" PI_CODING_AGENT=true FM_PI_HARNESS=pi-signed)
  [ "$got" = pi-signed ] || fail "signed Pi over pi ancestry resolved '$got', expected pi-signed"
  got=$(under_process "$bin" PI_CODING_AGENT=true)
  [ "$got" = pi ] || fail "plain Pi over pi ancestry resolved '$got', expected pi"
  got=$(under_process "$bin")
  [ "$got" = pi ] || fail "unmarked pi ancestry resolved '$got', expected pi"

  bin=$(named_bin "$TMP_ROOT/pi-signed-tree" pi-signed)
  got=$(under_process "$bin" PI_CODING_AGENT=true FM_PI_HARNESS=pi-signed)
  [ "$got" = pi-signed ] \
    || fail "signed Pi over shared signed-wrapper ancestry resolved '$got', expected pi-signed"
  got=$(under_process "$bin")
  [ "$got" = pi ] \
    || fail "unmarked signed-wrapper ancestry resolved '$got', expected pi"
  pass "an agreeing marker keeps Pi's finer identity that ancestry cannot prove"
}

pin_probe() {  # <named-executable> <home> <verb> [VAR=VAL ...]
  local bin=$1 home=$2 verb=$3
  shift 3
  env -u PI_CODING_AGENT -u FM_PI_HARNESS -u FM_SUPERVISION_ACTOR \
    -u FM_SUPERVISION_PRIMARY_HARNESS FM_HOME="$home" "$@" \
    "$bin" -c "r=\$(\"$HARNESS\" $verb 2>\"$home/stderr\"); rc=\$?; printf '%s|%s' \"\$r\" \"\$rc\""
}

test_supervision_branch_resolves_the_primary_pin() {
  local dir home bin verb got
  dir="$TMP_ROOT/primary-pin"
  home="$dir/home"
  mkdir -p "$home/config"
  bin=$(named_bin "$dir/pi-tree" pi)

  # Without the pin the branch reads as its own engine, which is the hazard.
  for verb in '' crew; do
    got=$(pin_probe "$bin" "$home" "$verb" PI_CODING_AGENT=true FM_SUPERVISION_ACTOR=branch)
    [ "$got" = 'pi|0' ] \
      || fail "an unpinned branch under a Pi engine resolved '${verb:-own}' as '$got', expected pi (the hazard is not live)"
  done

  for verb in '' crew; do
    got=$(pin_probe "$bin" "$home" "$verb" PI_CODING_AGENT=true \
      FM_SUPERVISION_ACTOR=branch FM_SUPERVISION_PRIMARY_HARNESS=pi-signed)
    [ "$got" = 'pi-signed|0' ] \
      || fail "a pinned branch resolved '${verb:-own}' as '$got', expected the primary's pi-signed"
  done
  printf 'default\n' > "$home/config/crew-harness"
  got=$(pin_probe "$bin" "$home" crew PI_CODING_AGENT=true \
    FM_SUPERVISION_ACTOR=branch FM_SUPERVISION_PRIMARY_HARNESS=pi-signed)
  [ "$got" = 'pi-signed|0' ] || fail "a pinned branch resolved a default crew config as '$got', expected pi-signed"

  # An explicit crew config is still the captain's choice, pin or no pin.
  printf 'pi\n' > "$home/config/crew-harness"
  got=$(pin_probe "$bin" "$home" crew PI_CODING_AGENT=true \
    FM_SUPERVISION_ACTOR=branch FM_SUPERVISION_PRIMARY_HARNESS=pi-signed)
  [ "$got" = 'pi|0' ] || fail "the pin overrode an explicit crew config: '$got'"
  rm -f "$home/config/crew-harness"

  # Main, or no actor at all, ignores the pin.
  got=$(pin_probe "$bin" "$home" '' PI_CODING_AGENT=true FM_SUPERVISION_PRIMARY_HARNESS=pi-signed)
  [ "$got" = 'pi|0' ] || fail "an unmarked process honored the branch-only pin: '$got'"
  got=$(pin_probe "$bin" "$home" '' PI_CODING_AGENT=true \
    FM_SUPERVISION_ACTOR=main FM_SUPERVISION_PRIMARY_HARNESS=pi-signed)
  [ "$got" = 'pi|0' ] || fail "the main actor honored the branch-only pin: '$got'"

  # The ancestry evidence verb reports evidence only and never consults it.
  got=$(pin_probe "$bin" "$home" ancestry PI_CODING_AGENT=true \
    FM_SUPERVISION_ACTOR=branch FM_SUPERVISION_PRIMARY_HARNESS=pi-signed)
  [ "$got" = 'comm pi|0' ] || fail "the ancestry verb consulted the pin: '$got'"
  pass "a supervision branch resolves own and crew to the primary's pinned harness"
}

test_supervision_branch_refuses_an_unknown_primary_pin() {
  local dir home bin verb got
  dir="$TMP_ROOT/primary-pin-bad"
  home="$dir/home"
  mkdir -p "$home/config"
  bin=$(named_bin "$dir/pi-tree" pi)
  for verb in '' crew; do
    got=$(pin_probe "$bin" "$home" "$verb" PI_CODING_AGENT=true \
      FM_SUPERVISION_ACTOR=branch FM_SUPERVISION_PRIMARY_HARNESS=unknown)
    [ "$got" = '|2' ] \
      || fail "an unknown pin resolved '${verb:-own}' as '$got', expected a refusal with nothing on stdout"
    assert_contains "$(cat "$home/stderr")" "FM_SUPERVISION_PRIMARY_HARNESS='unknown' names no known harness" \
      "the refusal did not name the bad pin"
  done
  pass "a supervision branch refuses to resolve a harness from a pin that names none"
}


test_pi_signed_survives_agreeing_ancestry
test_supervision_branch_resolves_the_primary_pin
test_supervision_branch_refuses_an_unknown_primary_pin
