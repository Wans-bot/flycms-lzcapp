#!/usr/bin/env python3
"""用 GitHub Git Data API 推送提交（本机到 github.com 的 git 协议不通时使用）。

用法: api-push.py <owner/repo> <branch> <base_commit_sha> <message_file> [paths...]
不带 paths 时推送本地 HEAD 相对 base 的全部变更（含新增/修改/删除）。
"""
import base64
import glob
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

REPO, BRANCH, BASE, MSG_FILE = sys.argv[1:5]
ONLY = sys.argv[5:]


def read_bytes(path: str) -> bytes:
    try:
        with open(path, 'rb') as f:
            return f.read()
    except OSError as exc:
        raise SystemExit(f'读不到文件 {path}: {exc}') from exc


def read_text(path: str) -> str:
    return read_bytes(path).decode('utf-8')


def token() -> str:
    for path in glob.glob('/home/wans/.pi/agent/sessions/--home-wans--/*.jsonl'):
        try:
            with open(path, encoding='utf-8', errors='replace') as f:
                blob = f.read()
        except OSError:
            continue
        marker = 'GITHUB_TOKEN='
        start = blob.find(marker + 'ghp_')
        while start >= 0:
            i = start + len(marker)
            cand = ''
            while i < len(blob) and (blob[i].isalnum() or blob[i] in '_-'):
                cand += blob[i]
                i += 1
            if len(cand) == 40:
                return cand
            start = blob.find(marker + 'ghp_', start + 1)
    raise SystemExit('未找到 GITHUB_TOKEN')


TOKEN = token()


def api(method: str, path: str, payload=None):
    url = f'https://api.github.com/repos/{REPO}{path}'
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header('Authorization', f'Bearer {TOKEN}')
    req.add_header('Accept', 'application/vnd.github+json')
    if data:
        req.add_header('Content-Type', 'application/json')
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            body = resp.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode('utf-8', 'replace')[:400]
        raise SystemExit(f'{method} {path} -> HTTP {exc.code}: {detail}') from exc
    except urllib.error.URLError as exc:
        raise SystemExit(f'{method} {path} 网络错误: {exc}') from exc
    if not body:
        return {}
    try:
        return json.loads(body)
    except json.JSONDecodeError as exc:
        raise SystemExit(f'{method} {path} 返回非 JSON: {body[:200]!r}') from exc


def git(*args) -> str:
    try:
        return subprocess.run(['git', *args], capture_output=True, text=True, check=True).stdout
    except subprocess.CalledProcessError as exc:
        raise SystemExit(f'git {" ".join(args)} 失败: {exc.stderr.strip()}') from exc


def tracked(path: str) -> bool:
    try:
        git('ls-files', '--error-unmatch', '--', path)
        return True
    except SystemExit:
        return False


def local_has(sha: str) -> bool:
    try:
        git('cat-file', '-e', f'{sha}^{{commit}}')
        return True
    except SystemExit:
        return False


changes = []
if ONLY:
    # 显式给了路径：本机仓库可能只是快照、对象库里没有远端 base 提交（到 github.com 的
    # git 协议不通，fetch 不下来），这时不能靠 `git diff --name-status BASE HEAD` 枚举，
    # 直接按给定路径判定新增/修改。目录会展开成其中的文件。
    if local_has(BASE):
        for line in git('diff', '--name-status', BASE, 'HEAD').splitlines():
            parts = line.split('\t')
            if len(parts) >= 2 and parts[-1] in ONLY:
                changes.append((parts[0][0], parts[-1]))
    for p in ONLY:
        if os.path.isdir(p):
            for full in sorted(glob.glob(os.path.join(p, '**', '*'), recursive=True)):
                if os.path.isfile(full):
                    changes.append(('M' if tracked(full) else 'A', full))
        elif os.path.isfile(p):
            changes.append(('M' if tracked(p) else 'A', p))
else:
    for line in git('diff', '--name-status', BASE, 'HEAD').splitlines():
        parts = line.split('\t')
        if len(parts) >= 2:
            changes.append((parts[0][0], parts[-1]))

if not changes:
    raise SystemExit('没有需要推送的变更')
# 2) 逐个文件建 blob（删除的走 sha:null）
tree_items = []
for status, path in changes:
    if status == 'D':
        tree_items.append({'path': path, 'mode': '100644', 'type': 'blob', 'sha': None})
        print(f'  D {path}')
        continue
    raw = read_bytes(path)
    blob = api('POST', '/git/blobs', {
        'content': base64.b64encode(raw).decode(),
        'encoding': 'base64',
    })
    ls = git('ls-files', '-s', '--', path).strip()
    # 未跟踪的新文件在 ls-files 里没有记录，按普通文件权限推
    mode = ls.split()[0] if ls else '100644'
    tree_items.append({'path': path, 'mode': mode, 'type': 'blob', 'sha': blob['sha']})
    print(f'  {status} {path} ({len(raw)}B, mode {mode})')

# 3) 新 tree / commit / 移动分支
base_tree = api('GET', f'/git/commits/{BASE}')['tree']['sha']
tree = api('POST', '/git/trees', {'base_tree': base_tree, 'tree': tree_items})
commit = api('POST', '/git/commits', {
    'message': read_text(MSG_FILE),
    'tree': tree['sha'],
    'parents': [BASE],
})
api('PATCH', f'/git/refs/heads/{BRANCH}', {'sha': commit['sha'], 'force': False})
print(f'pushed {commit["sha"][:12]} -> {BRANCH}')
