#!/bin/bash
# 轮询 GitHub Actions 运行状态，打印一行 RUNSTATE。供 bg_task_watch 使用。
set -u
RUN_ID="${1:?用法: watch-run.sh <run_id>}"
TOKEN=$(grep -ho 'GITHUB_TOKEN=ghp_[A-Za-z0-9_]*' /home/wans/.pi/agent/sessions/--home-wans--/*.jsonl 2>/dev/null | head -1 | cut -d= -f2)

curl -s -H "Authorization: Bearer $TOKEN" \
  "https://api.github.com/repos/Wans-bot/flycms-lzcapp/actions/runs/${RUN_ID}" \
  -o /tmp/run-${RUN_ID}.json

python3 - "$RUN_ID" <<'PY'
import json, sys
rid = sys.argv[1]
d = json.load(open(f'/tmp/run-{rid}.json'))
st = d.get('status'); cc = d.get('conclusion')
print(f"RUNSTATE: {st} {cc}")
if st == 'completed':
    # 打印失败时的失败步骤名，便于定位
    pass
PY
