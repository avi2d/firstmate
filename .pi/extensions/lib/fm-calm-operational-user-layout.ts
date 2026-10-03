// Throws when Pi lacks the patched seam, so the caller can skip only this adapter.
import { basename } from "node:path";
import type {
  Theme,
  UserMessageComponent as PiUserMessageComponent,
} from "@earendil-works/pi-coding-agent";
import * as PiCodingAgent from "@earendil-works/pi-coding-agent";
import { truncateToWidth, visibleWidth, type TuiMouseEvent } from "@earendil-works/pi-tui";
import { calmPresentationHides } from "./fm-calm-visibility.ts";
import {
  firstmateOperationalPresentation,
  firstmateSteeringDoorbellLine,
  type FirstmateCurrentOperationalKind,
} from "./fm-operational-input.ts";

type UserMessageConstructorArgs = ConstructorParameters<typeof PiUserMessageComponent>;
type MouseDispatchResult = ReturnType<PiUserMessageComponent["handleMouse"]>;
type UserMessageLike = {
  role: string;
  content: unknown;
};
type AddMessageOptions = {
  populateHistory?: boolean;
};
type InteractiveModePresentation = {
  chatContainer: {
    children: unknown[];
    addChild(component: PiUserMessageComponent): void;
  };
  editor: {
    addToHistory?(text: string): void;
  };
  getMarkdownThemeWithSettings(): UserMessageConstructorArgs[1];
  getMarkdownTransformers?(): UserMessageConstructorArgs[3];
  getUserMessageText(message: UserMessageLike): string;
  outputPad: number;
  toolOutputExpanded?: boolean;
};
type InteractiveModePrototype = {
  addMessageToChat(
    this: InteractiveModePresentation,
    message: UserMessageLike,
    options?: AddMessageOptions,
  ): void;
};

export type FirstmateOperationalRowKind = FirstmateCurrentOperationalKind | "steering-doorbell";

export type FirstmateOperationalRow = {
  kind: FirstmateOperationalRowKind;
  identity: string;
};

type CalmOperationalUserLayoutPatch = {
  hidesOperationalInput: () => boolean;
  classifyOperationalRow: (text: string) => FirstmateOperationalRow | undefined;
  theme?: Theme;
};

const OPERATIONAL_ROW_LABELS = {
  "session-start": "session start",
  watcher: "watcher wake",
  "turn-end-guard": "turn-end guard",
  "away-supervisor": "away supervisor",
  "from-firstmate": "from firstmate",
  "launch-brief": "launch brief",
  "branch-outcome": "supervision request",
  "steering-doorbell": "steering doorbell",
} satisfies Record<FirstmateOperationalRowKind, string>;

// The steering doorbell is a plain line a person could also type, so Calm hides only
// marker-carried input and the doorbell is collapsed but never hidden.
function calmMayHideOperationalRow(row: FirstmateOperationalRow): boolean {
  return row.kind !== "steering-doorbell";
}

// Keep the introduction-version symbol stable so a compatible upgrade cannot
// double-patch a live process.
const CALM_OPERATIONAL_USER_LAYOUT_PATCH = Symbol.for(
  "firstmate:calm-operational-user-layout:pi-1.0.0",
);

function contentIsTextOnly(content: unknown): boolean {
  if (typeof content === "string") return true;
  if (!Array.isArray(content) || content.length === 0) return false;
  return content.every(
    (block) =>
      typeof block === "object" &&
      block !== null &&
      (block as { type?: unknown }).type === "text" &&
      typeof (block as { text?: unknown }).text === "string",
  );
}

function launchedTaskId(): string | undefined {
  const inbox = process.env.FM_TASK_INBOX?.replace(/\/+$/, "");
  if (!inbox) return undefined;
  const name = basename(inbox);
  return name.endsWith(".inbox") ? name.slice(0, -".inbox".length) : name;
}

function firstLineOf(body: string): string {
  for (const line of body.split("\n")) {
    const text = line.replace(/^\s*#+\s*/, "").replace(/\s+/g, " ").trim();
    if (text) return text;
  }
  return "";
}

function operationalRowIdentity(kind: FirstmateOperationalRowKind, body: string): string {
  if (kind === "launch-brief" || kind === "steering-doorbell") {
    return launchedTaskId() ?? firstLineOf(body);
  }
  return firstLineOf(body);
}

export function classifyFirstmateOperationalRow(text: string): FirstmateOperationalRow | undefined {
  const presentation = firstmateOperationalPresentation(text);
  if (presentation) {
    return {
      kind: presentation.kind,
      identity: operationalRowIdentity(presentation.kind, presentation.body),
    };
  }
  const doorbell = firstmateSteeringDoorbellLine();
  if (doorbell !== undefined && text === doorbell) {
    return { kind: "steering-doorbell", identity: operationalRowIdentity("steering-doorbell", "") };
  }
  return undefined;
}

type CollapsedRowStyle = {
  label: (text: string) => string;
  identity: (text: string) => string;
  hint: (text: string) => string;
};

function collapsedRowStyle(theme: Theme | undefined): CollapsedRowStyle {
  if (!theme) return { label: (text) => text, identity: (text) => text, hint: (text) => text };
  return {
    label: (text) => theme.fg("customMessageLabel", theme.bold(text)),
    identity: (text) => theme.fg("muted", text),
    hint: (text) => theme.fg("dim", text),
  };
}

const IDENTITY_SEPARATOR = " · ";
const MIN_IDENTITY_WIDTH = 8;

function renderCollapsedOperationalRow(
  row: FirstmateOperationalRow,
  width: number,
  outputPad: number,
  expandKey: string,
  theme?: Theme,
): string {
  const style = collapsedRowStyle(theme);
  const pad = " ".repeat(Math.max(0, outputPad));
  const available = Math.max(1, width - 2 * pad.length);
  const label = `[firstmate] ${OPERATIONAL_ROW_LABELS[row.kind]}`;
  const hint = ` (${expandKey} to expand)`;
  const identityWidth =
    available - visibleWidth(label) - visibleWidth(hint) - visibleWidth(IDENTITY_SEPARATOR);
  const identity =
    row.identity && identityWidth >= MIN_IDENTITY_WIDTH
      ? IDENTITY_SEPARATOR + truncateToWidth(row.identity, identityWidth, "…")
      : "";
  const line = truncateToWidth(
    style.label(label) + style.identity(identity) + style.hint(hint),
    available,
    "…",
  );
  return pad + line;
}

const patchRegistry = globalThis as typeof globalThis & {
  [key: symbol]: CalmOperationalUserLayoutPatch | undefined;
};

function installedPatch(): CalmOperationalUserLayoutPatch | undefined {
  return patchRegistry[CALM_OPERATIONAL_USER_LAYOUT_PATCH];
}

export function bindOperationalRowTheme(theme: Theme): void {
  const installed = installedPatch();
  if (installed) installed.theme = theme;
}

export function installCalmOperationalUserLayout(): void {
  const hidesOperationalInput = (): boolean => calmPresentationHides("synthetic-user");
  const classifyOperationalRow = classifyFirstmateOperationalRow;
  const installed = installedPatch();
  if (installed) {
    installed.hidesOperationalInput = hidesOperationalInput;
    installed.classifyOperationalRow = classifyOperationalRow;
    return;
  }

  const patch: CalmOperationalUserLayoutPatch = {
    hidesOperationalInput,
    classifyOperationalRow,
  };
  const InteractiveMode = PiCodingAgent.InteractiveMode;
  if (typeof InteractiveMode !== "function") {
    throw new Error("Firstmate Calm requires Pi InteractiveMode");
  }
  const prototype = InteractiveMode.prototype as unknown as InteractiveModePrototype;
  const originalAddMessageToChat = prototype.addMessageToChat;
  if (typeof originalAddMessageToChat !== "function") {
    throw new Error("Firstmate Calm requires Pi InteractiveMode.addMessageToChat");
  }

  const UserMessageComponent = PiCodingAgent.UserMessageComponent;
  if (typeof UserMessageComponent !== "function") {
    throw new Error("Firstmate Calm requires Pi UserMessageComponent");
  }
  const keyText = PiCodingAgent.keyText;
  const expandKey = (): string => {
    try {
      return typeof keyText === "function" ? keyText("app.tools.expand") : "ctrl+o";
    } catch {
      return "ctrl+o";
    }
  };

  class FirstmateOperationalUserMessageComponent extends UserMessageComponent {
    private readonly row: FirstmateOperationalRow;
    private readonly rowOutputPad: number;
    private readonly hasLeadingSpacer: boolean;
    private expanded: boolean;

    constructor(
      text: UserMessageConstructorArgs[0],
      markdownTheme: UserMessageConstructorArgs[1],
      outputPad: number,
      markdownTransformers: UserMessageConstructorArgs[3],
      row: FirstmateOperationalRow,
      hasLeadingSpacer: boolean,
      expanded: boolean,
    ) {
      super(text, markdownTheme, outputPad, markdownTransformers);
      this.row = row;
      this.rowOutputPad = outputPad;
      this.hasLeadingSpacer = hasLeadingSpacer;
      this.expanded = expanded;
    }

    setExpanded(expanded: boolean): void {
      this.expanded = expanded;
      this.invalidate();
    }

    private hidden(): boolean {
      return calmMayHideOperationalRow(this.row) && patch.hidesOperationalInput();
    }

    override handleMouse(event: TuiMouseEvent): MouseDispatchResult {
      if (event.type !== "click" || event.button !== "left" || this.hidden()) return undefined;
      if (this.hasLeadingSpacer && event.y === 0) return undefined;
      this.setExpanded(!this.expanded);
      return {
        handled: true,
        target: {
          component: this,
          originX: event.screenX - event.x,
          originY: event.screenY - event.y,
          width: event.width,
          height: event.height,
        },
      };
    }

    override render(width: number): string[] {
      if (this.hidden()) return [];
      const lines = this.expanded
        ? super.render(width)
        : [renderCollapsedOperationalRow(this.row, width, this.rowOutputPad, expandKey(), patch.theme)];
      return this.hasLeadingSpacer ? ["", ...lines] : lines;
    }
  }

  prototype.addMessageToChat = function (
    message: UserMessageLike,
    options?: AddMessageOptions,
  ): void {
    if (message.role !== "user" || !contentIsTextOnly(message.content)) {
      originalAddMessageToChat.call(this, message, options);
      return;
    }

    const text = this.getUserMessageText(message);
    const row = text ? patch.classifyOperationalRow(text) : undefined;
    if (!row) {
      originalAddMessageToChat.call(this, message, options);
      return;
    }

    const component = new FirstmateOperationalUserMessageComponent(
      text,
      this.getMarkdownThemeWithSettings(),
      this.outputPad,
      this.getMarkdownTransformers?.(),
      row,
      this.chatContainer.children.length > 0,
      this.toolOutputExpanded === true,
    );
    this.chatContainer.addChild(component);
    if (options?.populateHistory) this.editor.addToHistory?.(text);
  };

  patchRegistry[CALM_OPERATIONAL_USER_LAYOUT_PATCH] = patch;
}
