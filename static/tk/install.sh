#!/bin/bash
# TK 子台用户安装入口（部署逻辑在 installer 镜像内）
# 用户获取: GitHub Dinopell/TK_INSTALL → static/tk/install.sh
# 开发维护: 本文件；发版执行 bash ops/sync-to-tk-install.sh
# 默认值与 springboot-app.jar 内 application.yml → ruoyi.substation 对齐：
#   TK_DATA        ↔ deployDataDir
#   IMAGE_REGISTRY ↔ imageRegistry
#   IMAGE_TAG      ↔ imageTag
set -euo pipefail

TK_DATA="${TK_DATA:-/root/app-deploy}"
REGISTRY="${IMAGE_REGISTRY:-ghcr.io/dinopell}"
TAG="${IMAGE_TAG:-latest}"
INSTALLER="${REGISTRY}/tk-substation-installer:${TAG}"

wait_for_docker() {
    local i
    for i in $(seq 1 15); do
        if docker info >/dev/null 2>&1; then
            return 0
        fi
        echo ">>> 等待 Docker 守护进程就绪 (${i}/15)..."
        sleep 2
    done
    echo ">>> Docker 守护进程未就绪，请稍后重试" >&2
    exit 1
}

docker_pull_retry() {
    local image="$1" tries="${2:-3}"
    local n=1
    while [ "$n" -le "$tries" ]; do
        if docker pull "$image"; then
            return 0
        fi
        echo ">>> 拉取失败 (${n}/${tries})，5 秒后重试: ${image}"
        sleep 5
        n=$((n + 1))
    done
    return 1
}

if ! command -v docker &>/dev/null; then
    echo ">>> 正在安装 Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl start docker 2>/dev/null || service docker start 2>/dev/null || true
    systemctl enable docker 2>/dev/null || true
fi

wait_for_docker

mkdir -p "$TK_DATA"

echo ">>> 拉取安装器镜像 ${INSTALLER}..."
docker_pull_retry "$INSTALLER"

echo ">>> 开始部署（数据目录: ${TK_DATA}）..."
# 兼容 installer 镜像内 CRLF 脚本（shebang 会变成 /bin/bash\r 导致 exec 失败）
docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${TK_DATA}:/data" \
    -e TK_DATA_DIR=/data \
    -e TK_HOST_DATA_DIR="${TK_DATA}" \
    -e IMAGE_REGISTRY="${REGISTRY}" \
    -e IMAGE_TAG="${TAG}" \
    ${FIX_HOST_NGINX:+-e FIX_HOST_NGINX="${FIX_HOST_NGINX}"} \
    ${DEPLOY_VERBOSE:+-e DEPLOY_VERBOSE="${DEPLOY_VERBOSE}"} \
    --entrypoint /bin/bash \
    "$INSTALLER" \
    -c "sed -i 's/\r$//' /opt/tk/deploy-internal.sh 2>/dev/null || true; exec /opt/tk/deploy-internal.sh"
