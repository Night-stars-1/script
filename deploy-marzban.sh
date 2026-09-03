#!/usr/bin/env bash
set -Eeuo pipefail

PANEL_PORT="${PANEL_PORT:-8080}"
SWAP_SIZE="${SWAP_SIZE:-2G}"
MARZBAN_DIR="/opt/marzban"
CERT_DIR="/var/lib/marzban/certs"
TEMPLATE_URL="https://raw.githubusercontent.com/Night-stars-1/script/main/marzban.html"
CLASH_TEMPLATE_URL="https://raw.githubusercontent.com/Night-stars-1/script/main/marzban-clash.yml"
XRAY_TEMPLATE_URL="https://raw.githubusercontent.com/Night-stars-1/script/main/xray_config.json"
TEMPLATE_DIR="/var/lib/marzban/templates"
TEMPLATE_DEST="$TEMPLATE_DIR/subscription/index.html"
CLASH_TEMPLATE_DEST="$TEMPLATE_DIR/clash/my-custom-template.yml"
XRAY_CONFIG_DEST="/var/lib/marzban/xray_config.json"
ACME_HOME="/root/.acme.sh"
CHANGE_XRAY_URL="https://raw.githubusercontent.com/Night-stars-1/script/main/change-xray-core.sh"
ADMIN_PASSWORD=""
DOMAIN=""
MARZBAN_NODE_DIR="${MARZBAN_NODE_DIR:-/opt/marzban-node}"
MARZBAN_NODE_DATA="${MARZBAN_NODE_DATA:-/var/lib/marzban-node}"
MARZBAN_NODE_SCRIPT_URL="https://github.com/Gozargah/Marzban-scripts/raw/master/marzban-node.sh"

die() { printf '\033[1;31m[marzban][ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1;36m[marzban]\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m[marzban][OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[marzban][WARN]\033[0m %s\n' "$*"; }

usage() {
  cat <<'EOF'
用法: deploy-marzban.sh [1|2|3|4|5] ...

  1  安装 Marzban 主节点（面板）
     deploy-marzban.sh 1 [管理员密码] [面板域名]
     deploy-marzban.sh [管理员密码] [面板域名]

  2  更新 Xray 内核
     deploy-marzban.sh 2
     deploy-marzban.sh 2 main [版本]
     deploy-marzban.sh 2 node [版本]

  3  设置 Cloudflare 中转
     deploy-marzban.sh 3 [域名]
     需提供 Cloudflare API Token（环境变量 CF_Token 或交互输入）

  4  安装 Marzban Node
     deploy-marzban.sh 4
     deploy-marzban.sh 4 [节点目录名]
     Client Certificate 可用 NODE_CLIENT_CERT_FILE 指定 PEM 文件，否则交互粘贴

  5  申请 TLS 证书（Cloudflare DNS-01）
     deploy-marzban.sh 5 [域名]
     证书安装到 /var/lib/marzban/certs/
     不要求域名 A 记录指向本机；需 CF_Token（环境变量或交互输入）
EOF
}

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

install_xray_config() {
  local tmp rendered
  tmp="$(mktemp)"
  rendered="$(mktemp)"
  if ! curl -fsSL "$XRAY_TEMPLATE_URL" -o "$tmp"; then
    rm -f "$tmp" "$rendered"
    die "Xray 核心配置下载失败: $XRAY_TEMPLATE_URL"
  fi
  jq empty "$tmp" >/dev/null 2>&1 || {
    rm -f "$tmp" "$rendered"
    die 'Xray 核心配置不是有效 JSON'
  }
  jq --arg domain "$DOMAIN" \
    'walk(if type == "string" then gsub("__MARZBAN_DOMAIN__"; $domain) else . end)' \
    "$tmp" >"$rendered"
  install -m 644 "$rendered" "$XRAY_CONFIG_DEST"
  rm -f "$tmp" "$rendered"
  jq empty "$XRAY_CONFIG_DEST" >/dev/null 2>&1 || die '生成后的 Xray 核心配置不是有效 JSON'
  ok "Xray 核心配置已安装: $XRAY_CONFIG_DEST"
}

resolve_change_xray_script() {
  local here tmp
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
  if [[ -n "$here" && -f "$here/change-xray-core.sh" ]]; then
    printf '%s\n' "$here/change-xray-core.sh"
    return 0
  fi
  tmp="$(mktemp)"
  if ! curl -fsSL "$CHANGE_XRAY_URL" -o "$tmp"; then
    rm -f "$tmp"
    die "无法下载 Xray 内核更换脚本: $CHANGE_XRAY_URL"
  fi
  printf '%s\n' "$tmp"
}

update_xray_core() {
  local script
  script="$(resolve_change_xray_script)"
  log '开始更新 Xray 内核'
  bash "$script" "$@"
  if [[ "$script" == /tmp/* || "$script" == /var/tmp/* ]]; then
    rm -f "$script"
  fi
}

compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null; then
    docker-compose "$@"
  else
    die '找不到 docker compose'
  fi
}

ensure_docker() {
  if ! command -v docker >/dev/null; then
    command -v curl >/dev/null || die '找不到 curl，无法安装 Docker'
    log '安装 Docker'
    curl -fsSL https://get.docker.com | sh
  fi
  command -v docker >/dev/null || die 'Docker 安装失败'
  docker info >/dev/null 2>&1 || die 'Docker 已安装但守护进程未运行'
}

read_client_cert() {
  local dest="$1" line
  mkdir -p "$(dirname "$dest")"
  if [[ -n "${NODE_CLIENT_CERT_FILE:-}" ]]; then
    [[ -s "$NODE_CLIENT_CERT_FILE" ]] || die "证书文件不存在或为空: $NODE_CLIENT_CERT_FILE"
    install -m 644 "$NODE_CLIENT_CERT_FILE" "$dest"
    grep -q 'BEGIN CERTIFICATE' "$dest" || die '证书内容不是有效 PEM（缺少 BEGIN CERTIFICATE）'
    return 0
  fi
  [[ -r /dev/tty ]] || die '需要交互终端粘贴 Client Certificate，或设置 NODE_CLIENT_CERT_FILE'
  printf '请粘贴面板里复制的 Client Certificate（PEM），空行结束:\n'
  : >"$dest"
  while IFS= read -r line </dev/tty; do
    [[ -z "$line" ]] && break
    printf '%s\n' "$line" >>"$dest"
  done
  [[ -s "$dest" ]] || die '未读到证书内容'
  grep -q 'BEGIN CERTIFICATE' "$dest" || die '证书内容不是有效 PEM（缺少 BEGIN CERTIFICATE）'
  chmod 644 "$dest"
}

install_marzban_node() {
  local name="${1:-marzban-node}" use_rest="" service_port xray_api_port node_ip compose_file cert_file
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "节点名称不合法: $name"
  MARZBAN_NODE_DIR="/opt/$name"
  MARZBAN_NODE_DATA="/var/lib/$name"
  compose_file="$MARZBAN_NODE_DIR/docker-compose.yml"
  cert_file="$MARZBAN_NODE_DATA/cert.pem"

  command -v apt-get >/dev/null || die '此脚本仅支持 Debian/Ubuntu 系统'
  if [[ -f "$compose_file" ]]; then
    warn "已检测到现有 Node: $MARZBAN_NODE_DIR"
    [[ -r /dev/tty ]] || die '已安装 Marzban Node。要覆盖请在交互终端重新运行'
    local reply=""
    read -r -p $'是否覆盖当前安装? [y/N]: ' reply </dev/tty
    [[ "$reply" =~ ^[Yy]$ ]] || die '已取消安装'
  fi

  log '安装依赖'
  apt-get update
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
  apt-get install -y -o Dpkg::Options::=--force-confold curl ca-certificates
  ensure_docker

  mkdir -p "$MARZBAN_NODE_DIR" "$MARZBAN_NODE_DATA" /var/lib/marzban
  read_client_cert "$cert_file"
  ok "证书已保存: $cert_file"

  use_rest="${NODE_USE_REST:-}"
  if [[ -z "$use_rest" ]]; then
    [[ -r /dev/tty ]] || die '需要交互终端选择 REST 协议'
    read -r -p $'是否使用 REST 协议? [Y/n]: ' use_rest </dev/tty
  fi
  if [[ -z "$use_rest" || "$use_rest" =~ ^([Yy]|true|TRUE|1)$ ]]; then
    use_rest=true
  else
    use_rest=false
  fi

  service_port="${SERVICE_PORT:-}"
  xray_api_port="${XRAY_API_PORT:-}"
  if [[ -z "$service_port" ]]; then
    [[ -r /dev/tty ]] || die '需要交互终端输入 SERVICE_PORT，或设置环境变量 SERVICE_PORT'
    read -r -p $'请输入 SERVICE_PORT [62050]: ' service_port </dev/tty
  fi
  service_port="${service_port:-62050}"
  [[ "$service_port" =~ ^[0-9]+$ && "$service_port" -ge 1 && "$service_port" -le 65535 ]] || die "SERVICE_PORT 无效: $service_port"

  if [[ -z "$xray_api_port" ]]; then
    [[ -r /dev/tty ]] || die '需要交互终端输入 XRAY_API_PORT，或设置环境变量 XRAY_API_PORT'
    read -r -p $'请输入 XRAY_API_PORT [62051]: ' xray_api_port </dev/tty
  fi
  xray_api_port="${xray_api_port:-62051}"
  [[ "$xray_api_port" =~ ^[0-9]+$ && "$xray_api_port" -ge 1 && "$xray_api_port" -le 65535 ]] || die "XRAY_API_PORT 无效: $xray_api_port"
  [[ "$xray_api_port" != "$service_port" ]] || die 'XRAY_API_PORT 不能与 SERVICE_PORT 相同'

  if command -v ss >/dev/null; then
    if ss -lntH "( sport = :$service_port )" | grep -q .; then
      die "TCP $service_port 已被占用"
    fi
    if ss -lntH "( sport = :$xray_api_port )" | grep -q .; then
      die "TCP $xray_api_port 已被占用"
    fi
  fi

  log "写入 $compose_file"
  cat >"$compose_file" <<EOF
services:
  marzban-node:
    container_name: ${name}
    image: gozargah/marzban-node:latest
    restart: always
    network_mode: host
    environment:
      SSL_CLIENT_CERT_FILE: "/var/lib/marzban-node/cert.pem"
      SERVICE_PORT: "${service_port}"
      XRAY_API_PORT: "${xray_api_port}"
EOF
  if [[ "$use_rest" == true ]]; then
    printf '      SERVICE_PROTOCOL: "rest"\n' >>"$compose_file"
  fi
  cat >>"$compose_file" <<EOF

    volumes:
      - ${MARZBAN_NODE_DATA}:/var/lib/marzban-node
      - /var/lib/marzban:/var/lib/marzban
EOF

  if [[ ! -x /usr/local/bin/marzban-node ]]; then
    log '安装 marzban-node 命令'
    curl -fsSL "$MARZBAN_NODE_SCRIPT_URL" -o /usr/local/bin/marzban-node
    chmod +x /usr/local/bin/marzban-node
  fi

  log '启动 Marzban Node'
  compose -f "$compose_file" --project-directory "$MARZBAN_NODE_DIR" up -d
  docker ps --format '{{.Names}}' | grep -qx "$name" || die 'Marzban Node 容器未运行，请查看: docker compose logs'
  ok 'Marzban Node 已启动'

  node_ip="$(curl -fsS --max-time 8 -4 https://ifconfig.io/ip 2>/dev/null || true)"
  node_ip="${node_ip//$'\n'/}"
  [[ -n "$node_ip" ]] || node_ip="$(curl -fsS --max-time 8 -4 https://api.ipify.org 2>/dev/null || true)"
  node_ip="${node_ip//$'\n'/}"

  log '完成'
  printf '目录: %s\n' "$MARZBAN_NODE_DIR"
  printf 'Client Certificate: %s\n' "$cert_file"
  if [[ "$use_rest" == true ]]; then
    printf '协议: REST\n'
  else
    printf '协议: gRPC\n'
  fi
  printf '面板添加节点时填写:\n'
  printf '  地址: %s\n' "${node_ip:-请自行填写节点公网 IP}"
  printf '  服务端口: %s\n' "$service_port"
  printf '  API 端口: %s\n' "$xray_api_port"
  printf '日志: docker compose -f %s logs -f\n' "$compose_file"
  printf '请在防火墙/安全组放行 TCP %s 和 %s，以及 Xray 入站端口\n' "$service_port" "$xray_api_port"
}

ensure_acme() {
  if [[ ! -x "$ACME_HOME/acme.sh" ]]; then
    command -v curl >/dev/null || die '找不到 curl，无法安装 acme.sh'
    log '安装 acme.sh'
    curl -fsSL https://get.acme.sh | sh
  fi
  [[ -x "$ACME_HOME/acme.sh" ]] || die "acme.sh 安装失败: $ACME_HOME/acme.sh"
}

issue_letsencrypt_cert() {
  local domain="$1"
  local reloadcmd="${2:-}"
  local mode="${3:-standalone}"
  local candidate ACME_CERT_SOURCE="" CERT_EXPIRES
  local -a ACME_INSTALL_ARGS=()
  [[ -n "$domain" ]] || die 'TLS 证书域名不能为空'
  [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || die '域名格式不正确'
  command -v openssl >/dev/null || die '找不到 openssl'
  if [[ "$mode" != dns_cf && "$mode" != standalone ]]; then
    die "未知签证书方式: $mode"
  fi

  if [[ "$mode" == standalone ]]; then
    command -v socat >/dev/null || die '找不到 socat，无法用 HTTP-01 签证书'
    log '预检查 DNS'
    DNS_IP="$(getent ahostsv4 "$domain" 2>/dev/null | awk 'NR == 1 { print $1 }' || true)"
    DNS_IPV6="$(getent ahostsv6 "$domain" 2>/dev/null | awk 'NR == 1 { print $1 }' || true)"
    printf 'A 记录: %s\n' "${DNS_IP:-未找到}"
    printf 'AAAA 记录: %s\n' "${DNS_IPV6:-未找到}"
    [[ -n "$DNS_IP" ]] || die '没有查到域名 A 记录，请先将域名解析到本机公网 IPv4'
    ok "A 记录已解析: $DNS_IP"
    log '检查 80 端口'
    if ss -lntH '( sport = :80 )' | grep -q .; then
      die 'TCP 80 已被占用。HTTP-01 签证书前请停止占用 80 的服务。'
    fi
  else
    [[ -n "${CF_Token:-}" ]] || die 'Cloudflare DNS-01 需要 CF_Token'
    log '使用 Cloudflare DNS-01，不要求域名 A 记录指向本机'
  fi

  ensure_acme
  "$ACME_HOME/acme.sh" --set-default-ca --server letsencrypt
  for candidate in \
    "$ACME_HOME/$domain/fullchain.cer" \
    "$ACME_HOME/${domain}_ecc/fullchain.cer"; do
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
    if [[ "$mode" == dns_cf ]]; then
      "$ACME_HOME/acme.sh" --issue --dns dns_cf -d "$domain" --keylength ec-256
    else
      "$ACME_HOME/acme.sh" --issue -d "$domain" --standalone --keylength ec-256
    fi
    ACME_INSTALL_ARGS=(--ecc)
  fi

  mkdir -p "$CERT_DIR"
  if [[ -n "$reloadcmd" ]]; then
    "$ACME_HOME/acme.sh" --install-cert -d "$domain" \
      "${ACME_INSTALL_ARGS[@]}" \
      --fullchain-file "$CERT_DIR/$domain.cer" \
      --key-file "$CERT_DIR/$domain.cer.key" \
      --reloadcmd "$reloadcmd"
  else
    "$ACME_HOME/acme.sh" --install-cert -d "$domain" \
      "${ACME_INSTALL_ARGS[@]}" \
      --fullchain-file "$CERT_DIR/$domain.cer" \
      --key-file "$CERT_DIR/$domain.cer.key"
  fi
  chmod 644 "$CERT_DIR/$domain.cer"
  chmod 600 "$CERT_DIR/$domain.cer.key"
  [[ -s "$CERT_DIR/$domain.cer" && -s "$CERT_DIR/$domain.cer.key" ]] || die '证书文件安装失败'
  openssl x509 -in "$CERT_DIR/$domain.cer" -noout -checkend 0 >/dev/null || die '证书无效或已过期'
  ok "TLS 证书已安装: $CERT_DIR/$domain.cer"
}

setup_tls_cert() {
  local reloadcmd="" node_name="" token=""
  command -v apt-get >/dev/null || die '此脚本仅支持 Debian/Ubuntu 系统'
  DOMAIN="${DOMAIN:-${NODE_TLS_DOMAIN:-}}"
  if [[ -z "$DOMAIN" ]]; then
    [[ -r /dev/tty ]] || die '需要交互终端输入 TLS 证书域名，或使用: deploy-marzban.sh 5 域名'
    read -r -p $'请输入 TLS 证书域名: ' DOMAIN </dev/tty
  fi
  [[ -n "$DOMAIN" ]] || die 'TLS 证书域名不能为空'
  token="${CF_Token:-${CF_TOKEN:-}}"
  if [[ -z "$token" ]]; then
    [[ -r /dev/tty ]] || die '需要交互终端输入 Cloudflare API Token，或先 export CF_Token'
    read -r -s -p $'请输入 Cloudflare API Token: ' token </dev/tty
    printf '\n'
    [[ -n "$token" ]] || die 'Cloudflare API Token 不能为空'
  fi
  export CF_Token="$token"
  log '安装依赖'
  apt-get update
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
  apt-get install -y -o Dpkg::Options::=--force-confold curl ca-certificates openssl
  if command -v docker >/dev/null; then
    node_name="$(docker ps --format '{{.Names}}' 2>/dev/null | awk '/marzban-node/{ print; exit }')"
    if [[ -n "$node_name" ]]; then
      reloadcmd="docker restart ${node_name}"
    fi
  fi
  if [[ -z "$reloadcmd" ]] && command -v marzban >/dev/null && [[ -f "$MARZBAN_DIR/.env" ]]; then
    reloadcmd='marzban restart -n'
  fi
  if [[ -z "$reloadcmd" ]]; then
    warn '未检测到 Marzban 或 Node 容器，仅安装证书文件'
  else
    log "证书续期将执行: $reloadcmd"
  fi
  issue_letsencrypt_cert "$DOMAIN" "$reloadcmd" dns_cf
  unset CF_Token
  log '完成'
  printf '域名: %s\n' "$DOMAIN"
  printf '证书: %s\n' "$CERT_DIR/$DOMAIN.cer"
  printf '私钥: %s\n' "$CERT_DIR/$DOMAIN.cer.key"
}

cert_sha256_fingerprint() {
  local cert="$1" fp
  [[ -s "$cert" ]] || die "证书不存在: $cert"
  fp="$(openssl x509 -in "$cert" -noout -fingerprint -sha256 | sed 's/^.*=//;s/://g' | tr '[:upper:]' '[:lower:]')"
  [[ -n "$fp" ]] || die "无法计算证书指纹: $cert"
  printf '%s\n' "$fp"
}

ensure_vless_xhttp_inbound() {
  local file="$XRAY_CONFIG_DEST" tmp
  [[ -f "$file" ]] || die "找不到 Xray 配置: $file，请先安装 Marzban"
  if ! command -v jq >/dev/null; then
    command -v apt-get >/dev/null || die '找不到 jq，无法更新 Xray 配置'
    apt-get install -y -o Dpkg::Options::=--force-confold jq
  fi
  command -v jq >/dev/null || die 'jq 安装失败'
  jq empty "$file" >/dev/null 2>&1 || die "Xray 配置不是有效 JSON: $file"
  tmp="$(mktemp)"
  jq --arg domain "$DOMAIN" \
    --arg cert "$CERT_DIR/$DOMAIN.cer" \
    --arg key "$CERT_DIR/$DOMAIN.cer.key" '
    .inbounds //= []
    | .inbounds |= map(select(.tag != "VLESS XHTTP TLS"))
    | .inbounds += [{
        "tag": "VLESS XHTTP TLS",
        "listen": "0.0.0.0",
        "port": 2087,
        "protocol": "vless",
        "settings": {
          "clients": [],
          "decryption": "none"
        },
        "streamSettings": {
          "network": "xhttp",
          "xhttpSettings": {
            "path": "/vlessx",
            "mode": "auto"
          },
          "security": "tls",
          "tlsSettings": {
            "serverName": $domain,
            "certificates": [
              {
                "ocspStapling": 3600,
                "certificateFile": $cert,
                "keyFile": $key
              }
            ],
            "minVersion": "1.2"
          }
        },
        "sniffing": {
          "enabled": true,
          "destOverride": ["http", "tls", "quic"]
        }
      }]
  ' "$file" >"$tmp"
  jq empty "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; die '写入 VLESS XHTTP inbound 后 JSON 无效'; }
  cp -a "$file" "$file.bak.$(date +%Y%m%d%H%M%S)"
  install -m 644 "$tmp" "$file"
  rm -f "$tmp"
  ok "已写入 VLESS XHTTP TLS inbound: $file"
}

setup_cf_relay() {
  local token="${CF_Token:-${CF_TOKEN:-}}"
  if [[ -z "$DOMAIN" ]]; then
    [[ -r /dev/tty ]] || die '需要交互终端来输入 Cloudflare 中转域名'
    read -r -p $'请输入 Cloudflare 中转域名: ' DOMAIN </dev/tty
  fi
  [[ -n "$DOMAIN" ]] || die '域名不能为空'
  [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die '域名格式不正确'
  if [[ -z "$token" ]]; then
    [[ -r /dev/tty ]] || die '需要交互终端来输入 Cloudflare API Token，或先 export CF_Token'
    read -r -s -p $'请输入 Cloudflare API Token: ' token </dev/tty
    printf '\n'
  fi
  [[ -n "$token" ]] || die 'Cloudflare API Token 不能为空'
  export CF_Token="$token"
  unset token

  ensure_acme
  "$ACME_HOME/acme.sh" --set-default-ca --server letsencrypt
  log "使用 Cloudflare DNS 签发证书: $DOMAIN"
  "$ACME_HOME/acme.sh" --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256

  mkdir -p "$CERT_DIR"
  if [[ -f "$MARZBAN_DIR/.env" ]]; then
    log '更新 Marzban 证书路径'
    cp -a "$MARZBAN_DIR/.env" "$MARZBAN_DIR/.env.bak.$(date +%Y%m%d%H%M%S)"
    set_env UVICORN_SSL_CERTFILE "$CERT_DIR/$DOMAIN.cer"
    set_env UVICORN_SSL_KEYFILE "$CERT_DIR/$DOMAIN.cer.key"
    set_env XRAY_SUBSCRIPTION_URL_PREFIX "https://$DOMAIN:${PANEL_PORT}"
    ok '已写入 .env'
  else
    warn "$MARZBAN_DIR/.env 不存在，已签发证书但未写入面板配置"
  fi
  log '写入 VLESS XHTTP TLS inbound'
  ensure_vless_xhttp_inbound
  "$ACME_HOME/acme.sh" --install-cert -d "$DOMAIN" --ecc \
    --fullchain-file "$CERT_DIR/$DOMAIN.cer" \
    --key-file "$CERT_DIR/$DOMAIN.cer.key" \
    --reloadcmd 'marzban restart -n'
  chmod 644 "$CERT_DIR/$DOMAIN.cer"
  chmod 600 "$CERT_DIR/$DOMAIN.cer.key"
  [[ -s "$CERT_DIR/$DOMAIN.cer" && -s "$CERT_DIR/$DOMAIN.cer.key" ]] || die '证书文件安装失败'
  openssl x509 -in "$CERT_DIR/$DOMAIN.cer" -noout -checkend 0 >/dev/null || die '证书无效或已过期'
  ok "证书已安装: $CERT_DIR/$DOMAIN.cer"
  unset CF_Token
  log '完成'
  printf '域名: %s\n' "$DOMAIN"
  printf '证书: %s\n' "$CERT_DIR/$DOMAIN.cer"
  printf '私钥: %s\n' "$CERT_DIR/$DOMAIN.cer.key"
  printf 'Xray inbound: VLESS XHTTP TLS  端口 2087  path /vlessx\n'
  printf '证书 SHA256 指纹: %s\n' "$(cert_sha256_fingerprint "$CERT_DIR/$DOMAIN.cer")"
  printf '客户端 pinnedPeerCertSha256 可用上面的指纹（不要写进服务端 xray_config.json）\n'
}

prompt_action() {
  local choice=""
  [[ -r /dev/tty ]] || die '需要交互终端，或使用: deploy-marzban.sh 1|2|3|4|5'
  {
    printf '\n请选择操作:\n'
    printf '  1. 安装 Marzban 主节点（面板）\n'
    printf '  2. 更新 Xray 内核\n'
    printf '  3. 设置 Cloudflare 中转\n'
    printf '  4. 安装 Marzban Node\n'
    printf '  5. 申请 TLS 证书（Cloudflare DNS-01）\n'
  } >/dev/tty
  read -r -p $'请输入编号 [1-5]: ' choice </dev/tty
  printf '%s\n' "$choice"
}

install_marzban() {
  [[ -r /dev/tty ]] || die '需要交互终端来输入缺少的域名或密码'
  if [[ -z "$ADMIN_PASSWORD" ]]; then
    read -r -s -p $'请输入 admin 管理员密码: ' ADMIN_PASSWORD </dev/tty
    printf '\n'
  fi
  [[ -n "$ADMIN_PASSWORD" ]] || die '管理员密码不能为空'
  if [[ -z "$DOMAIN" ]]; then
    read -r -p $'请输入面板域名: ' DOMAIN </dev/tty
  fi
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
    curl ca-certificates socat openssl dnsutils jq
  ok '依赖安装完成'

  log '安装 Marzban 主节点'
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

  log '申请 TLS 证书'
  issue_letsencrypt_cert "$DOMAIN" 'marzban restart -n'

  log '写入 Marzban HTTPS 配置'
  [[ -f "$MARZBAN_DIR/.env" ]] || die "$MARZBAN_DIR/.env 不存在"
  download_template "$TEMPLATE_URL" "$TEMPLATE_DEST"
  download_template "$CLASH_TEMPLATE_URL" "$CLASH_TEMPLATE_DEST"
  install_xray_config
  cp -a "$MARZBAN_DIR/.env" "$MARZBAN_DIR/.env.bak.$(date +%Y%m%d%H%M%S)"
  set_env UVICORN_HOST 0.0.0.0
  set_env UVICORN_PORT "$PANEL_PORT"
  set_env UVICORN_SSL_CERTFILE "$CERT_DIR/$DOMAIN.cer"
  set_env UVICORN_SSL_KEYFILE "$CERT_DIR/$DOMAIN.cer.key"
  set_env XRAY_SUBSCRIPTION_URL_PREFIX "https://$DOMAIN:$PANEL_PORT"
  set_env XRAY_JSON "$XRAY_CONFIG_DEST"
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
  printf 'Xray 配置: %s\n' "$XRAY_CONFIG_DEST"
}

main() {
  [[ "$(id -u)" == 0 ]] || die '请使用 root 执行: sudo -i'
  local action=""
  case "${1:-}" in
    -h|--help|help)
      usage
      return 0
      ;;
    1|install)
      ADMIN_PASSWORD="${2:-}"
      DOMAIN="${3:-}"
      action=install
      ;;
    2|update|core)
      shift
      update_xray_core "$@"
      return 0
      ;;
    3|cf|cloudflare)
      DOMAIN="${2:-}"
      action=cf
      ;;
    4|node)
      action=node
      ;;
    5|tls|cert)
      DOMAIN="${2:-}"
      action=tls
      ;;
    '')
      action="$(prompt_action)"
      ;;
    *)
      if [[ -n "${2:-}" ]]; then
        ADMIN_PASSWORD="$1"
        DOMAIN="$2"
        action=install
      else
        die "未知选项: $1（输入 1 安装主节点，2 更新内核，3 设置 CF 中转，4 安装 Node，5 申请 TLS 证书）"
      fi
      ;;
  esac
  case "$action" in
    1|install) install_marzban ;;
    2|update|core) update_xray_core ;;
    3|cf|cloudflare) setup_cf_relay ;;
    4|node) install_marzban_node "${2:-marzban-node}" ;;
    5|tls|cert) setup_tls_cert ;;
    *) die '无效选择，请输入 1、2、3、4 或 5' ;;
  esac
}

main "$@"
