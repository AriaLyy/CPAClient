#!/usr/bin/env bash
# setup-github-runner.sh — 在 fnOS NAS 上装一个 GitHub Actions self-hosted runner，
# 供 portal-push.yml 的 push-test 任务（runs-on: [self-hosted, nas]）经局域网直推 TaiChi。
#
# 背景：taichi-api.dddo.top 只在局域网 DNS 里存在（8.8.8.8 查 NXDOMAIN），GitHub 托管
# runner 到不了；web_t_0.1.0 已实录 curl exit 6。runner 进程出 GitHub 走本机代理，
# 访问 taichi/gitea 等局域网域名由 .env 里的 no_proxy 旁路。
#
# 用法（在你自己的终端，把脚本从仓库经 stdin 喂给 NAS，token 换成
# GitHub → 仓库 → Settings → Actions → Runners → New self-hosted runner → Linux x64 页面上的值）：
#   ssh lyy@192.168.50.201 "bash -s <TOKEN>" < tool/setup-github-runner.sh
# sudo 会要一次密码（svc.sh 装 systemd 服务必须 root）。
set -euo pipefail

TOKEN="${1:?用法: bash setup-github-runner.sh <REGISTRATION_TOKEN>}"
REPO_URL="https://github.com/AriaLyy/CPAClient"
DEST="/opt/actions-runner"
RUN_USER="$(whoami)"

[ "$(uname -m)" = "x86_64" ] || { echo "只支持 x86_64，当前 $(uname -m)"; exit 1; }
command -v curl >/dev/null || { echo "缺 curl"; exit 1; }

# ---- 选一条能上 GitHub 的路：本机 clash 7890 → 网关 7890 → 直连 ----
PROXY=""
for p in "http://127.0.0.1:7890" "http://192.168.50.1:7890"; do
  if curl -s -x "$p" -m 8 -o /dev/null https://api.github.com; then PROXY="$p"; break; fi
done
[ -n "$PROXY" ] || curl -s -m 8 -o /dev/null https://api.github.com || { echo "127.0.0.1:7890 / 192.168.50.1:7890 与直连都到不了 api.github.com，先修代理"; exit 1; }
CURL_PROXY=()
[ -n "$PROXY" ] && CURL_PROXY=(-x "$PROXY")
echo "代理: ${PROXY:-直连}"

# ---- 下载最新稳定版 runner ----
VER=$(curl "${CURL_PROXY[@]}" -s https://api.github.com/repos/actions/runner/releases/latest \
  | grep -m1 '"tag_name"' | cut -d'"' -f4 | sed 's/^v//')
[ -n "$VER" ] || { echo "取不到 runner 最新版本号"; exit 1; }
echo "runner 版本: $VER"
if [ ! -x "$DEST/config.sh" ]; then
  curl "${CURL_PROXY[@]}" -fL -o /tmp/actions-runner.tar.gz \
    "https://github.com/actions/runner/releases/download/v${VER}/actions-runner-linux-x64-${VER}.tar.gz"
  sudo mkdir -p "$DEST"
  sudo chown "$RUN_USER" "$DEST"
  tar -xzf /tmp/actions-runner.tar.gz -C "$DEST"
  rm -f /tmp/actions-runner.tar.gz
fi

# ---- runner 进程的代理环境：走代理上 GitHub，局域网域名旁路 ----
if [ -n "$PROXY" ]; then
  cat > "$DEST/.env" <<EOF
HTTP_PROXY=$PROXY
HTTPS_PROXY=$PROXY
http_proxy=$PROXY
https_proxy=$PROXY
no_proxy=localhost,127.0.0.1,gitea.dddo.top,taichi-api.dddo.top,taichi.dddo.top,192.168.50.201
NO_PROXY=localhost,127.0.0.1,gitea.dddo.top,taichi-api.dddo.top,taichi.dddo.top,192.168.50.201
EOF
fi

# ---- 注册（repo 级 runner，label=nas；--replace 同名旧注册自动顶掉）----
cd "$DEST"
./config.sh --url "$REPO_URL" --token "$TOKEN" --labels nas --unattended --replace

# ---- systemd 服务（root），常驻自启 ----
sudo ./svc.sh install
sudo ./svc.sh start
sleep 3
sudo ./svc.sh status || true
echo
echo "装好了。回 GitHub 仓库 Settings → Actions → Runners 应能看到 Idle 的 nas runner。"
echo "重置/换 token 重跑本脚本即可（--replace 会顶掉旧注册）。"
