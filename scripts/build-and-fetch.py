#!/usr/bin/env python3
"""
build-and-fetch.py — 触发/跟踪 GitHub Actions 构建，并把未签名 IPA 下到本地。

为什么不直接用 gh：本机 gh 的 Go HTTP 客户端经代理会 TLS handshake timeout，
而 curl 稳定。所以这里所有请求都走 curl，并且带重试（本机到 api.github.com
偶发 ~50% 丢包）。

用法：
    python scripts/build-and-fetch.py            # 等最新 commit 的 run，成功则下载 ipa
    python scripts/build-and-fetch.py --dispatch # 没有对应 run 时手动触发一次
    python scripts/build-and-fetch.py --sha <sha>

产物：out/<artifact>.zip 与解压出的 *.ipa
退出码：0 成功；1 构建失败（自动打印失败步骤）；2 超时
"""

import argparse
import json
import os
import subprocess
import sys
import time
import zipfile

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WF = "build-unsigned-ipa.yml"
POLL = 20          # 秒
TIMEOUT = 40 * 60  # 40 分钟


def token():
    env = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if env:
        return env.strip()
    f = os.path.join(os.path.expanduser("~"), ".config", "duo-ci-token")
    if os.path.exists(f):
        return open(f, encoding="utf-8").read().strip()
    sys.exit("没有 token：设 GITHUB_TOKEN 或先跑 scripts/gh-device-login.py")


TOKEN = token()


def api(method, path, body=None, allow=(), raw=False, out_file=None):
    url = path if path.startswith("http") else "https://api.github.com/" + path.lstrip("/")
    cmd = ["curl", "-sS", "-L", "--max-time", "45", "-X", method, url,
           "-H", f"Authorization: Bearer {TOKEN}",
           "-H", "Accept: application/vnd.github+json"]
    stdin = None
    if body is not None:
        cmd += ["-H", "Content-Type: application/json", "--data-binary", "@-"]
        stdin = json.dumps(body).encode()
    if out_file:
        cmd += ["-o", out_file, "-w", "%{http_code}"]
    else:
        cmd += ["-w", "\n__HTTP__%{http_code}"]

    last = ""
    for attempt in range(20):
        p = subprocess.run(cmd, input=stdin, capture_output=True)
        if out_file:
            code = int(p.stdout.decode().strip() or 0)
            if 200 <= code < 300:
                return code
            last = f"HTTP {code}"
        else:
            text = p.stdout.decode("utf-8", "replace")
            if "__HTTP__" in text:
                payload, _, code_s = text.rpartition("__HTTP__")
                code = int(code_s.strip() or 0)
                payload = payload.strip()
                if 200 <= code < 300:
                    return json.loads(payload) if payload else {}
                if code in allow:
                    return None
                last = f"HTTP {code} {payload[:200]}"
            else:
                last = p.stderr.decode("utf-8", "replace").strip() or "空响应"
        time.sleep(min(1 + attempt, 8))
    sys.exit(f"{method} {url} 失败（重试 20 次）: {last}")


def repo_full_name():
    url = subprocess.run(["git", "config", "--get", "remote.origin.url"],
                         cwd=REPO_ROOT, capture_output=True).stdout.decode().strip()
    name = url.split("github.com")[-1].strip("/:").replace(".git", "")
    if name.count("/") != 1:
        sys.exit(f"无法解析 owner/repo: {url}")
    return name


def head_sha():
    return subprocess.run(["git", "rev-parse", "HEAD"], cwd=REPO_ROOT,
                          capture_output=True).stdout.decode().strip()


def find_run(repo, sha):
    data = api("GET", f"repos/{repo}/actions/runs?head_sha={sha}&per_page=10")
    runs = [r for r in data.get("workflow_runs", []) if r["path"].endswith(WF)]
    if not runs:
        return None
    return max(runs, key=lambda r: r["id"])


def print_failed_steps(repo, run_id):
    print("\n--- 失败步骤 ---")
    jobs = api("GET", f"repos/{repo}/actions/runs/{run_id}/jobs")
    for job in jobs.get("jobs", []):
        print(f"[{job['name']}] conclusion={job['conclusion']}")
        for st in job.get("steps", []):
            mark = {"success": "✓", "failure": "✗", "skipped": "-"}.get(st["conclusion"], "?")
            print(f"   {mark} {st['name']}")
        if job.get("conclusion") == "failure":
            # 日志是 302 到临时 URL 的纯文本，直接用 curl -L 取
            out = subprocess.run(
                ["curl", "-sS", "-L", "--max-time", "60",
                 f"https://api.github.com/repos/{repo}/actions/jobs/{job['id']}/logs",
                 "-H", f"Authorization: Bearer {TOKEN}"],
                capture_output=True).stdout.decode("utf-8", "replace")
            tail = out.strip().splitlines()[-60:]
            print("\n--- 该 job 日志尾部 ---")
            print("\n".join(tail))


def download_artifact(repo, run_id):
    arts = api("GET", f"repos/{repo}/actions/runs/{run_id}/artifacts")
    items = arts.get("artifacts", [])
    if not items:
        return None
    art = next((a for a in items if "ipa" in a["name"].lower()), items[0])
    out_dir = os.path.join(REPO_ROOT, "out")
    os.makedirs(out_dir, exist_ok=True)
    zip_path = os.path.join(out_dir, art["name"] + ".zip")
    print(f"下载 artifact: {art['name']} ({art['size_in_bytes'] / 1024:.0f} KB)")
    api("GET", f"repos/{repo}/actions/artifacts/{art['id']}/zip", out_file=zip_path)
    with zipfile.ZipFile(zip_path) as z:
        z.extractall(out_dir)
    ipas = [os.path.join(dp, f) for dp, _, fs in os.walk(out_dir)
            for f in fs if f.lower().endswith(".ipa")]
    return ipas[0] if ipas else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sha", default=None)
    ap.add_argument("--dispatch", action="store_true")
    ap.add_argument("--timeout", type=int, default=TIMEOUT)
    args = ap.parse_args()

    repo = repo_full_name()
    sha = args.sha or head_sha()
    print(f"仓库: {repo}\ncommit: {sha}")

    run = find_run(repo, sha)
    if run is None and args.dispatch:
        print("没有对应 run，手动触发 workflow_dispatch")
        api("POST", f"repos/{repo}/actions/workflows/{WF}/dispatches",
            {"ref": "main", "inputs": {}})
        time.sleep(10)

    if run is None:
        for _ in range(10):
            run = find_run(repo, sha)
            if run:
                break
            time.sleep(6)
    if run is None:
        # 拿最新一次，便于排查
        data = api("GET", f"repos/{repo}/actions/runs?per_page=5")
        runs = data.get("workflow_runs", [])
        if not runs:
            sys.exit("没有任何 run：确认 workflow 文件已推送、且仓库启用了 Actions")
        run = runs[0]
        print(f"未找到该 commit 的 run，改用最新一次 run {run['id']} (head_sha={run['head_sha'][:7]})")

    rid = run["id"]
    print(f"run {rid}  {run['html_url']}")

    t0 = time.time()
    last = None
    while True:
        cur = api("GET", f"repos/{repo}/actions/runs/{rid}")
        status, concl = cur["status"], cur.get("conclusion")
        if (status, concl) != last:
            print(f"  [{int(time.time() - t0):4d}s] status={status} conclusion={concl}", flush=True)
            last = (status, concl)
        if status == "completed":
            break
        if time.time() - t0 > args.timeout:
            print("超时，任务仍未完成")
            sys.exit(2)
        time.sleep(POLL)

    if concl != "success":
        print(f"构建未成功: {concl}")
        print_failed_steps(repo, rid)
        sys.exit(1)

    ipa = download_artifact(repo, rid)
    if not ipa:
        sys.exit("构建成功但没找到 ipa 产物")
    size = os.path.getsize(ipa) / 1024 / 1024
    print(f"\nOK  IPA: {ipa}  ({size:.1f} MB)")
    print("下一步：Sideloadly 拖入该 ipa，填免费 Apple ID，Start。")


if __name__ == "__main__":
    main()
