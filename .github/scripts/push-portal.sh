#!/usr/bin/env bash
# push-portal.sh — 把单页 HTML 推为 TaiChi 门户草稿。portal-push 工作流（web_t/web_v tag）
# 唯一的推送入口，门户推送逻辑只此一份。
#
# 用法: push-portal.sh <API_BASE> <HTML 文件路径>
# 鉴权取环境变量 X_APP_ID / X_APP_SECRET（App Id + 推送密钥，管理后台一次性下发）。
#
# 平台坑（QCopy 2026-10-20 实录，同一套 TaiChi 平台）：单页 ≤5MB；HTML 转 JSON 必须
# 落盘 --data-binary（走 shell 变量传参撞 128KB 单参数上限）。
# 401=凭证错或密钥被重置 404=该应用还没建门户 400=门户非 HTML 型或超 5MB。
set -euo pipefail

API_BASE="${1:?用法: push-portal.sh <API_BASE> <HTML文件>}"
HTML_PATH="${2:?缺 HTML 文件路径}"
TMP="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"

[ -s "$HTML_PATH" ] || { echo "::error::HTML 不存在或为空: $HTML_PATH"; exit 1; }
if [ -z "${X_APP_ID:-}" ] || [ -z "${X_APP_SECRET:-}" ]; then
  echo "::error::缺 X_APP_ID / X_APP_SECRET 环境变量（门户推送凭证）"
  exit 1
fi

SIZE=$(wc -c < "$HTML_PATH")
if [ "$SIZE" -gt $((5 * 1024 * 1024)) ]; then
  echo "::error::单页 ${SIZE}B 超过平台 5MB 上限：资源内联改外链或压缩后再推"
  exit 1
fi

# HTML → JSON 字符串：不能走 shell 变量传参（单参数 128KB 上限），落盘用 --data-binary
python3 -c 'import json,sys; print(json.dumps({"html": open(sys.argv[1], encoding="utf-8").read()}))' \
  "$HTML_PATH" > "$TMP/portal-payload.json"

# 状态码驱动而非 curl -f：非 2xx 要能走到下面的分类提示，而不是被管道直接掐死
CODE=$(curl -s -o "$TMP/portal-resp.json" -w '%{http_code}' \
  --retry 3 --retry-delay 5 --connect-timeout 20 --max-time 120 \
  -X POST "$API_BASE/api/v1/portal-pages/push" \
  -H "X-App-Id: $X_APP_ID" \
  -H "X-App-Secret: $X_APP_SECRET" \
  -H 'Content-Type: application/json' \
  --data-binary @"$TMP/portal-payload.json")
cat "$TMP/portal-resp.json"; echo
if [ "$CODE" != "200" ]; then
  echo "::error::门户推送失败 HTTP $CODE（401=凭证错或密钥被重置 404=该应用还没建门户 400=门户非 HTML 型或超 5MB）"
  exit 1
fi
grep -q '"success":true' "$TMP/portal-resp.json" \
  || { echo "::error::平台返回 success:false"; exit 1; }
echo "门户草稿已更新 → $API_BASE"
