#!/usr/bin/env bash
# Behavior tests for the two Pi 1.1.0 small fixes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-1-1-0-small-fixes)

resolve_pi_package() {
  local candidate version
  for candidate in "${FM_PI_PACKAGE_DIR:-}" "$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"; do
    [ -n "$candidate" ] && [ -f "$candidate/package.json" ] || continue
    version=$(node -p "require('$candidate/package.json').version" 2>/dev/null) || continue
    if [ "$version" = "1.1.0" ]; then printf '%s\n' "$candidate"; return 0; fi
  done
  if command -v pi >/dev/null 2>&1; then
    candidate=$(cd "$(dirname "$(command -v pi)")/../@earendil-works/pi-coding-agent" 2>/dev/null && pwd -P)
    if [ -n "$candidate" ] && [ -f "$candidate/package.json" ]; then
      version=$(node -p "require('$candidate/package.json').version" 2>/dev/null) || version=""
      if [ "$version" = "1.1.0" ]; then printf '%s\n' "$candidate"; return 0; fi
    fi
  fi
  return 1
}
PI_PACKAGE_DIR=$(resolve_pi_package) || PI_PACKAGE_DIR=""
PI_TUI_DIR=""
TYPEBOX_DIR=""
if [ -n "$PI_PACKAGE_DIR" ]; then
  PI_TUI_DIR=$(node -p "require.resolve('@earendil-works/pi-tui/package.json',{paths:['$PI_PACKAGE_DIR']})" 2>/dev/null)
  PI_TUI_DIR=$(dirname "$PI_TUI_DIR")
  TYPEBOX_DIR=$(node -p "require.resolve('typebox/package.json',{paths:['$PI_PACKAGE_DIR']})" 2>/dev/null)
  TYPEBOX_DIR=$(dirname "$TYPEBOX_DIR")
fi

test_pi_1_1_0_is_the_proving_version() {
  if [ -z "$PI_PACKAGE_DIR" ]; then
    echo "skip: no local Pi 1.1.0 package; the live pipeline proof stays out of this run"
    return 0
  fi
  local live_version package_version
  live_version=$(pi --version 2>&1 | head -n 1)
  [ "$live_version" = "1.1.0" ] || fail "live pi must be 1.1.0 for this proof, got '$live_version'"
  package_version=$(node -p "require('$PI_PACKAGE_DIR/package.json').version")
  [ "$package_version" = "1.1.0" ] || fail "proving package must be 1.1.0, got '$package_version'"
  [ -n "$PI_TUI_DIR" ] && [ -d "$PI_TUI_DIR" ] || fail "could not resolve pi-tui beside the proving package"
  [ -n "$TYPEBOX_DIR" ] && [ -d "$TYPEBOX_DIR" ] || fail "could not resolve typebox beside the proving package"
  pass "the proving Pi is 1.1.0 live and on disk"
}

make_guard_fixture() {  # <name>
  local fixture=$1
  mkdir -p "$fixture/proj/.pi/extensions/lib" "$fixture/proj/bin" "$fixture/home"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$fixture/proj/.pi/extensions/"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$fixture/proj/.pi/extensions/lib/"
  printf '%s\n' '{"type":"module"}' > "$fixture/proj/package.json"
  cat > "$fixture/proj/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'guard-ran\n' >> "$FM_GUARD_CALLS"
printf 'repair instructions\n' >&2
exit "${FM_GUARD_EXIT:-0}"
SH
  chmod +x "$fixture/proj/bin/fm-turnend-guard.sh"
  printf '%s\n' "$fixture"
}

drive_settle_sequence() {  # <fixture>
  local fixture=$1
  (cd "$fixture/proj" && \
    FIXTURE_PROJ="$fixture/proj" \
    FM_HOME="$fixture/home" \
    FM_GUARD_CALLS="$fixture/guard-calls" \
    FM_OPERATIONAL_INPUT_SCRIPT="$ROOT/bin/fm-operational-input.sh" \
    node --input-type=module 2>&1 <<'JS'
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const proj = process.env.FIXTURE_PROJ;
const callsFile = process.env.FM_GUARD_CALLS;
const sequence = JSON.parse(process.env.SETTLE_SEQUENCE);
const extMod = await import(pathToFileURL(`${proj}/.pi/extensions/fm-primary-turnend-guard.ts`).href);

const handlers = {};
const followUps = [];
const pi = {
  on: (type, handler) => { (handlers[type] ??= []).push(handler); return () => {}; },
  sendUserMessage: async (content, options) => { followUps.push({ content, options }); },
};
extMod.default(pi);
const settle = handlers.agent_settled?.[0];
if (!settle) throw new Error("the guard registered no agent_settled handler");

const guardCalls = () => {
  try {
    return readFileSync(callsFile, "utf8").split("\n").filter((line) => line === "guard-ran").length;
  } catch {
    return 0;
  }
};
const snapshots = [];
for (const event of sequence) {
  await settle(event);
  await new Promise((resolve) => setTimeout(resolve, 50));
  snapshots.push({ guardCalls: guardCalls(), followUps: followUps.length });
}
let followUpShapesOk = true;
for (const followUp of followUps) {
  if (followUp.options?.deliverAs !== "followUp" || typeof followUp.content !== "string" || followUp.content.length === 0) {
    followUpShapesOk = false;
  }
}
process.stdout.write(JSON.stringify({ snapshots, followUpShapesOk }));
JS
)
}

test_guard_skips_followup_on_aborted_settle() {
  local fixture out
  fixture=$(make_guard_fixture "$TMP_ROOT/guard-aborted")
  : > "$fixture/guard-calls"
  out=$(FM_GUARD_EXIT=2 SETTLE_SEQUENCE='[{"type":"agent_settled","aborted":true}]' drive_settle_sequence "$fixture") \
    || fail "aborted settle drive failed: $out"
  [ "$out" = '{"snapshots":[{"guardCalls":0,"followUps":0}],"followUpShapesOk":true}' ] \
    || fail "an aborted settle must run no guard and send no follow-up, got '$out'"
  pass "a cancelled run settles with no guard run and no follow-up"
}

test_guard_still_follows_up_without_aborted_field() {
  local fixture out
  fixture=$(make_guard_fixture "$TMP_ROOT/guard-legacy")
  : > "$fixture/guard-calls"
  out=$(FM_GUARD_EXIT=2 SETTLE_SEQUENCE='[{"type":"agent_settled"}]' drive_settle_sequence "$fixture") \
    || fail "legacy settle drive failed: $out"
  [ "$out" = '{"snapshots":[{"guardCalls":1,"followUps":1}],"followUpShapesOk":true}' ] \
    || fail "a settle with no aborted field must keep the existing guard follow-up, got '$out'"
  pass "a settle from an older Pi without the aborted field still guards"
}

test_guard_still_follows_up_when_not_aborted() {
  local fixture out
  fixture=$(make_guard_fixture "$TMP_ROOT/guard-completed")
  : > "$fixture/guard-calls"
  out=$(FM_GUARD_EXIT=2 SETTLE_SEQUENCE='[{"type":"agent_settled","aborted":false}]' drive_settle_sequence "$fixture") \
    || fail "completed settle drive failed: $out"
  [ "$out" = '{"snapshots":[{"guardCalls":1,"followUps":1}],"followUpShapesOk":true}' ] \
    || fail "a completed settle must keep the existing guard follow-up, got '$out'"
  pass "a completed run still guards and follows up"
}

test_guard_abort_consumes_exactly_one_suppression() {
  local fixture out
  fixture=$(make_guard_fixture "$TMP_ROOT/guard-suppression")
  : > "$fixture/guard-calls"
  out=$(FM_GUARD_EXIT=2 SETTLE_SEQUENCE='[{"type":"agent_settled"},{"type":"agent_settled","aborted":true},{"type":"agent_settled"}]' drive_settle_sequence "$fixture") \
    || fail "suppression sequence drive failed: $out"
  [ "$out" = '{"snapshots":[{"guardCalls":1,"followUps":1},{"guardCalls":1,"followUps":1},{"guardCalls":2,"followUps":2}],"followUpShapesOk":true}' ] \
    || fail "an aborted settle must neither send nor wedge a second follow-up, got '$out'"
  pass "an aborted follow-up consumes its own suppression and the next run still guards"
}

test_guard_sequence_through_pi_runner() {
  if [ -z "$PI_PACKAGE_DIR" ]; then
    echo "skip: no local Pi 1.1.0 package; the runner proof stays out of this run"
    return 0
  fi
  local fixture out
  fixture=$(make_guard_fixture "$TMP_ROOT/guard-runner")
  : > "$fixture/guard-calls"
  out=$(cd "$fixture/proj" && \
    PI_PACKAGE_DIR="$PI_PACKAGE_DIR" \
    FIXTURE_PROJ="$fixture/proj" \
    FM_HOME="$fixture/home" \
    FM_GUARD_CALLS="$fixture/guard-calls" \
    FM_GUARD_EXIT=2 \
    FM_OPERATIONAL_INPUT_SCRIPT="$ROOT/bin/fm-operational-input.sh" \
    SETTLE_SEQUENCE='[{"type":"agent_settled","aborted":true},{"type":"agent_settled"}]' \
    node --input-type=module 2>&1 <<'JS'
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const PI = process.env.PI_PACKAGE_DIR;
const proj = process.env.FIXTURE_PROJ;
const callsFile = process.env.FM_GUARD_CALLS;
const sequence = JSON.parse(process.env.SETTLE_SEQUENCE);

const loader = await import(pathToFileURL(`${PI}/dist/core/extensions/loader.js`).href);
const runnerMod = await import(pathToFileURL(`${PI}/dist/core/extensions/runner.js`).href);
const extMod = await import(`${pathToFileURL(`${proj}/.pi/extensions/fm-primary-turnend-guard.ts`).href}?guard=${Date.now()}`);

const runtime = loader.createExtensionRuntime();
const eventBus = { on: () => () => {}, emit: () => {} };
const ext = await loader.loadExtensionFromFactory(extMod.default, proj, eventBus, runtime);

const followUps = [];
const runner = new runnerMod.ExtensionRunner([ext], runtime, proj, {}, {});
runner.bindCore(
  {
    sendMessage: async () => {},
    sendUserMessage: async (content, options) => { followUps.push({ content, options }); },
    appendEntry: async () => {},
    setSessionName: async () => {},
    getSessionName: async () => undefined,
    setLabel: async () => {},
    getActiveTools: () => [],
    getAllTools: () => [],
    getSettings: () => ({}),
    setActiveTools: () => {},
    refreshTools: () => {},
    getCommands: () => [],
    setModel: async () => {},
    getThinkingLevel: () => undefined,
    setThinkingLevel: async () => {},
  },
  {
    getModel: () => undefined,
    getScopedModels: () => [],
    isIdle: () => true,
    isProjectTrusted: () => true,
    getSignal: () => undefined,
    abort: () => {},
    hasPendingMessages: () => false,
    shutdown: () => {},
    getContextUsage: () => undefined,
    compact: async () => {},
    getSystemPrompt: () => "",
  },
  {},
);

const guardCalls = () => {
  try {
    return readFileSync(callsFile, "utf8").split("\n").filter((line) => line === "guard-ran").length;
  } catch {
    return 0;
  }
};
const snapshots = [];
for (const event of sequence) {
  await runner.emit(event);
  await new Promise((resolve) => setTimeout(resolve, 50));
  snapshots.push({ guardCalls: guardCalls(), followUps: followUps.length });
}
let followUpShapesOk = true;
for (const followUp of followUps) {
  if (followUp.options?.deliverAs !== "followUp" || typeof followUp.content !== "string" || followUp.content.length === 0) {
    followUpShapesOk = false;
  }
}
process.stdout.write(JSON.stringify({ snapshots, followUpShapesOk }));
JS
) || fail "runner sequence drive failed: $out"
  [ "$out" = '{"snapshots":[{"guardCalls":0,"followUps":0},{"guardCalls":1,"followUps":1}],"followUpShapesOk":true}' ] \
    || fail "the real runner must skip the aborted settle and guard the next, got '$out'"
  pass "Pi's own runner skips the aborted settle and guards the next"
}

make_calm_fixture() {  # <name>
  local fixture=$1 lib
  mkdir -p "$fixture/proj/.pi/extensions/lib" "$fixture/proj/node_modules/@earendil-works" "$fixture/home"
  cp "$ROOT/.pi/extensions/fm-calm.ts" "$fixture/proj/.pi/extensions/"
  for lib in fm-calm-assistant-layout.ts fm-calm-preservation.ts fm-calm-operational-user-layout.ts fm-calm-pending-operational-layout.ts fm-calm-visibility.ts fm-calm-working-ship.ts fm-calm-working-ship-sprite.ts fm-operational-input.ts; do
    cp "$ROOT/.pi/extensions/lib/$lib" "$fixture/proj/.pi/extensions/lib/"
  done
  ln -s "$PI_PACKAGE_DIR" "$fixture/proj/node_modules/@earendil-works/pi-coding-agent"
  ln -s "$PI_TUI_DIR" "$fixture/proj/node_modules/@earendil-works/pi-tui"
  ln -s "$TYPEBOX_DIR" "$fixture/proj/node_modules/typebox"
  printf '%s\n' '{"type":"module"}' > "$fixture/proj/package.json"
  printf '%s\n' "$fixture"
}

test_calm_shell_honors_output_pad_zero() {
  if [ -z "$PI_PACKAGE_DIR" ]; then
    echo "skip: no local Pi 1.1.0 package; the calm render proof stays out of this run"
    return 0
  fi
  local fixture out
  fixture=$(make_calm_fixture "$TMP_ROOT/calm-pad")
  out=$(cd "$fixture/proj" && PI_PACKAGE_DIR="$PI_PACKAGE_DIR" FM_HOME="$fixture/home" node --input-type=module 2>&1 <<'JS'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const PI = process.env.PI_PACKAGE_DIR;
const [{ ToolExecutionComponent }, { initTheme }, tui] = await Promise.all([
  import(pathToFileURL(`${PI}/dist/modes/interactive/components/tool-execution.js`).href),
  import(pathToFileURL(`${PI}/dist/modes/interactive/theme/theme.js`).href),
  import("@earendil-works/pi-tui"),
]);
initTheme("dark");
tui.setCapabilities({ images: null, trueColor: true, hyperlinks: false });

const tools = [];
let calmCommand;
const pi = {
  events: { emit() {}, on() {} },
  on() {},
  registerCommand: (name, command) => { if (name === "calm") calmCommand = command; },
  registerEntryRenderer() {},
  registerTool: (tool) => { tools.push(tool); },
  getAllTools: () => [],
};
const extMod = await import(`${pathToFileURL(`./.pi/extensions/fm-calm.ts`).href}?pad=${Date.now()}`);
extMod.default(pi);

const ui = {
  getEditorText: () => "",
  getToolsExpanded: () => false,
  onTerminalInput: () => () => {},
  setHiddenThinkingLabel() {},
  setStatus() {},
  setToolsExpanded() {},
  setWorkingVisible() {},
  notify() {},
};
await calmCommand.handler("", { ui });
await calmCommand.handler("", { ui });

const read = tools.find((tool) => tool.name === "read");
if (!read) throw new Error("the wrapped read tool was not registered");

writeFileSync("sample.txt", "alpha\n");
const renderUi = { requestRender() {} };
const renderRow = (outputPad) => {
  const row = new ToolExecutionComponent(
    "read",
    `read-pad-${String(outputPad)}`,
    { path: "sample.txt" },
    { showImages: false, outputPad },
    read,
    renderUi,
    process.cwd(),
  );
  row.markExecutionStarted();
  row.setArgsComplete();
  row.updateResult({ content: [{ type: "text", text: "alpha" }], details: {}, isError: false });
  return row.render(60).map((line) => line.replace(/\x1b\[[0-9;]*m/g, ""));
};
const pad0 = renderRow(0);
const pad1 = renderRow(1);
const content0 = pad0.find((line) => line.includes("read sample.txt"));
const content1 = pad1.find((line) => line.includes("read sample.txt"));
if (!content0 || !content1) throw new Error(`a wrapped row lost its content: ${JSON.stringify({ pad0, pad1 })}`);
process.stdout.write(JSON.stringify({
  identical: JSON.stringify(pad0) === JSON.stringify(pad1),
  pad0Leading: content0.length - content0.trimStart().length,
  pad1Leading: content1.length - content1.trimStart().length,
}));
JS
) || fail "outputPad row drive failed: $out"
  [ "$out" = '{"identical":false,"pad0Leading":0,"pad1Leading":1}' ] \
    || fail "outputPad 0 must drop the shell padding that outputPad 1 keeps, got '$out'"
  pass "a calm-wrapped row renders with no shell padding under outputPad 0"
}

test_calm_shell_falls_back_to_one_without_output_pad() {
  if [ -z "$PI_PACKAGE_DIR" ]; then
    echo "skip: no local Pi 1.1.0 package; the calm fallback proof stays out of this run"
    return 0
  fi
  local fixture out
  fixture=$(make_calm_fixture "$TMP_ROOT/calm-fallback")
  out=$(cd "$fixture/proj" && PI_PACKAGE_DIR="$PI_PACKAGE_DIR" FM_HOME="$fixture/home" node --input-type=module 2>&1 <<'JS'
import { pathToFileURL } from "node:url";

const PI = process.env.PI_PACKAGE_DIR;
const { initTheme, theme } = await import(pathToFileURL(`${PI}/dist/modes/interactive/theme/theme.js`).href);
initTheme("dark");

const tools = [];
let calmCommand;
const pi = {
  events: { emit() {}, on() {} },
  on() {},
  registerCommand: (name, command) => { if (name === "calm") calmCommand = command; },
  registerEntryRenderer() {},
  registerTool: (tool) => { tools.push(tool); },
  getAllTools: () => [],
};
const extMod = await import(`${pathToFileURL(`./.pi/extensions/fm-calm.ts`).href}?fallback=${Date.now()}`);
extMod.default(pi);

const ui = {
  getEditorText: () => "",
  getToolsExpanded: () => false,
  onTerminalInput: () => () => {},
  setHiddenThinkingLabel() {},
  setStatus() {},
  setToolsExpanded() {},
  setWorkingVisible() {},
  notify() {},
};
await calmCommand.handler("", { ui });
await calmCommand.handler("", { ui });

const read = tools.find((tool) => tool.name === "read");
if (!read) throw new Error("the wrapped read tool was not registered");

const renderShell = async (outputPad) => {
  const context = {
    args: { path: "sample.txt" },
    toolCallId: "call-fallback",
    invalidate() {},
    lastComponent: undefined,
    state: {},
    cwd: process.cwd(),
    executionStarted: true,
    argsComplete: true,
    isPartial: false,
    expanded: true,
    showImages: false,
    isError: false,
    durationMs: undefined,
    ...(outputPad === undefined ? {} : { outputPad }),
  };
  const shell = await read.renderCall({ path: "sample.txt" }, theme, context);
  return shell.render(60).map((line) => line.replace(/\x1b\[[0-9;]*m/g, ""));
};
const absent = await renderShell(undefined);
const one = await renderShell(1);
const zero = await renderShell(0);
process.stdout.write(JSON.stringify({
  absentMatchesOne: JSON.stringify(absent) === JSON.stringify(one),
  zeroDiffers: JSON.stringify(zero) !== JSON.stringify(one),
}));
JS
) || fail "outputPad fallback drive failed: $out"
  [ "$out" = '{"absentMatchesOne":true,"zeroDiffers":true}' ] \
    || fail "a missing outputPad must fall back to stock padding, got '$out'"
  pass "a calm-wrapped shell falls back to stock padding without outputPad"
}

test_pi_1_1_0_is_the_proving_version
test_guard_skips_followup_on_aborted_settle
test_guard_still_follows_up_without_aborted_field
test_guard_still_follows_up_when_not_aborted
test_guard_abort_consumes_exactly_one_suppression
test_guard_sequence_through_pi_runner
test_calm_shell_honors_output_pad_zero
test_calm_shell_falls_back_to_one_without_output_pad

echo "all fm-pi-1-1-0-small-fixes tests passed"
