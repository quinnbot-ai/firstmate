import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";

export type FooterTheme = {
  fg(color: string, text: string): string;
};

export type FooterStatus = {
  key: string;
  value: string;
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
  statuses: FooterStatus[];
};

const colorize = (theme: FooterTheme, color: string, label: string, value: string): string =>
  theme.fg(color, label) + theme.fg("text", value);

const fit = (line: string, width: number): string => truncateToWidth(line, Math.max(1, width));

const sanitizeSingleLine = (text: string): string =>
  text
    .replace(/[\u0000-\u001f\u007f]/g, " ")
    .replace(/ +/g, " ")
    .trim();

const pack = (segments: string[], width: number): string[] => {
  const lines: string[] = [];
  let line = "";
  for (const segment of segments) {
    const fitted = fit(segment, width);
    if (!line) {
      line = fitted;
    } else if (footerVisibleWidth(line) + 2 + footerVisibleWidth(fitted) <= Math.max(1, width)) {
      line += `  ${fitted}`;
    } else {
      lines.push(line);
      line = fitted;
    }
  }
  if (line) lines.push(line);
  return lines;
};

export function formatFooterLines(data: FooterData, width: number, theme: FooterTheme): string[] {
  const state = colorize(theme, data.state === "running" ? "success" : "muted", "● ", data.state);
  const model = colorize(theme, "accent", "model ", data.model);
  const thinking = colorize(theme, "accent", "think ", data.thinking);
  const location = colorize(theme, "purple", "dir ", data.project);
  const branch = colorize(theme, "aqua", "git ", data.branch || "-");
  const usage = [
    colorize(theme, "warning", "ctx ", data.context),
    colorize(theme, "muted", "↑", data.input),
    colorize(theme, "muted", "↓", data.output),
    colorize(theme, "aqua", "$", data.cost),
  ];
  const statuses = data.statuses
    .map(({ key, value }) => ({ key: sanitizeSingleLine(key), value: sanitizeSingleLine(value) }))
    .sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : a.value < b.value ? -1 : a.value > b.value ? 1 : 0))
    .map(({ key, value }) => colorize(theme, "muted", `${key}${value ? ": " : ""}`, value));

  return [...pack([state, model, thinking, location, branch], width), ...pack(usage, width), ...pack(statuses, width)];
}

export function footerVisibleWidth(line: string): number {
  return visibleWidth(line);
}
