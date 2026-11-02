#!/usr/bin/env python3
"""
push-via-api.py — 绕过 github.com 主站，用 GitHub Git Data API 直接提交。

用途：本机网络到 github.com 的 HTTPS/SSH 均不可达（CONNECT 502 / 直连超时），
但 api.github.com 正常，因此标准 `git push` 无法使用。本脚本通过 REST API
创建 blob -> tree -> commit -> 更新 ref，效果等价于一次 push（全量快照，
因此在工作区删除的文件也会在远端被删除）。

先决条件：本机 `gh` 已登录，且 token 具备 Contents: write
（若首次提交包含 .github/workflows/ 还需 Workflows: write）。

用法：
    python scripts/push-via-api.py [--branch main] [--message "..."]

退出码：0 成功；非 0 失败（stderr 带 GitHub 原始错误）。
"""

import argparse
import base64
import json
import os
import subprocess
import sys
import time

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 这些永远不推送
SKIP_PREFIXES = (".git/", "out/", "build/", "DerivedData/")
SKIP_FILES = {".DS_Store"}


def run_git(*args):
    p = subprocess.run(["git", *args], cwd=REPO_ROOT, capture_output=True)
    if p.returncode != 0:
        sys.exit(f"git {' '.join(args)} 失败: {p.stderr.decode('utf-8', 'replace')}")
    return p.stdout.decode("utf-8", "replace")


def tracked_files():
    out = run_git("ls-files", "-z")
    files = [f for f in out.split("\0") if f]
    keep = []
    for f in files:
        norm = f.replace("\\", "/")
        if norm in SKIP_FILES or norm.startswith(SKIP_PREFIXES):
            continue
        keep.append(norm)
    return keep


def _token():
    """取 token：环境变量 > 设备码登录落盘的文件 > gh。

    文件优先于 gh，因为 gh 可能收不进（缺 read:org），而我们只需要
    Contents/Workflows 写权限，文件里的 token 已足够。
    """
    env = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if env:
        return env.strip()
    f = os.path.join(os.path.expanduser("~"), ".config", "duo-ci-token")
    if os.path.exists(f):
        t = open(f, encoding="utf-8").read().strip()
        if t:
            return t
    t = subprocess.run(["gh", "auth", "token"], capture_output=True).stdout.decode().strip()
    if not t:
        sys.exit("拿不到 token：没有 GITHUB_TOKEN、没有 ~/.config/duo-ci-token、gh 也未登录")
    return t


TOKEN = _token()


def api(method, path, body=None, allow_404=False):
    """用 curl 调 GitHub API。

    为什么不用 `gh api`：本机代理对 Go 客户端的 TLS 栈不友好，POST 频繁
    TLS handshake timeout，而 curl 稳定。此脚本在 Windows + 代理环境下
    以 curl 为准。
    """
    url = path if path.startswith("http") else "https://api.github.com/" + path.lstrip("/")
    cmd = ["curl", "-sS", "--max-time", "30", "-X", method, url,
           "-H", f"Authorization: Bearer {TOKEN}",
           "-H", "Accept: application/vnd.github+json",
           "-w", "\n__HTTP__%{http_code}"]
    stdin = None
    if body is not None:
        cmd += ["-H", "Content-Type: application/json", "--data-binary", "@-"]
        stdin = json.dumps(body).encode("utf-8")

    last_err = ""
    for attempt in range(20):
        p = subprocess.run(cmd, input=stdin, capture_output=True)
        out = p.stdout.decode("utf-8", "replace")
        if "__HTTP__" in out:
            payload, _, code = out.rpartition("__HTTP__")
            code = int(code.strip() or 0)
            payload = payload.strip()
            if code == 0:
                last_err = p.stderr.decode("utf-8", "replace").strip() or "curl 返回 0"
            elif code == 404 and allow_404:
                return None
            elif code == 409 and allow_404 and "empty" in payload.lower():
                # 空仓库读 ref 会返回 409 而不是 404
                return None
            elif 200 <= code < 300:
                return json.loads(payload) if payload else {}
            else:
                sys.exit(f"{method} {url} -> HTTP {code}\n{payload[:800]}")
        else:
            last_err = p.stderr.decode("utf-8", "replace").strip() or "无输出"
        import time
        time.sleep(min(1 + attempt, 8))   # 丢包严重，短退避多试
    sys.exit(f"{method} {url} 连试 20 次失败: {last_err}")


def blob_sha1(data: bytes) -> str:
    """算 git blob 的 SHA-1，用来和远端已有 blob 比对，跳过没变的文件。"""
    import hashlib
    h = hashlib.sha1()
    h.update(b"blob %d\0" % len(data))
    h.update(data)
    return h.hexdigest()


def remote_tree(full_name, branch):
    """返回 {path: sha}；仓库为空时返回 {}。"""
    ref = api("GET", f"repos/{full_name}/git/ref/heads/{branch}", allow_404=True)
    if ref is None:
        return {}
    tree = api("GET", f"repos/{full_name}/git/trees/{ref['object']['sha']}?recursive=1")
    return {t["path"]: t["sha"] for t in tree.get("tree", []) if t["type"] == "blob"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--branch", default="main")
    ap.add_argument("--message", default="")
    args = ap.parse_args()

    # 从 remote.origin.url 解析 owner/repo（curl 不支持 gh 的 {owner}/{repo} 占位符）
    remote = run_git("config", "--get", "remote.origin.url").strip()
    full_name = remote.split("github.com")[-1].strip("/:").replace(".git", "")
    if full_name.count("/") != 1:
        sys.exit(f"无法从 remote 解析 owner/repo: {remote}")
    repo = api("GET", f"repos/{full_name}")
    print(f"仓库: {full_name}  (private={repo['private']}, 默认分支={repo.get('default_branch')})")

    files = tracked_files()
    print(f"待推送文件 {len(files)} 个")

    # 0) 空仓库要先引导：Git Data API 在没有任何 commit 的仓库上返回
    #    409 "Git Repository is empty"，必须先用 Contents API 落一个文件。
    ref = api("GET", f"repos/{full_name}/git/ref/heads/{args.branch}", allow_404=True)
    if ref is None:
        seed = next((f for f in ("README.md", ".gitattributes") if f in files), files[0])
        print(f"仓库为空，先用 Contents API 提交 {seed} 作为引导提交")
        with open(os.path.join(REPO_ROOT, seed), "rb") as fh:
            seed_b64 = base64.b64encode(fh.read()).decode("ascii")
        api("PUT", f"repos/{full_name}/contents/{seed}",
            {"message": args.message or "Initial commit", "content": seed_b64,
             "branch": args.branch})
        ref = api("GET", f"repos/{full_name}/git/ref/heads/{args.branch}", allow_404=True)
        if ref is None:
            sys.exit("引导提交后仍读不到 ref，请检查默认分支名是否为 " + args.branch)

    # 1) blobs —— 只上传内容变了的文件（本机丢包严重，能省一次是一次）
    existing = remote_tree(full_name, args.branch)
    entries = []
    changed = 0
    for i, rel in enumerate(files, 1):
        abs_path = os.path.join(REPO_ROOT, rel)
        with open(abs_path, "rb") as fh:
            data = fh.read()
        local = blob_sha1(data)
        if existing.get(rel) == local:
            entries.append({"path": rel, "mode": "100755" if os.access(abs_path, os.X_OK) else "100644",
                            "type": "blob", "sha": local})
            print(f"  [{i:2d}/{len(files)}] skip {rel}（未改动）", flush=True)
            continue
        blob = api("POST", f"repos/{full_name}/git/blobs",
                   {"content": base64.b64encode(data).decode("ascii"), "encoding": "base64"})
        entries.append({"path": rel, "mode": "100755" if os.access(abs_path, os.X_OK) else "100644",
                        "type": "blob", "sha": blob["sha"]})
        changed += 1
        print(f"  [{i:2d}/{len(files)}] blob {rel}  ({len(data)} B)", flush=True)
        time.sleep(0.4)   # 别把代理和 API 打太急

    removed = sorted(set(existing) - set(files))
    if removed:
        print(f"将删除远端多出的 {len(removed)} 个文件：" + ", ".join(removed[:5]) +
              (" ..." if len(removed) > 5 else ""))
    print(f"变更文件 {changed} 个，未变 {len(files) - changed} 个")

    # 2) tree（不带 base_tree = 全量快照）
    tree = api("POST", f"repos/{full_name}/git/trees", {"tree": entries})
    print(f"tree: {tree['sha']}")

    # 3) 父提交
    ref = api("GET", f"repos/{full_name}/git/ref/heads/{args.branch}", allow_404=True)
    parents = [ref["object"]["sha"]] if ref else []
    print("父提交: " + (parents[0] if parents else "(无，这是首次提交)"))

    # 4) commit
    msg = args.message or run_git("log", "-1", "--pretty=%s").strip()
    body = {"message": msg, "tree": tree["sha"]}
    if parents:
        body["parents"] = parents
    commit = api("POST", f"repos/{full_name}/git/commits", body)
    print(f"commit: {commit['sha']}  \"{msg}\"")

    # 5) 更新 / 创建 ref
    if ref:
        api("PATCH", f"repos/{full_name}/git/refs/heads/{args.branch}", {"sha": commit["sha"]})
        print(f"已更新 refs/heads/{args.branch}")
    else:
        api("POST", f"repos/{full_name}/git/refs",
            {"ref": f"refs/heads/{args.branch}", "sha": commit["sha"]})
        print(f"已创建 refs/heads/{args.branch}")

    print(f"\n完成: https://github.com/{full_name}/commit/{commit['sha']}")


if __name__ == "__main__":
    main()
