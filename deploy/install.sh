#!/usr/bin/env bash
# 从已下载的源码构建并安装 arb-web（Ubuntu / Debian + systemd）。
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

if (( EUID == 0 )); then
    echo '请用有 sudo 权限的普通用户运行 bash deploy/install.sh；不要对整个脚本使用 sudo。' >&2
    exit 1
fi
if ! command -v sudo >/dev/null || ! command -v apt-get >/dev/null ||
   ! command -v systemctl >/dev/null || [[ ! -d /run/systemd/system ]]; then
    echo '本脚本需要 Ubuntu / Debian、sudo 和正在运行的 systemd。' >&2
    exit 1
fi

sudo -v
if ! command -v cc >/dev/null || ! command -v curl >/dev/null ||
   [[ ! -s /etc/ssl/certs/ca-certificates.crt ]]; then
    sudo apt-get update
    sudo apt-get install -y build-essential curl ca-certificates
fi

export PATH="$HOME/.cargo/bin:$PATH"
if ! command -v cargo >/dev/null; then
    echo '==> 安装 Rust（当前用户）'
    curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs |
        sh -s -- -y --profile minimal --default-toolchain none --no-modify-path
fi

echo '==> 构建 arb-web（构建成功后才更新服务）'
cargo build --locked --release --package arb-web --bin arb-web --target-dir target

if ! getent group arb >/dev/null; then
    sudo groupadd --system arb
fi
if ! id -u arb >/dev/null 2>&1; then
    sudo useradd --system --gid arb --home-dir /opt/arb-bot --shell /usr/sbin/nologin arb
fi
sudo install -d -o root -g arb -m 0750 /opt/arb-bot
sudo install -d -o arb -g arb -m 0750 /var/lib/arb-bot

# 不导入源码目录中的 .env，避免首次部署意外启动实盘。
if ! sudo test -e /etc/arb-bot.env; then
    sudo install -o root -g root -m 0600 .env.example /etc/arb-bot.env
fi

# 先在目标目录准备文件，再原子替换；正在运行的进程可以继续排空。
staged_binary=$(sudo mktemp /opt/arb-bot/.arb-web.XXXXXX)
trap 'sudo rm -f -- "$staged_binary"' EXIT
sudo install -o root -g root -m 0755 target/release/arb-web "$staged_binary"
sudo mv -fT -- "$staged_binary" /opt/arb-bot/arb-web
trap - EXIT

sudo install -o root -g root -m 0644 deploy/arb-web.service /etc/systemd/system/arb-web.service
sudo systemctl daemon-reload
if ! sudo systemctl enable arb-web || ! sudo systemctl restart arb-web; then
    echo '服务启动失败，请查看：sudo journalctl -u arb-web -n 100 --no-pager' >&2
    exit 1
fi

echo '==> 已安装并请求启动 arb-web。默认地址：http://127.0.0.1:8080'
echo '状态：sudo systemctl status arb-web；日志：sudo journalctl -u arb-web -f'
