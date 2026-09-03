#!/usr/bin/env bash
# 更换 Marzban / Marzban Node 使用的 Xray-core。
# 用法:
#   bash change-xray-core.sh                  # 交互选择目标与版本
#   bash change-xray-core.sh main             # 主节点，交互选版本
#   bash change-xray-core.sh node v25.12.8    # 节点，指定版本
# 环境变量:
#   TARGET=main|node
#   XRAY_CORE_VERSION=v25.12.8
#   MARZBAN_NODE_DIR=/opt/marzban-node
#   GITHUB_PROXY=https://ghfast.top/          # 可选，加速 GitHub 文件下载
#   SKIP_RESTART=1                            # 只安装内核，不重启服务
#   SKIP_CUSTOM_XRAY_CORE=1                   # 直接退出
#   NONINTERACTIVE=1                          # 不提示，安装最新正式版
set -Eeuo pipefail

TARGET="${1:-${TARGET:-}}"
REQUESTED_VERSION="${2:-${XRAY_CORE_VERSION:-}}"
MARZBAN_DIR="${MARZBAN_DIR:-/opt/marzban}"
XRAY_CORE_DIR="${XRAY_CORE_DIR:-/var/lib/marzban/xray-core}"
XRAY_CORE_BIN="${XRAY_CORE_BIN:-$XRAY_CORE_DIR/xray}"
XRAY_RELEASES_API="${XRAY_RELEASES_API:-https://api.github.com/repos/XTLS/Xray-core/releases?per_page=8}"
SELECTED_XRAY_VERSION=""

die() { printf '\033[1;31m[xray-core][ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1;36m[xray-core]\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m[xray-core][OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[xray-core][WARN]\033[0m %s\n' "$*"; }

usage() {
  cat <<'EOF'
用法: change-xray-core.sh [main|node] [版本]

  main   更换 Marzban 主节点（面板）内核
  node   更换 Marzban Node 内核
  版本   如 v25.12.8 或 latest；省略则交互选择

环境变量: TARGET, XRAY_CORE_VERSION, MARZBAN_NODE_DIR, GITHUB_PROXY, SKIP_RESTART, NONINTERACTIVE
EOF
}

github_file_url() {
  local url="$1"
  if [[ -n "${GITHUB_PROXY:-}" ]]; then
    printf '%s/%s\n' "${GITHUB_PROXY%/}" "$url"
  else
    printf '%s\n' "$url"
  fi
}

xray_asset_name() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'Xray-linux-64.zip\n' ;;
    aarch64|arm64) printf 'Xray-linux-arm64-v8a.zip\n' ;;
    *) die "不支持的架构: $(uname -m)，仅支持 x86_64 / aarch64" ;;
  esac
}

ensure_pkgs() {
  local need=() pkg
  command -v curl >/dev/null || need+=(curl ca-certificates)
  command -v jq >/dev/null || need+=(jq)
  command -v unzip >/dev/null || need+=(unzip)
  ((${#need[@]})) || return 0
  command -v apt-get >/dev/null || die "缺少依赖: ${need[*]}，且当前系统不是 Debian/Ubuntu"
  log "安装依赖: ${need[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y -o Dpkg::Options::=--force-confold "${need[@]}"
  for pkg in curl jq unzip; do
    command -v "$pkg" >/dev/null || die "依赖安装失败: $pkg"
  done
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

compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null; then
    docker-compose "$@"
  else
    die '找不到 docker compose'
  fi
}

fetch_release_json() {
  local json
  json="$(curl -fsSL --retry 3 --retry-delay 1 "$XRAY_RELEASES_API")" \
    || die '无法访问 GitHub API 获取 Xray-core 版本，请检查网络或稍后重试'
  printf '%s' "$json" | jq -e 'type == "array" and length > 0' >/dev/null \
    || die "GitHub API 返回异常: $(printf '%s' "$json" | jq -r '.message // "未知错误"' 2>/dev/null || printf '非 JSON')"
  printf '%s' "$json"
}

list_versions() {
  jq -r '.[] | select(.prerelease | not) | .tag_name'
}

normalize_tag() {
  local tag="$1"
  [[ -n "$tag" ]] || return 1
  [[ "$tag" == v* ]] || tag="v$tag"
  printf '%s\n' "$tag"
}

pick_version() {
  local json="$1" choice="" i tag
  local -a versions=()
  mapfile -t versions < <(printf '%s' "$json" | list_versions)
  ((${#versions[@]})) || die '没有可用的 Xray-core 正式版本'
  if [[ -n "$REQUESTED_VERSION" ]]; then
    if [[ "$REQUESTED_VERSION" == latest ]]; then
      SELECTED_XRAY_VERSION="${versions[0]}"
      return 0
    fi
    tag="$(normalize_tag "$REQUESTED_VERSION")"
    SELECTED_XRAY_VERSION="$tag"
    return 0
  fi
  if [[ "${NONINTERACTIVE:-0}" == 1 || ! -r /dev/tty ]]; then
    SELECTED_XRAY_VERSION="${versions[0]}"
    log "非交互模式，安装最新正式版 ${SELECTED_XRAY_VERSION}"
    return 0
  fi
  printf '\n可用的 Xray-core 版本:\n'
  for i in "${!versions[@]}"; do
    printf '  %d. %s\n' "$((i + 1))" "${versions[$i]}"
  done
  read -r -p $'请选择版本编号，直接回车安装最新正式版 ('"${versions[0]}"$'): ' choice </dev/tty
  if [[ -z "$choice" ]]; then
    SELECTED_XRAY_VERSION="${versions[0]}"
    return 0
  fi
  if [[ "$choice" =~ ^[0-9]+$ ]]; then
    i=$((choice - 1))
    if (( i >= 0 && i < ${#versions[@]} )); then
      SELECTED_XRAY_VERSION="${versions[$i]}"
      return 0
    fi
    warn "编号无效，改用最新正式版 ${versions[0]}"
    SELECTED_XRAY_VERSION="${versions[0]}"
    return 0
  fi
  SELECTED_XRAY_VERSION="$(normalize_tag "$choice")"
}

download_url_for() {
  local json="$1" tag="$2" asset="$3" url
  url="$(printf '%s' "$json" | jq -r --arg tag "$tag" --arg asset "$asset" '
    first(.[] | select(.tag_name == $tag) | .assets[] | select(.name == $asset) | .browser_download_url) // empty
  ')"
  if [[ -z "$url" || "$url" == null ]]; then
    url="https://github.com/XTLS/Xray-core/releases/download/${tag}/${asset}"
  fi
  github_file_url "$url"
}

verify_sha256() {
  local zip="$1" dgst_url="$2" dgst expected actual
  dgst="$(mktemp)"
  if ! curl -fsSL --retry 2 -o "$dgst" "$dgst_url"; then
    rm -f "$dgst"
    warn '未获取到 SHA256 校验文件，跳过校验'
    return 0
  fi
  expected="$(awk 'BEGIN { IGNORECASE=1 } /^sha256:/{ print $2; exit }' "$dgst")"
  rm -f "$dgst"
  if [[ -z "$expected" ]]; then
    warn '校验文件中没有 sha256，跳过校验'
    return 0
  fi
  actual="$(sha256sum "$zip" | awk '{ print $1 }')"
  [[ "$expected" == "$actual" ]] || die "SHA256 校验失败 (期望 ${expected}, 实际 ${actual})"
  ok 'SHA256 校验通过'
}

install_xray_core() {
  local json="$1" tag="$2" asset url workdir zip
  asset="$(xray_asset_name)"
  url="$(download_url_for "$json" "$tag" "$asset")"
  workdir="$(mktemp -d)"
  zip="$workdir/$asset"
  log "正在下载 Xray-core ${tag} (${asset})"
  curl -fL --retry 3 --retry-delay 2 -o "$zip" "$url" || {
    rm -rf "$workdir"
    die "下载失败: $url"
  }
  unzip -t "$zip" >/dev/null || {
    rm -rf "$workdir"
    die '下载的压缩包损坏'
  }
  verify_sha256 "$zip" "${url}.dgst"
  unzip -o -q "$zip" -d "$workdir/out"
  [[ -f "$workdir/out/xray" ]] || {
    rm -rf "$workdir"
    die '压缩包中没有 xray 可执行文件'
  }
  mkdir -p "$XRAY_CORE_DIR"
  install -m 755 "$workdir/out/xray" "$XRAY_CORE_BIN"
  local f
  for f in geoip.dat geosite.dat geoip-only-cn-private.dat; do
    if [[ -f "$workdir/out/$f" ]]; then
      install -m 644 "$workdir/out/$f" "$XRAY_CORE_DIR/$f"
    fi
  done
  rm -rf "$workdir"
  [[ -x "$XRAY_CORE_BIN" ]] || die "安装失败: $XRAY_CORE_BIN 不可执行"
  "$XRAY_CORE_BIN" version >/dev/null || die 'xray 无法执行，安装失败'
  ok "Xray-core ${tag} 已安装到 $XRAY_CORE_BIN"
}

pick_target() {
  local choice=""
  if [[ -n "$TARGET" ]]; then
    return 0
  fi
  [[ -r /dev/tty ]] || die '需要交互终端，或通过参数指定: change-xray-core.sh main|node [版本]'
  printf '\n选择要更换内核的目标:\n'
  printf '  1. Marzban 主节点（面板）\n'
  printf '  2. Marzban Node（节点）\n'
  read -r -p $'请输入编号 [1-2]: ' choice </dev/tty
  case "$choice" in
    1|main|MAIN) TARGET=main ;;
    2|node|NODE) TARGET=node ;;
    *) die '无效选择，请输入 1 或 2' ;;
  esac
}

upsert_compose_key() {
  local file="$1" key="$2" value="$3"
  if grep -qE "^[[:space:]]*${key}:" "$file"; then
    sed -i -E "s|^([[:space:]]*)${key}:[[:space:]]*.*|\\1${key}: \"${value}\"|" "$file"
    return 0
  fi
  grep -qE '^[[:space:]]*environment:' "$file" || die "$file 中找不到 environment:"
  awk -v k="$key" -v v="$value" '
    BEGIN { done=0 }
    /^[[:space:]]*environment:[[:space:]]*$/ && !done {
      print
      print "      " k ": \"" v "\""
      done=1
      next
    }
    { print }
  ' "$file" >"${file}.tmp"
  mv "${file}.tmp" "$file"
}

upsert_compose_volume() {
  local file="$1" mapping="$2"
  if grep -qE "^[[:space:]]*-[[:space:]]*[\"']?${mapping}[\"']?[[:space:]]*$" "$file"; then
    return 0
  fi
  grep -qE '^[[:space:]]*volumes:' "$file" || die "$file 中找不到 volumes:"
  awk -v m="$mapping" '
    BEGIN { done=0 }
    /^[[:space:]]*volumes:[[:space:]]*$/ && !done {
      print
      print "      - " m
      done=1
      next
    }
    { print }
  ' "$file" >"${file}.tmp"
  mv "${file}.tmp" "$file"
}

find_compose_file() {
  local dir="$1"
  if [[ -f "$dir/docker-compose.yml" ]]; then
    printf '%s\n' "$dir/docker-compose.yml"
  elif [[ -f "$dir/docker-compose.yaml" ]]; then
    printf '%s\n' "$dir/docker-compose.yaml"
  else
    return 1
  fi
}

looks_like_node_compose() {
  local file="$1"
  grep -Eq 'gozargah/marzban-node|marzban-node:' "$file"
}

find_marzban_node_dir() {
  local d f
  if [[ -n "${MARZBAN_NODE_DIR:-}" ]]; then
    f="$(find_compose_file "$MARZBAN_NODE_DIR")" || die "MARZBAN_NODE_DIR 中没有 docker-compose.yml: $MARZBAN_NODE_DIR"
    printf '%s\n' "$MARZBAN_NODE_DIR"
    return 0
  fi
  for d in \
    /opt/marzban-node \
    /opt/Marzban-node \
    /root/marzban-node \
    /root/Marzban-node \
    "$HOME/Marzban-node" \
    "$HOME/marzban-node"; do
    f="$(find_compose_file "$d" 2>/dev/null || true)"
    if [[ -n "$f" ]] && looks_like_node_compose "$f"; then
      printf '%s\n' "$d"
      return 0
    fi
  done
  while IFS= read -r f; do
    if looks_like_node_compose "$f"; then
      printf '%s\n' "$(dirname "$f")"
      return 0
    fi
  done < <(find /opt /root /home /var/lib -maxdepth 4 \( -name docker-compose.yml -o -name docker-compose.yaml \) 2>/dev/null)
  return 1
}

update_marzban_main() {
  [[ -f "$MARZBAN_DIR/.env" ]] || die "$MARZBAN_DIR/.env 不存在，请确认已安装 Marzban 主节点"
  command -v marzban >/dev/null || die '找不到 marzban 命令'
  log '写入 XRAY_EXECUTABLE_PATH'
  set_env XRAY_EXECUTABLE_PATH "$XRAY_CORE_BIN"
  if [[ "${SKIP_RESTART:-0}" == 1 ]]; then
    warn '已设置 SKIP_RESTART=1，跳过重启 Marzban'
    return 0
  fi
  log '正在重启 Marzban'
  marzban restart -n
  ok "Marzban 主节点内核已切换为 $SELECTED_XRAY_VERSION"
}

update_marzban_node() {
  local dir compose_file
  dir="$(find_marzban_node_dir)" || die '未找到 Marzban Node 的 docker-compose.yml，可用 MARZBAN_NODE_DIR 指定目录'
  compose_file="$(find_compose_file "$dir")" || die "未找到 compose 文件: $dir"
  log "更新 Node 配置: $compose_file"
  cp -a "$compose_file" "${compose_file}.bak.$(date +%Y%m%d%H%M%S)"
  upsert_compose_key "$compose_file" XRAY_EXECUTABLE_PATH "$XRAY_CORE_BIN"
  upsert_compose_volume "$compose_file" '/var/lib/marzban:/var/lib/marzban'
  if [[ "${SKIP_RESTART:-0}" == 1 ]]; then
    warn '已设置 SKIP_RESTART=1，跳过重启 Marzban Node'
    return 0
  fi
  log '正在重建 Marzban Node 容器'
  compose -f "$compose_file" --project-directory "$dir" up -d --force-recreate
  ok "Marzban Node 内核已切换为 $SELECTED_XRAY_VERSION"
}

main() {
  case "${1:-}" in
    -h|--help|help) usage; exit 0 ;;
  esac
  if [[ "${SKIP_CUSTOM_XRAY_CORE:-0}" == 1 ]]; then
    warn '已设置 SKIP_CUSTOM_XRAY_CORE=1，跳过自定义 Xray 内核'
    exit 0
  fi
  [[ "$(uname)" == Linux ]] || die '此脚本仅支持 Linux'
  [[ "$(id -u)" == 0 ]] || die '请使用 root 执行: sudo -i'
  case "$TARGET" in
    ''|main|node|1|2) ;;
    -h|--help|help) usage; exit 0 ;;
    *) die "未知目标: $TARGET（应为 main 或 node）" ;;
  esac
  case "$TARGET" in
    1) TARGET=main ;;
    2) TARGET=node ;;
  esac
  ensure_pkgs
  pick_target
  local json
  json="$(fetch_release_json)"
  pick_version "$json"
  log "将安装 Xray-core $SELECTED_XRAY_VERSION"
  install_xray_core "$json" "$SELECTED_XRAY_VERSION"
  case "$TARGET" in
    main) update_marzban_main ;;
    node) update_marzban_node ;;
    *) die "未知目标: $TARGET" ;;
  esac
}

main "$@"
