import { Effect, Schema } from "effect";
import { Lexer, splitProgram, commandPosition } from "../fm-arm-command-policy.mjs";
import { readFileSync, statSync } from "node:fs";
import { isAbsolute, normalize, resolve } from "node:path";

class PolicyInputError extends Schema.TaggedError<PolicyInputError>()("PolicyInputError", {
  detail: Schema.String
}) {}

class ApprovalStoreError extends Schema.TaggedError<ApprovalStoreError>()("ApprovalStoreError", {
  detail: Schema.String
}) {}

class ShareRefused extends Schema.TaggedError<ShareRefused>()("ShareRefused", {
  code: Schema.String,
  reason: Schema.String
}) {}

interface LexSubstitution {
  readonly kind: string;
  readonly content: string;
}

interface LexWord {
  readonly type: "word";
  readonly value: string;
  readonly literal: boolean;
  readonly quoted: boolean;
  readonly unquotedExpansion: boolean;
  readonly subs: ReadonlyArray<LexSubstitution>;
}

interface LexRedirect {
  readonly type: "redir";
  readonly value: string;
  readonly inlineTarget: boolean;
  readonly fd: number;
  readonly heredoc?: string;
}

interface LexGroup {
  readonly type: "group";
  readonly kind: string;
  readonly content: string;
}

interface LexOp {
  readonly type: "op";
  readonly value: string;
}

type LexToken = LexWord | LexRedirect | LexGroup | LexOp;

interface LexPosition {
  readonly words: ReadonlyArray<LexWord>;
  readonly index: number;
  readonly command: LexWord | undefined;
  readonly wrappers: ReadonlyArray<string>;
  readonly prefixAssignments: number;
  readonly unresolvedWrapperOption: boolean;
  readonly wrapperPayloads: ReadonlyArray<string>;
}

const isLexWord = (token: LexToken): token is LexWord =>
  token.type === "word" && typeof token.value === "string" && Array.isArray((token as LexWord).subs);

const lowerBase = (value: string): string =>
  value.toLowerCase().split(/[\\/]/).filter((part) => part.length > 0).at(-1) ?? value.toLowerCase();

type PublishTarget =
  | { readonly kind: "file"; readonly path: string }
  | { readonly kind: "site"; readonly id: string };

type ScanResult =
  | { readonly kind: "clean" }
  | { readonly kind: "attempt"; readonly candidates: ReadonlyArray<PublishTarget> }
  | { readonly kind: "unclassifiable" };

const SHARE_BINARIES = new Set(["lavish-axi", "lavish"]);
const TRANSPARENT_RUNNERS = new Set(["npx", "bunx", "yarn", "pnpm", "dlx", "mise"]);
const SHELLS = new Set(["sh", "bash", "zsh", "dash"]);
const INTERPRETERS = new Set(["node", "bun", "deno", "python", "python3", "ruby", "perl", "php"]);
const FETCHERS = new Set(["curl", "wget"]);
const MAX_DEPTH = 5;
const APPROVAL_TTL_SECONDS = 1800;
const FUTURE_SKEW_SECONDS = 300;

const hasStrongMarkers = (text: string): boolean => /lavish/i.test(text) || /ht-ml/i.test(text);

const mergeScan = (left: ScanResult, right: ScanResult): ScanResult => {
  if (left.kind === "attempt" && right.kind === "attempt") {
    return { kind: "attempt", candidates: [...left.candidates, ...right.candidates] };
  }
  if (left.kind === "attempt") return left;
  if (right.kind === "attempt") return right;
  if (left.kind === "unclassifiable" || right.kind === "unclassifiable") return { kind: "unclassifiable" };
  return { kind: "clean" };
};

const scanWords = (words: ReadonlyArray<LexWord>, from: number, scan: (text: string, depth: number) => ScanResult, depth: number): ScanResult => {
  let result: ScanResult = { kind: "clean" };
  for (let i = from; i < words.length; i += 1) {
    for (const sub of words[i].subs) {
      result = mergeScan(result, scan(sub.content, depth + 1));
    }
  }
  return result;
};

const findSubcommand = (words: ReadonlyArray<LexWord>, from: number): { index: number; value: string } | undefined => {
  let i = from;
  while (i < words.length) {
    const word = words[i];
    if (!word.literal || word.subs.length > 0) return undefined;
    if (word.value.length === 0) {
      i += 1;
      continue;
    }
    if (word.value.startsWith("-") && word.value.length > 1) {
      i += flagTakesValue(word.value) ? 2 : 1;
      continue;
    }
    return { index: i, value: word.value };
  }
  return undefined;
};

const flagTakesValue = (flag: string): boolean =>
  flag === "--site" || flag === "--update-key" || flag === "--token" || flag === "--password" || flag === "-X" || flag === "--request" || flag === "-e" || flag === "--eval" || flag === "-c" || flag === "-r";

const extractLavishCandidates = (words: ReadonlyArray<LexWord>, from: number): ReadonlyArray<PublishTarget> => {
  const candidates: Array<PublishTarget> = [];
  let site: string | undefined;
  let index = from;
  while (index < words.length) {
    const word = words[index];
    if (!word.literal || word.subs.length > 0) {
      index += 1;
      continue;
    }
    const value = word.value;
    if (value === "--unpublish") {
      index += 1;
      continue;
    }
    if (value === "--site" && index + 1 < words.length) {
      site = words[index + 1].value;
      index += 2;
      continue;
    }
    const siteEquals = value.match(/^--site=(.+)$/);
    if (siteEquals?.[1]) {
      site = siteEquals[1];
      index += 1;
      continue;
    }
    if (flagTakesValue(value)) {
      index += 2;
      continue;
    }
    if (value.startsWith("-") && value.length > 1) {
      index += 1;
      continue;
    }
    if (value.length > 0) {
      candidates.push({ kind: "file", path: value });
      index += 1;
      continue;
    }
    index += 1;
  }
  if (candidates.length === 0 && site !== undefined && site.length > 0) {
    candidates.push({ kind: "site", id: site });
  }
  return candidates;
};

const CURL_UPLOAD_FLAGS = new Set([
  "-d", "--data", "--data-raw", "--data-ascii", "--data-binary", "--data-urlencode",
  "--json", "-F", "--form", "--form-string", "-T", "--upload-file", "--post-data", "--post-file"
]);

interface FetcherSignal {
  readonly upload: boolean;
  readonly candidates: ReadonlyArray<PublishTarget>;
}

const extractCurlCandidates = (words: ReadonlyArray<LexWord>, from: number, tool: string): FetcherSignal => {
  let upload = false;
  let method = "";
  let site: string | undefined;
  const files: Array<string> = [];
  let index = from;
  while (index < words.length) {
    const word = words[index];
    if (!word.literal || word.subs.length > 0) {
      index += 1;
      continue;
    }
    const value = word.value;
    const lower = value.toLowerCase();
    const hostAt = lower.indexOf("ht-ml");
    if (hostAt !== -1) {
      const segment = value.slice(hostAt).match(/ht-ml[^/\s]*\/([^\s/?#]+)/i);
      if (segment?.[1]) site = segment[1];
      else upload = upload || tool === "wget";
      index += 1;
      continue;
    }
    if (tool === "curl" && CURL_UPLOAD_FLAGS.has(value)) {
      upload = true;
      const operand = words[index + 1];
      if (operand?.literal && operand.subs.length === 0) {
        const file = fileOperand(operand.value);
        if (file !== undefined) files.push(file);
      }
      index += 2;
      continue;
    }
    if (tool === "curl") {
      const joined = value.match(/^--([a-z-]+)=([\s\S]*)$/);
      if (joined && CURL_UPLOAD_FLAGS.has(`--${joined[1]}`)) {
        upload = true;
        const file = fileOperand(joined[2]);
        if (file !== undefined) files.push(file);
        index += 1;
        continue;
      }
      if (joined?.[1] === "request") {
        method = joined[2].toUpperCase();
        index += 1;
        continue;
      }
      const shortD = value.match(/^-d([\s\S]+)$/);
      if (shortD) {
        upload = true;
        const file = fileOperand(shortD[1]);
        if (file !== undefined) files.push(file);
        index += 1;
        continue;
      }
      const shortF = value.match(/^-F([\s\S]+)$/);
      if (shortF) {
        upload = true;
        const file = shortF[1].match(/@([^;,\s]+)/)?.[1];
        if (file !== undefined) files.push(file);
        index += 1;
        continue;
      }
    }
    if (tool === "wget" && (value === "--post-data" || value === "--post-file")) {
      upload = true;
      if (value === "--post-file" && index + 1 < words.length) {
        files.push(words[index + 1].value);
      }
      index += value === "--post-file" ? 2 : 1;
      continue;
    }
    if (tool === "wget") {
      const joinedFile = value.match(/^--post-file=([\s\S]+)$/)?.[1];
      if (joinedFile !== undefined) {
        upload = true;
        files.push(joinedFile);
        index += 1;
        continue;
      }
      if (/^--post-data=[\s\S]*$/.test(value)) {
        upload = true;
        index += 1;
        continue;
      }
      const methodFlag = value.match(/^--method=(.+)$/i)?.[1];
      if (methodFlag) {
        method = methodFlag.toUpperCase();
        index += 1;
        continue;
      }
    }
    if ((value === "-X" || value === "--request") && index + 1 < words.length) {
      method = words[index + 1].value.toUpperCase();
      index += 2;
      continue;
    }
    index += 1;
  }
  const writes = upload || method === "POST" || method === "PUT" || method === "PATCH" || method === "DELETE";
  if (!writes) return { upload: false, candidates: [] };
  const candidates: Array<PublishTarget> = files.map((path) => ({ kind: "file" as const, path }));
  if (site !== undefined) candidates.push({ kind: "site", id: site });
  return { upload: true, candidates };
};

const fileOperand = (operand: string): string | undefined =>
  operand.startsWith("@") && operand !== "@-" ? operand.slice(1) : undefined;

const UPLOAD_TOKENS = /post|put\b|upload|fetch\s*\(|axios|requests?\.\s*(post|put|patch|delete|request)\s*\(|urlopen\s*\([^)]*\bdata\s*=|http\.request|multipart|--data|\b-F\b|upload-file/i;

const inlineCodePublishes = (code: string): boolean => /ht-ml/i.test(code) && UPLOAD_TOKENS.test(code);

const LAVISH_SHARE_TEXT = /(?:^|[^\w-])lavish(?:-axi)?(?=[\s"'])(?:[^\n;|&]|\\\n)*?[\s"']share(?=[\s"';|&)]|$)/im;

const textSignalsPublish = (text: string): boolean => {
  if (LAVISH_SHARE_TEXT.test(text)) return true;
  return /ht-ml/i.test(text) && UPLOAD_TOKENS.test(text);
};

const scanScriptFile = (path: string, scan: (text: string, depth: number) => ScanResult, depth: number): ScanResult => {
  let content = "";
  try {
    content = readFileSync(path, "utf8");
  } catch {
    return { kind: "clean" };
  }
  const byText: ScanResult = textSignalsPublish(content) ? { kind: "attempt", candidates: [{ kind: "file", path }] } : { kind: "clean" };
  // The command lexer cannot read most whole scripts, so a mention alone would refuse every script naming lavish.
  if (content.length > 262144) return byText;
  const inner = scan(content, depth + 1);
  if (inner.kind === "attempt" && inner.candidates.length > 0) return inner;
  return byText;
};

const scanShellNode = (position: LexPosition, node: ReadonlyArray<LexToken>, scan: (text: string, depth: number) => ScanResult, depth: number): ScanResult => {
  let result: ScanResult = { kind: "clean" };
  const words = position.words;
  for (let i = position.index + 1; i < words.length; i += 1) {
    const word = words[i];
    if (!word.literal || word.subs.length > 0) continue;
    if (/^-[A-Za-z]*c[A-Za-z]*$/.test(word.value)) {
      let payloadIndex = i + 1;
      if (words[payloadIndex]?.value === "--") payloadIndex += 1;
      const payload = words[payloadIndex];
      if (payload && payload.subs.length === 0) {
        result = mergeScan(result, scan(payload.value, depth + 1));
      } else if (payload && words.slice(0, i).some((earlier) => /lavish|share|ht-ml/i.test(earlier.value))) {
        return { kind: "unclassifiable" };
      }
      i = payloadIndex;
      continue;
    }
    if (word.value === "--") continue;
    if (/^-/.test(word.value)) continue;
    const operand = word.value;
    if (operand.length === 0) continue;
    try {
      const resolved = resolve(process.cwd(), operand);
      result = mergeScan(result, scanScriptFile(resolved, scan, depth));
    } catch {
      result = mergeScan(result, { kind: "clean" });
    }
    break;
  }
  for (const token of node) {
    if (token.type !== "redir") continue;
    if (token.fd !== 0) continue;
    if (typeof token.heredoc === "string") {
      result = mergeScan(result, scan(token.heredoc, depth + 1));
    } else if (token.inlineTarget) {
      const target = node[node.indexOf(token) + 1];
      if (target && isLexWord(target) && target.subs.length === 0) {
        result = mergeScan(result, scan(target.value, depth + 1));
      }
    }
  }
  return result;
};

const scanInterpreterNode = (position: LexPosition, tool: string, scan: (text: string, depth: number) => ScanResult, depth: number): ScanResult => {
  let result: ScanResult = { kind: "clean" };
  const words = position.words;
  let index = position.index + 1;
  if (tool === "deno" && words[index]?.value === "eval") index += 1;
  while (index < words.length) {
    const word = words[index];
    if (!word.literal || word.subs.length > 0) {
      index += 1;
      continue;
    }
    if ((word.value === "-e" || word.value === "--eval" || word.value === "-c" || word.value === "-r") && index + 1 < words.length) {
      const code = words[index + 1];
      if (code.subs.length === 0 && inlineCodePublishes(code.value)) {
        const site = code.value.match(/ht-ml[^/\\s]*\/([^\s"'/?#]+)/i)?.[1];
        const candidates: Array<PublishTarget> = site ? [{ kind: "site", id: site }] : [];
        result = mergeScan(result, { kind: "attempt", candidates });
      }
      index += 2;
      continue;
    }
    if (word.value.startsWith("-") && word.value.length > 1) {
      index += 1;
      continue;
    }
    if (word.value.length === 0) {
      index += 1;
      continue;
    }
    try {
      const resolved = resolve(process.cwd(), word.value);
      result = mergeScan(result, scanScriptFile(resolved, scan, depth));
    } catch {
      result = mergeScan(result, { kind: "clean" });
    }
    break;
  }
  return result;
};

const scanNode = (node: ReadonlyArray<LexToken>, scan: (text: string, depth: number) => ScanResult, depth: number): ScanResult => {
  let result: ScanResult = { kind: "clean" };
  for (const token of node) {
    if (token.type === "group") {
      result = mergeScan(result, scan(token.content, depth + 1));
    }
  }
  const words = node.filter(isLexWord);
  result = mergeScan(result, scanWords(words, 0, scan, depth));
  let position: LexPosition | undefined;
  try {
    position = commandPosition(node as Array<{ type: string }>) as unknown as LexPosition;
  } catch {
    return hasStrongMarkers(node.map((token) => (isLexWord(token) ? token.value : "")).join(" ")) ? { kind: "unclassifiable" } : result;
  }
  if (!position || !position.command || typeof position.command.value !== "string") return result;
  for (const payload of position.wrapperPayloads ?? []) {
    result = mergeScan(result, scan(payload, depth + 1));
  }
  const tool = lowerBase(position.command.value);
  if (tool.length === 0) return result;
  if (SHARE_BINARIES.has(tool)) {
    const subcommand = findSubcommand(position.words, position.index + 1);
    if (subcommand?.value.toLowerCase() === "share") {
      return mergeScan(result, { kind: "attempt", candidates: extractLavishCandidates(position.words, subcommand.index + 1) });
    }
    return result;
  }
  if (TRANSPARENT_RUNNERS.has(tool)) {
    for (let i = position.index + 1; i < position.words.length; i += 1) {
      const word = position.words[i];
      if (!word.literal || word.subs.length > 0) continue;
      if (!SHARE_BINARIES.has(lowerBase(word.value))) continue;
      const subcommand = findSubcommand(position.words, i + 1);
      if (subcommand?.value.toLowerCase() === "share") {
        return mergeScan(result, { kind: "attempt", candidates: extractLavishCandidates(position.words, subcommand.index + 1) });
      }
    }
    return result;
  }
  if (FETCHERS.has(tool)) {
    const signal = extractCurlCandidates(position.words, position.index + 1, tool);
    const mentionsHost = position.words.some((word) => word.literal && /ht-ml/i.test(word.value));
    if (mentionsHost && signal.upload) {
      return mergeScan(result, { kind: "attempt", candidates: signal.candidates });
    }
    return result;
  }
  if (SHELLS.has(tool)) {
    return mergeScan(result, scanShellNode(position, node, scan, depth));
  }
  if (tool === "eval") {
    for (let i = position.index + 1; i < position.words.length; i += 1) {
      const word = position.words[i];
      if (word.subs.length === 0) {
        result = mergeScan(result, scan(word.value, depth + 1));
      }
    }
    return result;
  }
  if (INTERPRETERS.has(tool)) {
    return mergeScan(result, scanInterpreterNode(position, tool, scan, depth));
  }
  return result;
};

const scanProgram = Effect.fnUntraced(function* (text: string, depth: number): ScanResult {
  if (depth > MAX_DEPTH) {
    return hasStrongMarkers(text) ? { kind: "unclassifiable" } : { kind: "clean" };
  }
  let tokens: Array<LexToken>;
  try {
    const lexed = new Lexer(text).tokenize() as unknown as { tokens: Array<LexToken>; error: string };
    if (typeof lexed.error === "string" && lexed.error.length > 0) {
      return hasStrongMarkers(text) ? { kind: "unclassifiable" } : { kind: "clean" };
    }
    tokens = lexed.tokens;
  } catch {
    return hasStrongMarkers(text) ? { kind: "unclassifiable" } : { kind: "clean" };
  }
  let program: { nodes: Array<Array<LexToken>> };
  try {
    program = splitProgram(tokens as Array<{ type: string }>) as unknown as { nodes: Array<Array<LexToken>> };
  } catch {
    return hasStrongMarkers(text) ? { kind: "unclassifiable" } : { kind: "clean" };
  }
  const scan = (inner: string, innerDepth: number): ScanResult => Effect.runSync(scanProgram(inner, innerDepth));
  let result: ScanResult = { kind: "clean" };
  for (const node of program.nodes) {
    result = mergeScan(result, scanNode(node, scan, depth));
  }
  return result;
});

interface ApprovalEntry {
  readonly at: number;
  readonly target: string;
}

const parseApprovalLine = (line: string): ApprovalEntry | undefined => {
  const match = line.match(/^\s*(\d+)\s+(\S(?:.*\S)?)\s*$/);
  if (!match) return undefined;
  const at = Number.parseInt(match[1], 10);
  if (!Number.isSafeInteger(at)) return undefined;
  return { at, target: match[2] };
};

const normalizeTarget = (target: string): string => {
  if (target.startsWith("site:")) return target;
  const trimmed = target.trim();
  if (trimmed.startsWith("site:")) return trimmed;
  const absolute = isAbsolute(trimmed) ? trimmed : resolve(process.cwd(), trimmed);
  return normalize(absolute);
};

const candidateKey = (candidate: PublishTarget): string =>
  candidate.kind === "site" ? `site:${candidate.id}` : normalizeTarget(candidate.path);

const readApprovalEntries = Effect.fn("readApprovalEntries")(function* (home: string) {
  const lines = yield* Effect.try({
    try: () => readFileSync(`${home}/state/lavish-share-approvals`, "utf8").split("\n"),
    catch: () => new ApprovalStoreError({ detail: "approval store unreadable" })
  });
  return lines.map(parseApprovalLine).filter((entry): entry is ApprovalEntry => entry !== undefined);
});

const checkCandidate = Effect.fn("checkCandidate")(function* (candidate: PublishTarget, home: string, nowSeconds: number, fileEntries: ReadonlyArray<ApprovalEntry>) {
  const key = candidateKey(candidate);
  const sessionRaw = process.env.FM_LAVISH_SHARE_APPROVED ?? "";
  const sessionTargets = sessionRaw.split(/\r?\n/).map((line) => line.trim()).filter((line) => line.length > 0);
  if (sessionTargets.some((target) => normalizeTarget(target) === key)) return true;
  for (const entry of fileEntries) {
    if (normalizeTarget(entry.target) !== key) continue;
    if (entry.at > nowSeconds + FUTURE_SKEW_SECONDS) continue;
    if (nowSeconds - entry.at > APPROVAL_TTL_SECONDS) continue;
    if (candidate.kind === "site") return true;
    const mtime = yield* Effect.try({
      try: () => Math.floor(statSync(normalizeTarget(candidate.path)).mtimeMs / 1000),
      catch: () => new ApprovalStoreError({ detail: "share target unreadable" })
    }).pipe(Effect.option);
    if (mtime._tag === "None") continue;
    if (entry.at >= mtime.value) return true;
  }
  return false;
});

const confirmMessage = (display: string): string =>
  `share-guard: refusing to publish ${display} to ht-ml.app without the captain's in-the-moment confirmation. ` +
  `Ask the captain to confirm this exact share; after an explicit yes, record it with ` +
  `'printf "%s %s\\n" "$(date +%s)" "<absolute path or site:<id>>" >> "$FM_HOME/state/lavish-share-approvals"' ` +
  `or export FM_LAVISH_SHARE_APPROVED="<absolute path or site:<id>>", then re-run. ` +
  `File approvals cover the exact bytes for 30 minutes.`;

const decide = Effect.fn("decide")(function* (command: string, home: string) {
  const scan = yield* scanProgram(command, 0);
  if (scan.kind === "clean") return "allow\n";
  if (scan.kind === "unclassifiable") {
    return yield* new ShareRefused({
      code: "share-unclassifiable",
      reason: `${confirmMessage("this command")} The command mentions a share target but its shape cannot be classified, so it stays refused.`
    });
  }
  const nowSeconds = Math.floor(Date.now() / 1000);
  const fileEntries = yield* readApprovalEntries(home).pipe(
    Effect.catchTag("ApprovalStoreError", () => Effect.succeed([] as ReadonlyArray<ApprovalEntry>))
  );
  if (scan.candidates.length === 0) {
    return yield* new ShareRefused({
      code: "share-unresolved",
      reason: `${confirmMessage("this publish")} No share target could be read from the command, so name the exact file or site:<id> in the approval.`
    });
  }
  for (const candidate of scan.candidates) {
    const approved = yield* checkCandidate(candidate, home, nowSeconds, fileEntries);
    if (approved) return "allow\n";
  }
  const display = scan.candidates.map((candidate) => candidate.kind === "site" ? `site:${candidate.id}` : candidate.path).join(", ");
  return yield* new ShareRefused({
    code: "share-unapproved",
    reason: confirmMessage(display)
  });
});

const parseArgs = (argv: ReadonlyArray<string>): Effect.Effect<{ command: string; root: string; home: string }, PolicyInputError> =>
  Effect.try({
    try: () => {
      let command = "";
      let root = "";
      let home = "";
      for (let i = 0; i < argv.length; i += 1) {
        const name = argv[i];
        if (name === "--command" || name === "--root" || name === "--home") {
          if (i + 1 >= argv.length) throw new Error(`${name} requires a value`);
          const value = argv[i + 1];
          if (name === "--command") command = value;
          if (name === "--root") root = value;
          if (name === "--home") home = value;
          i += 1;
          continue;
        }
        if (name === "--help" || name === "-h") {
          process.stdout.write("Usage: policy.ts --command <cmd> --root <root> --home <home>\n");
          process.exit(0);
        }
        throw new Error(`unknown argument: ${name}`);
      }
      if (root.length === 0 || home.length === 0) throw new Error("--root and --home are required");
      return { command, root, home };
    },
    catch: (cause) => new PolicyInputError({ detail: cause instanceof Error ? cause.message : String(cause) })
  });

const policyMain = Effect.gen(function* () {
  const args = yield* parseArgs(process.argv.slice(2)).pipe(Effect.catchTag("PolicyInputError", () => Effect.succeed(undefined)));
  if (args === undefined) return "allow\n";
  if (args.command.length === 0) return "allow\n";
  const outcome = yield* decide(args.command, args.home).pipe(
    Effect.catchTags({
      ShareRefused: (refused) => Effect.succeed(`deny\t${refused.code}\t${refused.reason}\n`),
      ApprovalStoreError: () => Effect.succeed("allow\n")
    })
  );
  return outcome;
});

const runnable = policyMain.pipe(Effect.catch(() => Effect.succeed("allow\n")));
process.stdout.write(Effect.runSync(runnable));
