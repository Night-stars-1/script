#!/usr/bin/env bash
set -Eeuo pipefail

DOMAIN=""
ADMIN_PASSWORD="${1:-}"
PANEL_PORT="${PANEL_PORT:-8000}"
SWAP_SIZE="${SWAP_SIZE:-2G}"
MARZBAN_DIR="/opt/marzban"
CERT_DIR="/var/lib/marzban/certs"
TEMPLATE_URL="https://raw.githubusercontent.com/Night-stars-1/script/main/marzban.html"
CLASH_TEMPLATE_URL="https://raw.githubusercontent.com/Night-stars-1/script/main/marzban-clash.yml"
TEMPLATE_DIR="/var/lib/marzban/templates"
TEMPLATE_DEST="$TEMPLATE_DIR/subscription/index.html"
CLASH_TEMPLATE_DEST="$TEMPLATE_DIR/clash/my-custom-template.yml"
ACME_HOME="/root/.acme.sh"

die() { printf '\033[1;31m[marzban][ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1;36m[marzban]\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m[marzban][OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[marzban][WARN]\033[0m %s\n' "$*"; }

[[ "$(id -u)" == 0 ]] || die '请使用 root 执行: sudo -i'
[[ -n "$ADMIN_PASSWORD" ]] || die '请将 admin 管理员密码作为脚本第一个参数传入'
[[ -r /dev/tty ]] || die '需要交互终端来输入域名'
read -r -p $'请输入面板域名: ' DOMAIN </dev/tty
[[ -n "$DOMAIN" ]] || die '域名不能为空'
[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die '域名格式不正确'
command -v apt-get >/dev/null || die '此脚本仅支持 Debian/Ubuntu 系统'
log '预检查 DNS'
DNS_IP="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR == 1 { print $1 }' || true)"
DNS_IPV6="$(getent ahostsv6 "$DOMAIN" 2>/dev/null | awk 'NR == 1 { print $1 }' || true)"
printf 'A 记录: %s\n' "${DNS_IP:-未找到}"
printf 'AAAA 记录: %s\n' "${DNS_IPV6:-未找到}"
[[ -n "$DNS_IP" ]] || die '没有查到域名 A 记录，请先将域名解析到 VPS 公网 IPv4'
ok "A 记录已解析: $DNS_IP"

set_env() {
  local key="$1" value="$2" file="$MARZBAN_DIR/.env" tmp
  tmp="$(mktemp)"
  if [[ -f "$file" ]]; then
    awk -v k="$key" -v v="$value" '
      BEGIN { done=0 }
      $0 ~ "^[[:space:]]*" k "[[:space:]]*=" { if (!done) { print k " = \"" v "\""; done=1 }; next }
      { print }
      END { if (!done) print k " = \"" v "\"" }
    ' "$file" >"$tmp"
  else
    printf '%s = "%s"\n' "$key" "$value" >"$tmp"
  fi
  install -m 600 "$tmp" "$file"
  rm -f "$tmp"
}

download_template() {
  local url="$1" destination="$2" tmp
  tmp="$(mktemp)"
  if ! curl -fsSL "$url" -o "$tmp"; then
    rm -f "$tmp"
    die "模板下载失败: $url"
  fi
  [[ -s "$tmp" ]] || { rm -f "$tmp"; die "模板下载后为空: $url"; }
  install -D -m 644 "$tmp" "$destination"
  rm -f "$tmp"
  [[ -s "$destination" ]] || die "模板安装失败: $destination"
  ok "模板已安装: $destination"
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
ok "Swap 已启用: $(swapon --show=SIZE --noheadings /swapfile 2>/dev/null | xargs)"

log '安装依赖'
apt-get update
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export APT_LISTCHANGES_FRONTEND=none
apt-get install -y \
  -o Dpkg::Options::=--force-confold \
  curl ca-certificates socat openssl dnsutils
ok '依赖安装完成'

log '安装 Marzban'
if ! command -v marzban >/dev/null; then
  MARZBAN_INSTALLER="$(mktemp)"
  curl -fsSL https://github.com/Gozargah/Marzban-scripts/raw/master/marzban.sh -o "$MARZBAN_INSTALLER"
  grep -Eq '^[[:space:]]*follow_marzban_logs[[:space:]]*$' "$MARZBAN_INSTALLER" \
    || die 'Marzban 官方安装脚本格式已变化，未找到日志跟随调用，已停止以避免错误执行'
  sed -i 's/^[[:space:]]*follow_marzban_logs[[:space:]]*$/    :/' "$MARZBAN_INSTALLER"
  bash "$MARZBAN_INSTALLER" install
  rm -f "$MARZBAN_INSTALLER"
fi
command -v marzban >/dev/null || die 'Marzban 安装后找不到 marzban 命令'
marzban status >/dev/null || die 'Marzban 安装后状态检查失败，请运行 marzban logs 查看原因'
command -v docker >/dev/null && ok 'Docker 命令可用' || die '找不到 Docker 命令'
docker ps --format '{{.Names}}' | grep -q . || die 'Docker 已安装但没有运行中的容器'
ok 'Docker 容器正在运行'

log '检查 80 端口'
if ss -lntH '( sport = :80 )' | grep -q .; then
  die 'TCP 80 已被占用。standalone 签证书前请停止占用 80 的服务。'
fi

log '安装 acme.sh 并申请证书'
if [[ ! -x "$ACME_HOME/acme.sh" ]]; then
  curl -fsSL https://get.acme.sh | sh
fi
"$ACME_HOME/acme.sh" --set-default-ca --server letsencrypt
ACME_CERT_SOURCE=""
ACME_INSTALL_ARGS=()
for candidate in \
  "$ACME_HOME/$DOMAIN/fullchain.cer" \
  "$ACME_HOME/${DOMAIN}_ecc/fullchain.cer"; do
  if [[ -s "$candidate" ]] && openssl x509 -in "$candidate" -noout -checkend 2592000 >/dev/null 2>&1; then
    ACME_CERT_SOURCE="$candidate"
    [[ "$candidate" == *"_ecc/"* ]] && ACME_INSTALL_ARGS+=(--ecc)
    break
  fi
done

if [[ -n "$ACME_CERT_SOURCE" ]]; then
  CERT_EXPIRES="$(openssl x509 -in "$ACME_CERT_SOURCE" -noout -enddate | cut -d= -f2-)"
  ok "检测到有效证书，跳过签发，有效期至: $CERT_EXPIRES"
else
  log '未检测到有效期超过 30 天的证书，开始申请或续期'
  "$ACME_HOME/acme.sh" --issue -d "$DOMAIN" --standalone --keylength ec-256
  ACME_INSTALL_ARGS=(--ecc)
fi

mkdir -p "$CERT_DIR"
"$ACME_HOME/acme.sh" --install-cert -d "$DOMAIN" \
  "${ACME_INSTALL_ARGS[@]}" \
  --fullchain-file "$CERT_DIR/$DOMAIN.cer" \
  --key-file "$CERT_DIR/$DOMAIN.cer.key" \
  --reloadcmd 'marzban restart -n'
chmod 644 "$CERT_DIR/$DOMAIN.cer"
chmod 600 "$CERT_DIR/$DOMAIN.cer.key"
[[ -s "$CERT_DIR/$DOMAIN.cer" && -s "$CERT_DIR/$DOMAIN.cer.key" ]] || die '证书文件安装失败'
openssl x509 -in "$CERT_DIR/$DOMAIN.cer" -noout -checkend 0 >/dev/null || die '证书无效或已过期'
ok "证书已安装: $CERT_DIR"

log '写入 Marzban HTTPS 配置'
[[ -f "$MARZBAN_DIR/.env" ]] || die "$MARZBAN_DIR/.env 不存在"
download_template "$TEMPLATE_URL" "$TEMPLATE_DEST"
download_template "$CLASH_TEMPLATE_URL" "$CLASH_TEMPLATE_DEST"
cp -a "$MARZBAN_DIR/.env" "$MARZBAN_DIR/.env.bak.$(date +%Y%m%d%H%M%S)"
set_env UVICORN_HOST 0.0.0.0
set_env UVICORN_PORT "$PANEL_PORT"
set_env UVICORN_SSL_CERTFILE "$CERT_DIR/$DOMAIN.cer"
set_env UVICORN_SSL_KEYFILE "$CERT_DIR/$DOMAIN.cer.key"
set_env XRAY_SUBSCRIPTION_URL_PREFIX "https://$DOMAIN:$PANEL_PORT"
set_env CUSTOM_TEMPLATES_DIRECTORY "$TEMPLATE_DIR/"
set_env SUBSCRIPTION_PAGE_TEMPLATE "subscription/index.html"
set_env CLASH_SUBSCRIPTION_TEMPLATE "clash/my-custom-template.yml"
marzban restart -n
ok 'Marzban 已重启'

log '检查部署状态'
marzban status >/dev/null 2>&1 || die 'Marzban 状态检查失败，请运行: marzban logs'
ok 'Marzban 状态正常'
PANEL_READY=false
for _ in $(seq 1 30); do
  if curl -fsS \
    --noproxy '*' \
    --resolve "$DOMAIN:$PANEL_PORT:127.0.0.1" \
    --connect-timeout 2 \
    --max-time 5 \
    "https://$DOMAIN:$PANEL_PORT/" >/dev/null 2>&1; then
    PANEL_READY=true
    break
  fi
  sleep 2
done
[[ "$PANEL_READY" == true ]] || die 'Marzban 容器已运行，但 HTTPS 面板在 60 秒内未就绪，请运行: marzban logs'
ok "HTTPS 面板已在本机端口 $PANEL_PORT 就绪"

if curl -fsS --noproxy '*' --connect-timeout 10 --max-time 20 "https://$DOMAIN:$PANEL_PORT/" >/dev/null 2>&1; then
  ok "HTTPS 面板可通过公网域名访问: https://$DOMAIN:$PANEL_PORT"
else
  warn "本机面板正常，但无法通过公网域名访问，请检查安全组和 TCP $PANEL_PORT"
fi

log '配置管理员'
if marzban cli admin list --username admin --limit 1 </dev/tty 2>/dev/null \
  | sed -E $'s/\033\\[[0-9;]*[mK]//g' \
  | grep -Eq '(^|[^[:alnum:]_])admin([^[:alnum:]_]|$)'; then
  warn '管理员 admin 已存在，跳过创建，参数中的密码不会覆盖现有密码'
else
  marzban cli admin create \
    --username admin \
    --password "$ADMIN_PASSWORD" \
    --sudo \
    --telegram-id 0 \
    --discord-webhook 0 </dev/tty
  ok '管理员 admin 创建成功'
fi
unset ADMIN_PASSWORD

log '完成'
printf '面板: https://%s:%s\n' "$DOMAIN" "$PANEL_PORT"
printf '管理员: admin\n'
printf '查看日志: marzban logs\n'
printf '证书目录: %s\n' "$CERT_DIR"
printf '订阅页模板: %s\n' "$TEMPLATE_DEST"
printf 'Clash 模板: %s\n' "$CLASH_TEMPLATE_DEST"
