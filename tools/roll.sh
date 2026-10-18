#!/bin/bash
# 一次「构建产物 → 可安装 LPK」的搬运：
#   1. 把 ghcr 上的 backend/web 镜像复制进官方源 registry.lazycat.cloud
#   2. 用复制后的真实 tag 改写 lzc-manifest.yml 里两条 image
#   3. lzc-cli project release 打成 LPK
#
# 用法: tools/roll.sh <short-sha>
# 前置: 该 sha 的 Action 构建已成功，ghcr 上有 flycms-lzcapp:<sha> 与 flycms-lzcapp-web:<sha>
set -euo pipefail

SHA="${1:?用法: tools/roll.sh <short-sha>}"
cd "$(dirname "$0")/.."
OUT=${OUT_LPK:-/tmp/flycms-build/application.lpk}

copy_image() {
  local repo="$1" log
  log=$(mktemp)
  lzc-cli appstore copy-image "ghcr.io/wans-bot/${repo}:${SHA}" --arch amd64 > "$log" 2>&1 || {
    echo "复制 ${repo}:${SHA} 失败："; tail -20 "$log"; return 1;
  }
  sed -n 's/^uploaded:[[:space:]]*//p' "$log" | tail -1
  rm -f "$log"
}

BACKEND=$(copy_image flycms-lzcapp)
WEB=$(copy_image flycms-lzcapp-web)
[ -n "$BACKEND" ] && [ -n "$WEB" ] || { echo "未解析到复制后的镜像地址"; exit 1; }
echo "backend -> $BACKEND"
echo "web     -> $WEB"

python3 - "$BACKEND" "$WEB" <<'PY'
import sys
backend, web = sys.argv[1], sys.argv[2]
path = 'lzc-manifest.yml'
lines = open(path, encoding='utf-8').read().split('\n')
seen = {'b': 0, 'w': 0}
for i, line in enumerate(lines):
    s = line.strip()
    if not s.startswith('image:'):
        continue
    if 'flycms-lzcapp-web:' in s:
        indent = line[:len(line) - len(line.lstrip())]
        lines[i] = f'{indent}image: {web}'
        seen['w'] += 1
    elif 'flycms-lzcapp:' in s:
        indent = line[:len(line) - len(line.lstrip())]
        lines[i] = f'{indent}image: {backend}'
        seen['b'] += 1
if seen != {'b': 1, 'w': 1}:
    raise SystemExit(f'镜像行匹配数异常: {seen}')
open(path, 'w', encoding='utf-8').write('\n'.join(lines))
print('manifest 已更新')
PY

lzc-cli project release -o "$OUT"
ls -l "$OUT"
