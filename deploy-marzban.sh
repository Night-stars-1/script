#!/usr/bin/env bash
set -Eeuo pipefail

DOMAIN="${1:-}"
PANEL_PORT="${PANEL_PORT:-8000}"
SWAP_SIZE="${SWAP_SIZE:-2G}"
MARZBAN_DIR="/opt/marzban"
CERT_DIR="/var/lib/marzban/certs"
ACME_HOME="/root/.acme.sh"

die() { printf '\033[1;31m[marzban][ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1;36m[marzban]\033[0m %s\n' "$*"; }

[[ "$(id -u)" == 0 ]] || die '请使用 root 执行: sudo -i'
[[ -n "$DOMAIN" ]] || die "用法: $0 <域名>，例如 $0 mb1.example.com"
command -v apt-get >/dev/null || die '此脚本仅支持 Debian/Ubuntu 系统'

set_env() {
  local key="$1" value="$2" file="$MARZBAN_DIR/.env" tmp
  tmp="$(mktemp)"
  if [[ -f "$file" ]]; then
    awk -v k="$key" -v v="$value" '
      BEGIN { done=0 }
      $0 ~ "^[[:space:]]*" k "=" { if (!done) { print k "=" v; done=1 }; next }
      { print }
      END { if (!done) print k "=" v }
    ' "$file" >"$tmp"
  else
    printf '%s=%s\n' "$key" "$value" >"$tmp"
  fi
  install -m 600 "$tmp" "$file"
  rm -f "$tmp"
}

log '准备 Swap'
if ! swapon --show=NAME --noheadings | grep -qx '/swapfile'; then
  if [[ ! -f /swapfile ]]; then
    fallocate -l "$SWAP_SIZE" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=progress
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
  fi
  swapon /swapfile
fi
grep -q '^/swapfile ' /etc/fstab || printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
install -m 644 /dev/null /etc/sysctl.d/99-marzban-swappiness.conf
printf 'vm.swappiness=30\n' >/etc/sysctl.d/99-marzban-swappiness.conf
sysctl -p /etc/sysctl.d/99-marzban-swappiness.conf >/dev/null

log '安装依赖'
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates socat openssl dnsutils

log '安装 Marzban'
if ! command -v marzban >/dev/null; then
  bash -c "$(curl -fsSL https://github.com/Gozargah/Marzban-scripts/raw/master/marzban.sh)" @ install
fi
command -v marzban >/dev/null || die 'Marzban 安装后找不到 marzban 命令'
marzban status || true

log '检查 DNS 和 80 端口'
printf 'A 记录: '; dig +short A "$DOMAIN" | tail -1
printf 'AAAA 记录: '; dig +short AAAA "$DOMAIN" | tail -1 || true
if ss -lntH '( sport = :80 )' | grep -q .; then
  die 'TCP 80 已被占用。standalone 签证书前请停止占用 80 的服务。'
fi

log '安装 acme.sh 并申请证书'
if [[ ! -x "$ACME_HOME/acme.sh" ]]; then
  curl -fsSL https://get.acme.sh | sh
fi
"$ACME_HOME/acme.sh" --set-default-ca --server letsencrypt
"$ACME_HOME/acme.sh" --issue -d "$DOMAIN" --standalone

mkdir -p "$CERT_DIR"
"$ACME_HOME/acme.sh" --install-cert -d "$DOMAIN" \
  --fullchain-file "$CERT_DIR/$DOMAIN.cer" \
  --key-file "$CERT_DIR/$DOMAIN.cer.key" \
  --reloadcmd 'marzban restart'
chmod 644 "$CERT_DIR/$DOMAIN.cer"
chmod 600 "$CERT_DIR/$DOMAIN.cer.key"

log '写入 Marzban HTTPS 配置'
[[ -f "$MARZBAN_DIR/.env" ]] || die "$MARZBAN_DIR/.env 不存在"
cp -a "$MARZBAN_DIR/.env" "$MARZBAN_DIR/.env.bak.$(date +%Y%m%d%H%M%S)"
set_env UVICORN_HOST 0.0.0.0
set_env UVICORN_PORT "$PANEL_PORT"
set_env UVICORN_SSL_CERTFILE "$CERT_DIR/$DOMAIN.cer"
set_env UVICORN_SSL_KEYFILE "$CERT_DIR/$DOMAIN.cer.key"
set_env XRAY_SUBSCRIPTION_URL_PREFIX "https://$DOMAIN:$PANEL_PORT"
marzban restart

log '完成'
printf '面板: https://%s:%s\n' "$DOMAIN" "$PANEL_PORT"
printf '创建管理员: marzban cli admin create --sudo\n'
printf '查看日志: marzban logs\n'
printf '证书目录: %s\n' "$CERT_DIR"
