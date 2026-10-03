#!/usr/bin/env bash
# Classifier, render-decision, and real-Pi checks for Firstmate's collapsed operational rows.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-operational-row-collapse)
LIB_DIR="$ROOT/.pi/extensions/lib"
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}
TMUX_SOCKET="fm-op-collapse-$$"

cleanup() {
  if command -v tmux >/dev/null 2>&1; then
    tmux -L "$TMUX_SOCKET" kill-server 2>/dev/null || true
  fi
  fm_test_cleanup
}
trap cleanup EXIT

# The steering doorbell names only the inbox basename, so this is the identity every
# check below expects for launch-brief and doorbell rows.
TASK_ID=collapse-task
TASK_INBOX="$TMP_ROOT/state/$TASK_ID.inbox"

pi_package_available() {
  command -v node >/dev/null 2>&1 && [ -f "$PI_PACKAGE_DIR/package.json" ]
}

make_lib_fixture() {  # <dir>
  local dir=$1
  mkdir -p "$dir/lib" "$dir/node_modules/@earendil-works"
  cp "$LIB_DIR/fm-calm-operational-user-layout.ts" "$LIB_DIR/fm-calm-visibility.ts" \
    "$LIB_DIR/fm-operational-input.ts" "$dir/lib/"
  ln -s "$PI_PACKAGE_DIR" "$dir/node_modules/@earendil-works/pi-coding-agent"
  ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$dir/node_modules/@earendil-works/pi-tui"
  printf '%s\n' '{"type":"module"}' >"$dir/package.json"
}

run_fixture_node() {  # <dir>; script on stdin
  (cd "$1" && \
    FM_OPERATIONAL_INPUT_SCRIPT="$ROOT/bin/fm-operational-input.sh" \
    FM_TASK_INBOX_LIB="$ROOT/bin/fm-task-inbox-lib.sh" \
    FM_TASK_INBOX="$TASK_INBOX" TASK_ID="$TASK_ID" PI_PACKAGE_DIR="$PI_PACKAGE_DIR" \
    node --input-type=module 2>&1)
}

test_classifier() {
  local fixture out
  if ! pi_package_available; then
    echo "skip: node or the installed Pi package not found for the operational-row classifier test"
    return 0
  fi
  fixture="$TMP_ROOT/classifier"
  make_lib_fixture "$fixture"
  out=$(run_fixture_node "$fixture" <<'JS'
import { execFileSync } from "node:child_process";
const rows = await import("./lib/fm-calm-operational-user-layout.ts");
const input = await import("./lib/fm-operational-input.ts");
const doorbellFor = (inbox) => execFileSync("bash", ["-c", '. "$1" && fm_task_inbox_doorbell_line "$2/x.msg"', "_", process.env.FM_TASK_INBOX_LIB, inbox], { encoding: "utf8" });
const expectRow = (text, kind, identity) => {
  const row = rows.classifyFirstmateOperationalRow(text);
  if (row?.kind !== kind || row?.identity !== identity) {
    throw new Error(`expected ${kind} "${identity}" for ${JSON.stringify(text.slice(0, 60))}, got ${JSON.stringify(row)}`);
  }
};
const firstLines = {
  "session-start": "Session digest headline",
  watcher: "FIRSTMATE WATCHER WAKE: signal: probe done",
  "turn-end-guard": "TURN WOULD END BLIND - supervision is off.",
  "away-supervisor": "Away digest headline",
  "from-firstmate": "Steer headline",
  "branch-outcome": "Supervision processing request headline",
};
for (const [kind, headline] of Object.entries(firstLines)) {
  expectRow(input.encodeFirstmateOperationalInput(kind, `\n${headline}\nFULL_BODY_LINE`), kind, headline);
}
expectRow(input.encodeFirstmateOperationalInput("launch-brief", "# Current worker role contract\nFULL_BODY_LINE"), "launch-brief", process.env.TASK_ID);
expectRow(doorbellFor(process.env.FM_TASK_INBOX), "steering-doorbell", process.env.TASK_ID);
expectRow("\u2063Supervisor escalate (legacy) headline", "away-supervisor", "Supervisor escalate (legacy) headline");

const watcher = input.encodeFirstmateOperationalInput("watcher", "FIRSTMATE WATCHER WAKE: signal: x");
const captainText = [
  "please explain the FIRSTMATE_OP: v1 watcher: marker",
  "FIRSTMATE_OP: v1 watcher: ASCII_ONLY_CAPTAIN_MESSAGE",
  `Captain quote: ${watcher}`,
  "\u2063FIRSTMATE_OP: v1 not-a-kind: body",
  "\u2063FIRSTMATE_OP: v1 watcher:",
  doorbellFor(`${process.env.FM_TASK_INBOX}-other`),
  `${doorbellFor(process.env.FM_TASK_INBOX)} and please also look at this`,
  ": Firstmate instruction waiting: please look",
];
for (const text of captainText) {
  const row = rows.classifyFirstmateOperationalRow(text);
  if (row !== undefined) throw new Error(`classified captain text ${JSON.stringify(text)} as ${JSON.stringify(row)}`);
}
JS
) || fail "operational-row classifier failed: $out"
  [ -z "$out" ] || fail "operational-row classifier printed output: $out"

  out=$(cd "$fixture" && env -u FM_TASK_INBOX \
    FM_OPERATIONAL_INPUT_SCRIPT="$ROOT/bin/fm-operational-input.sh" \
    FM_TASK_INBOX_LIB="$ROOT/bin/fm-task-inbox-lib.sh" DOORBELL_INBOX="$TASK_INBOX" \
    node --input-type=module 2>&1 <<'JS'
import { execFileSync } from "node:child_process";
const rows = await import("./lib/fm-calm-operational-user-layout.ts");
const input = await import("./lib/fm-operational-input.ts");
const doorbell = execFileSync("bash", ["-c", '. "$1" && fm_task_inbox_doorbell_line "$2/x.msg"', "_", process.env.FM_TASK_INBOX_LIB, process.env.DOORBELL_INBOX], { encoding: "utf8" });
if (rows.classifyFirstmateOperationalRow(doorbell) !== undefined) {
  throw new Error("a doorbell line collapsed in a process with no steering inbox of its own");
}
const brief = rows.classifyFirstmateOperationalRow(input.encodeFirstmateOperationalInput("launch-brief", "\n# Charter headline\nbody"));
if (brief?.identity !== "Charter headline") throw new Error(`launch brief without an inbox used ${JSON.stringify(brief)}`);
JS
) || fail "operational-row classifier outside a Firstmate launch failed: $out"
  pass "every Firstmate operational kind and this process's own steering doorbell classify with a kind and short identity, while captain text that mentions the marker, a foreign or extended doorbell, and a doorbell outside a launch stay unclassified"
}

test_render_decision() {
  local fixture out
  if ! pi_package_available; then
    echo "skip: node or the installed Pi package not found for the operational-row render test"
    return 0
  fi
  fixture="$TMP_ROOT/render"
  make_lib_fixture "$fixture"
  out=$(run_fixture_node "$fixture" <<'JS'
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";
const packageRoot = process.env.PI_PACKAGE_DIR;
const [{ InteractiveMode }, { UserMessageComponent }, { initTheme, theme }, { visibleWidth }] = await Promise.all([
  import(pathToFileURL(`${packageRoot}/dist/modes/interactive/interactive-mode.js`).href),
  import(pathToFileURL(`${packageRoot}/dist/modes/interactive/components/user-message.js`).href),
  import(pathToFileURL(`${packageRoot}/dist/modes/interactive/theme/theme.js`).href),
  import(pathToFileURL(`${packageRoot}/node_modules/@earendil-works/pi-tui/dist/index.js`).href),
]);
initTheme("dark");
const layout = await import("./lib/fm-calm-operational-user-layout.ts");
const visibility = await import("./lib/fm-calm-visibility.ts");
const input = await import("./lib/fm-operational-input.ts");
layout.installCalmOperationalUserLayout();
layout.bindOperationalRowTheme(theme);

const strip = (line) => line.replace(/\x1b\[[0-9;]*m|\x1b\][^\x07]*\x07/g, "");
const doorbell = execFileSync("bash", ["-c", '. "$1" && fm_task_inbox_doorbell_line "$2/x.msg"', "_", process.env.FM_TASK_INBOX_LIB, process.env.FM_TASK_INBOX], { encoding: "utf8" });
const operational = [
  ["launch brief", input.encodeFirstmateOperationalInput("launch-brief", "# Current worker role contract\nFULL_TEXT_LAUNCH")],
  ["watcher wake", input.encodeFirstmateOperationalInput("watcher", "FIRSTMATE WATCHER WAKE: signal: x\n\nFULL_TEXT_WATCHER")],
  ["supervision request", input.encodeFirstmateOperationalInput("branch-outcome", "Processing request\nFULL_TEXT_BRANCH")],
  ["steering doorbell", doorbell],
];
const captain = "CAPTAIN_TYPED mentions FIRSTMATE_OP: v1 watcher: and must stay whole";

function chatMode(expanded) {
  return {
    chatContainer: { children: [], addChild(component) { this.children.push(component); } },
    editor: { addToHistory() {} },
    getMarkdownTransformers: () => [],
    getMarkdownThemeWithSettings: () => undefined,
    getUserMessageText: (message) => typeof message.content === "string"
      ? message.content
      : message.content.map((block) => block.text).join(""),
    outputPad: 1,
    toolOutputExpanded: expanded,
  };
}
const stockRows = (text) => ["", ...new UserMessageComponent(text, undefined, 1, []).render(100)];
const click = (y) => ({ type: "click", button: "left", x: 2, y, screenX: 2, screenY: 10 + y, width: 100, height: 4, shift: false, alt: false, ctrl: false });

const mode = chatMode(false);
mode.chatContainer.children.push({ render: () => ["PREDECESSOR"] });
for (const [, text] of operational) {
  InteractiveMode.prototype.addMessageToChat.call(mode, { role: "user", content: [{ type: "text", text }] });
}
InteractiveMode.prototype.addMessageToChat.call(mode, { role: "user", content: captain });
const [, ...added] = mode.chatContainer.children;
const captainRow = added.pop();

for (const [index, [label, text]] of operational.entries()) {
  const row = added[index];
  for (const width of [100, 40]) {
    const collapsed = row.render(width);
    if (collapsed.length !== 2 || collapsed[0] !== "") {
      throw new Error(`${label} did not collapse to its spacer and one line at width ${width}: ${JSON.stringify(collapsed)}`);
    }
    if (visibleWidth(collapsed[1]) > width) throw new Error(`${label} overflowed width ${width}`);
    if (strip(collapsed[1]).includes("FULL_TEXT") || strip(collapsed[1]).includes("instruction waiting")) {
      throw new Error(`${label} leaked its full text into the collapsed line`);
    }
  }
  const line = strip(row.render(100)[1]);
  if (!line.includes(`[firstmate] ${label}`) || !line.includes("to expand")) {
    throw new Error(`${label} collapsed line does not name its kind and expansion: ${line}`);
  }
  if ((label === "launch brief" || label === "steering doorbell") && !line.includes(process.env.TASK_ID)) {
    throw new Error(`${label} collapsed line does not name its task: ${line}`);
  }
  if (label === "watcher wake" && !line.includes("signal: x")) {
    throw new Error(`watcher collapsed line does not name its wake: ${line}`);
  }
  row.setExpanded(true);
  if (JSON.stringify(row.render(100)) !== JSON.stringify(stockRows(text))) {
    throw new Error(`${label} expanded row differs from Pi's stock user row`);
  }
  row.setExpanded(false);
  if (row.handleMouse(click(0)) !== undefined || row.render(100).length !== 2) {
    throw new Error(`${label} toggled from a click on its leading spacer`);
  }
  if (!row.handleMouse(click(1))?.handled || JSON.stringify(row.render(100)) !== JSON.stringify(stockRows(text))) {
    throw new Error(`${label} did not expand on a click`);
  }
  if (!row.handleMouse(click(1))?.handled || row.render(100).length !== 2) {
    throw new Error(`${label} did not collapse again on a second click`);
  }
}
if (JSON.stringify(captainRow.render(100)) !== JSON.stringify(new UserMessageComponent(captain, undefined, 1, []).render(100))) {
  throw new Error("captain text that mentions the marker did not render as Pi's stock user row");
}

const expandedMode = chatMode(true);
expandedMode.chatContainer.children.push({ render: () => ["PREDECESSOR"] });
InteractiveMode.prototype.addMessageToChat.call(expandedMode, { role: "user", content: operational[1][1] });
if (JSON.stringify(expandedMode.chatContainer.children[1].render(100)) !== JSON.stringify(stockRows(operational[1][1]))) {
  throw new Error("a row added while tools are expanded did not start expanded");
}

visibility.setCalmPresentation(true);
for (const [index, [label]] of operational.entries()) {
  const rendered = added[index].render(100);
  if (label === "steering doorbell") {
    if (rendered.length !== 2) throw new Error("Calm hid the plain-text steering doorbell instead of leaving it collapsed");
  } else if (rendered.length !== 0) {
    throw new Error(`Calm left the marker-carried ${label} row visible`);
  }
}
visibility.setCalmPresentation(false);
JS
) || fail "operational-row render decision failed: $out"
  [ -z "$out" ] || fail "operational-row render decision printed output: $out"
  pass "operational rows render as one themed in-width line under their spacer, expand to Pi's exact stock row by the expand control or a click, start expanded with tools expanded, stay hidden under Calm only when marker-carried, and captain text renders stock"
}

PI_LIVE_SKIP=
pi_live_available() {
  if ! command -v pi >/dev/null 2>&1 || ! command -v tmux >/dev/null 2>&1 || ! command -v node >/dev/null 2>&1; then
    PI_LIVE_SKIP="pi, tmux, or node not found"
    return 1
  fi
  pi --help 2>&1 | grep -q -- '--tui-mode' || { PI_LIVE_SKIP="this Pi has no --tui-mode regular for scrollback capture"; return 1; }
}

# The real worker extension, generated by fm-spawn for a Pi ship.
spawn_worker_extension() {  # <case-dir>; prints the extension path
  local case_dir=$1 home proj wt fakebin out
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" pi)
  fm_test_spawn_home "$home" pi
  fm_git_worktree "$proj" "$wt" "wt-op-collapse"
  fm_test_spawn_brief "$home" "$TASK_ID"
  out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" "$TASK_ID" "$proj" --mode no-mistakes --yolo off) \
    || fail "fm-spawn could not generate the Pi worker extension: $out"
  [ -f "$home/state/$TASK_ID.pi-ext.ts" ] || fail "fm-spawn wrote no Pi worker extension: $out"
  printf '%s\n' "$home/state/$TASK_ID.pi-ext.ts"
}

write_session_fixture() {  # <session-file> <cwd>
  node --input-type=module - "$1" "$2" "$ROOT" "$TASK_INBOX" <<'JS'
import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";
const [out, cwd, root, inbox] = process.argv.slice(2);
const encode = (kind, body) => execFileSync(`${root}/bin/fm-operational-input.sh`, ["encode", kind], { input: body, encoding: "utf8" });
const doorbell = execFileSync("bash", ["-c", '. "$1" && fm_task_inbox_doorbell_line "$2/x.msg"', "_", `${root}/bin/fm-task-inbox-lib.sh`, inbox], { encoding: "utf8" });
const users = [
  encode("launch-brief", "# Current worker role contract\nFULL_TEXT_LAUNCH_BRIEF"),
  encode("session-start", "Session digest headline\nFULL_TEXT_SESSION_START"),
  encode("watcher", "FIRSTMATE WATCHER WAKE: signal: probe done\n\nFULL_TEXT_WATCHER"),
  encode("turn-end-guard", "TURN WOULD END BLIND - supervision is off.\n\nFULL_TEXT_TURN_END"),
  encode("away-supervisor", "Away digest headline\nFULL_TEXT_AWAY"),
  encode("from-firstmate", "Steer headline\nFULL_TEXT_FROM_FIRSTMATE"),
  encode("branch-outcome", "Supervision processing request headline\nFULL_TEXT_BRANCH_OUTCOME"),
  "\u2063Supervisor escalate (legacy)\nFULL_TEXT_LEGACY_AWAY",
  doorbell,
  "CAPTAIN_TYPED explain the FIRSTMATE_OP: v1 watcher: marker\nCAPTAIN_SECOND_LINE stays visible",
];
const usage = { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
const lines = [JSON.stringify({ type: "session", version: 3, id: "0f0f0f0f-0000-4000-8000-00000000c011", timestamp: new Date(0).toISOString(), cwd })];
let parent = null;
let count = 0;
const push = (message) => {
  const id = (++count).toString(16).padStart(8, "0");
  lines.push(JSON.stringify({ type: "message", id, parentId: parent, timestamp: new Date(count * 1000).toISOString(), message }));
  parent = id;
};
const assistant = (content, stopReason) => ({ role: "assistant", content, api: "fixture", provider: "fixture", model: "fixture", usage, stopReason, timestamp: count * 1000 });
for (const [index, text] of users.entries()) {
  push({ role: "user", content: [{ type: "text", text }], timestamp: count * 1000 });
  push(assistant([{ type: "text", text: `ASSISTANT_PROSE_${index}` }], "stop"));
}
push(assistant([{ type: "text", text: "ASSISTANT_BEFORE_FAILED_TOOL" }, { type: "toolCall", id: "call_failed", name: "bash", arguments: { command: "false FAILED_TOOL_COMMAND" } }], "toolUse"));
push({ role: "toolResult", toolCallId: "call_failed", toolName: "bash", content: [{ type: "text", text: "FAILED_TOOL_OUTPUT exit code 1" }], isError: true, timestamp: count * 1000 });
push(assistant([{ type: "text", text: "ASSISTANT_BEFORE_PENDING_TOOL" }, { type: "toolCall", id: "call_pending", name: "bash", arguments: { command: "sleep 1 PENDING_TOOL_COMMAND" } }], "toolUse"));
writeFileSync(out, lines.join("\n") + "\n");
JS
}

OPERATIONAL_FULL_TEXT=(
  FULL_TEXT_LAUNCH_BRIEF FULL_TEXT_SESSION_START FULL_TEXT_WATCHER FULL_TEXT_TURN_END FULL_TEXT_AWAY
  FULL_TEXT_FROM_FIRSTMATE FULL_TEXT_BRANCH_OUTCOME FULL_TEXT_LEGACY_AWAY "instruction waiting"
)
ALWAYS_VISIBLE=(
  CAPTAIN_TYPED CAPTAIN_SECOND_LINE ASSISTANT_PROSE_0 ASSISTANT_PROSE_9 ASSISTANT_BEFORE_FAILED_TOOL
  FAILED_TOOL_COMMAND FAILED_TOOL_OUTPUT ASSISTANT_BEFORE_PENDING_TOOL PENDING_TOOL_COMMAND
)

# Restores the fixture session in a real Pi and captures the whole transcript before and
# after the tools-expand key. Prints the two capture paths.
capture_restored_session() {  # <label> <workdir> <pi -e args...>
  local label=$1 workdir=$2 session before after i
  shift 2
  session="$workdir/$label.jsonl"
  before="$workdir/$label.collapsed.txt"
  after="$workdir/$label.expanded.txt"
  cp "$workdir/fixture.jsonl" "$session"
  tmux -L "$TMUX_SOCKET" kill-session -t "$label" 2>/dev/null || true
  tmux -L "$TMUX_SOCKET" new-session -d -s "$label" -x 100 -y 50 \
    "cd '$workdir/project' && env -u FM_TASK_ID FM_TASK_INBOX='$TASK_INBOX' FM_HOME='$workdir/home' PI_CODING_AGENT_DIR='$workdir/agent' PI_OFFLINE=1 pi --tui-mode regular --approve --no-context-files --no-skills --no-prompt-templates --no-extensions $* --session '$session'; sleep 30"
  i=0
  while [ "$i" -lt 200 ]; do
    tmux -L "$TMUX_SOCKET" capture-pane -p -t "$label" -S -3000 >"$before" 2>/dev/null || true
    grep -Fq "PENDING_TOOL_COMMAND" "$before" && grep -Fq "────" "$before" && break
    sleep 0.05
    i=$((i + 1))
  done
  sleep 0.5
  tmux -L "$TMUX_SOCKET" capture-pane -p -t "$label" -S -3000 >"$before"
  tmux -L "$TMUX_SOCKET" send-keys -t "$label" C-o
  i=0
  while [ "$i" -lt 100 ]; do
    tmux -L "$TMUX_SOCKET" capture-pane -p -t "$label" -S -3000 >"$after" 2>/dev/null || true
    grep -Fq "Tool output: expanded" "$after" && break
    sleep 0.05
    i=$((i + 1))
  done
  tmux -L "$TMUX_SOCKET" kill-session -t "$label" 2>/dev/null || true
  head -n "$(wc -l <"$workdir/fixture.jsonl")" "$session" | cmp -s - "$workdir/fixture.jsonl" \
    || fail "$label Pi run changed the saved session's existing entries"
}

assert_each_visible() {  # <file> <label> <words...>
  local file=$1 label=$2 word
  shift 2
  for word in "$@"; do
    grep -Fq -- "$word" "$file" || fail "$label is missing $word"$'\n'"--- capture ---"$'\n'"$(cat "$file")"
  done
}

assert_each_absent() {  # <file> <label> <words...>
  local file=$1 label=$2 word
  shift 2
  for word in "$@"; do
    if grep -Fq -- "$word" "$file"; then
      fail "$label still shows $word"$'\n'"--- capture ---"$'\n'"$(cat "$file")"
    fi
  done
}

test_real_pi_restored_session() {
  local workdir worker_ext label collapsed rows
  if ! pi_live_available; then
    echo "skip: $PI_LIVE_SKIP for the real-Pi operational-row check"
    return 0
  fi
  workdir="$TMP_ROOT/live"
  mkdir -p "$workdir/project" "$workdir/home/config" "$workdir/agent"
  write_session_fixture "$workdir/fixture.jsonl" "$workdir/project"
  worker_ext=$(spawn_worker_extension "$TMP_ROOT/spawn")

  capture_restored_session stock "$workdir"
  assert_each_visible "$workdir/stock.collapsed.txt" "stock Pi" "${OPERATIONAL_FULL_TEXT[@]}" "${ALWAYS_VISIBLE[@]}"
  assert_each_absent "$workdir/stock.collapsed.txt" "stock Pi" "[firstmate]"

  capture_restored_session main "$workdir" -e "$ROOT/.pi/extensions/fm-calm.ts"
  capture_restored_session worker "$workdir" -e "$worker_ext"
  for label in main worker; do
    collapsed="$workdir/$label.collapsed.txt"
    assert_each_absent "$collapsed" "$label Pi before expansion" "${OPERATIONAL_FULL_TEXT[@]}"
    assert_each_visible "$collapsed" "$label Pi before expansion" "${ALWAYS_VISIBLE[@]}"
    assert_each_visible "$collapsed" "$label Pi before expansion" \
      "[firstmate] launch brief · $TASK_ID" \
      "[firstmate] session start · Session digest headline" \
      "[firstmate] watcher wake · FIRSTMATE WATCHER WAKE: signal: probe done" \
      "[firstmate] turn-end guard · TURN WOULD END BLIND" \
      "[firstmate] away supervisor · Away digest headline" \
      "[firstmate] from firstmate · Steer headline" \
      "[firstmate] supervision request · Supervision processing request headline" \
      "[firstmate] away supervisor · Supervisor escalate (legacy)" \
      "[firstmate] steering doorbell · $TASK_ID"
    rows=$(grep -c '\[firstmate\]' "$collapsed")
    [ "$rows" -eq 9 ] || fail "$label Pi collapsed $rows rows instead of the nine operational rows"
    assert_each_visible "$workdir/$label.expanded.txt" "$label Pi after the expand key" \
      "${OPERATIONAL_FULL_TEXT[@]}" "${ALWAYS_VISIBLE[@]}"
  done
  pass "a real Pi restoring every operational kind collapses only those rows to one line each in the main and worker extensions, keeps captain text, assistant prose, a failed tool call, and a pending tool call whole, expands every row on the expand key, and leaves the saved session untouched"
}

test_real_pi_live_worker_input() {
  local workdir worker_ext doorbell pane i
  if ! pi_live_available; then
    echo "skip: $PI_LIVE_SKIP for the real-Pi live worker input check"
    return 0
  fi
  workdir="$TMP_ROOT/live-worker"
  mkdir -p "$workdir/project" "$workdir/agent" "$workdir/sessions"
  worker_ext=$(spawn_worker_extension "$TMP_ROOT/spawn-live")
  cat >"$workdir/provider.ts" <<'TS'
import { createFauxCore, fauxAssistantMessage, fauxText } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI): void {
  const faux = createFauxCore({
    api: "op-collapse-e2e-api",
    provider: "op-collapse-e2e",
    models: [{
      id: "deterministic",
      name: "Operational collapse E2E",
      reasoning: false,
      input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 4096,
      maxTokens: 128,
    }],
    tokenSize: { min: 1, max: 1 },
  });
  faux.setResponses([
    fauxAssistantMessage([fauxText("WORKER_REPLY_ONE")]),
    fauxAssistantMessage([fauxText("WORKER_REPLY_TWO")]),
    fauxAssistantMessage([fauxText("WORKER_REPLY_THREE")]),
  ]);
  pi.registerProvider("op-collapse-e2e", {
    baseUrl: "http://127.0.0.1/unused",
    apiKey: "test-only",
    api: faux.api,
    models: faux.models,
    streamSimple: faux.streamSimple,
  });
}
TS
  printf '# Current worker role contract\nLIVE_FULL_TEXT_BRIEF\n' \
    | "$ROOT/bin/fm-operational-input.sh" encode launch-brief >"$workdir/brief.enc"
  doorbell=$(bash -c '. "$1" && fm_task_inbox_doorbell_line "$2/x.msg"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$TASK_INBOX")
  pane="$workdir/pane.txt"
  tmux -L "$TMUX_SOCKET" new-session -d -s live -x 100 -y 50 \
    "cd '$workdir/project' && env -u FM_TASK_ID FM_TASK_INBOX='$TASK_INBOX' PI_CODING_AGENT_DIR='$workdir/agent' PI_OFFLINE=1 pi --tui-mode regular --approve --no-context-files --no-skills --no-prompt-templates --no-extensions -e '$workdir/provider.ts' -e '$worker_ext' --provider op-collapse-e2e --model deterministic --session-dir '$workdir/sessions' \"\$(cat '$workdir/brief.enc')\"; sleep 30"
  wait_live() {  # <text>
    i=0
    while [ "$i" -lt 200 ]; do
      tmux -L "$TMUX_SOCKET" capture-pane -p -t live -S -3000 >"$pane" 2>/dev/null || true
      grep -Fq -- "$1" "$pane" && return 0
      sleep 0.05
      i=$((i + 1))
    done
    fail "live worker Pi never showed $1"$'\n'"--- capture ---"$'\n'"$(cat "$pane")"
  }
  wait_live WORKER_REPLY_ONE
  tmux -L "$TMUX_SOCKET" send-keys -t live -l "$doorbell"
  tmux -L "$TMUX_SOCKET" send-keys -t live Enter
  wait_live WORKER_REPLY_TWO
  tmux -L "$TMUX_SOCKET" send-keys -t live -l ": Firstmate instruction waiting: CAPTAIN_LOOKALIKE stays whole"
  tmux -L "$TMUX_SOCKET" send-keys -t live Enter
  wait_live WORKER_REPLY_THREE
  tmux -L "$TMUX_SOCKET" kill-session -t live 2>/dev/null || true
  assert_each_visible "$pane" "live worker Pi" \
    "[firstmate] launch brief · $TASK_ID" \
    "[firstmate] steering doorbell · $TASK_ID" \
    ": Firstmate instruction waiting: CAPTAIN_LOOKALIKE stays whole"
  assert_each_absent "$pane" "live worker Pi" LIVE_FULL_TEXT_BRIEF "steering inbox, read and act"
  grep -rFq LIVE_FULL_TEXT_BRIEF "$workdir/sessions" || fail "the live launch brief was not saved whole in the session"
  grep -rFq "steering inbox, read and act" "$workdir/sessions" || fail "the live doorbell was not saved whole in the session"
  pass "a real Pi worker launched with its encoded brief and rung with its doorbell shows each as one collapsed line, saves both whole, and renders a look-alike typed line in full"
}

test_classifier
test_render_decision
test_real_pi_restored_session
test_real_pi_live_worker_input
