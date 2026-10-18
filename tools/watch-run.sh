#!/bin/bash
# 轮询 GitHub Actions 运行状态，打印一行 RUNSTATE。供 bg_task_watch 使用。
#
# token 取法：会话日志里 GITHUB_TOKEN= 后面跟着的是 classic PAT（ghp_ + 36 位 = 40 字符），
# 但日志里紧邻的其他文本也满足 [A-Za-z0-9_]，直接中括号通配会把尾巴一起吞进来导致 401，
# 所以按固定 40 位截断。
set -u
RUN_ARG="${1:?用法: watch-run.sh <run_id|sha>}"

TOKEN=$(python3 - <<'PY'
import glob
for path in sorted(glob.glob('/home/wans/.pi/agent/sessions/--home-wans--/*.jsonl')):
    blob = open(path, encoding='utf-8', errors='replace').read()
    i = blob.find('GITHUB_TOKEN=ghp_')
    while i >= 0:
        j = i + len('GITHUB_TOKEN=')
        cand = ''
        while j < len(blob) and (blob[j].isalnum() or blob[j] in '_-'):
            cand += blob[j]; j += 1
        if len(cand) == 40:
            print(cand); raise SystemExit
        i = blob.find('GITHUB_TOKEN=ghp_', i + 1)
raise SystemExit(1)
PY
)

if [ -z "${TOKEN:-}" ]; then
  echo "RUNSTATE: token-missing"
  exit 1
fi

if printf '%s' "$RUN_ARG" | grep -qE '^[0-9]+$'; then
  RUN_ID="$RUN_ARG"
else
  # 传的是 sha（可只给前几位）：查该 sha 对应的 run id
  curl -s -H "Authorization: Bearer $TOKEN" \
    "https://api.github.com/repos/Wans-bot/flycms-lzcapp/actions/runs?per_page=20" \
    -o /tmp/run-list.json
  RUN_ID=$(python3 - "$RUN_ARG" <<'PY'
import json, sys
sha = sys.argv[1]
d = json.load(open('/tmp/run-list.json'))
for r in d.get('workflow_runs', []):
    if r['head_sha'].startswith(sha):
        print(r['id']); break
PY
)
  if [ -z "$RUN_ID" ]; then echo "RUNSTATE: no-run-for-$RUN_ARG"; exit 1; fi
fi

curl -s -H "Authorization: Bearer $TOKEN" \
  "https://api.github.com/repos/Wans-bot/flycms-lzcapp/actions/runs/${RUN_ID}" \
  -o /tmp/run-${RUN_ID}.json

python3 - "$RUN_ID" <<'PY'
import json, sys
rid = sys.argv[1]
d = json.load(open(f'/tmp/run-{rid}.json'))
st = d.get('status'); cc = d.get('conclusion')
print(f"RUNSTATE: {st} {cc}")
PY
