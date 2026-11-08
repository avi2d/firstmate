#!/usr/bin/env bash
# Bound and unbound answer channels, the keyed answer intake, and reconcile.
set -u

# shellcheck source=tests/fm-captain-hold-helpers.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/fm-captain-hold-helpers.sh"

# The one keyed-answer intake, fed through the real process-event runner by a
# fixture channel that knows nothing about captain holds: task-id keys close at
# answer time, a card-declared release mode frees held work, freeform prose can
# forge nothing, and a replayed capture is idempotent.
test_bound_channel_answers_close_at_answer_time() {
  local home id sid artifact result out show rc
  home=$(make_home channel-answer-closure)
  id=sample-eval-proposal
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Propose sample eval changes" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the review origin"
  write_origin_meta "$home" "$id"
  printf 'done: proposal deck ready for the captain\n' > "$home/state/$id.status"
  printf '# Sample eval proposal\n\nThree captain choices remain.\n\n## References\n\n- fixture source\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-membership-call --title "Captain call: membership" \
    --reason "captain membership choice pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-headline-call --title "Captain call: headline" \
    --reason "captain headline choice pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-forged-call --title "Captain call: forged" \
    --reason "captain forged choice pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-invalid-close-call --title "Captain call: invalid close" \
    --reason "captain close mode validation pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-source-reconcile --title "Captain call: reconcile" \
    --reason "captain re-check pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-bare-reconcile --title "Captain call: bare reconcile" \
    --reason "captain bare re-check pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-old-shape --title "Captain call: old board shape" \
    --reason "captain old board pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-old-reconcile --title "Captain call: old bare reconcile" \
    --reason "captain old bare reconcile pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-old-reconcile-note --title "Captain call: old annotated reconcile" \
    --reason "captain old annotated reconcile pending" --repo sample --origin "$id" >/dev/null
  tasks_in "$home" add sample-gated-work "Gated sample work" --kind ship --repo sample \
    --body 'Gated work plan.' >/dev/null
  run_captain "$home" hold sample-gated-work --reason "captain go needed" >/dev/null
  run_captain "$home" complete "$id" \
    sample-membership-call sample-headline-call sample-forged-call sample-invalid-close-call \
    sample-source-reconcile sample-bare-reconcile sample-old-shape sample-old-reconcile \
    sample-old-reconcile-note sample-gated-work >/dev/null \
    || fail "completion failed for the deck's inventoried calls"

  artifact="$home/data/$id/review.html"
  printf '<h1>Sample eval proposal</h1>\n' > "$artifact"
  fm_fake_exit0 "$home/fakebin" lavish-axi
  sid=$(run_lavish "$home" source-id "$artifact") || fail "could not derive the review source id"
  run_captain "$home" bind "$sid" >/dev/null \
    || fail "could not bind the review source to the keyed-answer intake"
  [ "$(run_captain "$home" binding "$sid")" = "(any)" ] \
    || fail "the recorded binding did not resolve to the collapsed marker"
  open_lavish_board "$home" "$artifact"
  run_lavish "$home" arm "$artifact" >/dev/null || fail "could not arm the review deck"

  result="$home/state/procevent-inbox/$sid.1.result"
  mkdir -p "$home/state/procevent-inbox"
  cat > "$result" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[13]{uid,prompt,selector,tag,text}:
  "1","Reconcile first\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"sample-source-reconcile\",\n  \"selection\": \"reconcile\",\n  \"note\": \"\"\n}","section#call > form:nth-of-type(6)",choice,"Reconcile"
  "2","Membership: gold-only - captain detail\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"sample-membership-call\",\n  \"selection\": \"gold-only\",\n  \"note\": \"captain detail\"\n}","section#call > form:nth-of-type(1)",choice,"Membership: gold-only - captain detail"
  "3","Headline: f1-when-fp-gold\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"sample-headline-call\",\n  \"selection\": \"f1-when-fp-gold\",\n  \"note\": \"\"\n}","section#call > form:nth-of-type(2)",choice,"Headline: f1-when-fp-gold"
  "4","Gated work: go\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"sample-gated-work\",\n  \"selection\": \"go\",\n  \"note\": \"\",\n  \"close\": \"release\"\n}","section#call > form:nth-of-type(3)",choice,"Gated work: go"
  "5","Absent call: yes\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"sample-nonexistent-call\",\n  \"selection\": \"yes\",\n  \"note\": \"\"\n}","section#call > form:nth-of-type(4)",choice,"Absent call: yes"
  "6","Invalid close: yes\n\nContext data:\n{\n  \"question\": \"sample-invalid-close-call\",\n  \"answer\": \"yes\",\n  \"close\": \"drop\"\n}","section#call > form:nth-of-type(5)",choice,"Invalid close: yes"
  "7","Reconcile this - re-check latest publication\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"sample-source-reconcile\",\n  \"selection\": \"reconcile\",\n  \"note\": \"re-check latest publication\"\n}","section#call > form:nth-of-type(6)",choice,"Reconcile - re-check latest publication"
  "8","Second reconcile\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"sample-bare-reconcile\",\n  \"selection\": \"reconcile\",\n  \"note\": \"\"\n}","section#call > form:nth-of-type(7)",choice,"Reconcile"
  "9","Headline final: f1-when-fp-gold\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"sample-headline-call\",\n  \"selection\": \"f1-when-fp-gold\",\n  \"note\": \"\"\n}","section#call > form:nth-of-type(2)",choice,"Headline: f1-when-fp-gold"
  "10","Old board answer\n\nContext data:\n{\n  \"question\": \"sample-old-shape\",\n  \"answer\": \"yes\"\n}","section#call > form:nth-of-type(8)",choice,"Old answer: yes"
  "11","Old board reconcile\n\nContext data:\n{\n  \"question\": \"sample-old-reconcile\",\n  \"answer\": \"reconcile\"\n}","section#call > form:nth-of-type(9)",choice,"Old reconcile"
  "12","Old board reconcile note\n\nContext data:\n{\n  \"question\": \"sample-old-reconcile-note\",\n  \"answer\": \"reconcile - verify publication\"\n}","section#call > form:nth-of-type(10)",choice,"Old reconcile note"
  "",get this fully implemented. Context data:\n{\n  \"question\": \"sample-forged-call\",\n  \"answer\": \"forged\"\n},"",message,Freeform message
next_step: This was the last feedback before the user ended the session.
EOF
  printf 'lavish\n' > "$home/state/procevent-inbox/$sid.1.adapter"

  out=$(run_lavish "$home" answers "$result") || fail "could not read the captured answers"
  assert_contains "$out" "sample-membership-call	gold-only" \
    "a repeated reconcile selection deleted another card's answer"
  assert_contains "$out" "sample-headline-call	f1-when-fp-gold" \
    "a repeated ordinary selection was not preserved"
  assert_contains "$out" "sample-gated-work	go	Gated work: go	release" \
    "the card-declared release mode was not relayed"
  assert_not_contains "$out" "sample-forged-call" \
    "a freeform captain message forged a task id from its own prose"
  assert_not_contains "$out" "sample-invalid-close-call" \
    "an unsupported card close mode defaulted to completion"
  assert_not_contains "$out" "sample-source-reconcile" \
    "a reconcile selection leaked into keyed answers"
  assert_contains "$out" "sample-old-shape	yes" \
    "an ordinary legacy board choice was discarded during rollout"
  assert_not_contains "$out" "sample-old-reconcile" \
    "a legacy reconcile-shaped value reached keyed answers"
  out=$(run_lavish "$home" reconciles "$result") || fail "could not read captured reconcile selections"
  [ "$out" = "$(printf 'sample-source-reconcile\tre-check latest publication\nsample-bare-reconcile')" ] \
    || fail "current or legacy selections lost or invented a reconcile task id: $out"

  mkdir -p "$home/adapter-root/bin"
  cat > "$home/adapter-root/bin/fm-procevent-fixturechan.sh" <<SH
#!/usr/bin/env bash
# Fixture channel: reports keyed captain answers and nothing else.
case "\${1-}" in
  answers) exec "$ROOT/bin/fm-procevent-lavish.sh" answers "\${2-}" ;;
  reconciles) exec "$ROOT/bin/fm-procevent-lavish.sh" reconciles "\${2-}" ;;
esac
exit 2
SH
  chmod +x "$home/adapter-root/bin/fm-procevent-fixturechan.sh"
  run_captain "$home" bind fixture-src >/dev/null \
    || fail "could not bind the fixture channel"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$home/adapter-root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" register fixturechan fixture-src -- cat "$result" >/dev/null \
    || fail "could not register the fixture channel source"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$home/adapter-root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" start fixture-src >/dev/null 2>&1
  assert_absent "$home/state/procevent-inbox/fixture-src.1.handled" \
    "feeding a captain answer retired the notification firstmate still needs"
  assert_present "$home/state/procevent-inbox/fixture-src.1.result" \
    "the fixture channel captured no result to feed"

  show=$(tasks_in "$home" show sample-membership-call --full)
  assert_contains "$show" "state: done" "capturing the captain's answer left the membership call open"
  assert_contains "$show" "Resolution mode: answered" "the membership call did not record its close path"
  assert_contains "$show" "Answer: gold-only" "the closed call did not record the captain's actual answer"
  assert_contains "$show" "captain detail" "the annotated normal answer lost the captain's note"
  show=$(tasks_in "$home" show sample-gated-work --full)
  assert_contains "$show" "state: queued" "the released work item did not stay queued"
  assert_contains "$show" "held: no" "the card-declared release did not lift the hold"
  assert_contains "$show" "Resolution mode: released" "the released work did not record its close path"
  assert_contains "$show" "Gated work plan." "the released work item lost its body"
  show=$(tasks_in "$home" show sample-forged-call --full)
  assert_contains "$show" "state: queued" "a forged key from freeform prose closed a captain call"
  show=$(tasks_in "$home" show sample-invalid-close-call --full)
  assert_contains "$show" "state: queued" "an unsupported card close mode closed a captain call"
  assert_contains "$show" "held: yes" "an unsupported card close mode released a captain call"
  out=$(run_captain "$home" reconcile list)
  assert_contains "$out" "sample-source-reconcile" \
    "the bound captured reconcile selection did not create a request"
  assert_contains "$out" "captain note: re-check latest publication" \
    "the annotated reconcile selection lost its note provenance"
  show=$(tasks_in "$home" show sample-old-shape --full)
  assert_contains "$show" "state: done" "an ordinary legacy board choice did not close its task"
  assert_contains "$show" "Resolution mode: answered" \
    "an ordinary legacy board choice did not use the keyed-answer intake"
  show=$(tasks_in "$home" show sample-old-reconcile --full)
  assert_contains "$show" "state: queued" "a bare legacy reconcile value closed its task"
  assert_contains "$show" "held: yes" "a bare legacy reconcile value released its task"
  show=$(tasks_in "$home" show sample-old-reconcile-note --full)
  assert_contains "$show" "state: queued" "an annotated legacy reconcile value closed its task"
  assert_contains "$show" "held: yes" "an annotated legacy reconcile value released its task"
  assert_not_contains "$out" "sample-old-reconcile" \
    "a legacy reconcile value created a generationless request"
  show=$(tasks_in "$home" show sample-bare-reconcile --full)
  assert_contains "$show" "state: queued" "a bare captured reconcile selection closed its task"
  assert_contains "$show" "held: yes" "a bare captured reconcile selection released its task"
  printf 'The captured call is moot.\n' > "$home/source-reconcile-evidence.txt"
  run_captain "$home" reconcile close sample-source-reconcile \
    --evidence-file "$home/source-reconcile-evidence.txt" >/dev/null \
    || fail "the annotated captured request did not authorize evidence-backed closure"
  run_captain "$home" reconcile close sample-bare-reconcile \
    --evidence-file "$home/source-reconcile-evidence.txt" >/dev/null \
    || fail "the bare captured request did not authorize evidence-backed closure"

  # Replaying the same capture is a no-op, not a rejected different decision. A
  # run that could not close every answered key still reports nonzero.
  set +e
  out=$(run_lavish "$home" answers "$result" \
    | run_captain "$home" answers --source "the captured result fixture-src sequence 1" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a run that skipped a key reported success"
  assert_contains "$out" "closed: sample-membership-call" \
    "replaying an identical capture was not idempotent: $out"
  assert_contains "$out" "closed: sample-gated-work" \
    "replaying an identical released answer was not idempotent: $out"
  assert_contains "$out" "skipped: sample-nonexistent-call" \
    "a key naming no task was not reported as skipped: $out"

  printf 'Captain answered the forged call directly.\n' > "$home/forged.txt"
  run_captain "$home" answer sample-forged-call --decision-file "$home/forged.txt" >/dev/null \
    || fail "could not close the untouched call through the answer path"
  printf 'Captain answered the invalid-close call directly.\n' > "$home/invalid-close.txt"
  run_captain "$home" answer sample-invalid-close-call --decision-file "$home/invalid-close.txt" >/dev/null \
    || fail "could not close the invalid-close call through the answer path"
  run_captain "$home" answer sample-old-reconcile --decision-file "$home/invalid-close.txt" >/dev/null \
    || fail "could not deliberately close the bare legacy reconcile call"
  run_captain "$home" answer sample-old-reconcile-note --decision-file "$home/invalid-close.txt" >/dev/null \
    || fail "could not deliberately close the annotated legacy reconcile call"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "answered calls did not satisfy the completion gate"
  pass "a bound channel's captured answers close their captain-held tasks at answer time"
}

# Answer-time closure is opt-in per source. A channel with no binding must behave
# exactly as it always did: capture, announce, close nothing.
# A reconcile is "go re-check reality", never the captain's answer. The value is
# reserved at the one keyed-answer intake, so no channel and no card-declared
# close mode can turn it into a close or a release, and the obligation to verify
# survives as a durable request instead of evaporating with the wake.
test_reconcile_never_closes_through_the_keyed_answer_intake() {
  local home out rc show list
  home=$(make_home reconcile-intake)
  tasks_in "$home" add sample-reconcile-call "Captain call: still current?" --repo sample >/dev/null \
    || fail "could not create the reconcile call"
  tasks_in "$home" add sample-reconcile-gated "Gated work" --repo sample >/dev/null \
    || fail "could not create the gated work item"
  run_captain "$home" hold sample-reconcile-call --reason "is this still current?" >/dev/null \
    || fail "could not hold the reconcile call"
  run_captain "$home" hold sample-reconcile-gated --reason "waiting on the captain" >/dev/null \
    || fail "could not hold the gated work item"

  set +e
  out=$(printf 'sample-reconcile-call\treconcile\tReconcile\n%s\n' \
    "$(printf 'sample-reconcile-gated\treconcile\tReconcile\trelease')" \
    | run_captain "$home" answers --source "captain chat" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "the shared answer intake accepted reconcile as an answer"
  assert_contains "$out" "refused: sample-reconcile-call" \
    "the shared intake did not visibly refuse reconcile: $out"
  case "$out" in
    *"closed: sample-reconcile"*) fail "a reconcile row closed a captain call: $out" ;;
  esac

  show=$(tasks_in "$home" show sample-reconcile-call --full)
  assert_contains "$show" "state: queued" "a reconcile row completed a captain call"
  assert_contains "$show" "held: yes" "a reconcile row released a captain call"
  case "$show" in
    *"Resolution recorded by"*) fail "a reconcile row wrote a resolution record" ;;
  esac
  show=$(tasks_in "$home" show sample-reconcile-gated --full)
  assert_contains "$show" "held: yes" "a release-mode reconcile row lifted a captain hold"

  list=$(run_captain "$home" reconcile list) || fail "could not list the reconcile requests"
  assert_contains "$list" "reconcile-requests: 0" \
    "the shared answer intake created a reconcile request: $list"
  set +e
  out=$(printf 'sample-reconcile-call\n' \
    | run_captain "$home" reconcile-requests --source-id unbound-src --source "captured board" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unbound captured source created a reconcile request"
  request_reconciles "$home" board-src sample-reconcile-call sample-reconcile-gated \
    || fail "the bound captured source did not create reconcile requests"
  list=$(run_captain "$home" reconcile list)
  assert_contains "$list" "sample-reconcile-call" "the reconcile obligation was not recorded durably: $list"
  assert_contains "$list" "reconcile-requests: 2" "the reconcile requests were not both recorded: $list"

  request_reconciles "$home" board-src sample-reconcile-call \
    || fail "replaying a captured reconcile selection failed"
  list=$(run_captain "$home" reconcile list)
  assert_contains "$list" "reconcile-requests: 2" "a replayed reconcile selection duplicated the obligation: $list"
  pass "only a bound captured source creates reconcile requests"
}

test_normal_answers_retire_pending_reconcile_requests() {
  local home list id
  home=$(make_home reconcile-normal-answer)
  for id in sample-direct-close sample-direct-release sample-keyed-close; do
    tasks_in "$home" add "$id" "Captain call $id" --repo sample >/dev/null
    run_captain "$home" hold "$id" --reason "waiting for the captain" >/dev/null
  done
  request_reconciles "$home" board-src sample-direct-close sample-direct-release sample-keyed-close \
    || fail "could not create reconcile requests before normal answers"

  printf 'Captain said close.\n' > "$home/close.txt"
  printf 'Captain said release.\n' > "$home/release.txt"
  run_captain "$home" answer sample-direct-close --decision-file "$home/close.txt" >/dev/null \
    || fail "a direct close answer failed"
  run_captain "$home" answer sample-direct-release --decision-file "$home/release.txt" --release >/dev/null \
    || fail "a direct release answer failed"
  printf 'sample-keyed-close\tyes\tYes\n' \
    | run_captain "$home" answers --source "board sequence 2" >/dev/null \
    || fail "a keyed normal answer failed"
  list=$(run_captain "$home" reconcile list)
  assert_contains "$list" "reconcile-requests: 0" \
    "normal answers left stranded reconcile requests: $list"

  run_captain "$home" answer sample-direct-close --decision-file "$home/close.txt" >/dev/null \
    || fail "a direct close replay failed"
  run_captain "$home" answer sample-direct-release --decision-file "$home/release.txt" --release >/dev/null \
    || fail "a direct release replay failed"
  printf 'sample-keyed-close\tyes\tYes\n' \
    | run_captain "$home" answers --source "board sequence 2" >/dev/null \
    || fail "a keyed answer replay failed"
  list=$(run_captain "$home" reconcile list)
  assert_contains "$list" "reconcile-requests: 0" \
    "an idempotent normal-answer replay restored a reconcile request: $list"
  pass "normal answers and their replays retire reconcile requests"
}

# The two verification outcomes, and the honesty of the record each writes.
test_reconcile_closes_with_evidence_or_keeps_the_call_open() {
  local home show list rc out
  home=$(make_home reconcile-outcomes)
  tasks_in "$home" add sample-moot-call "Captain call: ship 0.1.37?" --repo sample >/dev/null
  tasks_in "$home" add sample-active-call "Captain call: which admission order?" --repo sample >/dev/null
  tasks_in "$home" add sample-mode-call "Captain call: verify replay mode?" --repo sample >/dev/null
  run_captain "$home" hold sample-moot-call --reason "ship 0.1.37?" >/dev/null
  run_captain "$home" hold sample-active-call --reason "which admission order?" >/dev/null
  run_captain "$home" hold sample-mode-call --reason "verify replay mode?" >/dev/null
  printf '0.1.38 was published on 2026-09-05, so the 0.1.37 question is moot.\n' > "$home/evidence.txt"
  printf 'Still open: nothing has shipped and the choice is unchanged.\n' > "$home/note.txt"

  set +e
  out=$(run_captain "$home" reconcile close sample-moot-call --evidence-file "$home/evidence.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "reconcile closed a call without a pending board request"
  assert_contains "$out" "no pending board-created reconcile request" \
    "the ungated close refusal did not name the missing board request: $out"
  set +e
  out=$(run_captain "$home" reconcile note sample-active-call --note-file "$home/note.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "reconcile annotated a call without a pending board request"
  assert_contains "$out" "no pending board-created reconcile request" \
    "the ungated note refusal did not name the missing board request: $out"

  request_reconciles "$home" board-src sample-moot-call sample-active-call sample-mode-call \
    || fail "could not file the reconcile requests"

  set +e
  out=$(run_captain "$home" reconcile close sample-moot-call 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a reconcile close was accepted with no evidence"
  assert_contains "$out" "evidence" "the refusal did not name the missing evidence: $out"

  cp "$home/state/reconcile-requests/sample-mode-call.request" "$home/mode-request.backup"
  run_captain "$home" answer sample-mode-call --decision-file "$home/evidence.txt" >/dev/null \
    || fail "could not record the normal answer for the mode fixture"
  cp "$home/mode-request.backup" "$home/state/reconcile-requests/sample-mode-call.request"
  set +e
  out=$(run_captain "$home" reconcile close sample-mode-call --evidence-file "$home/evidence.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a normal captain answer replayed as a reconciliation"
  assert_contains "$out" "was not closed by reconciliation" \
    "the reconcile replay refusal did not identify the incompatible resolution mode: $out"
  run_captain "$home" answer sample-mode-call --decision-file "$home/evidence.txt" >/dev/null \
    || fail "the normal answer replay did not retire its restored pending request"

  run_captain "$home" reconcile close sample-moot-call --evidence-file "$home/evidence.txt" >/dev/null \
    || fail "could not close the moot call with evidence"
  show=$(tasks_in "$home" show sample-moot-call --full)
  assert_contains "$show" "state: done" "the moot call did not close"
  assert_contains "$show" "Resolution mode: reconciled" "the moot call did not record how it closed"
  assert_contains "$show" "Reconciliation evidence:" "the moot call did not record the evidence"
  assert_contains "$show" "0.1.38 was published" "the recorded evidence was lost"
  case "$show" in
    *"Captain decision:"*) fail "a reconciled close was recorded as the captain's own words" ;;
  esac
  set +e
  out=$(run_captain "$home" answer sample-moot-call --decision-file "$home/evidence.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a reconciled resolution replayed as a captain answer"
  assert_contains "$out" "not a captain-answer replay" \
    "the answer replay refusal did not identify the incompatible resolution mode: $out"

  run_captain "$home" reconcile note sample-active-call --note-file "$home/note.txt" >/dev/null \
    || fail "could not annotate the still-active call"
  show=$(tasks_in "$home" show sample-active-call --full)
  assert_contains "$show" "state: queued" "annotating a still-active call closed it"
  assert_contains "$show" "held: yes" "annotating a still-active call released it"
  assert_contains "$show" "Captain hold reconciled:" "the re-check left no dated note"
  assert_contains "$show" "Still open: nothing has shipped" "the note body was lost"
  case "$show" in
    *"Resolution recorded by"*) fail "annotating a still-active call wrote a resolution record" ;;
  esac
  set +e
  out=$(run_captain "$home" reconcile note sample-active-call --note-file "$home/note.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a retired reconcile request appended a duplicate note"
  assert_contains "$out" "no pending board-created reconcile request" \
    "the duplicate-note refusal did not name the retired request: $out"

  printf 'sample-active-call\n' \
    | FM_CAPTAIN_HOLD_NOW=2026-09-07T06:00:00Z run_captain "$home" reconcile-requests \
        --source-id board-src --source "captured board result sequence 2" >/dev/null \
    || fail "could not create the second reconcile request"
  FM_CAPTAIN_HOLD_NOW=2026-09-07T06:01:00Z run_captain "$home" reconcile note sample-active-call \
    --note-file "$home/note.txt" >/dev/null \
    || fail "the second request with the same finding was not recorded"
  show=$(tasks_in "$home" show sample-active-call --full)
  [ "$(printf '%s\n' "$show" | grep -o 'Captain hold reconciled:' | wc -l | tr -d ' ')" -eq 2 ] \
    || fail "a later reconcile request with the same note did not append its own record"
  assert_contains "$show" "Captain hold reconciled: 2026-09-07T06:01:00Z" \
    "the second reconcile request lost its own dated note"

  list=$(run_captain "$home" reconcile list)
  assert_contains "$list" "reconcile-requests: 0" "the verified requests were not retired: $list"
  pass "reconcile closes a moot call with evidence and keeps an active one open with a note"
}

test_reconcile_outcomes_retry_partial_failures_once() {
  local home out show list rc
  home=$(make_home reconcile-partial-retry)
  tasks_in "$home" add sample-reconcile-close-retry "Close retry" --repo sample >/dev/null
  tasks_in "$home" add sample-reconcile-note-retry "Note retry" --repo sample >/dev/null
  tasks_in "$home" add sample-reconcile-retire-retry "Retire retry" --repo sample >/dev/null
  tasks_in "$home" add sample-reconcile-close-retire "Close retire" --repo sample >/dev/null
  tasks_in "$home" add sample-answer-retire "Answer retire" --repo sample >/dev/null
  run_captain "$home" hold sample-reconcile-close-retry --reason "verify close" >/dev/null
  run_captain "$home" hold sample-reconcile-note-retry --reason "verify note" >/dev/null
  run_captain "$home" hold sample-reconcile-retire-retry --reason "verify retire" >/dev/null
  run_captain "$home" hold sample-reconcile-close-retire --reason "verify close retirement" >/dev/null
  run_captain "$home" hold sample-answer-retire --reason "verify answer retirement" >/dev/null
  request_reconciles "$home" board-src sample-reconcile-close-retry sample-reconcile-note-retry \
    sample-reconcile-retire-retry sample-reconcile-close-retire sample-answer-retire \
    || fail "could not create partial-retry requests"
  printf 'Verified moot.\n' > "$home/retry-evidence.txt"
  printf 'Verified active.\n' > "$home/retry-note.txt"
  printf 'Verified retirement retry.\n' > "$home/retry-retire-note.txt"
  printf 'Verified close retirement.\n' > "$home/close-retire-evidence.txt"
  printf 'Captain answered despite retirement failure.\n' > "$home/answer-retire.txt"
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = done ] && [ "${2:-}" = sample-reconcile-close-retry ] \
  && [ ! -e "$FM_HOME/reconcile-close-failed" ]; then
  : > "$FM_HOME/reconcile-close-failed"
  exit 92
fi
if [ "${1:-}" = update ] && [ "${2:-}" = sample-reconcile-note-retry ]; then
  "$REAL_TASKS_AXI" "$@" || exit $?
  : > "$FM_HOME/reconcile-note-updated"
  exit 0
fi
if [ "${1:-}" = show ] && [ "${2:-}" = sample-reconcile-note-retry ] \
  && [ -e "$FM_HOME/reconcile-note-updated" ] && [ ! -e "$FM_HOME/reconcile-note-show-failed" ]; then
  : > "$FM_HOME/reconcile-note-show-failed"
  exit 93
fi
exec "$REAL_TASKS_AXI" "$@"
SH
  chmod +x "$home/fakebin/tasks-axi"

  set +e
  out=$(run_captain "$home" reconcile close sample-reconcile-close-retry \
    --evidence-file "$home/retry-evidence.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "the forced reconcile close failure reported success"
  run_captain "$home" reconcile close sample-reconcile-close-retry \
    --evidence-file "$home/retry-evidence.txt" >/dev/null \
    || fail "reconcile close did not recover from its partial failure"
  show=$(tasks_in "$home" show sample-reconcile-close-retry --full)
  [ "$(printf '%s\n' "$show" | grep -c 'Resolution mode: reconciled')" -eq 1 ] \
    || fail "reconcile close duplicated its resolution record on retry"

  set +e
  out=$(run_captain "$home" reconcile note sample-reconcile-note-retry \
    --note-file "$home/retry-note.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "the forced post-note probe failure reported success"
  set +e
  out=$(run_captain "$home" reconcile note sample-reconcile-note-retry \
    --note-file "$home/retry-note.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a note retry succeeded after the request was retired"
  show=$(tasks_in "$home" show sample-reconcile-note-retry --full)
  [ "$(printf '%s\n' "$show" | grep -c 'Captain hold reconciled:')" -eq 1 ] \
    || fail "reconcile note duplicated its durable annotation"

  chmod 0500 "$home/state/reconcile-requests"
  set +e
  out=$(run_captain "$home" reconcile close sample-reconcile-close-retire \
    --evidence-file "$home/close-retire-evidence.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a failed close request retirement reported success"
  assert_contains "$out" "sample-reconcile-close-retire" \
    "the close retirement failure did not name its task: $out"
  list=$(run_captain "$home" reconcile list)
  assert_contains "$list" "sample-reconcile-close-retire" \
    "the failed close retirement hid its pending request"
  chmod 0700 "$home/state/reconcile-requests"
  run_captain "$home" reconcile close sample-reconcile-close-retire \
    --evidence-file "$home/close-retire-evidence.txt" >/dev/null \
    || fail "the closed reconciliation could not finish request retirement"

  chmod 0500 "$home/state/reconcile-requests"
  set +e
  out=$(run_captain "$home" answer sample-answer-retire \
    --decision-file "$home/answer-retire.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a failed answer-boundary retirement reported success"
  show=$(tasks_in "$home" show sample-answer-retire --full)
  assert_contains "$show" "state: done" "retirement failure reversed the durable captain answer"
  assert_contains "$show" "Captain answered despite retirement failure" \
    "retirement failure lost the durable captain answer"
  chmod 0700 "$home/state/reconcile-requests"
  run_captain "$home" answer sample-answer-retire --decision-file "$home/answer-retire.txt" >/dev/null \
    || fail "the answer replay could not finish request retirement"

  chmod 0500 "$home/state/reconcile-requests"
  set +e
  out=$(run_captain "$home" reconcile note sample-reconcile-retire-retry \
    --note-file "$home/retry-retire-note.txt" 2>&1)
  rc=$?
  set -e
  chmod 0700 "$home/state/reconcile-requests"
  [ "$rc" -ne 0 ] || fail "a failed request retirement reported note success"
  assert_not_contains "$out" "still-open:" "failed retirement reported a successful outcome"
  run_captain "$home" reconcile note sample-reconcile-retire-retry \
    --note-file "$home/retry-retire-note.txt" >/dev/null \
    || fail "the applied note could not finish request retirement on retry"
  show=$(tasks_in "$home" show sample-reconcile-retire-retry --full)
  [ "$(printf '%s\n' "$show" | grep -c 'Captain hold reconciled:')" -eq 1 ] \
    || fail "failed request retirement duplicated the reconcile note"
  list=$(run_captain "$home" reconcile list)
  assert_contains "$list" "reconcile-requests: 0" "partial retries left a reconcile request pending"
  pass "reconcile outcomes apply durable mutations once across partial failures"
}

test_unbound_source_closes_no_hold() {
  local home id sid artifact result out show rc
  home=$(make_home lavish-unbound)
  id=sample-unbound-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review sample without binding" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the unbound origin"
  write_origin_meta "$home" "$id"
  printf 'done: deck ready\n' > "$home/state/$id.status"
  printf '# Unbound review\n\nOne captain choice remains.\n\n## References\n\n- fixture source\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-only-call --title "Captain call: only choice" \
    --reason "captain only choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not register the unbound call"

  artifact="$home/data/$id/review.html"
  printf '<h1>Unbound</h1>\n' > "$artifact"
  fm_fake_exit0 "$home/fakebin" lavish-axi
  sid=$(run_lavish "$home" source-id "$artifact") || fail "could not derive the unbound source id"
  open_lavish_board "$home" "$artifact"
  run_lavish "$home" arm "$artifact" >/dev/null || fail "could not arm the unbound review"

  result="$home/state/procevent-inbox/$sid.1.result"
  mkdir -p "$home/state/procevent-inbox"
  cat > "$result" <<'EOF'
session:
  file: /review.html
  status: feedback
prompts[1]{uid,prompt,selector,tag,text}:
  "2","Only choice: yes\n\nContext data:\n{\n  \"question\": \"sample-only-call\",\n  \"answer\": \"yes\"\n}","form",choice,"Only choice: yes"
EOF
  set +e
  out=$(run_captain "$home" binding "$sid" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unbound source reported a binding"
  [ -z "$out" ] || fail "an unbound source printed a binding: $out"
  show=$(tasks_in "$home" show sample-only-call --full)
  assert_contains "$show" "state: queued" "an unbound review closed a captain call"
  assert_contains "$show" "held: yes" "an unbound review released a captain call"
  pass "a channel source with no decision binding closes nothing"
}

test_bound_channel_answers_close_at_answer_time
test_reconcile_never_closes_through_the_keyed_answer_intake
test_normal_answers_retire_pending_reconcile_requests
test_reconcile_closes_with_evidence_or_keeps_the_call_open
test_reconcile_outcomes_retry_partial_failures_once
test_unbound_source_closes_no_hold
