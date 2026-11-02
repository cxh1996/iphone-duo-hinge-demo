#!/usr/bin/env bash
# fetch-ipa.sh —— 在 Windows(Git Bash) 上一条命令完成：提交 → 推送 → 等流水线 → 下载 ipa
#
# 用法：
#   bash scripts/fetch-ipa.sh                # 用默认提交信息
#   bash scripts/fetch-ipa.sh "调整UI"        # 自定义提交信息
#   bash scripts/fetch-ipa.sh --no-push      # 不改代码，只重新构建并下载
#
# 前置：gh 已登录（gh auth status），仓库已有 origin 远端。

set -euo pipefail
cd "$(dirname "$0")/.."

WF="build-unsigned-ipa.yml"
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)

if [ "${1:-}" != "--no-push" ]; then
  MSG="${1:-update hinge demo}"
  echo "==> 1/4 提交"
  git add -A
  if git diff --cached --quiet; then
    echo "    (无改动)"
  else
    git -c core.autocrlf=false commit -q -m "$MSG"
    echo "    committed: $MSG"
  fi
else
  echo "==> 1/4 跳过提交"
fi

echo "==> 2/4 推送（push 会自动触发流水线）"
git push -u origin main || true
sleep 8

HEAD_SHA=$(git rev-parse HEAD)
RUN_ID=$(gh run list --workflow "$WF" --limit 10 --json databaseId,headSha \
  --jq "map(select(.headSha==\"$HEAD_SHA\"))[0].databaseId // empty")

if [ -z "${RUN_ID:-}" ]; then
  echo "    该 commit 没有对应 run，手动触发一次"
  gh workflow run "$WF" --ref main
  sleep 12
  RUN_ID=$(gh run list --workflow "$WF" --limit 1 --json databaseId --jq '.[0].databaseId')
fi

echo "==> 3/4 等待构建（run $RUN_ID）"
echo "    https://github.com/$REPO/actions/runs/$RUN_ID"
if ! gh run watch "$RUN_ID" --exit-status --interval 15; then
  echo "!! 构建失败，失败步骤日志："
  gh run view "$RUN_ID" --log-failed | tail -80
  exit 1
fi

echo "==> 4/4 下载产物"
rm -rf out && mkdir -p out
gh run download "$RUN_ID" -n HingeDemo-unsigned-ipa -D out
[ -f out/HingeDemo-unsigned-ipa.zip ] && (cd out && unzip -o -q HingeDemo-unsigned-ipa.zip)

IPA=$(find out -name "*.ipa" | head -1)
if [ -z "${IPA:-}" ]; then
  echo "!! 没有 ipa，out/ 内容："; ls -R out; exit 1
fi

echo ""
echo "完成：$IPA"
echo "大小：$(du -h "$IPA" | cut -f1)"
echo ""
echo "下一步：拖进 Sideloadly → 填免费 Apple ID → Start。"
echo "缺 Sideloadly / Apple 驱动：右键运行 scripts\\bootstrap-windows.ps1（需 UAC 授权）"
