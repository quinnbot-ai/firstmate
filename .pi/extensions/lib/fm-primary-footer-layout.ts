import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";

export type FooterTheme = {
  fg(color: string, text: string): string;
};

export type FooterData = {
  state: "running" | "idle";
  model: string;
  thinking: string;
  project: string;
  branch: string;
  context: string;
  input: string;
  output: string;
  cost: string;
  statuses: string[];
};

const colorize = (theme: FooterTheme, color: string, label: string, value: string): string =>
  theme.fg(color, label) + theme.fg("text", value);

const fit = (line: string, width: number): string => truncateToWidth(line, Math.max(1, width));

export function formatFooterLines(data: FooterData, width: number, theme: FooterTheme): string[] {
  const state = colorize(theme, data.state === "running" ? "success" : "muted", "● ", data.state);
  const model = colorize(theme, "accent", "model ", `${data.model}${data.thinking ? ` · ${data.thinking}` : ""}`);
  const location = colorize(theme, "purple", "dir ", data.project);
  const branch = data.branch ? colorize(theme, "aqua", "git ", data.branch) : "";
  const usage = [
    colorize(theme, "warning", "ctx ", data.context),
    colorize(theme, "muted", "↑", data.input),
    colorize(theme, "muted", "↓", data.output),
    colorize(theme, "aqua", "$", data.cost),
  ].join(" ");
  const status = data.statuses.length ? data.statuses.join(" · ") : "";

  if (width < 58) {
    return [fit(`${state} ${model}`, width), ...(status ? [fit(status, width)] : [])];
  }
  if (width < 92) return [fit(`${state} ${model}  ${location}`, width), fit([status, usage].filter(Boolean).join("  "), width)];
  const first = [state, model, location, branch].filter(Boolean).join("  ");
  const second = [usage, status].filter(Boolean).join("  ");
  return [fit(first, width), fit(second || " ", width)];
}

export function footerVisibleWidth(line: string): number {
  return visibleWidth(line);
}
