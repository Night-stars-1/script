#!/usr/bin/env bash
# 辅节点(边缘)加入集群跑 proxy 的引导脚本 —— 在【辅节点本机】以 root 运行。
#   check:环境体检(本机内外网 IP + 到主服务器各端口连通性),只读零变更
#   join: 写 config.yaml/registries.yaml + 安装 k3s agent + 等待节点 Ready
# 打标签/调副本在主服务器执行,join 结束会打印命令清单。
# 背景与安全组要求见 deployments/k8s-server/multinode-public.md。
#
# 用法:
#   本机跑:      scripts/k8s-edge.sh check
#                scripts/k8s-edge.sh join     # token/仓库密码运行时终端输入
#   从工作机推:  scp scripts/k8s-edge.sh root@<辅节点>:/tmp/ \
#                && ssh root@<辅节点> 'bash /tmp/k8s-edge.sh check'
#
# 配置(env):
#   MAIN_PUBLIC_IP=114.55.170.102   主服务器公网 IP
#   K3S_PORT=6443  REGISTRY_PORT=5000  REDIS_PORT=6379  PG_PORT=5432
#   ---- join 专用 ----
#   K3S_TOKEN / REGISTRY_PASSWORD   默认运行时交互输入;env 预设可免交互(供自动化)
#   PROXY_ADVERTISE_HOST=<空>       proxy 广播地址(域名/IP,随注册打标签;交互回车=公网IP,none=不打)
#   TUNNEL_ADVERTISE_HOST=<空>      tunnel 广播域名(随注册打 tunnel 标签;交互回车=不跑 tunnel)
#   REGISTRY_USERNAME=registry      镜像仓库用户名
#   K3S_VERSION=v1.36.2+k3s1        必须与主服务器一致(kubectl get nodes 可查)
#   REMOTE_REGISTRY=172.25.55.165:5000  pod 镜像前缀(与部署时 REMOTE_REGISTRY 一致)
#   K3S_MIRROR=cn                   安装镜像源(cn=rancher 国内镜像;其他值=官方 get.k3s.io)
set -euo pipefail

MAIN_PUBLIC_IP="${MAIN_PUBLIC_IP:-114.55.170.102}"
K3S_PORT="${K3S_PORT:-6443}"
REGISTRY_PORT="${REGISTRY_PORT:-5000}"
REDIS_PORT="${REDIS_PORT:-6379}"
PG_PORT="${PG_PORT:-5432}"
K3S_VERSION="${K3S_VERSION:-v1.36.2+k3s1}"
REMOTE_REGISTRY="${REMOTE_REGISTRY:-172.25.55.165:5000}"
REGISTRY_USERNAME="${REGISTRY_USERNAME:-registry}"
K3S_MIRROR="${K3S_MIRROR:-cn}"

log() { printf '\033[1;36m[k8s-edge]\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m[k8s-edge] ✓\033[0m %s\n' "$*"; }
bad() { printf '\033[1;31m[k8s-edge] ✗\033[0m %s\n' "$*"; FAILED=1; }
die() { printf '\033[1;31m[k8s-edge] %s\033[0m\n' "$*" >&2; exit 1; }

FAILED=0
NODE_PRIVATE_IP=""
NODE_PUBLIC_IP=""

# 阿里云元数据服务;非阿里云机器请求超时后自动回退通用手段
META="http://100.100.100.200/latest/meta-data"

# 本机内网 IP:优先云元数据,回退"到主服务器的路由源地址"(多网卡时取真正出口那张)
detect_ips() {
  local private public
  private="$(curl -sf -m 3 "$META/private-ipv4" 2>/dev/null || true)"
  if [[ -z "$private" ]]; then
    # 管道整体兜 || true:ip 不存在(127)时 pipefail 会静默炸掉整个脚本
    private="$(ip -4 route get "$MAIN_PUBLIC_IP" 2>/dev/null |
      awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }' || true)"
  fi
  # 公网 IP:优先云元数据 EIP,回退公网回显服务
  public="$(curl -sf -m 3 "$META/eipv4" 2>/dev/null || true)"
  if [[ -z "$public" ]]; then
    public="$(curl -sf -m 5 https://ipinfo.io/ip 2>/dev/null || true)"
  fi
  [[ -n "$private" ]] || die "获取内网 IP 失败(云元数据与 ip route 都拿不到)"
  [[ -n "$public" ]] || die "获取公网 IP 失败(云元数据与 ipinfo.io 都拿不到)"
  NODE_PRIVATE_IP="$private"
  NODE_PUBLIC_IP="$public"
  log "本机内网 IP: $NODE_PRIVATE_IP"
  log "本机公网 IP: $NODE_PUBLIC_IP"
}

# 纯 bash TCP 探测(不依赖 nc):通/不通,不通给安全组排查提示
tcp_probe() {
  local host="$1" port="$2" desc="$3"
  if timeout 4 bash -c "echo > /dev/tcp/$host/$port" 2>/dev/null; then
    ok "$desc($host:$port)"
  else
    bad "$desc($host:$port)不通 —— 检查主服务器安全组是否放行本机 $NODE_PUBLIC_IP"
  fi
}

cmd_check() {
  command -v curl >/dev/null 2>&1 || die "缺少 curl"
  detect_ips

  log "---- 到主服务器 $MAIN_PUBLIC_IP 的连通性 ----"
  # k3s API:不止端口通,还要求 /ping 应答 pong(证明是 k3s 而非别的进程占端口)
  if [[ "$(curl -sk -m 5 "https://$MAIN_PUBLIC_IP:$K3S_PORT/ping" 2>/dev/null)" == "pong" ]]; then
    ok "k3s API($MAIN_PUBLIC_IP:$K3S_PORT,/ping=pong)"
  else
    bad "k3s API($MAIN_PUBLIC_IP:$K3S_PORT)不通或无应答 —— 检查主服务器安全组 $K3S_PORT/tcp 放行本机 $NODE_PUBLIC_IP"
  fi

  # 镜像仓库:HTTP /v2/ 有应答即可(200=匿名可读,401=要凭证,都算通)
  local code
  code="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://$MAIN_PUBLIC_IP:$REGISTRY_PORT/v2/" 2>/dev/null || true)"
  if [[ "$code" == "200" || "$code" == "401" ]]; then
    ok "镜像仓库($MAIN_PUBLIC_IP:$REGISTRY_PORT,/v2/ HTTP $code)"
  else
    bad "镜像仓库($MAIN_PUBLIC_IP:$REGISTRY_PORT)不通(HTTP ${code:-000}) —— 检查安全组 $REGISTRY_PORT/tcp"
  fi

  tcp_probe "$MAIN_PUBLIC_IP" "$REDIS_PORT" "Redis"
  tcp_probe "$MAIN_PUBLIC_IP" "$PG_PORT" "PostgreSQL"

  # 出网:拉 docker.io 镜像要走的加速站(有 HTTP 应答即可)
  code="$(curl -s -m 6 -o /dev/null -w '%{http_code}' "https://docker.1panel.live/v2/" 2>/dev/null || true)"
  if [[ -n "$code" && "$code" != "000" ]]; then
    ok "公网出网(docker.1panel.live HTTP $code)"
  else
    bad "公网出网异常 —— docker.io 镜像加速站无应答,拉基础镜像会失败"
  fi

  # vxlan 是 UDP 无握手、10250 是入方向,本机都探不了,只列清单人工确认
  log "---- 请人工确认安全组放行(开放方 ← 来源) ----"
  log "  主服务器 $MAIN_PUBLIC_IP:51820/udp  ← $NODE_PUBLIC_IP"
  log "  本机 $NODE_PUBLIC_IP:51820/udp  ← $MAIN_PUBLIC_IP"
  log "  本机 $NODE_PUBLIC_IP:10250/tcp ← $MAIN_PUBLIC_IP"

  if ((FAILED)); then
    die "体检未通过,先修复上述 ✗ 项再继续"
  fi
  log "体检通过。下一步: K3S_TOKEN=<token> REGISTRY_PASSWORD=<密码> $0 join"
}

# 写文件前先比对:已是目标内容则跳过;有差异则备份原文件再覆盖(可回滚、幂等重跑)
write_file_with_backup() {
  local path="$1" content="$2" ts
  if [[ -f "$path" ]]; then
    if [[ "$(cat "$path")" == "$content" ]]; then
      log "$path 已是目标内容,跳过"
      return 0
    fi
    ts="$(date +%Y%m%d%H%M%S)"
    cp -a "$path" "$path.bak.$ts"
    log "已备份原 $path → $path.bak.$ts"
  fi
  printf '%s\n' "$content" >"$path"
  log "已写入 $path"
}

# 等待 agent 激活,再用 kubelet 自身凭证确认本节点 Ready(node 授权器允许 kubelet 读自己的 Node)
wait_join() {
  local node="$1" waited=0 state=""
  while ((waited < 120)); do
    state="$(systemctl is-active k3s-agent 2>/dev/null || true)"
    if [[ "$state" == "active" ]]; then break; fi
    if [[ -t 1 ]]; then
      printf '\r\033[K\033[1;36m[k8s-edge]\033[0m 等待 k3s-agent 激活(%s) %ss ...' "$state" "$waited"
    fi
    sleep 3
    waited=$((waited + 3))
  done
  if [[ -t 1 ]]; then printf '\r\033[K'; fi
  [[ "$state" == "active" ]] || die "k3s-agent 120s 未激活,排查: journalctl -u k3s-agent -n 30"
  ok "k3s-agent 服务已激活"

  local kc=/var/lib/rancher/k3s/agent/kubelet.kubeconfig
  waited=0
  while ((waited < 60)); do
    if k3s kubectl --kubeconfig "$kc" get node "$node" --no-headers 2>/dev/null | awk '$2 == "Ready" { found = 1 } END { exit !found }'; then
      ok "节点 $node 已 Ready"
      return 0
    fi
    if [[ -t 1 ]]; then
      printf '\r\033[K\033[1;36m[k8s-edge]\033[0m 等待节点 Ready %ss ...' "$waited"
    fi
    sleep 3
    waited=$((waited + 3))
  done
  if [[ -t 1 ]]; then printf '\r\033[K'; fi
  log "60s 内未在本地确认 Ready(不代表失败),请在主服务器核对: kubectl get nodes -o wide"
}

cmd_join() {
  [[ "$(id -u)" == "0" ]] || die "join 需要 root 执行"
  # token/密码默认终端交互输入;env 预设可跳过交互(供自动化),非 TTY 且未预设则报错
  if [[ -z "${K3S_TOKEN:-}" ]]; then
    [[ -t 0 ]] || die "非交互环境请用 env 预设 K3S_TOKEN"
    read -r -p "K3S join token(主服务器: cat /var/lib/rancher/k3s/server/node-token): " K3S_TOKEN
    [[ -n "$K3S_TOKEN" ]] || die "token 不能为空"
  fi
  if [[ -z "${REGISTRY_PASSWORD:-}" ]]; then
    [[ -t 0 ]] || die "非交互环境请用 env 预设 REGISTRY_PASSWORD"
    read -rs -p "镜像仓库密码(用户 $REGISTRY_USERNAME,输入不回显): " REGISTRY_PASSWORD
    echo
    [[ -n "$REGISTRY_PASSWORD" ]] || die "密码不能为空"
  fi

  # 先过体检(内含 IP 探测,置 NODE_PRIVATE_IP/NODE_PUBLIC_IP),不通不动手
  cmd_check

  # proxy/tunnel 标签随注册自动打(k3s node-label 仅首次注册生效;idlephone.io/* 自定义
  # 前缀不受 NodeRestriction 限制)。proxy 回车=广播本机公网 IP,输 none=不打;
  # tunnel 回车=跳过(它还依赖本机 nginx/TLS/DNS 与主侧 replicas+deploy,默认不掺和)。
  if [[ -z "${PROXY_ADVERTISE_HOST:-}" ]]; then
    if [[ -t 0 ]]; then
      read -r -p "本节点 proxy 广播地址(域名;回车=用公网IP $NODE_PUBLIC_IP;输 none=跳过打标签): " PROXY_ADVERTISE_HOST
    fi
    PROXY_ADVERTISE_HOST="${PROXY_ADVERTISE_HOST:-$NODE_PUBLIC_IP}"
  fi
  if [[ -z "${TUNNEL_ADVERTISE_HOST:-}" && -t 0 ]]; then
    read -r -p "本节点 tunnel 广播域名(回车=本节点不跑 tunnel): " TUNNEL_ADVERTISE_HOST
  fi
  TUNNEL_ADVERTISE_HOST="${TUNNEL_ADVERTISE_HOST:-}"

  mkdir -p /etc/rancher/k3s

  # 1. config.yaml:node-ip=内网 node-external-ip=公网(flannel 公网互联/在线列表都依赖它)。
  #    注意不能写 advertise-address —— 那是 server 参数,agent 解析直接失败退出。
  local label_lines=""
  if [[ "$PROXY_ADVERTISE_HOST" != "none" ]]; then
    label_lines+="
  - \"idlephone.io/proxy=true\"
  - \"idlephone.io/proxy-host=$PROXY_ADVERTISE_HOST\""
  fi
  if [[ -n "$TUNNEL_ADVERTISE_HOST" ]]; then
    label_lines+="
  - \"idlephone.io/tunnel=true\"
  - \"idlephone.io/tunnel-host=$TUNNEL_ADVERTISE_HOST\""
  fi
  local k3s_config
  k3s_config="node-ip: \"$NODE_PRIVATE_IP\"
node-external-ip: \"$NODE_PUBLIC_IP\""
  if [[ -n "$label_lines" ]]; then
    k3s_config+="
node-label:$label_lines"
  fi
  write_file_with_backup /etc/rancher/k3s/config.yaml "$k3s_config"

  # 2. registries.yaml:docker.io 走国内加速;pod 镜像前缀(REMOTE_REGISTRY,通常是主服务器
  #    内网 IP:5000,本机路由不到)重定向到主服务器公网入口。凭证按"镜像前缀/实际入口"两个键
  #    都配 —— containerd 匹配凭证的键因版本而异,双写兜底。
  local registries mirror_extra="" configs_extra=""
  if [[ "$REMOTE_REGISTRY" != "$MAIN_PUBLIC_IP:$REGISTRY_PORT" ]]; then
    mirror_extra="
  \"$REMOTE_REGISTRY\":
    endpoint:
      - \"http://$MAIN_PUBLIC_IP:$REGISTRY_PORT\""
    configs_extra="
  \"$REMOTE_REGISTRY\":
    auth:
      username: $REGISTRY_USERNAME
      password: \"$REGISTRY_PASSWORD\""
  fi
  registries="mirrors:
  docker.io:
    endpoint:
      - \"https://docker.1panel.live\"
      - \"https://docker.1panel.dev\"
      - \"https://docker.1ms.run\"$mirror_extra
configs:
  \"$MAIN_PUBLIC_IP:$REGISTRY_PORT\":
    auth:
      username: $REGISTRY_USERNAME
      password: \"$REGISTRY_PASSWORD\"$configs_extra"
  write_file_with_backup /etc/rancher/k3s/registries.yaml "$registries"

  # 3. 安装 k3s agent(幂等,已装且版本一致时安装器自动跳过下载)
  local install_url
  if [[ "$K3S_MIRROR" == "cn" ]]; then
    install_url="https://rancher-mirror.rancher.cn/k3s/k3s-install.sh"
  else
    install_url="https://get.k3s.io"
  fi
  log "安装 k3s agent $K3S_VERSION(镜像源:$K3S_MIRROR)..."
  curl -sfL "$install_url" |
    INSTALL_K3S_MIRROR="$K3S_MIRROR" INSTALL_K3S_VERSION="$K3S_VERSION" \
      K3S_URL="https://$MAIN_PUBLIC_IP:$K3S_PORT" K3S_TOKEN="$K3S_TOKEN" \
      sh -s - agent

  # 安装器在"配置未变"时会跳过服务启动(实际踩过),这里显式 enable + restart 保证配置生效
  systemctl enable k3s-agent >/dev/null 2>&1 || true
  log "重启 k3s-agent 应用配置 ..."
  systemctl restart k3s-agent

  local node
  node="$(hostname | tr '[:upper:]' '[:lower:]')"
  wait_join "$node"

  log "---- join 完成 ----"
  if [[ "$PROXY_ADVERTISE_HOST" != "none" ]]; then
    log "  proxy 标签已随注册打上(proxy=true, proxy-host=$PROXY_ADVERTISE_HOST),DaemonSet 会自动铺到本节点"
  else
    log "  未打 proxy 标签,需要时在主服务器: kubectl label node $node idlephone.io/proxy=true idlephone.io/proxy-host=<地址>"
  fi
  if [[ -n "$TUNNEL_ADVERTISE_HOST" ]]; then
    log "  tunnel 标签已随注册打上(tunnel=true, tunnel-host=$TUNNEL_ADVERTISE_HOST)"
  fi
  log "---- 在【主服务器】核对 ----"
  log "  节点:  kubectl get nodes -o wide          ($node EXTERNAL-IP 应为 $NODE_PUBLIC_IP)"
  log "  proxy: kubectl -n idlephone get pods -o wide | grep proxy   (本节点应出现且 Running)"
  if [[ -n "$TUNNEL_ADVERTISE_HOST" ]]; then
    log "  tunnel: 本机 nginx/TLS/DNS 自行配好;VALUES 里 tunnel.replicas 改成 tunnel 节点数,重新跑 scripts/k8s-server.sh deploy"
  else
    log "  tunnel(可选): kubectl label node $node idlephone.io/tunnel=true idlephone.io/tunnel-host=<域名或 $NODE_PUBLIC_IP>"
    log "                VALUES 里 tunnel.replicas 改成 tunnel 节点数,重新跑 scripts/k8s-server.sh deploy"
  fi
}

case "${1:-}" in
  check) cmd_check ;;
  join) cmd_join ;;
  *)
    echo "用法: $0 {check|join}"
    echo "  check  环境体检:本机内外网 IP + 到主服务器连通性(只读,零变更)"
    echo "  join   写 k3s 配置 + 安装 agent 入集群(需 K3S_TOKEN/REGISTRY_PASSWORD)"
    exit 1
    ;;
esac
