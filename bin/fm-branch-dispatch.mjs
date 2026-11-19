#!/usr/bin/env node
// fm-branch-dispatch.mjs - the command-line entry to supervision-branch wake
// dispatch, for a host that is not a Pi process (bin/fm-supervision-host.sh,
// docs/supervision-host.md).
//
// It reimplements nothing: .pi/extensions/lib/fm-branch-dispatch.ts stays the
// single owner of which queued rows the branch may claim and of the wake text,
// and this file only prints that module's answers in a shape a shell can read.
// The Pi branch extension and this entry therefore apply identical rules.
//
// Usage:
// Usage: fm-branch-dispatch.mjs scope [--heartbeat] | offer | wake-prompt --report <surface> [--mirror-file <path>]
// repository's own state/. Exit 0 on success, 2 on invalid use, 3 when a
// wake-prompt --mirror-file cannot be read.

import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const dispatch = await import(pathToFileURL(path.join(root, ".pi", "extensions", "lib", "fm-branch-dispatch.ts")).href);

function usage() {
  process.stderr.write(
    "usage: fm-branch-dispatch.mjs scope [--heartbeat] | offer | wake-prompt --report <surface> [--mirror-file <path>]\n",
  );
  process.exit(2);
}

function stateDir() {
  if (process.env.FM_STATE_OVERRIDE) return process.env.FM_STATE_OVERRIDE;
  const home = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
  return path.join(home, "state");
}

function scopeLines(scope, heartbeat) {
  const unscoped = heartbeat;
  return (
    `status=${scope.status}\n` +
    `corrupted=${scope.corrupted ? 1 : 0}\n` +
    `rows=${scope.eligibleSeqs.join(" ")}\n` +
    `tasks=${scope.eligibleTasks.join(" ")}\n` +
    `unscoped=${unscoped ? 1 : 0}\n`
  );
}

const [command, ...args] = process.argv.slice(2);

if (command === "scope") {
  let heartbeat = false;
  for (const arg of args) {
    if (arg === "--heartbeat") heartbeat = true;
    else usage();
  }
  process.stdout.write(scopeLines(dispatch.scopeForUnreadWake(stateDir(), heartbeat), heartbeat));
} else if (command === "offer") {
  if (args.length !== 0) usage();
  const message = readFileSync(0, "utf8").split(/\r?\n/)[0] ?? "";
  const verdict = dispatch.branchOfferForWake(stateDir(), message, true);
  process.stdout.write(`eligible=${verdict.eligible ? 1 : 0}\n${scopeLines(verdict.scope, verdict.heartbeat)}`);
} else if (command === "wake-prompt") {
  let report = "";
  let mirrorFile = "";
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === "--report" && index + 1 < args.length) report = args[++index];
    else if (arg === "--mirror-file" && index + 1 < args.length) mirrorFile = args[++index];
    else usage();
  }
  if (!report) usage();
  const message = readFileSync(0, "utf8").replace(/\n+$/, "");
  let mirror = "";
  if (mirrorFile) {
    try {
      mirror = readFileSync(mirrorFile, "utf8");
    } catch {
      process.stderr.write(`fm-branch-dispatch.mjs: the dialog mirror feed ${mirrorFile} could not be read\n`);
      process.exit(3);
    }
  }
  process.stdout.write(`${dispatch.branchWakePrompt(message, report, mirror)}\n`);
} else {
  usage();
}
