#!/usr/bin/env python3
"""
gh-device-login.py — 手动实现 GitHub OAuth Device Flow，并把拿到的 token 写进 gh。

为什么不用 `gh auth login --web`：
  本机 github.com 只能经 curl + 本地代理(127.0.0.1:7890)访问，gh 自带的 Go
  HTTP 客户端在该代理下会 TLS handshake timeout / schannel 失败。curl 稳定，
  所以这里全程用 curl 发请求。

用到的 OAuth App：GitHub CLI 官方 client_id（只申请 repo + workflow 两个 scope）。

用法：
    python scripts/gh-device-login.py            # 全程自动：取码 -> 轮询 -> 写 gh
    python scripts/gh-device-login.py --code-only # 只取设备码，不轮询

授权页：https://github.com/login/device
"""

import argparse
import json
import os
import subprocess
import sys
import time

CLIENT_ID = "178c6fc778ccc68e1d6a"          # GitHub CLI 官方 OAuth App
# repo=读写代码仓库；workflow=推送 .github/workflows；read:org=gh 校验 token 的硬要求
SCOPES = "repo,workflow,read:org"
PROXY = "http://127.0.0.1:7890"              # 本机唯一能到 github.com 的代理
TOKEN_FILE = os.path.join(os.path.expanduser("~"), ".config", "duo-ci-token")


def curl(*args, timeout=60):
    cmd = ["curl", "-sS", "--max-time", str(timeout), "-x", PROXY, *args]
    p = subprocess.run(cmd, capture_output=True)
    return p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace"), p.returncode


def post_form(url, fields, accept="application/json"):
    """POST 表单，带重试。

    本机 curl 走 schannel，经代理偶发 "failed to receive handshake"，属瞬时
    错误；轮询一次失败就退出会白白浪费设备码，所以这里退避重试。
    """
    data = "&".join(f"{k}={v}" for k, v in fields.items())
    last = ""
    for attempt in range(6):
        out, err, rc = curl("-X", "POST", url, "-H", f"Accept: {accept}",
                            "-H", "Content-Type: application/x-www-form-urlencoded",
                            "--data-binary", data)
        if rc == 0 and out.strip():
            try:
                return json.loads(out)
            except json.JSONDecodeError:
                last = f"非 JSON 响应: {out[:200]}"
        else:
            last = err.strip() or f"curl rc={rc}"
        time.sleep(2 + 2 * attempt)
    sys.exit(f"请求 {url} 连试 6 次失败: {last}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--code-only", action="store_true")
    args = ap.parse_args()

    # 1) 申请设备码
    dc = post_form("https://github.com/login/device/code",
                   {"client_id": CLIENT_ID, "scope": SCOPES})
    if "device_code" not in dc:
        sys.exit(f"申请设备码失败: {json.dumps(dc, ensure_ascii=False)}")

    user_code = dc["user_code"]
    device_code = dc["device_code"]
    interval = int(dc.get("interval", 5))
    expires = int(dc.get("expires_in", 900))

    print("=" * 46)
    print(f"  一次性验证码： {user_code}")
    print(f"  打开：        {dc.get('verification_uri', 'https://github.com/login/device')}")
    print(f"  有效期：      {expires // 60} 分钟")
    print("=" * 46, flush=True)

    if args.code_only:
        return

    # 2) 轮询换 token
    print("等待你在浏览器里授权……", flush=True)
    deadline = time.time() + expires
    poll_no = 0
    while time.time() < deadline:
        time.sleep(interval)
        poll_no += 1
        r = post_form("https://github.com/login/oauth/access_token",
                      {"client_id": CLIENT_ID,
                       "device_code": device_code,
                       "grant_type": "urn:ietf:params:oauth:grant-type:device_code"})
        err = r.get("error")
        left = int(deadline - time.time())
        if err == "authorization_pending":
            print(f"[poll {poll_no}] 还没授权（剩余 {left}s）", flush=True)
            continue
        if err == "slow_down":
            interval += 5
            print(f"[poll {poll_no}] 服务器要求降速，间隔改为 {interval}s", flush=True)
            continue
        if err:
            print(f"[poll {poll_no}] 错误: {err} — {r.get('error_description', '')}", flush=True)
            if err in ("expired_token", "access_denied", "incorrect_device_code"):
                sys.exit(f"授权失败: {err}")
            continue
        token = r.get("access_token")
        if not token:
            print(f"[poll {poll_no}] 返回里没有 token: {json.dumps(r, ensure_ascii=False)[:200]}", flush=True)
            continue

        print("已拿到 access token。", flush=True)

        # ① 无论 gh 收不收，先把 token 落盘 —— 上一版就是 gh 校验失败把 token 白扔了
        os.makedirs(os.path.dirname(TOKEN_FILE), exist_ok=True)
        with open(TOKEN_FILE, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(token + "\n")
        try:
            os.chmod(TOKEN_FILE, 0o600)
        except OSError:
            pass
        print(f"已保存到 {TOKEN_FILE}", flush=True)

        # ② 再尝试写入 gh（方便用 gh run watch 等命令）
        p = subprocess.run(["gh", "auth", "login", "--hostname", "github.com",
                            "--git-protocol", "https", "--with-token"],
                           input=token.encode(), capture_output=True)
        if p.returncode != 0:
            msg = p.stderr.decode("utf-8", "replace").strip()
            print(f"警告：写入 gh 失败（不影响推送，推送走文件 token）：{msg}", flush=True)
        else:
            print("OK  gh 已登录", flush=True)

        print("scopes = " + r.get("scope", SCOPES), flush=True)
        return

    sys.exit("设备码已过期，请重跑本脚本")


if __name__ == "__main__":
    main()
