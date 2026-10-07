#!/usr/bin/env node
// Semantic policy for the cd-guard: does a shell command persistently change the
// PRIMARY firstmate shell's own working directory?
//
// A stray persistent top-level `cd projects/<clone>` silently relocates the
// primary shell, so the next firstmate-owned command (a backlog write, an
// fm-* lifecycle call, tasks-axi) runs inside a project clone instead of the
// home. This policy blocks exactly that class of command; the environmental
// scoping to the real primary checkout lives in the bin/fm-cd-pretool-check.sh
// transport, not here. See docs/cd-guard.md for the full contract.
//
// The shell tokenizer and command-position analysis are imported from
// bin/fm-arm-command-policy.mjs, the sole owner of firstmate's shell
// classification, so this guard never duplicates shell lexing. This policy
// never evaluates, expands, sources, or runs any byte of the submitted command;
// it inspects lexical command positions only.

import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";
import path from "node:path";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

const REASONS = {
  "persistent-cd":
    "a persistent top-level directory change in the primary firstmate checkout is blocked; it would move the shell out of the home so a later firstmate-owned command runs inside a project clone. Reach the target without moving the shell - use git -C <dir> or an absolute path on the command itself - or scope the cd to a subshell like (cd <dir> && ...).",
};

// Directory-changing builtins that mutate the calling shell's own cwd.
const CD_BUILTINS = new Set(["cd", "pushd", "popd"]);

// Wrappers that fork or exec a child before reaching the builtin, so a cd behind
// them never persists to the parent shell (and generally just fails, since cd is
// a builtin with no external program). `command` is deliberately NOT here: it
// runs the builtin in the current shell, so `command cd x` still persists.
const FORKING_WRAPPERS = new Set(["env", "sudo", "nohup", "timeout", "gtimeout", "exec"]);

function isPipe(separator) {
  return separator === "|" || separator === "|&";
}

// A top-level command-list node persists its cwd change to the parent shell
// unless it runs in a subshell context: backgrounded with a trailing `&`, or a
// stage of a pipeline (bash runs every pipeline stage in a subshell).
function nodePersists(separators, index) {
  if (separators[index] === "&") return false;
  if (isPipe(separators[index]) || isPipe(separators[index - 1])) return false;
  return true;
}

function deny(code) {
  return { decision: "deny", code, reason: REASONS[code] };
}

// A cd/pushd to the primary checkout root is already home: allowing it avoids
// a wasted tool round-trip for the redundant return-to-home agents emit.
function isHomeTarget(words, homeReal) {
  if (!homeReal) return false;
  let targets = words;
  if (targets.length > 0 && targets[0].value === "--" && targets[0].literal && targets[0].subs.length === 0) targets = targets.slice(1);
  if (targets.length !== 1) return false;
  const word = targets[0];
  if (!word.literal || word.subs.length > 0 || word.unquotedExpansion) return false;
  if (!path.isAbsolute(word.value)) return false;
  try {
    return realpathSync(word.value) === homeReal;
  } catch {
    return false;
  }
}

function hasPathQualifiedCommandPrefix(position) {
  return position.words
    .slice(position.prefixAssignments, position.index)
    .some((word) => word.value.includes("/") && word.value.split("/").at(-1) === "command");
}

function hasCommandQueryPrefix(position) {
  let commandPrefix = false;
  for (const word of position.words.slice(position.prefixAssignments, position.index)) {
    if (word.value === "command") {
      commandPrefix = true;
      continue;
    }
    if (commandPrefix && /^-[^-]*[vV]/.test(word.value)) return true;
  }
  return false;
}

function decision(command, home) {
  const lexed = new Lexer(command).tokenize();
  // Fail open on syntax this classifier cannot tokenize. The cd-guard's threat
  // model is agent mistakes - an accidental bare `cd projects/foo` always
  // tokenizes - so we prioritize zero false blocks over catching malformed or
  // deliberately obfuscated bypasses, which stay out of scope by design.
  if (lexed.error) return { decision: "allow" };
  let homeReal = "";
  if (home) {
    try {
      homeReal = realpathSync(home);
    } catch {
      homeReal = "";
    }
  }

  const { nodes, separators } = splitProgram(lexed.tokens);
  for (let index = 0; index < nodes.length; index += 1) {
    if (!nodePersists(separators, index)) continue;
    // commandPosition ignores subshell/brace groups, quoted data, comments, and
    // substitutions (they contribute no top-level command word), and skips
    // leading assignments and wrappers to find the executed command word.
    const position = commandPosition(nodes[index]);
    if (hasPathQualifiedCommandPrefix(position)) continue;
    if (hasCommandQueryPrefix(position)) continue;
    let commandWord = position.command;
    let wordIndex = position.index;
    while (commandWord && (commandWord.value === "builtin" || commandWord.value === "command")) {
      wordIndex += 1;
      commandWord = position.words[wordIndex];
    }
    if (!commandWord) continue;
    if (!CD_BUILTINS.has(commandWord.value)) continue;
    if (position.wrappers.some((wrapper) => FORKING_WRAPPERS.has(wrapper))) continue;
    if ((commandWord.value === "cd" || commandWord.value === "pushd") && isHomeTarget(position.words.slice(wordIndex + 1), homeReal)) continue;
    return deny("persistent-cd");
  }
  return { decision: "allow" };
}

function parseArguments(argv) {
  const result = { command: "", commandSet: false, home: "" };
  for (let i = 0; i < argv.length; i += 1) {
    const name = argv[i];
    if (name === "--command" || name === "--home") {
      if (i + 1 >= argv.length) throw new Error(`${name} requires a value`);
      result[name.slice(2)] = argv[i + 1];
      if (name === "--command") result.commandSet = true;
      i += 1;
      continue;
    }
    if (name.startsWith("--command=")) {
      result.command = name.slice("--command=".length);
      result.commandSet = true;
      continue;
    }
    if (name.startsWith("--home=")) {
      result.home = name.slice("--home=".length);
      continue;
    }
    throw new Error(`unknown argument: ${name}`);
  }
  return result;
}

function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  const self = fileURLToPath(import.meta.url);
  try {
    return realpathSync(entry) === realpathSync(self);
  } catch {
    return entry === self;
  }
}

if (invokedDirectly()) {
  try {
    const args = parseArguments(process.argv.slice(2));
    if (!args.commandSet || !args.command) {
      process.stdout.write("allow\n");
    } else {
      const result = decision(args.command, args.home);
      if (result.decision === "allow") {
        process.stdout.write("allow\n");
      } else {
        process.stdout.write(`deny\t${result.code}\t${result.reason}\n`);
      }
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

export { decision };
