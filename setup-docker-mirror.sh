#!/bin/sh

set -eu

# 默认配置多个公开镜像地址，也可通过参数或环境变量覆盖。
DEFAULT_MIRRORS=https://docker.1panel.live,https://docker.1panel.dev,https://docker.1ms.run
if [ -n "${DOCKER_REGISTRY_MIRRORS:-}" ]; then
    MIRROR_URLS=$DOCKER_REGISTRY_MIRRORS
elif [ -n "${DOCKER_REGISTRY_MIRROR:-}" ]; then
    # 兼容旧版脚本使用的单数环境变量。
    MIRROR_URLS=$DOCKER_REGISTRY_MIRROR
else
    MIRROR_URLS=$DEFAULT_MIRRORS
fi
CONFIG_FILE=/etc/docker/daemon.json
ACTION=set
RESTART_DOCKER=true
POSITIONAL_MIRROR=

usage() {
    cat <<'EOF'
用法：
  ./setup-docker-mirror.sh [镜像地址] [选项]
  ./setup-docker-mirror.sh --remove [选项]

为 Ubuntu 上的 Docker daemon 配置 Docker Hub 镜像加速地址。
不提供地址时，默认使用：
  https://docker.1panel.live
  https://docker.1panel.dev
  https://docker.1ms.run

选项：
      --mirror 地址   设置镜像地址；多个地址使用英文逗号分隔
      --remove        删除 registry-mirrors 配置，保留其他 Docker 配置
      --no-restart    修改配置后不重启 Docker
  -h, --help          显示此帮助信息

示例：
  ./setup-docker-mirror.sh
  ./setup-docker-mirror.sh https://docker.1ms.run
  ./setup-docker-mirror.sh --mirror https://mirror-a.example.com,https://mirror-b.example.com
  ./setup-docker-mirror.sh --remove

也可以通过 DOCKER_REGISTRY_MIRRORS 环境变量指定镜像地址列表。
EOF
}

die() {
    printf '错误：%s\n' "$*" >&2
    exit 1
}

require_value() {
    [ "$#" -ge 2 ] || die "$1 需要提供一个值"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --mirror)
            require_value "$@"
            MIRROR_URLS=$2
            shift 2
            ;;
        --remove)
            ACTION=remove
            shift
            ;;
        --no-restart)
            RESTART_DOCKER=false
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --*)
            die "未知选项：$1（使用 --help 查看用法）"
            ;;
        *)
            [ -z "$POSITIONAL_MIRROR" ] || die "只能提供一个镜像地址"
            POSITIONAL_MIRROR=$1
            shift
            ;;
    esac
done

if [ -n "$POSITIONAL_MIRROR" ]; then
    MIRROR_URLS=$POSITIONAL_MIRROR
fi

[ "$(uname -s)" = "Linux" ] || die "此脚本用于 Ubuntu/Linux，不支持当前系统"
command -v systemctl >/dev/null 2>&1 || die "找不到 systemctl，当前系统可能没有使用 systemd"
command -v python3 >/dev/null 2>&1 || die "找不到 python3，无法安全修改 JSON 配置"

run_as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        command -v sudo >/dev/null 2>&1 || die "需要 root 权限，请安装 sudo 或使用 root 用户运行"
        sudo "$@"
    fi
}

umask 077
CURRENT_CONFIG=$(mktemp "${TMPDIR:-/tmp}/docker-daemon-current.XXXXXX")
NEW_CONFIG=$(mktemp "${TMPDIR:-/tmp}/docker-daemon-new.XXXXXX")
trap 'rm -f "$CURRENT_CONFIG" "$NEW_CONFIG"' EXIT HUP INT TERM

# 先复制现有配置，再使用 JSON 解析器只修改 registry-mirrors 字段。
HAD_CONFIG=false
if run_as_root test -f "$CONFIG_FILE"; then
    HAD_CONFIG=true
    run_as_root cat "$CONFIG_FILE" >"$CURRENT_CONFIG"
else
    printf '{}\n' >"$CURRENT_CONFIG"
fi

if [ "$ACTION" = "remove" ] && [ "$HAD_CONFIG" = "false" ]; then
    printf 'Docker 配置文件不存在，无需移除镜像加速配置。\n'
    exit 0
fi

python3 - "$ACTION" "$MIRROR_URLS" "$CURRENT_CONFIG" "$NEW_CONFIG" <<'PY'
import json
import sys

action, mirror_value, source_path, target_path = sys.argv[1:]

try:
    with open(source_path, "r", encoding="utf-8") as source:
        config = json.load(source)
except json.JSONDecodeError as exc:
    raise SystemExit(f"错误：现有 daemon.json 不是有效 JSON：{exc}")

if not isinstance(config, dict):
    raise SystemExit("错误：daemon.json 的顶层内容必须是 JSON 对象")

if action == "remove":
    config.pop("registry-mirrors", None)
else:
    mirrors = [item.strip().rstrip("/") for item in mirror_value.split(",") if item.strip()]
    if not mirrors:
        raise SystemExit("错误：至少需要提供一个镜像地址")
    for mirror in mirrors:
        if "\n" in mirror or "\r" in mirror:
            raise SystemExit("错误：镜像地址不能包含换行符")
        if not mirror.startswith(("https://", "http://")):
            raise SystemExit(f"错误：镜像地址必须以 https:// 或 http:// 开头：{mirror}")
    config["registry-mirrors"] = mirrors

with open(target_path, "w", encoding="utf-8") as target:
    json.dump(config, target, ensure_ascii=False, indent=2, sort_keys=True)
    target.write("\n")
PY

if cmp -s "$CURRENT_CONFIG" "$NEW_CONFIG"; then
    if [ "$ACTION" = "remove" ]; then
        printf '当前没有配置镜像加速地址，无需修改。\n'
    else
        printf '镜像加速地址已经配置，无需修改。\n'
    fi
    exit 0
fi

# 在覆盖原配置前，让 dockerd 检查新配置的语法和字段。
if command -v dockerd >/dev/null 2>&1; then
    run_as_root dockerd --validate --config-file "$NEW_CONFIG" >/dev/null || \
        die "Docker 拒绝新的 daemon.json，未修改原配置"
fi

BACKUP_FILE=
if [ "$HAD_CONFIG" = "true" ]; then
    BACKUP_FILE=$CONFIG_FILE.bak.$(date +%Y%m%d%H%M%S).$$
    run_as_root cp -p "$CONFIG_FILE" "$BACKUP_FILE"
fi

run_as_root install -d -m 755 "$(dirname "$CONFIG_FILE")"
run_as_root install -m 644 "$NEW_CONFIG" "$CONFIG_FILE"
printf 'Docker 配置已写入：%s\n' "$CONFIG_FILE"

if [ -n "$BACKUP_FILE" ]; then
    printf '原配置已备份：%s\n' "$BACKUP_FILE"
fi

if [ "$RESTART_DOCKER" = "false" ]; then
    printf '请运行 sudo systemctl restart docker 使配置生效。\n'
    exit 0
fi

if ! run_as_root systemctl restart docker; then
    printf 'Docker 重启失败，正在恢复原配置...\n' >&2
    if [ "$HAD_CONFIG" = "true" ]; then
        run_as_root install -m 644 "$CURRENT_CONFIG" "$CONFIG_FILE"
    else
        run_as_root rm -f "$CONFIG_FILE"
    fi
    run_as_root systemctl restart docker >/dev/null 2>&1 || true
    die "新配置未生效，原配置已恢复"
fi

if [ "$ACTION" = "remove" ]; then
    printf '镜像加速配置已移除，Docker 已重启。\n'
else
    printf '镜像加速地址已设置为：\n'
    printf '%s\n' "$MIRROR_URLS" | tr ',' '\n' | sed 's/^/  /'
    printf 'Docker 已重启，可以运行以下命令测试：\n'
    printf '  docker pull hello-world\n'
    printf '\n提示：这是第三方公开服务，可用性和服务策略可能随时变化。\n'
fi
