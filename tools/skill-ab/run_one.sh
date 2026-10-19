#!/bin/sh
# One A/B run: a fresh headless agent gets one SKILL.md variant and one task.
#
#   sh tools/skill-ab/run_one.sh <task T1..T5> <arm A|B> <rep 1..> [out_dir]
#
# Env: LOOPCTRL_HOST (required, e.g. 192.168.31.31:8300)
#      AB_MODEL       (default claude-sonnet-5-5; keep it the same for both arms)
#      AB_SKILL_A / AB_SKILL_B  skill files (default: written by prepare.sh)
#
# Before the agent starts, the device is reset to the same state every time: home
# screen, the task's apps terminated. Timing stats are snapshotted before and after
# so the scorer can count the RPCs the agent made. Nothing here taps inside an app.
set -eu

task=$1; arm=$2; rep=$3
here=$(cd "$(dirname "$0")" && pwd)
out=${4:-$here/runs}
host=${LOOPCTRL_HOST:?set LOOPCTRL_HOST}
model=${AB_MODEL:-claude-sonnet-5-5}
run_id=$(printf '%s-%s-%02d' "$task" "$arm" "$rep")
dir=$out/$run_id
skill=$(eval echo "\${AB_SKILL_$arm:-$here/skills/SKILL.$arm.md}")
client=$here/../../Scripts/loopctrl_rpc.py

[ -f "$skill" ] || { echo "missing $skill — run prepare.sh first" >&2; exit 1; }
[ -e "$dir" ] && { echo "$dir exists — refusing to overwrite a run" >&2; exit 1; }
mkdir -p "$dir/work"
cp "$skill" "$dir/work/SKILL.md"
cp "$client" "$dir/work/loopctrl_rpc.py"

rpc() { python3 -I "$dir/work/loopctrl_rpc.py" --host "$host" call "$@"; }

prompt_file=$dir/prompt.txt
apps=$(python3 -I - "$here/tasks.json" "$task" "$run_id" "$prompt_file" <<'EOF'
import json, sys
spec, tid, run_id, out = sys.argv[1:]
t = next(t for t in json.load(open(spec))["tasks"] if t["id"] == tid)
open(out, "w").write(t["prompt"].replace("{run}", run_id))
print(" ".join(t["apps"]), t["max_minutes"])
EOF
)
minutes=${apps##* }; apps=${apps% *}

# ── Same starting state for every run ───────────────────────────────────────
rpc home > "$dir/setup.log" 2>&1 || true
for b in $apps; do rpc terminate_app "{\"bundle_id\":\"$b\"}" >> "$dir/setup.log" 2>&1 || true; done
rpc config > "$dir/pre_config.json"

cat > "$dir/meta.json" <<EOF
{"run_id":"$run_id","task":"$task","arm":"$arm","rep":$rep,"model":"$model","host":"$host",
 "skill_sha1":"$(shasum "$skill" | cut -c1-12)","started":"$(date -u +%FT%TZ)","limit_min":$minutes}
EOF

header="手机由 LoopCtrl 控制，地址 $host。Python 客户端是当前目录的 ./loopctrl_rpc.py（用法：python3 loopctrl_rpc.py --host $host call <method> '<json>'），设备已配对，密钥在 ~/.loopctrl。开始前先完整阅读 ./SKILL.md 并按它操作。只做任务要求的事；需要用户确认的步骤，任务里已经授权的范围之外一律停下汇报。"

# ── The agent ───────────────────────────────────────────────────────────────
# perl alarm = a wall-clock cap (macOS has no timeout(1)).
start=$(date +%s)
( cd "$dir/work" && perl -e 'alarm shift; exec @ARGV' $((minutes * 60)) \
    claude -p "$header

$(cat "$prompt_file")" \
    --model "$model" --output-format stream-json --verbose \
    --allowedTools "Bash" "Read" --no-session-persistence --strict-mcp-config \
    > "$dir/transcript.jsonl" 2> "$dir/agent.stderr" ) || echo "agent exit $?" >> "$dir/agent.stderr"
end=$(date +%s)

# ── After ───────────────────────────────────────────────────────────────────
rpc config > "$dir/post_config.json" || true
rpc logs '{"max_elements":500}' > "$dir/logs.json" || true
python3 -I "$dir/work/loopctrl_rpc.py" --host "$host" shot "$dir/end.jpg" > /dev/null 2>&1 || true
python3 -I - "$dir/meta.json" "$((end - start))" <<'EOF'
import json, sys
p, secs = sys.argv[1], int(sys.argv[2])
m = json.load(open(p)); m["wall_s"] = secs; json.dump(m, open(p, "w"), ensure_ascii=False)
EOF
# Operator fills this in after checking the phone (1 = pass, 0 = fail).
python3 -I - "$here/tasks.json" "$task" "$dir/checks.json" <<'EOF'
import json, sys
spec, tid, out = sys.argv[1:]
t = next(t for t in json.load(open(spec))["tasks"] if t["id"] == tid)
json.dump({c["id"]: None for c in t["checkpoints"]}, open(out, "w"), indent=1)
EOF
echo "done $run_id in $((end - start))s → $dir (fill in checks.json)"
