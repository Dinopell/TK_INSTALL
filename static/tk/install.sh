#!/bin/bash
# TK 子台用户安装入口（部署逻辑在 installer 镜像内）
# 用户获取: GitHub Dinopell/TK_INSTALL → static/tk/install.sh
# 开发维护: 本文件；发版执行 bash ops/sync-to-tk-install.sh
# 默认值与 springboot-app.jar 内 application.yml → ruoyi.substation 对齐：
#   TK_DATA        ↔ deployDataDir
#   IMAGE_REGISTRY ↔ imageRegistry
#   IMAGE_TAG      ↔ imageTag
set -euo pipefail

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

TK_DATA="${TK_DATA:-/root/app-deploy}"
REGISTRY="${IMAGE_REGISTRY:-ghcr.io/dinopell}"
TAG="${IMAGE_TAG:-latest}"
INSTALLER="${REGISTRY}/tk-substation-installer:${TAG}"
INSTALL_LOG="${TK_DATA}/deploy.log"
DEPLOY_VERBOSE="${DEPLOY_VERBOSE:-0}"

install_log() {
    mkdir -p "$TK_DATA" 2>/dev/null || true
    echo -e "$@" >>"$INSTALL_LOG" 2>/dev/null || true
}

install_msg() {
    if [ "$DEPLOY_VERBOSE" = "1" ]; then
        echo -e "$@"
    else
        install_log "$@"
    fi
}

install_err() {
    echo -e "$@" >&2
}

wait_for_docker() {
    local i
    for i in $(seq 1 15); do
        if docker info >/dev/null 2>&1; then
            return 0
        fi
        install_msg "${YELLOW}>>> 等待 Docker 守护进程就绪 (${i}/15)...${NC}"
        sleep 2
    done
    install_err "${RED}>>> Docker 守护进程未就绪，请稍后重试${NC}"
    exit 1
}

docker_pull_retry() {
    local image="$1" tries="${2:-3}"
    local n=1
    while [ "$n" -le "$tries" ]; do
        if [ "$DEPLOY_VERBOSE" = "1" ]; then
            if docker pull "$image"; then
                return 0
            fi
        elif docker pull "$image" >>"$INSTALL_LOG" 2>&1; then
            return 0
        fi
        install_msg "${YELLOW}>>> 拉取失败 (${n}/${tries})，5 秒后重试: ${image}${NC}"
        sleep 5
        n=$((n + 1))
    done
    return 1
}

if ! command -v docker &>/dev/null; then
    install_msg "${BLUE}>>> 正在安装 Docker...${NC}"
    curl -fsSL https://get.docker.com | sh >>"$INSTALL_LOG" 2>&1
    systemctl start docker 2>/dev/null || service docker start 2>/dev/null || true
    systemctl enable docker 2>/dev/null || true
fi

wait_for_docker

mkdir -p "$TK_DATA"

# 首次安装：预写 ADMIN_API_HOSTS，避免管理端 /prod-api/ 被 Nginx 444 拦截
_install_detect_public_ip() {
    local ip=""
    for url in "https://api4.ipify.org" "https://ifconfig.me/ip" "https://icanhazip.com"; do
        ip="$(curl -fsS --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]')" || true
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')" || true
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ip"
        return 0
    fi
    return 1
}

if [ ! -f "${TK_DATA}/deploy.env" ]; then
    if _auto_ip="$(_install_detect_public_ip)"; then
        umask 077
        cat > "${TK_DATA}/deploy.env" <<EOF
# TK 子台配置（install.sh 自动生成，$(date -Iseconds 2>/dev/null || date))
ADMIN_API_HOSTS=${_auto_ip}
TK_SHIELD_ENABLED=1
TK_UA_BLOCK_ENABLED=1
EOF
        chmod 600 "${TK_DATA}/deploy.env"
        install_msg "${GREEN}>>> 已自动创建 ${TK_DATA}/deploy.env，ADMIN_API_HOSTS=${_auto_ip}${NC}"
    fi
fi

# 生产环境变量持久化：在 TK_DATA/deploy.env 中配置 SSL/CDN/管理 API 等（见 deploy/deploy.env.example）
_install_admin_hosts_needs_auto() {
    case "${1:-}" in
        ""|你的服务器公网IP|你的公网IP|1.2.3.4) return 0 ;;
        *) return 1 ;;
    esac
}

if [ -f "${TK_DATA}/deploy.env" ]; then
    set -a
    # shellcheck source=/dev/null
    . "${TK_DATA}/deploy.env"
    set +a
    if _install_admin_hosts_needs_auto "${ADMIN_API_HOSTS:-}"; then
        if _auto_ip="$(_install_detect_public_ip)"; then
            if grep -q '^ADMIN_API_HOSTS=' "${TK_DATA}/deploy.env"; then
                sed -i "s|^ADMIN_API_HOSTS=.*|ADMIN_API_HOSTS=${_auto_ip}|" "${TK_DATA}/deploy.env"
            else
                echo "ADMIN_API_HOSTS=${_auto_ip}" >> "${TK_DATA}/deploy.env"
            fi
            ADMIN_API_HOSTS="$_auto_ip"
            export ADMIN_API_HOSTS
            install_msg "${GREEN}>>> 已自动设置 ADMIN_API_HOSTS=${_auto_ip}${NC}"
        fi
    fi
    install_msg "${GREEN}>>> 已加载 ${TK_DATA}/deploy.env${NC}"
fi

HOST_TOTAL_MEM_MB="$(awk '/MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 2048)"
if [ "$HOST_TOTAL_MEM_MB" -lt 512 ] 2>/dev/null; then
    HOST_TOTAL_MEM_MB=2048
fi

install_msg "${YELLOW}>>> 拉取安装器镜像 ${INSTALLER}...${NC}"
if ! docker_pull_retry "$INSTALLER"; then
    install_err "${RED}>>> 拉取安装器镜像失败: ${INSTALLER}${NC}"
    install_err "${YELLOW}>>> 详见 ${INSTALL_LOG}${NC}"
    exit 1
fi

install_msg "${YELLOW}>>> 启动安装器（数据目录: ${TK_DATA}）...${NC}"
# 交互式终端下分配 TTY，安装器内五模块进度条才能原地刷新
DOCKER_RUN_TTY=()
if [ -t 1 ]; then
    DOCKER_RUN_TTY=(-it)
fi
# 兼容 installer 镜像内 CRLF 脚本（shebang 会变成 /bin/bash\r 导致 exec 失败）
docker run --rm "${DOCKER_RUN_TTY[@]}" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${TK_DATA}:/data" \
    -v /proc/meminfo:/host/proc/meminfo:ro \
    -e TK_DATA_DIR=/data \
    -e TK_HOST_DATA_DIR="${TK_DATA}" \
    -e HOST_TOTAL_MEM_MB="${HOST_TOTAL_MEM_MB}" \
    -e IMAGE_REGISTRY="${REGISTRY}" \
    -e IMAGE_TAG="${TAG}" \
    ${JVM_XMX_MB:+-e JVM_XMX_MB="${JVM_XMX_MB}"} \
    ${JVM_XMS_MB:+-e JVM_XMS_MB="${JVM_XMS_MB}"} \
    ${MYSQL_INNODB_BUFFER:+-e MYSQL_INNODB_BUFFER="${MYSQL_INNODB_BUFFER}"} \
    ${REDIS_MAXMEMORY:+-e REDIS_MAXMEMORY="${REDIS_MAXMEMORY}"} \
    ${FIX_HOST_NGINX:+-e FIX_HOST_NGINX="${FIX_HOST_NGINX}"} \
    ${DEPLOY_VERBOSE:+-e DEPLOY_VERBOSE="${DEPLOY_VERBOSE}"} \
    ${SUBSTATION_SSL_CHALLENGE_TYPE:+-e SUBSTATION_SSL_CHALLENGE_TYPE="${SUBSTATION_SSL_CHALLENGE_TYPE}"} \
    ${SSL_HTTP01_ENABLED:+-e SSL_HTTP01_ENABLED="${SSL_HTTP01_ENABLED}"} \
    ${SSL_HTTP01_ENABLED_FORCE:+-e SSL_HTTP01_ENABLED_FORCE="${SSL_HTTP01_ENABLED_FORCE}"} \
    ${CLOUDFLARE_API_TOKEN:+-e CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN}"} \
    ${CDN_ENABLED:+-e CDN_ENABLED="${CDN_ENABLED}"} \
    ${CDN_PROVIDER:+-e CDN_PROVIDER="${CDN_PROVIDER}"} \
    ${CDN_REAL_IP_FROM:+-e CDN_REAL_IP_FROM="${CDN_REAL_IP_FROM}"} \
    ${CDN_REAL_IP_HEADER:+-e CDN_REAL_IP_HEADER="${CDN_REAL_IP_HEADER}"} \
    ${ADMIN_API_HOSTS:+-e ADMIN_API_HOSTS="${ADMIN_API_HOSTS}"} \
    ${TK_SHIELD_ENABLED:+-e TK_SHIELD_ENABLED="${TK_SHIELD_ENABLED}"} \
    ${TK_UA_BLOCK_ENABLED:+-e TK_UA_BLOCK_ENABLED="${TK_UA_BLOCK_ENABLED}"} \
    ${TK_WHITELIST_REDIRECT_URL:+-e TK_WHITELIST_REDIRECT_URL="${TK_WHITELIST_REDIRECT_URL}"} \
    ${TOKEN_SECRET:+-e TOKEN_SECRET="${TOKEN_SECRET}"} \
    ${VISIT_PASS_HMAC_SECRET:+-e VISIT_PASS_HMAC_SECRET="${VISIT_PASS_HMAC_SECRET}"} \
    ${MYSQL_PWD:+-e MYSQL_PWD="${MYSQL_PWD}"} \
    --entrypoint /bin/bash \
    "$INSTALLER" \
    -c "sed -i 's/\r$//' /opt/tk/deploy-internal.sh 2>/dev/null || true; exec /opt/tk/deploy-internal.sh"
