// Verified against Pi 0.81.1 and 0.82.0, which add each ordinary user row as a native
// spacer-plus-user-component pair via InteractiveMode.addMessageToChat. This adapter
// decorates that exact topology and throws if it is unavailable; fm-calm.ts catches that
// and skips only this adapter with a diagnostic instead of blocking Calm or Pi. It changes
// only presentation and never message delivery.
import * as PiCodingAgent from "@earendil-works/pi-coding-agent";
import { calmPresentationHides } from "./fm-calm-visibility.ts";
import { classifyFirstmateCurrentOperationalText } from "./fm-operational-input.ts";

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
  };
  editor: {
    addToHistory?(text: string): void;
  };
  getUserMessageText(message: UserMessageLike): string;
};
type InteractiveModePrototype = {
  addMessageToChat(
    this: InteractiveModePresentation,
    message: UserMessageLike,
    options?: AddMessageOptions,
  ): void;
};
type CalmOperationalUserLayoutPatch = {
  hidesOperationalInput: () => boolean;
  isOperationalInput: (text: string) => boolean;
};

// Keep the introduction-version symbol stable so a compatible upgrade cannot
// double-patch a live process.
const CALM_OPERATIONAL_USER_LAYOUT_PATCH = Symbol.for(
  "firstmate:calm-operational-user-layout:pi-0.81.1",
);
const LEGACY_CALM_OPERATIONAL_PREFIX = "\u2063Supervisor escalate (";

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

export function installCalmOperationalUserLayout(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmOperationalUserLayoutPatch | undefined;
  };
  const hidesOperationalInput = (): boolean => calmPresentationHides("synthetic-user");
  const isOperationalInput = (text: string): boolean => {
    if (!text.includes("\u2063")) return false;
    return (
      classifyFirstmateCurrentOperationalText(text) !== undefined ||
      text.startsWith(LEGACY_CALM_OPERATIONAL_PREFIX)
    );
  };
  const installed = registry[CALM_OPERATIONAL_USER_LAYOUT_PATCH];
  if (installed) {
    installed.hidesOperationalInput = hidesOperationalInput;
    installed.isOperationalInput = isOperationalInput;
    return;
  }

  const patch: CalmOperationalUserLayoutPatch = {
    hidesOperationalInput,
    isOperationalInput,
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

  prototype.addMessageToChat = function (
    message: UserMessageLike,
    options?: AddMessageOptions,
  ): void {
    if (message.role !== "user" || !contentIsTextOnly(message.content)) {
      originalAddMessageToChat.call(this, message, options);
      return;
    }

    const text = this.getUserMessageText(message);
    if (!text || !patch.isOperationalInput(text)) {
      originalAddMessageToChat.call(this, message, options);
      return;
    }

    // Keep Pi's own spacer and user-row construction together so adjacent follow-ups
    // retain the same transcript topology as ordinary native input.
    const before = this.chatContainer.children.length;
    const hasPrecedingRow = before > 0;
    originalAddMessageToChat.call(this, message, options);
    const added = this.chatContainer.children.length - before;
    const expectedAdded = hasPrecedingRow ? 2 : 1;
    if (added !== expectedAdded) {
      throw new Error("Firstmate Calm requires Pi's spacer-plus-user operational row topology");
    }
    const spacer = hasPrecedingRow
      ? (this.chatContainer.children[before] as {
          render?: (width: number) => string[];
        } | undefined)
      : undefined;
    const component = this.chatContainer.children[before + expectedAdded - 1] as {
      render?: (width: number) => string[];
    } | undefined;
    if (
      !component ||
      typeof component.render !== "function" ||
      (hasPrecedingRow && (!spacer || typeof spacer.render !== "function"))
    ) {
      throw new Error("Firstmate Calm could not locate Pi's operational spacer and user row");
    }
    const render = component.render.bind(component);
    if (spacer) {
      const renderSpacer = spacer.render!.bind(spacer);
      spacer.render = (width: number): string[] => (
        patch.hidesOperationalInput() ? [] : renderSpacer(width)
      );
    }
    component.render = (width: number): string[] => {
      if (patch.hidesOperationalInput()) return [];
      return render(width);
    };
  };

  registry[CALM_OPERATIONAL_USER_LAYOUT_PATCH] = patch;
}
