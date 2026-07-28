import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { formatFooterLines, type FooterData } from "./lib/fm-primary-footer-layout.ts";

const shortNumber = (value: number): string =>
  value < 1000 ? String(value) : `${(value / 1000).toFixed(value < 10000 ? 1 : 0)}k`;

const projectName = (cwd: string): string => cwd.split(/[\\/]/).filter(Boolean).pop() || cwd;

export default function (pi: ExtensionAPI) {
  let requestRender: (() => void) | undefined;
  let currentBranch = "";
  let currentContext: ExtensionContext | undefined;

  const refreshTitle = (ctx: typeof currentContext): void => {
    if (!ctx) return;
    const model = ctx.model?.id || "no-model";
    const branch = currentBranch || "no-branch";
    ctx.ui.setTitle(`Firstmate · ${projectName(ctx.cwd)} · ${branch} · ${model}`);
  };

  const stats = (ctx: NonNullable<typeof currentContext>): FooterData => {
    let input = 0;
    let output = 0;
    let cost = 0;
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry.type !== "message" || entry.message.role !== "assistant") continue;
      const usage = (entry.message as { usage: { input: number; output: number; cost: { total: number } } }).usage;
      input += usage.input;
      output += usage.output;
      cost += usage.cost.total;
    }
    const usage = ctx.getContextUsage();
    return {
      state: ctx.isIdle() ? "idle" : "running",
      model: ctx.model?.id || "no-model",
      thinking: ctx.thinkingLevel ? `think:${ctx.thinkingLevel}` : "",
      project: projectName(ctx.cwd),
      branch: currentBranch,
      context: usage?.tokens == null ? "?" : `${shortNumber(usage.tokens)}${usage.percent == null ? "" : ` (${Math.round(usage.percent)}%)`}`,
      input: shortNumber(input),
      output: shortNumber(output),
      cost: cost.toFixed(3),
      statuses: [],
    };
  };

  const redraw = (_event: unknown, ctx: ExtensionContext) => {
    currentContext = ctx;
    refreshTitle(ctx);
    requestRender?.();
  };
  pi.on("agent_start", redraw);
  pi.on("agent_end", redraw);
  pi.on("agent_settled", redraw);
  pi.on("message_update", redraw);
  pi.on("message_end", redraw);
  pi.on("model_select", redraw);
  pi.on("thinking_level_select", redraw);
  pi.on("session_info_changed", redraw);

  pi.on("session_start", (_event, ctx) => {
    currentContext = ctx;
    ctx.ui.setTheme("firstmate-dark");
    ctx.ui.setFooter((tui, theme, footerData) => {
      currentBranch = footerData.getGitBranch() || "";
      const unsubscribe = footerData.onBranchChange(() => {
        currentBranch = footerData.getGitBranch() || "";
        refreshTitle(currentContext);
        tui.requestRender();
      });
      requestRender = () => tui.requestRender();
      refreshTitle(ctx);
      return {
        dispose() {
          unsubscribe();
          requestRender = undefined;
        },
        invalidate() {},
        render(width: number) {
          const data = stats(ctx);
          data.statuses = [...footerData.getExtensionStatuses().values()];
          return formatFooterLines(data, width, theme);
        },
      };
    });
  });
}
