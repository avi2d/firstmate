#!/usr/bin/env bash
# Moving Queued items from a remote second mate's backlog into the parent's.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-backlog-reclaim)
PARENT="$TMP_ROOT/parent"
REMOTE="$TMP_ROOT/remote"
FAKE_ROOT="$TMP_ROOT/code"
mkdir -p "$PARENT/data" "$PARENT/state" "$REMOTE/data" "$REMOTE/state" "$FAKE_ROOT"
cp -R "$ROOT/bin" "$FAKE_ROOT/bin"
mkdir -p "$REMOTE/bin"
printf 'fixture\n' > "$REMOTE/AGENTS.md"
printf 'ios\n' > "$REMOTE/.fm-secondmate-home"
printf '%s\n' "- ios - iOS delivery (host: remote-mac; root: /remote/code; home: $REMOTE; scope: iOS work; projects: alpha; added 2026-08-02)" > "$PARENT/data/secondmates.md"
cat > "$FAKE_ROOT/bin/fm-on.sh" <<'SH'
#!/usr/bin/env bash
set -u
[ "$1" = ios ] || exit 91
command_name=$2
shift 2
printf '%s %s\n' "$command_name" "$*" >> "$FM_TEST_REMOTE_LOG"
case "${FM_TEST_FAULT:-}:$command_name:${1:-}" in
  unreachable:*) exit 255 ;;
  lose-stage:fm-backlog-receive.sh:reclaim-stage|lose-release:fm-backlog-receive.sh:reclaim-release)
    FM_HOME="$FM_TEST_REMOTE_HOME" bash "$(dirname "$0")/$command_name" "$@" >/dev/null
    exit 255
    ;;
esac
exec env FM_HOME="$FM_TEST_REMOTE_HOME" bash "$(dirname "$0")/$command_name" "$@"
SH
chmod +x "$FAKE_ROOT/bin/fm-on.sh"
export FM_TEST_REMOTE_LOG="$TMP_ROOT/remote.log" FM_TEST_REMOTE_HOME="$REMOTE"

seed_backlogs() {
  cat > "$REMOTE/data/backlog.md" <<'MD'
## In flight

- [ ] fly - Ship the flying thing (kind: ship)

## Queued

- [ ] q1 - First queued item (kind: ship)
- [ ] q2 - Second queued item blocked-by: q1 (kind: ship)
- [ ] q3 - Held queued item (kind: captain) (hold: captain call)

## Done

- [x] old - Finished item (kind: ship)
MD
  cat > "$PARENT/data/backlog.md" <<'MD'
## In flight

## Queued

- [ ] mine - Parent item (kind: ship)

## Done
MD
}

reclaim() {
  FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_HOME="$PARENT" bash "$FAKE_ROOT/bin/fm-backlog-reclaim.sh" "$@"
}

section_of() { # <file> <key>
  awk -v key="$2" '/^## /{s=$0} $0 ~ "^- \\[[ x]\\] " key " " {print s}' "$1"
}

seed_backlogs
before_remote=$(cat "$REMOTE/data/backlog.md")
before_parent=$(cat "$PARENT/data/backlog.md")
out=$(reclaim ios --dry-run --all 2>&1) || fail "dry run refused: $out"
printf '%s\n' "$out" | grep -F 'would move 3 Queued item(s), 1 held' >/dev/null || fail "dry run did not count the Queued set: $out"
[ "$(cat "$REMOTE/data/backlog.md")" = "$before_remote" ] || fail "dry run changed the second mate's backlog"
[ "$(cat "$PARENT/data/backlog.md")" = "$before_parent" ] || fail "dry run changed the parent's backlog"
[ ! -e "$REMOTE/state/handoff/reclaim.outbox.md" ] || fail "dry run staged a reclaim"
pass "dry run reports the Queued set and changes neither backlog"

out=$(reclaim ios fly 2>&1) && fail "an In-flight item was reclaimed: $out"
printf '%s\n' "$out" | grep -F 'fly (In flight)' >/dev/null || fail "In-flight refusal did not name the item: $out"
out=$(reclaim ios old 2>&1) && fail "a Done item was reclaimed: $out"
out=$(reclaim ios q2 2>&1) && fail "a blocked item was reclaimed without its blocker: $out"
[ "$(cat "$REMOTE/data/backlog.md")" = "$before_remote" ] || fail "a refused reclaim changed the second mate's backlog"
[ "$(cat "$PARENT/data/backlog.md")" = "$before_parent" ] || fail "a refused reclaim changed the parent's backlog"
pass "In-flight, Done and stranding selections are refused with both backlogs untouched"

out=$(reclaim ios --all 2>&1) || fail "reclaim of the Queued set failed: $out"
for key in q1 q2 q3; do
  [ "$(section_of "$PARENT/data/backlog.md" "$key")" = '## Queued' ] || fail "$key did not arrive Queued in the parent: $(cat "$PARENT/data/backlog.md")"
  [ -z "$(section_of "$REMOTE/data/backlog.md" "$key")" ] || fail "$key is still in the second mate's backlog"
done
assert_grep "q2 - Second queued item blocked-by: q1" "$PARENT/data/backlog.md" "the dependency did not survive the move"
assert_grep "q3 - Held queued item (kind: captain) (hold: captain call)" "$PARENT/data/backlog.md" "the hold did not survive the move"
[ "$(section_of "$REMOTE/data/backlog.md" fly)" = '## In flight' ] || fail "the In-flight item did not stay with the second mate"
[ ! -e "$REMOTE/state/handoff/reclaim.outbox.md" ] || fail "the staged copy outlived a confirmed reclaim"
pass "reclaim moves every Queued item with its notes and leaves In-flight work behind"

out=$(reclaim ios --all 2>&1) || fail "a repeated reclaim failed: $out"
printf '%s\n' "$out" | grep -F 'nothing to move' >/dev/null || fail "a repeated reclaim did not report an empty set: $out"
out=$(reclaim ios q1 2>&1) || fail "reclaiming an item already moved failed: $out"
[ "$(grep -c '^- \[ \] q1 ' "$PARENT/data/backlog.md")" -eq 1 ] || fail "a repeated reclaim duplicated q1"
pass "a repeated reclaim is a no-op"

seed_backlogs
out=$(FM_TEST_FAULT=unreachable reclaim ios --all 2>&1) && fail "an unreachable second mate was reported reclaimed: $out"
printf '%s\n' "$out" | grep -F 'completion is unknown' >/dev/null || fail "lost transport was not reported as unknown completion: $out"
[ "$(cat "$PARENT/data/backlog.md")" = "$before_parent" ] || fail "an unreachable reclaim changed the parent's backlog"
pass "an unreachable second mate leaves both backlogs as they were"

seed_backlogs
out=$(FM_TEST_FAULT=lose-stage reclaim ios q3 2>&1) && fail "a lost staging reply was reported reclaimed: $out"
[ -f "$REMOTE/state/handoff/reclaim.outbox.md" ] || fail "staging did not run before the reply was lost"
[ -z "$(section_of "$PARENT/data/backlog.md" q3)" ] || fail "the parent inserted an item it never confirmed"
out=$(reclaim ios q1 q2 2>&1) && fail "a different reclaim started over an unfinished one: $out"
printf '%s\n' "$out" | grep -F 'still staged' >/dev/null || fail "the unfinished reclaim was not named: $out"
out=$(reclaim ios q3 2>&1) || fail "rerunning the interrupted reclaim failed: $out"
[ "$(section_of "$PARENT/data/backlog.md" q3)" = '## Queued' ] || fail "the rerun did not finish the staged item"
[ ! -e "$REMOTE/state/handoff/reclaim.outbox.md" ] || fail "the rerun did not release the staged copy"
pass "a reclaim whose staging reply was lost finishes on rerun and blocks a different reclaim meanwhile"

seed_backlogs
out=$(FM_TEST_FAULT=lose-release reclaim ios q3 2>&1) && fail "a lost release was reported as a clean reclaim: $out"
printf '%s\n' "$out" | grep -F 'unconfirmed' >/dev/null || fail "lost release was not reported as unconfirmed: $out"
[ "$(section_of "$PARENT/data/backlog.md" q3)" = "## Queued" ] || fail "the item was not inserted before the release"
out=$(reclaim ios q3 2>&1) || fail "rerunning after a lost release failed: $out"
[ "$(grep -c '^- \[ \] q3 ' "$PARENT/data/backlog.md")" -eq 1 ] || fail "rerunning after a lost release duplicated q3"
pass "a reclaim whose release reply was lost reconciles on rerun without duplicating"

printf '%s\n' "- ios - iOS delivery (scope: iOS work; projects: alpha; added 2026-08-02)" > "$PARENT/data/secondmates.md"
out=$(reclaim ios --all 2>&1) && fail "a local second mate was routed as remote: $out"
printf '%s\n' "$out" | grep -F 'not a registered remote second mate' >/dev/null || fail "local second mate refusal was unclear: $out"
pass "a local second mate is refused"
