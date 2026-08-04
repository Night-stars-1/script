#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)

# 以下配置均可通过同名环境变量覆盖。
REGISTRY_USER=${REGISTRY_USER:-registry}
REGISTRY_PORT=${REGISTRY_PORT:-5000}
REGISTRY_BIND=${REGISTRY_BIND:-127.0.0.1}
REGISTRY_CONTAINER=${REGISTRY_CONTAINER:-docker-registry}
REGISTRY_IMAGE=${REGISTRY_IMAGE:-registry:2}
HTPASSWD_IMAGE=${HTPASSWD_IMAGE:-httpd:2-alpine}
REGISTRY_DATA_DIR=${REGISTRY_DATA_DIR:-"$SCRIPT_DIR/docker-registry/data"}
REGISTRY_AUTH_DIR=${REGISTRY_AUTH_DIR:-"$SCRIPT_DIR/docker-registry/auth"}

usage() {
    cat <<'EOF'
Usage: ./install-docker-registry.sh [options]

Download and start an authenticated Docker Registry.

Options:
  -u, --username USER   Login username (default: registry)
      --bind ADDRESS    Listen address (default: 127.0.0.1)
      --port PORT       Listen port (default: 5000)
      --name NAME       Container name (default: docker-registry)
  -h, --help            Show this help

The password is read silently from the terminal. For non-interactive use,
set REGISTRY_PASSWORD in the environment. Other settings can also be
overridden with the environment variables shown in the script header.

Examples:
  ./install-docker-registry.sh -u admin
  REGISTRY_PASSWORD='change-me' ./install-docker-registry.sh
  REGISTRY_BIND=0.0.0.0 REGISTRY_PORT=5000 ./install-docker-registry.sh
EOF
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

# 解析常用命令行参数，密码不通过参数传递，避免被 shell 历史记录保存。
while [ "$#" -gt 0 ]; do
    case "$1" in
        -u|--username)
            [ "$#" -ge 2 ] || die "$1 requires a value"
            REGISTRY_USER=$2
            shift 2
            ;;
        --bind)
            [ "$#" -ge 2 ] || die "$1 requires a value"
            REGISTRY_BIND=$2
            shift 2
            ;;
        --port)
            [ "$#" -ge 2 ] || die "$1 requires a value"
            REGISTRY_PORT=$2
            shift 2
            ;;
        --name)
            [ "$#" -ge 2 ] || die "$1 requires a value"
            REGISTRY_CONTAINER=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1 (use --help for usage)"
            ;;
    esac
done

command -v docker >/dev/null 2>&1 || die "docker is not installed or is not in PATH"
docker info >/dev/null 2>&1 || die "the Docker daemon is not running or is not accessible"

[ -n "$REGISTRY_BIND" ] || die "bind address cannot be empty"
[ -n "$REGISTRY_CONTAINER" ] || die "container name cannot be empty"

# 只允许替换由本脚本创建的同名容器，避免误删用户已有容器。
replace_existing=false
if docker container inspect "$REGISTRY_CONTAINER" >/dev/null 2>&1; then
    managed=$(docker inspect --format '{{ index .Config.Labels "io.codex.registry-script" }}' "$REGISTRY_CONTAINER" 2>/dev/null || true)
    [ "$managed" = "true" ] || die "container '$REGISTRY_CONTAINER' already exists and was not created by this script"
    replace_existing=true
fi

case "$REGISTRY_USER" in
    ''|*[!A-Za-z0-9_.@-]*)
        die "username may contain only letters, numbers, '.', '_', '@', and '-'"
        ;;
esac

case "$REGISTRY_PORT" in
    ''|*[!0-9]*) die "port must be a number" ;;
    ??????*) die "port must be between 1 and 65535" ;;
esac

if [ "$REGISTRY_PORT" -lt 1 ] 2>/dev/null || [ "$REGISTRY_PORT" -gt 65535 ] 2>/dev/null; then
    die "port must be between 1 and 65535"
fi

if [ -z "${REGISTRY_PASSWORD:-}" ]; then
    [ -t 0 ] || die "set REGISTRY_PASSWORD when running non-interactively"

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

    printf 'Registry password: ' >&2
    stty -echo
    IFS= read -r REGISTRY_PASSWORD
    restore_tty
    printf '\n' >&2

    printf 'Confirm password: ' >&2
    stty -echo
    IFS= read -r password_confirmation
    restore_tty
    printf '\n' >&2
    trap - EXIT HUP INT TERM

    [ "$REGISTRY_PASSWORD" = "$password_confirmation" ] || die "passwords do not match"
    unset password_confirmation
fi

[ -n "$REGISTRY_PASSWORD" ] || die "password cannot be empty"

# Registry 数据和认证文件保存在脚本目录中，重新创建容器后仍会保留。
umask 077
mkdir -p "$REGISTRY_DATA_DIR" "$REGISTRY_AUTH_DIR"
auth_file="$REGISTRY_AUTH_DIR/htpasswd"
auth_tmp=$(mktemp "$REGISTRY_AUTH_DIR/.htpasswd.XXXXXX")
trap 'rm -f "$auth_tmp"' EXIT HUP INT TERM

printf 'Pulling %s and %s...\n' "$REGISTRY_IMAGE" "$HTPASSWD_IMAGE"
docker pull "$REGISTRY_IMAGE"
docker pull "$HTPASSWD_IMAGE"

# 使用 bcrypt 算法生成 Registry 所需的 htpasswd 文件。
printf '%s\n' "$REGISTRY_PASSWORD" |
    docker run --rm -i --entrypoint htpasswd "$HTPASSWD_IMAGE" -Bni "$REGISTRY_USER" >"$auth_tmp"
[ -s "$auth_tmp" ] || die "failed to generate the htpasswd file"
chmod 600 "$auth_tmp"
mv "$auth_tmp" "$auth_file"
trap - EXIT HUP INT TERM

if [ "$replace_existing" = "true" ]; then
    printf 'Replacing existing container %s...\n' "$REGISTRY_CONTAINER"
    docker rm -f "$REGISTRY_CONTAINER" >/dev/null
fi

# 启动开启 htpasswd 认证的官方 Registry 容器。
printf 'Starting Registry on %s:%s...\n' "$REGISTRY_BIND" "$REGISTRY_PORT"
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

unset REGISTRY_PASSWORD

# Docker 成功创建容器不代表服务一定能持续运行，因此检查一次容器状态。
sleep 1
running=$(docker inspect --format '{{.State.Running}}' "$REGISTRY_CONTAINER" 2>/dev/null || true)
if [ "$running" != "true" ]; then
    docker logs "$REGISTRY_CONTAINER" >&2 2>/dev/null || true
    die "Registry container failed to stay running"
fi

login_host=$REGISTRY_BIND
case "$login_host" in
    0.0.0.0|'::'|'[::]') login_host=REGISTRY_HOST ;;
esac

printf '\nRegistry is running. Log in with:\n'
printf '  docker login %s:%s -u %s\n' "$login_host" "$REGISTRY_PORT" "$REGISTRY_USER"
printf '\nData directory: %s\n' "$REGISTRY_DATA_DIR"
printf 'Stop command:   docker stop %s\n' "$REGISTRY_CONTAINER"

if [ "$REGISTRY_BIND" != "127.0.0.1" ] && [ "$REGISTRY_BIND" != "localhost" ] && [ "$REGISTRY_BIND" != "::1" ]; then
    printf '\nWarning: this Registry uses HTTP. Configure TLS before exposing it to a network.\n' >&2
fi
