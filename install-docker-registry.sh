#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)

# 以下配置均可通过同名环境变量覆盖。
REGISTRY_USER=${REGISTRY_USER:-admin}
REGISTRY_PORT=${REGISTRY_PORT:-5000}
REGISTRY_BIND=${REGISTRY_BIND:-127.0.0.1}
REGISTRY_CONTAINER=${REGISTRY_CONTAINER:-docker-registry}
REGISTRY_IMAGE=${REGISTRY_IMAGE:-registry:2}
HTPASSWD_IMAGE=${HTPASSWD_IMAGE:-httpd:2-alpine}
REGISTRY_DATA_DIR=${REGISTRY_DATA_DIR:-"$SCRIPT_DIR/docker-registry/data"}
REGISTRY_AUTH_DIR=${REGISTRY_AUTH_DIR:-"$SCRIPT_DIR/docker-registry/auth"}

usage() {
    cat <<'EOF'
用法：./install-docker-registry.sh [选项]

下载并启动一个启用密码认证的 Docker Registry。

选项：
  -u, --username 用户名   登录用户名（默认：admin）
      --bind 地址         监听地址（默认：127.0.0.1）
      --port 端口         监听端口（默认：5000）
      --name 名称         容器名称（默认：docker-registry）
  -h, --help             显示此帮助信息

脚本会从终端静默读取密码。非交互运行时，请设置 REGISTRY_PASSWORD
环境变量。其他配置也可以通过脚本开头所列的同名环境变量覆盖。

示例：
  ./install-docker-registry.sh -u admin
  REGISTRY_PASSWORD='change-me' ./install-docker-registry.sh
  REGISTRY_BIND=0.0.0.0 REGISTRY_PORT=5000 ./install-docker-registry.sh
EOF
}

die() {
    printf '错误：%s\n' "$*" >&2
    exit 1
}

# 解析常用命令行参数，密码不通过参数传递，避免被 shell 历史记录保存。
while [ "$#" -gt 0 ]; do
    case "$1" in
        -u|--username)
            [ "$#" -ge 2 ] || die "$1 需要提供一个值"
            REGISTRY_USER=$2
            shift 2
            ;;
        --bind)
            [ "$#" -ge 2 ] || die "$1 需要提供一个值"
            REGISTRY_BIND=$2
            shift 2
            ;;
        --port)
            [ "$#" -ge 2 ] || die "$1 需要提供一个值"
            REGISTRY_PORT=$2
            shift 2
            ;;
        --name)
            [ "$#" -ge 2 ] || die "$1 需要提供一个值"
            REGISTRY_CONTAINER=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "未知选项：$1（使用 --help 查看用法）"
            ;;
    esac
done

command -v docker >/dev/null 2>&1 || die "未安装 Docker，或者 docker 不在 PATH 中"
docker info >/dev/null 2>&1 || die "Docker 服务未运行或当前用户无权访问"

[ -n "$REGISTRY_BIND" ] || die "监听地址不能为空"
[ -n "$REGISTRY_CONTAINER" ] || die "容器名称不能为空"

# 只允许替换由本脚本创建的同名容器，避免误删用户已有容器。
replace_existing=false
if docker container inspect "$REGISTRY_CONTAINER" >/dev/null 2>&1; then
    managed=$(docker inspect --format '{{ index .Config.Labels "io.codex.registry-script" }}' "$REGISTRY_CONTAINER" 2>/dev/null || true)
    [ "$managed" = "true" ] || die "容器 '$REGISTRY_CONTAINER' 已存在，且不是由本脚本创建的"
    replace_existing=true
fi

case "$REGISTRY_USER" in
    ''|*[!A-Za-z0-9_.@-]*)
        die "用户名只能包含字母、数字、'.'、'_'、'@' 和 '-'"
        ;;
esac

case "$REGISTRY_PORT" in
    ''|*[!0-9]*) die "端口必须是数字" ;;
    ??????*) die "端口必须在 1 到 65535 之间" ;;
esac

if [ "$REGISTRY_PORT" -lt 1 ] 2>/dev/null || [ "$REGISTRY_PORT" -gt 65535 ] 2>/dev/null; then
    die "端口必须在 1 到 65535 之间"
fi

if [ -z "${REGISTRY_PASSWORD:-}" ]; then
    [ -t 0 ] || die "非交互运行时请设置 REGISTRY_PASSWORD"

    # 关闭终端回显读取密码，并确保脚本被中断时恢复回显。
    old_stty=$(stty -g)
    restore_tty() {
        stty "$old_stty" 2>/dev/null || true
    }
    abort_prompt() {
        restore_tty
        trap - EXIT HUP INT TERM
        printf '\n' >&2
        exit 130
    }
    trap 'restore_tty' EXIT
    trap 'abort_prompt' HUP INT TERM

    printf '请输入 Registry 密码：' >&2
    stty -echo
    IFS= read -r REGISTRY_PASSWORD
    restore_tty
    printf '\n' >&2

    printf '请再次输入密码：' >&2
    stty -echo
    IFS= read -r password_confirmation
    restore_tty
    printf '\n' >&2
    trap - EXIT HUP INT TERM

    [ "$REGISTRY_PASSWORD" = "$password_confirmation" ] || die "两次输入的密码不一致"
    unset password_confirmation
fi

[ -n "$REGISTRY_PASSWORD" ] || die "密码不能为空"

# Registry 数据和认证文件保存在脚本目录中，重新创建容器后仍会保留。
umask 077
mkdir -p "$REGISTRY_DATA_DIR" "$REGISTRY_AUTH_DIR"
auth_file="$REGISTRY_AUTH_DIR/htpasswd"
auth_tmp=$(mktemp "$REGISTRY_AUTH_DIR/.htpasswd.XXXXXX")
htpasswd_container="${REGISTRY_CONTAINER}-htpasswd-$$"

# 密码生成使用临时容器；无论成功、失败还是中断，都清理容器和临时文件。
cleanup_htpasswd() {
    rm -f "$auth_tmp"
    managed=$(docker inspect --format '{{ index .Config.Labels "io.codex.registry-htpasswd" }}' "$htpasswd_container" 2>/dev/null || true)
    if [ "$managed" = "true" ]; then
        docker rm -f "$htpasswd_container" >/dev/null 2>&1 || true
    fi
}
trap cleanup_htpasswd EXIT HUP INT TERM

printf '正在拉取 %s 和 %s...\n' "$REGISTRY_IMAGE" "$HTPASSWD_IMAGE"
docker pull "$REGISTRY_IMAGE"
docker pull "$HTPASSWD_IMAGE"

# 使用 bcrypt 算法生成 Registry 所需的 htpasswd 文件。
printf '%s\n' "$REGISTRY_PASSWORD" |
    docker run --name "$htpasswd_container" \
        --label io.codex.registry-htpasswd=true \
        -i --entrypoint htpasswd "$HTPASSWD_IMAGE" -Bni "$REGISTRY_USER" >"$auth_tmp"
[ -s "$auth_tmp" ] || die "无法生成 htpasswd 文件"
docker rm -f "$htpasswd_container" >/dev/null 2>&1 || true
htpasswd_container=
chmod 600 "$auth_tmp"
mv "$auth_tmp" "$auth_file"
trap - EXIT HUP INT TERM

if [ "$replace_existing" = "true" ]; then
    printf '正在替换已有容器 %s...\n' "$REGISTRY_CONTAINER"
    docker rm -f "$REGISTRY_CONTAINER" >/dev/null
fi

# 启动开启 htpasswd 认证的官方 Registry 容器。
printf '正在启动 Registry，监听地址为 %s:%s...\n' "$REGISTRY_BIND" "$REGISTRY_PORT"
docker run -d \
    --name "$REGISTRY_CONTAINER" \
    --label io.codex.registry-script=true \
    --restart unless-stopped \
    -p "$REGISTRY_BIND:$REGISTRY_PORT:5000" \
    -v "$REGISTRY_DATA_DIR:/var/lib/registry" \
    -v "$auth_file:/auth/htpasswd:ro" \
    -e REGISTRY_AUTH=htpasswd \
    -e 'REGISTRY_AUTH_HTPASSWD_REALM=Registry Realm' \
    -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
    "$REGISTRY_IMAGE" >/dev/null

# Docker 成功创建容器不代表服务一定能持续运行，因此检查一次容器状态。
sleep 1
running=$(docker inspect --format '{{.State.Running}}' "$REGISTRY_CONTAINER" 2>/dev/null || true)
if [ "$running" != "true" ]; then
    docker logs "$REGISTRY_CONTAINER" >&2 2>/dev/null || true
    die "Registry 容器启动后意外退出"
fi

login_host=$REGISTRY_BIND
case "$login_host" in
    0.0.0.0|'::'|'[::]') login_host=REGISTRY_HOST ;;
esac

printf '\nRegistry 已启动。登录命令：\n'
printf '  docker login %s:%s -u %s\n' "$login_host" "$REGISTRY_PORT" "$REGISTRY_USER"
printf '用户名：%s\n' "$REGISTRY_USER"
printf '密码：%s\n' "$REGISTRY_PASSWORD"
printf '\n数据目录：%s\n' "$REGISTRY_DATA_DIR"
printf '停止命令：docker stop %s\n' "$REGISTRY_CONTAINER"

unset REGISTRY_PASSWORD

if [ "$REGISTRY_BIND" != "127.0.0.1" ] && [ "$REGISTRY_BIND" != "localhost" ] && [ "$REGISTRY_BIND" != "::1" ]; then
    printf '\n警告：当前 Registry 使用 HTTP。暴露到网络前请先配置 TLS。\n' >&2
fi
