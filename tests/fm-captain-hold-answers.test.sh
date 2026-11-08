#!/usr/bin/env bash
# Board, round, and chat answer channels, intake bounds, and status signalling.
set -u

# shellcheck source=tests/fm-captain-hold-helpers.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/fm-captain-hold-helpers.sh"

# A board answer must reach the keyed-answer intake through the RUNNER, not just
# through a hand-fed `answers` call. The captain answered ten calls on a bearings
# board, the board accepted them, and nothing collected them: the source that
# collects a board is a supervised process, and while it was not running the
# board went on presenting as armed. Everything between the captured result and
# the closed task is asserted here end to end - capture, the wake that tells
# firstmate to look, and the recorded answer - because each of those was intact
# on its own while the chain as a whole delivered nothing.
test_board_answer_reaches_the_keyed_answer_intake() {
  local home sid stub out queue show
  home=$(make_home board-channel)
  sid=lavish-b0a4d0000000f1e2
  fm_test_track_procevent_home "$home" "$home/procevent-claims"

  run_captain "$home" hold sample-board-call --title "Choose the sample board route" \
    --reason "captain board route choice pending" --repo sample >/dev/null \
    || fail "could not register the board call"

  # One published Lavish poll response carrying the captain's structured answer,
  # in the shape the adapter's own reader parses: a declared field order, an
  # indented CSV row, and the versioned answer context inside its prompt.
  stub="$home/board-source.sh"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
cat <<'OUT'
session:
  status: feedback
  session_ended: false
prompts[1]{tag,text,prompt}:
  "choice","Take the north route","Context data: {\"schema\":\"fm-bearings-answer.v1\",\"question\":\"sample-board-call\",\"selection\":\"north\",\"note\":\"\"}"
OUT
SH
  chmod +x "$stub"

  run_procevent "$home" register lavish "$sid" -- "$stub" >/dev/null \
    || fail "could not register the board source"
  run_captain "$home" bind "$sid" >/dev/null \
    || fail "could not bind the board source to the keyed-answer intake"

  out=$(run_procevent "$home" start "$sid" 2>&1) \
    || fail "the board source runner did not complete: $out"
  assert_contains "$out" "$sid.1.result" "the board answer was never durably captured: $out"
  assert_contains "$out" "answers-fed: $sid" \
    "the captured board answer never reached the keyed-answer intake: $out"

  queue=$(cat "$home/state/.wake-queue" 2>/dev/null || true)
  assert_contains "$queue" "check: procevent lavish $sid 1" \
    "the captured board answer produced no wake: $queue"

  show=$(tasks_in "$home" show sample-board-call --full)
  assert_contains "$show" "state: done" "the board answer did not close the captain call"
  assert_contains "$show" "north" "the board answer lost the captain's selection"
  assert_contains "$show" "the captured result $sid sequence 1" \
    "the recorded answer did not name the board result that carried it"
  pass "a board answer reaches the keyed-answer intake and wakes firstmate"
}

# The captain's words are recorded as the UTF-8 the board sent, whatever script
# they are written in: a note with a character at or below U+00FF, a note with
# one above it, and a label carrying a typographic dash.
test_board_answer_keeps_the_captains_non_ascii_words() {
  local home sid stub out err expected stored
  home=$(make_home board-channel-utf8)
  sid=lavish-b0a4d0000000f1e3
  fm_test_track_procevent_home "$home" "$home/procevent-claims"
  stored="$home/data/backlog.md"

  run_captain "$home" hold sample-accent-call --title "Choose the sample drink" \
    --reason "captain drink choice pending" --repo sample >/dev/null \
    || fail "could not register the accented call"
  run_captain "$home" hold sample-cyrillic-call --title "Choose the sample crossing" \
    --reason "captain crossing choice pending" --repo sample >/dev/null \
    || fail "could not register the cyrillic call"

  stub="$home/board-source.sh"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
cat <<'OUT'
session:
  status: feedback
  session_ended: false
prompts[2]{tag,text,prompt}:
  "choice","Drink — café","Context data: {\"schema\":\"fm-bearings-answer.v1\",\"question\":\"sample-accent-call\",\"selection\":\"\",\"note\":\"café au lait\"}"
  "choice","Переправа: north - через мост","Context data: {\"schema\":\"fm-bearings-answer.v1\",\"question\":\"sample-cyrillic-call\",\"selection\":\"north\",\"note\":\"через мост\"}"
OUT
SH
  chmod +x "$stub"

  "$stub" > "$home/board.result"
  err="$home/answers.err"
  out=$(run_lavish "$home" answers "$home/board.result" 2>"$err") \
    || fail "the adapter could not read the non-ASCII answers"
  expected=$(printf 'sample-accent-call\tcafé au lait\tDrink — café\nsample-cyrillic-call\tnorth\tПереправа: north - через мост')
  [ "$out" = "$expected" ] \
    || fail "the adapter changed the bytes of the captain's words: $(printf '%s' "$out" | od -c | head -8)"
  assert_no_grep "Wide character" "$err" "the adapter warned about a wide character instead of writing UTF-8"

  run_procevent "$home" register lavish "$sid" -- "$stub" >/dev/null \
    || fail "could not register the board source"
  run_captain "$home" bind "$sid" >/dev/null \
    || fail "could not bind the board source to the keyed-answer intake"
  out=$(run_procevent "$home" start "$sid" 2>&1) \
    || fail "the board source runner did not complete: $out"
  assert_contains "$out" "answers-fed: $sid" "the captured answers never reached the intake: $out"

  # data/backlog.md is the markdown backend's own persisted artifact, read here
  # for its bytes because the shown field re-encodes them.
  LC_ALL=C grep -qF "Answer: café au lait" "$stored" \
    || fail "the recorded note lost the UTF-8 bytes of a character at or below U+00FF"
  LC_ALL=C grep -qF "Answer as shown to the captain: Drink — café" "$stored" \
    || fail "the recorded label lost the UTF-8 bytes of its typographic dash"
  LC_ALL=C grep -qF "Answer as shown to the captain: Переправа: north - через мост" "$stored" \
    || fail "the recorded label lost the UTF-8 bytes of its cyrillic words"
  ! LC_ALL=C grep -q "$(printf '[^\xc3]\xe9')" "$stored" \
    || fail "the recorded answer holds a lone latin-1 byte, so it is no longer valid UTF-8"
  pass "a board answer keeps the captain's non-ASCII words byte for byte"
}

# A grilling round is one captain-held task answered by one board submission
# that carries every question of the round. The row below is the real capture a
# throwaway round page produced through lavish-axi 0.1.77 and a browser: the
# held task must record every question id with its selection and note, and the
# round note, rather than closing on the round note alone. A round the intake
# cannot record whole records nothing and leaves the round held.
test_round_answer_records_every_question_whole() {
  local home sid result out show round_answer long_ctx long_answer oversize_ctx stored id i note
  home=$(make_home round-channel)
  sid=lavish-b0a4d0000000f1e4
  fm_test_track_procevent_home "$home" "$home/procevent-claims"
  stored="$home/data/backlog.md"

  for id in sample-interview-r1 sample-long-round sample-duplicate-round sample-unslugged-round \
    sample-selected-round sample-empty-round sample-blank-round sample-partial-entry-round \
    sample-oversize-round; do
    run_captain "$home" hold "$id" --title "Grilling round $id" \
      --reason "round questions pending" --repo sample >/dev/null \
      || fail "could not register $id"
  done

  long_ctx='{"schema":"fm-bearings-answer.v1","question":"sample-long-round","selection":"","note":"","answers":['
  long_answer=''
  note="keep this choice because the neighbors asked for it twice, the hall confirmed the space, and the budget holds for the first season without new volunteers or paid staff of any kind"
  for i in 01 02 03 04 05 06 07 08 09 10 11 12; do
    [ "$i" = 01 ] || { long_ctx="$long_ctx,"; long_answer="$long_answer; "; }
    long_ctx="$long_ctx{\"question\":\"q$i\",\"selection\":\"option-$i\",\"note\":\"$note $i\"}"
    long_answer="${long_answer}q$i: option-$i (note: \"$note $i\")"
  done
  long_ctx="$long_ctx]}"
  [ "$(printf '%s' "$long_answer" | LC_ALL=C wc -c | tr -d ' ')" -gt 2048 ] \
    || fail "precondition: the long round must be longer than four 512-character fields"

  oversize_ctx='{"schema":"fm-bearings-answer.v1","question":"sample-oversize-round","selection":"","note":"","answers":['
  note=$(printf 'перенести на субботу %.0s' $(seq 1 20))
  for i in 01 02 03 04 05 06 07 08; do
    [ "$i" = 01 ] || oversize_ctx="$oversize_ctx,"
    oversize_ctx="$oversize_ctx{\"question\":\"q$i\",\"selection\":\"\",\"note\":\"${note% }\"}"
  done
  oversize_ctx="$oversize_ctx]}"
  [ "$(printf '%s' "$oversize_ctx" | perl -MEncode=decode -e 'local $/; print length(decode("UTF-8", <STDIN>))')" -lt 3840 ] \
    && [ "$(printf '%s' "$oversize_ctx" | LC_ALL=C wc -c | tr -d ' ')" -gt 3840 ] \
    || fail "precondition: the oversize round must fit the 3840-byte bound in characters but not in bytes"

  result="$home/round.result"
  {
    printf 'session:\n  file: /round.html\n  status: feedback\nprompts[10]{uid,prompt,selector,tag,text}:\n'
    cat <<'ROW'
  "1","Round 1 answers - audience: neighbors - start with Elm, Oak and Birch streets; format: low-cost-sale - sale — €1 per book; \"free\" invites dumping; day: no selection; storage: no selection - ask the hall manager first\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"sample-interview-r1\",\n  \"selection\": \"\",\n  \"note\": \"Looks right overall; revisit the day once the hall confirms.\",\n  \"answers\": [\n    {\n      \"question\": \"audience\",\n      \"selection\": \"neighbors\",\n      \"note\": \"start with Elm, Oak and Birch streets\"\n    },\n    {\n      \"question\": \"format\",\n      \"selection\": \"low-cost-sale\",\n      \"note\": \"sale — €1 per book; \\\"free\\\" invites dumping\"\n    },\n    {\n      \"question\": \"day\",\n      \"selection\": \"\",\n      \"note\": \"\"\n    },\n    {\n      \"question\": \"storage\",\n      \"selection\": \"\",\n      \"note\": \"ask the hall manager first\"\n    }\n  ]\n}",form#round,choice,Round 1 answers for 4 questions
ROW
    lavish_choice_row 2 "Round 2 answers for 12 questions" "$long_ctx"
    lavish_choice_row 3 "Duplicate question" \
      '{"schema":"fm-bearings-answer.v1","question":"sample-duplicate-round","selection":"","note":"","answers":[{"question":"day","selection":"saturday","note":""},{"question":"day","selection":"sunday","note":""}]}'
    lavish_choice_row 4 "Question id with a space" \
      '{"schema":"fm-bearings-answer.v1","question":"sample-unslugged-round","selection":"","note":"","answers":[{"question":"the day","selection":"saturday","note":""}]}'
    lavish_choice_row 5 "Round with a top-level selection" \
      '{"schema":"fm-bearings-answer.v1","question":"sample-selected-round","selection":"yes","note":"","answers":[{"question":"day","selection":"saturday","note":""}]}'
    lavish_choice_row 6 "Round with no questions" \
      '{"schema":"fm-bearings-answer.v1","question":"sample-empty-round","selection":"","note":"a note alone","answers":[]}'
    lavish_choice_row 7 "Round the captain left blank" \
      '{"schema":"fm-bearings-answer.v1","question":"sample-blank-round","selection":"","note":"","answers":[{"question":"day","selection":"","note":""}]}'
    lavish_choice_row 8 "Round entry without a note field" \
      '{"schema":"fm-bearings-answer.v1","question":"sample-partial-entry-round","selection":"","note":"","answers":[{"question":"day","selection":"saturday"}]}'
    lavish_choice_row 9 "Round larger than the intake records" "$oversize_ctx"
    lavish_choice_row 10 "Membership: gold-only - captain detail" \
      '{"schema":"fm-bearings-answer.v1","question":"sample-single-call","selection":"gold-only","note":"captain detail"}'
  } > "$result"
  run_captain "$home" hold sample-single-call --title "Choose the sample membership" \
    --reason "captain membership choice pending" --repo sample >/dev/null \
    || fail "could not register the single-question call"

  out=$(run_lavish "$home" answers "$result") || fail "the adapter could not read the round answers"
  round_answer='audience: neighbors (note: "start with Elm, Oak and Birch streets"); format: low-cost-sale (note: "sale — €1 per book; \"free\" invites dumping"); day: (no selection); storage: (no selection) (note: "ask the hall manager first"); round note: "Looks right overall; revisit the day once the hall confirms."'
  assert_contains "$out" "sample-interview-r1	$round_answer	Round 1 answers for 4 questions" \
    "the real round capture did not yield every question with its selection and note"
  assert_contains "$out" "sample-long-round	$long_answer	Round 2 answers for 12 questions" \
    "a round longer than one 512-character field was not reported whole"
  assert_contains "$out" "sample-single-call	gold-only	Membership: gold-only - captain detail" \
    "a single-question answer beside rounds changed shape"
  for id in sample-duplicate-round sample-unslugged-round sample-selected-round sample-empty-round \
    sample-blank-round sample-partial-entry-round sample-oversize-round; do
    assert_not_contains "$out" "$id" "a round the intake cannot record whole was reported: $id"
  done

  run_procevent "$home" register lavish "$sid" -- cat "$result" >/dev/null \
    || fail "could not register the round board source"
  run_captain "$home" bind "$sid" >/dev/null \
    || fail "could not bind the round board source to the keyed-answer intake"
  out=$(run_procevent "$home" start "$sid" 2>&1) \
    || fail "the round board source runner did not complete: $out"
  assert_contains "$out" "answers-fed: $sid" "the captured round never reached the intake: $out"

  show=$(tasks_in "$home" show sample-interview-r1 --full)
  assert_contains "$show" "state: done" "the answered round did not close its held task"
  # data/backlog.md is the markdown backend's own persisted artifact, read here
  # for its bytes because the shown field re-encodes them.
  LC_ALL=C grep -qF "Answer: $round_answer" "$stored" \
    || fail "the round's held task did not record every question, selection, and note"
  LC_ALL=C grep -qF "Answer: $long_answer" "$stored" \
    || fail "the long round's held task did not record the round whole"
  show=$(tasks_in "$home" show sample-single-call --full)
  assert_contains "$show" "state: done" "a single-question answer beside rounds did not close its call"
  for id in sample-duplicate-round sample-unslugged-round sample-selected-round sample-empty-round \
    sample-blank-round sample-partial-entry-round sample-oversize-round; do
    show=$(tasks_in "$home" show "$id" --full)
    assert_contains "$show" "held: yes" "a round the intake cannot record whole changed its held task: $id"
    assert_contains "$show" "state: queued" "a round the intake cannot record whole closed its held task: $id"
  done
  pass "a round answer records every question whole on its one held task"
}

# The intake records an answer up to 3840 bytes, so a round fits whole, and
# cuts a longer one on a character boundary so the record stays valid UTF-8 and
# inside the 8192-byte record that `answer` accepts.
test_keyed_answer_intake_bounds_answers_in_whole_characters() {
  local home stored long huge out
  home=$(make_home keyed-answer-bound)
  stored="$home/data/backlog.md"
  run_captain "$home" hold sample-long-answer-call --title "Choose the long sample answer" \
    --reason "captain long answer pending" --repo sample >/dev/null \
    || fail "could not register the long-answer call"
  run_captain "$home" hold sample-huge-answer-call --title "Choose the huge sample answer" \
    --reason "captain huge answer pending" --repo sample >/dev/null \
    || fail "could not register the huge-answer call"

  long=$(printf 'keep the saturday slot %.0s' $(seq 1 30))
  long=${long% }
  [ "${#long}" -gt 512 ] || fail "precondition: the long answer must be longer than 512 characters"
  huge=x$(printf 'с%.0s' $(seq 1 3000))
  out=$(printf 'sample-long-answer-call\t%s\t\nsample-huge-answer-call\t%s\t\n' "$long" "$huge" \
    | run_captain "$home" answers --source "a bounded keyed answer") \
    || fail "the intake did not record the long answers: $out"
  assert_contains "$out" "closed: sample-long-answer-call" "the long answer did not close its call: $out"
  assert_contains "$out" "closed: sample-huge-answer-call" "the huge answer did not close its call: $out"

  # data/backlog.md is the markdown backend's own persisted artifact, read here
  # for its bytes because the shown field re-encodes them.
  LC_ALL=C grep -qF "Answer: $long" "$stored" \
    || fail "an answer longer than 512 characters but inside the bound was cut"
  LC_ALL=C grep -qxF "  Answer: x$(printf 'с%.0s' $(seq 1 1919))" "$stored" \
    || fail "an answer past the bound was not cut to 3840 bytes on a character boundary"
  pass "the keyed-answer intake records answers up to 3840 bytes in whole characters"
}

# The intake is channel-agnostic, so chat must reach it the same way a captured
# review does - for a task-id key, and for a legacy composed identity.
test_chat_channel_feeds_the_same_keyed_answer_intake() {
  local home id fb show list
  home=$(make_home chat-channel)
  id=sample-chat-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review sample chat routing" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the chat-channel origin"
  write_origin_meta "$home" "$id" ship
  printf 'needs-decision [key=chat-choice]: pick option A or option B\n' > "$home/state/$id.status"
  printf '# Chat review\n\nTwo captain choices remain.\n\n## References\n\n- fixture source\n' > "$home/data/$id/report.md"
  run_shim "$home" hold "$id" chat-choice \
    --title "Choose the sample chat option" --reason "captain chat choice pending" --repo sample >/dev/null \
    || fail "could not register the legacy chat row"
  run_captain "$home" hold sample-chat-followup --title "Choose the chat follow-up" \
    --reason "captain follow-up choice pending" --repo sample >/dev/null \
    || fail "could not register the task-id chat call"
  run_captain "$home" hold sample-chat-reconcile --title "Reconcile from chat" \
    --reason "captain chat reconcile pending" --repo sample >/dev/null \
    || fail "could not register the chat reconcile call"
  run_captain "$home" complete "$id" "$id-decision-chat-choice" sample-chat-followup \
    sample-chat-reconcile >/dev/null \
    || fail "completion failed for the chat calls"
  grep -F 'captain-held [key=chat-choice]' "$home/state/$id.status" >/dev/null \
    || fail "precondition: completion did not transfer the decision to its durable owner"

  fb="$home/fakebin"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "$FM_SEND_LOG"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"

  : > "$home/send.log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" --resolve-key chat-choice "go with option A" >/dev/null 2>&1 \
    || fail "an answer to a transferred legacy decision was refused by the chat channel"
  # The answer rides fm-send's durable inbox plane: the record carries the
  # text while the typed channel carries only the doorbell.
  grep -qF "go with option A" "$home/state/$id.inbox/001.msg" \
    || fail "the answer text never reached the worker's durable inbox record"
  show=$(tasks_in "$home" show "$id-decision-chat-choice" --full)
  assert_contains "$show" "state: done" "a chat answer left the legacy row open"
  assert_contains "$show" "Answer: go with option A" "the chat-answered row lost the captain answer"

  : > "$home/send.log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" --resolve-key sample-chat-followup "take the second option" >/dev/null 2>&1 \
    || fail "an answer keyed by a task id was refused by the chat channel"
  show=$(tasks_in "$home" show sample-chat-followup --full)
  assert_contains "$show" "state: done" "a chat answer left the task-id call open"
  assert_contains "$show" "Resolution mode: answered" "the chat-answered call did not record its close path"
  assert_contains "$show" "Answer: take the second option" "the chat-answered call lost the captain answer"
  assert_contains "$show" "answer sent to $id" "the chat-answered call lost its channel provenance"

  : > "$home/send.log"
  set +e
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" --resolve-key sample-chat-reconcile reconcile >/dev/null 2>&1
  set -e
  show=$(tasks_in "$home" show sample-chat-reconcile --full)
  assert_contains "$show" "state: queued" "a chat reconcile answer closed the call"
  list=$(run_captain "$home" reconcile list)
  assert_contains "$list" "reconcile-requests: 0" "a chat reconcile answer created a board request"
  printf 'Chat cannot authorize this closure.\n' > "$home/chat-reconcile.txt"
  if run_captain "$home" reconcile close sample-chat-reconcile \
    --evidence-file "$home/chat-reconcile.txt" >/dev/null 2>&1; then
    fail "a chat reconcile answer authorized evidence-backed closure"
  fi
  run_captain "$home" answer sample-chat-reconcile --decision-file "$home/chat-reconcile.txt" >/dev/null \
    || fail "could not close the chat reconcile fixture normally"

  if env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" --resolve-key sample-chat-followup "again" \
    > "$home/closed-key.out" 2> "$home/closed-key.err"; then
    fail "a key already closed in both ledgers was accepted"
  fi
  run_captain "$home" verify "$id" >/dev/null \
    || fail "chat-answered calls did not satisfy the completion gate"
  pass "the chat channel feeds the same keyed-answer intake a captured review does"
}

test_origin_slug_validation_precedes_path_construction() {
  local home
  home=$(make_home slug-validation)
  if run_captain "$home" complete "../escape" --none > "$home/escape.out" 2> "$home/escape.err"; then
    fail "complete accepted a path-escaping origin id"
  fi
  assert_grep "privacy-safe slug" "$home/escape.err" "the refusal must name the slug contract"
  if run_captain "$home" verify "../escape" > "$home/escape-verify.out" 2> "$home/escape-verify.err"; then
    fail "verify accepted a path-escaping origin id"
  fi
  if run_captain "$home" hold "bad id" --title "x" --reason "y" > "$home/bad-hold.out" 2> "$home/bad-hold.err"; then
    fail "hold accepted an invalid task id"
  fi
  pass "completion and verification validate origins before constructing paths"
}

# --- record divergence ------------------------------------------------------

# Reconstructs the 2026-08-06 loss with synthetic names: the answer was posted
# as a `resolved [key=...]` line and nothing else, so the status fold went quiet
# while the durable captain-held task stayed open and kept reading as if the
# captain had never spoken. Both identities that can carry a captain call must
# be caught - the collapsed one (the key IS the task id) and the legacy derived
# one a pre-collapse origin minted - and the report must reach the drain, which
# is where firstmate actually looks.
test_status_resolution_over_an_open_hold_is_signalled() {
  local home id out drain
  home=$(make_home divergence-signalled)
  id=sample-route-review
  tasks_in "$home" add "$id" "Investigate sample routing" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$id"
  run_captain "$home" hold sample-route-call \
    --title "Choose route: north or south" --reason "captain route choice pending" \
    --repo sample --origin "$id" >/dev/null \
    || fail "could not register the collapsed-identity captain call"
  run_captain "$home" hold "$id-decision-access" \
    --title "Open or restricted sample access" --reason "captain access choice pending" \
    --repo sample --origin "$id" >/dev/null \
    || fail "could not register the legacy-identity captain call"
  cat > "$home/state/$id.status" <<'EOF'
working: report drafted
needs-decision [key=sample-route-call]: north or south
resolved [key=sample-route-call]: answered: north
needs-decision [key=access]: open or restricted sample access
resolved [key=access]: answered: restricted
done: report complete
EOF

  out=$(run_captain "$home" diverged) || fail "diverged failed on the reconstructed loss"
  printf '%s\n' "$out" | grep -F "sample-route-call	$id	sample-route-call" >/dev/null \
    || fail "the collapsed-identity divergence was not signalled: $out"
  printf '%s\n' "$out" | grep -F "$id-decision-access	$id	access" >/dev/null \
    || fail "the legacy-identity divergence was not signalled: $out"

  drain=$(run_drain "$home") || fail "the drain failed while reporting divergence"
  printf '%s\n' "$drain" | grep -F 'RECORD DIVERGENCE' >/dev/null \
    || fail "the divergence never reached the drain: $drain"
  printf '%s\n' "$drain" | grep -F 'sample-route-call [key=sample-route-call]' >/dev/null \
    || fail "the drain section omitted the collapsed-identity divergence: $drain"
  printf '%s\n' "$drain" | grep -F "$id-decision-access [key=access]" >/dev/null \
    || fail "the drain section omitted the legacy-identity divergence: $drain"

  # It signals; it never closes. Both records must survive the report unchanged,
  # because closing a captain call wrongly removes it from review entirely.
  assert_grep "sample-route-call" "$home/data/backlog.md" "the report must not remove the captain-held task"
  tasks_in "$home" show sample-route-call --full | grep -E '^  held: yes' >/dev/null \
    || fail "the report released or closed the captain-held task"
  [ "$(grep -c '^resolved \[key=sample-route-call\]' "$home/state/$id.status")" = 1 ] \
    || fail "the report rewrote the status log"

  # And it names BOTH reconciliation directions. A status resolution is not proof
  # the captain ruled: one of the real cases dissolved because its premise was
  # false and another was a question of fact whose first reading was wrong, so
  # the only safe instruction is "reconcile with what actually happened".
  printf '%s\n' "$drain" | grep -F 'fm-captain-hold.sh answer' >/dev/null \
    || fail "the drain section does not say how to record the captain's answer: $drain"
  printf '%s\n' "$drain" | grep -F 're-open the status decision' >/dev/null \
    || fail "the drain section does not offer the re-open direction: $drain"
  pass "a status resolution over a still-open captain-held task is signalled, not closed"
}

# The false-signal boundary, driven by the shapes that are genuinely fine. A
# captain call whose deliverable IS the decision has no routed work item at all,
# and that is legitimate: routed work must never be part of the test. Nor may a
# verified `captain-held` transfer, a still-open status decision, an already
# answered call, or an ordinary task that merely had a keyed question answered.
test_legitimate_holds_produce_no_divergence_signal() {
  local home id out drain answer
  home=$(make_home divergence-no-false-signal)
  id=sample-systems-review
  tasks_in "$home" add "$id" "Investigate sample systems" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$id"

  # (1) The decision IS the deliverable: held for the captain, nothing routed,
  # no status line anywhere naming it.
  run_captain "$home" hold sample-standalone-call \
    --title "Adopt the sample naming convention" --reason "captain call with no routed work" \
    --repo sample >/dev/null || fail "could not register the deliverable-is-the-decision call"
  # (2) The verified transfer: still open structurally, closed on the status side
  # by the captain-held verb command_complete writes.
  run_captain "$home" hold sample-transfer-call \
    --title "Choose the sample retention window" --reason "captain retention choice pending" \
    --repo sample >/dev/null || fail "could not register the transferred call"
  # (4) An already answered call whose status line reads resolved.
  run_captain "$home" hold sample-answered-call \
    --title "Choose the sample export format" --reason "captain export choice pending" \
    --repo sample >/dev/null || fail "could not register the answered call"
  answer="$home/answer.txt"
  printf 'Export as CSV.\n' > "$answer"
  run_captain "$home" answer sample-answered-call --decision-file "$answer" >/dev/null \
    || fail "could not record the captain answer fixture"
  # (5) An ordinary in-flight work item that is not held for the captain.
  tasks_in "$home" add sample-plain-work "Ordinary sample work" --kind ship --repo sample --start >/dev/null \
    || fail "could not create the ordinary work fixture"

  cat > "$home/state/$id.status" <<'EOF'
working: report drafted
needs-decision [key=sample-transfer-call]: choose the retention window
captain-held [key=sample-transfer-call]: tracked by sample-transfer-call
needs-decision [key=sample-open-call]: still open on both sides
needs-decision [key=sample-answered-call]: choose the export format
resolved [key=sample-answered-call]: answered: CSV
needs-decision [key=sample-plain-work]: worker question about the sample fixture
resolved [key=sample-plain-work]: answered: go ahead
EOF
  # (3) A still-open status decision whose structured twin is also still open.
  run_captain "$home" hold sample-open-call \
    --title "Choose the sample refresh cadence" --reason "captain cadence choice pending" \
    --repo sample >/dev/null || fail "could not register the still-open call"

  out=$(run_captain "$home" diverged) || fail "diverged failed on the legitimate shapes"
  [ -z "$out" ] || fail "legitimate captain holds produced a false divergence signal: $out"

  drain=$(run_drain "$home") || fail "the drain failed on the legitimate shapes"
  if printf '%s\n' "$drain" | grep -F 'RECORD DIVERGENCE' >/dev/null; then
    fail "the drain printed a divergence section with nothing diverging: $drain"
  fi
  printf '%s\n' "$drain" | grep -F 'sample-open-call' >/dev/null \
    || fail "setup error: the still-open decision should still reach OPEN DECISIONS: $drain"
  pass "a captain call with no routed work, a verified transfer, an open decision, and an answered call all stay silent"
}

test_board_answer_reaches_the_keyed_answer_intake
test_board_answer_keeps_the_captains_non_ascii_words
test_round_answer_records_every_question_whole
test_keyed_answer_intake_bounds_answers_in_whole_characters
test_chat_channel_feeds_the_same_keyed_answer_intake
test_origin_slug_validation_precedes_path_construction
test_status_resolution_over_an_open_hold_is_signalled
test_legitimate_holds_produce_no_divergence_signal
