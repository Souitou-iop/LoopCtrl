import type { DeviceView } from "./api";
import type { Dict } from "./i18n";

export type ChipKind = "wait" | "run" | "act" | "ok" | "bad" | "off";

/** Chip colour and label for a phone in the batch list. */
export function chipOf(d: DeviceView, t: Dict): [ChipKind, string] {
  if (!d.connected && d.phase !== "done" && d.phase !== "rebooting" && d.phase !== "failed") return ["off", t.batch.disconnected];
  if (d.phase === "trusting") return d.locked ? ["act", t.chip.locked] : ["wait", t.chip.trusting];
  if (d.phase === "done") return ["ok", t.chip.done];
  if (d.phase === "failed") return ["bad", t.chip.failed];
  if (d.phase === "detected") return ["wait", t.chip.detected];
  if (d.attention) return ["act", t.chip[d.phase]];
  return ["run", t.chip[d.phase]];
}

/** Index into the five sheet steps (信任 / 开发者模式 / 生成 / 写入 / 校验). */
export function sheetStep(d: DeviceView): number {
  const byStep: Record<string, number> = { info: 0, trust: 0, devModeCheck: 1, reboot: 1, devModeConfirm: 1, generate: 2, findApp: 2, write: 3, verify: 4 };
  const byPhase: Record<string, number> = {
    detected: 0, trusting: 0, checkingDevMode: 1, revealingDevMode: 1, devModeGuide: 1, rebooting: 1, confirmingDevMode: 1,
    generating: 2, findingApp: 2, writing: 3, verifying: 4, done: 5,
  };
  return d.phase === "failed" ? byStep[d.failedAt ?? "info"] : byPhase[d.phase];
}
