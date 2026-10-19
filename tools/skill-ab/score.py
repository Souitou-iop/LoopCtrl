#!/usr/bin/env python3
"""Score SKILL.md A/B runs.

Reads every run directory under tools/skill-ab/runs (or argv[1]) and writes
runs.csv and summary.md next to them.

Per run:
  success      every critical checkpoint in checks.json is 1 (operator-filled)
  safety_fail  any safety checkpoint is 0
  score        share of all checkpoints passed
  turns        agent turns (result event num_turns)
  tool_calls   Bash/Read calls the agent made
  rpc          UI RPCs the device served during the run (config timing delta,
               config/logs excluded)
  screenshots, timeouts, queued, repeats (the same action sent twice in a row
               with no read between), grounded (reported values found verbatim
               in what the phone returned)
  wall_s, cost_usd, in_tok, out_tok
"""
import csv
import json
import re
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
RUNS = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / "runs"
TASKS = {t["id"]: t for t in json.load(open(HERE / "tasks.json"))["tasks"]}
NON_UI = {"config", "logs", "reset", "stream_ticket"}
ACTIONS = {"tap", "double_tap", "long_press", "type", "swipe", "drag", "page", "scroll",
           "find_and_tap", "tap_element", "clear_text", "open_url", "launch_app"}
READS = {"page_source", "find_element", "screen_text", "screenshot", "collect", "scroll_to_element"}
CALL_RE = re.compile(r"(?:\bcall|\br)\s+([a-z_]+)(?:\s+'([^']*)')?")


def load_json(p):
    try:
        txt = Path(p).read_text()
        start = txt.find("{")
        return json.loads(txt[start:]) if start >= 0 else None
    except (OSError, ValueError):
        return None


def timing_counts(cfg):
    if not cfg:
        return {}
    res = cfg.get("result", cfg)
    return {t["method"]: t["count"] for t in res.get("timing", [])}


def transcript(path):
    """(tool commands in order, tool result texts, final result event)."""
    cmds, outputs, final = [], [], {}
    try:
        lines = Path(path).read_text().splitlines()
    except OSError:
        return cmds, outputs, final
    for line in lines:
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if ev.get("type") == "result":
            final = ev
        msg = ev.get("message") or {}
        for block in msg.get("content") or []:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "tool_use":
                inp = block.get("input") or {}
                cmds.append(inp.get("command") or inp.get("file_path") or "")
            elif block.get("type") == "tool_result":
                c = block.get("content")
                if isinstance(c, list):
                    c = "\n".join(x.get("text", "") for x in c if isinstance(x, dict))
                outputs.append(str(c or ""))
    return cmds, outputs, final


def rpc_sequence(cmds):
    seq = []
    for c in cmds:
        for m in CALL_RE.finditer(c):
            seq.append((m.group(1), m.group(2) or ""))
    return seq


def repeats(seq):
    n, prev = 0, None
    for method, params in seq:
        if method in READS:
            prev = None
            continue
        if method in ACTIONS and prev == (method, params):
            n += 1
        prev = (method, params) if method in ACTIONS else None
    return n


def reported(final_text):
    """The last JSON object in the agent's final answer."""
    for m in reversed(list(re.finditer(r"\{[^{}]*\}", final_text or "", re.S))):
        try:
            return json.loads(m.group(0))
        except ValueError:
            continue
    return {}


def score_run(d):
    meta = load_json(d / "meta.json") or {}
    task = TASKS.get(meta.get("task"), {})
    checks = load_json(d / "checks.json") or {}
    cmds, outputs, final = transcript(d / "transcript.jsonl")
    seq = rpc_sequence(cmds)
    pre, post = timing_counts(load_json(d / "pre_config.json")), timing_counts(load_json(d / "post_config.json"))
    rpc = sum(post.get(k, 0) - pre.get(k, 0) for k in post if k not in NON_UI)
    joined = "\n".join(outputs)
    rep = reported(final.get("result", ""))
    fields = task.get("report_fields", [])
    grounded = None
    if task.get("grounded"):
        vals = [str(rep.get(f, "")).strip() for f in fields]
        grounded = sum(1 for v in vals if v and v in joined) / max(1, len(vals))
    cps = {c["id"]: c for c in task.get("checkpoints", [])}
    filled = {k: v for k, v in checks.items() if v is not None}
    complete = len(filled) == len(cps) and cps
    success = bool(complete) and all(filled.get(k) == 1 for k, c in cps.items() if c["critical"])
    safety_fail = any(filled.get(k) == 0 for k, c in cps.items() if c.get("safety"))
    usage = final.get("usage") or {}
    return {
        "run": d.name, "task": meta.get("task"), "arm": meta.get("arm"), "rep": meta.get("rep"),
        "checked": bool(complete), "success": int(success) if complete else "",
        "safety_fail": int(safety_fail), "score": round(sum(filled.values()) / len(cps), 2) if complete else "",
        "turns": final.get("num_turns", ""), "tool_calls": len(cmds), "rpc": rpc,
        "screenshots": sum(1 for m, _ in seq if m == "screenshot") + sum(c.count(" shot ") for c in cmds),
        "timeouts": joined.count("may still be running") + joined.count("exceeded"),
        "queued": joined.count("has NOT run yet"), "repeats": repeats(seq),
        "grounded": "" if grounded is None else round(grounded, 2),
        "wall_s": meta.get("wall_s", ""), "cost_usd": final.get("total_cost_usd", ""),
        "in_tok": usage.get("input_tokens", 0) + usage.get("cache_read_input_tokens", 0)
                  + usage.get("cache_creation_input_tokens", 0),
        "out_tok": usage.get("output_tokens", ""),
    }


def med(rows, key):
    vals = [r[key] for r in rows if isinstance(r[key], (int, float))]
    return round(statistics.median(vals), 1) if vals else "–"


def main():
    rows = [score_run(d) for d in sorted(RUNS.iterdir()) if (d / "meta.json").exists()] if RUNS.exists() else []
    if not rows:
        print(f"no runs under {RUNS}")
        return
    with open(RUNS / "runs.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)
    keys = ["turns", "tool_calls", "rpc", "screenshots", "timeouts", "repeats", "wall_s", "cost_usd"]
    out = ["# SKILL.md A/B summary", "",
           "| task | arm | runs | checked | success | safety fails | " + " | ".join(f"median {k}" for k in keys) + " |",
           "|" + "---|" * (6 + len(keys))]
    for t in sorted({r["task"] for r in rows}):
        for arm in ("A", "B"):
            rs = [r for r in rows if r["task"] == t and r["arm"] == arm]
            if not rs:
                continue
            checked = [r for r in rs if r["checked"]]
            succ = f"{sum(r['success'] for r in checked)}/{len(checked)}" if checked else "–"
            out.append(f"| {t} | {arm} | {len(rs)} | {len(checked)} | {succ} | {sum(r['safety_fail'] for r in rs)} | "
                       + " | ".join(str(med(rs, k)) for k in keys) + " |")
    out += ["", "Medians over runs; success counts only runs whose checks.json is fully filled in."]
    (RUNS / "summary.md").write_text("\n".join(out) + "\n")
    print("\n".join(out))


if __name__ == "__main__":
    main()
