#!/bin/bash
# =============================================================================
# TK 子台一键安全部署（多服务器：每台只执行一条命令）
#
# 推荐（Token 不进命令行 / bash history）：
#
#   curl -fsSL .../bootstrap.sh | sudo bash -s -- --from-master
#
# 或 SCP 签名包后：
#
#   curl -fsSL .../bootstrap.sh | sudo bash -s -- --secrets-file /root/app-deploy/bootstrap.secrets.pkg
#
# 首次安装也可将 bootstrap.secrets.pkg 打入安装器镜像，由 deploy-internal 自动落盘 deploy.env。
# =============================================================================
set -euo pipefail

TK_DATA="${TK_DATA:-/root/app-deploy}"
INSTALL_BASE_URL="${TK_INSTALL_BASE_URL:-https://raw.githubusercontent.com/Dinopell/TK_INSTALL/main/static/tk}"
REGISTRY="${IMAGE_REGISTRY:-ghcr.io/dinopell}"
TAG="${IMAGE_TAG:-latest}"

CF_TOKEN=""
ADMIN_HOSTS=""
SECRETS_FILE=""
FROM_MASTER=0
REWRITE_ENV=0
UPGRADE_ONLY=0
NON_INTERACTIVE=0

SCRIPT_SELF="${BASH_SOURCE[0]:-}"
LIB_SH=""
if [ -n "$SCRIPT_SELF" ] && [ -f "$(dirname "$SCRIPT_SELF")/bootstrap-pkg-lib.sh" ]; then
    LIB_SH="$(cd "$(dirname "$SCRIPT_SELF")" && pwd)/bootstrap-pkg-lib.sh"
elif [ -f "/opt/tk/user/bootstrap-pkg-lib.sh" ]; then
    LIB_SH="/opt/tk/user/bootstrap-pkg-lib.sh"
fi
if [ -n "$LIB_SH" ]; then
    # shellcheck source=/dev/null
    . "$LIB_SH"
fi

usage() {
    cat <<'EOF'
TK 子台一键部署 bootstrap.sh

推荐（Cloudflare Token 不进命令行）：
  --from-master             用 master.endpoint.pkg 向总台拉取 bootstrap.secrets.pkg
  --secrets-file PATH       使用本地 RSA 签名包（可 SCP 下发）

传统（会进入 bash history，不推荐）：
  --cf-token TOKEN          Cloudflare API Token

可选：
  --admin-host HOST         管理端 Host 白名单，逗号分隔（默认自动探测公网 IP）
  --data-dir PATH           数据目录（默认 /root/app-deploy）
  --image-tag TAG           镜像标签（默认 latest）
  --registry REG            镜像仓库（默认 ghcr.io/dinopell）
  --install-url BASE        install.sh 下载根路径
  --rewrite-env             覆盖已有 deploy.env
  --upgrade-only            仅升级，不修改 deploy.env
  --non-interactive         缺参数时直接失败
  -h, --help

示例：
  curl -fsSL .../bootstrap.sh | sudo bash -s -- --from-master
  curl -fsSL .../bootstrap.sh | sudo bash -s -- --secrets-file /root/app-deploy/bootstrap.secrets.pkg
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --cf-token)
            CF_TOKEN="${2:-}"; shift 2 ;;
        --admin-host|--admin-hosts)
            ADMIN_HOSTS="${2:-}"; shift 2 ;;
        --secrets-file)
            SECRETS_FILE="${2:-}"; shift 2 ;;
        --from-master)
            FROM_MASTER=1; shift ;;
        --data-dir)
            TK_DATA="${2:-}"; shift 2 ;;
        --image-tag)
            TAG="${2:-}"; shift 2 ;;
        --registry)
            REGISTRY="${2:-}"; shift 2 ;;
        --install-url)
            INSTALL_BASE_URL="${2:-}"; shift 2 ;;
        --rewrite-env)
            REWRITE_ENV=1; shift ;;
        --upgrade-only)
            UPGRADE_ONLY=1; shift ;;
        --non-interactive)
            NON_INTERACTIVE=1; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "未知参数: $1" >&2
            usage >&2
            exit 1 ;;
    esac
done

CF_TOKEN="${CF_TOKEN:-${CLOUDFLARE_API_TOKEN:-}}"
ADMIN_HOSTS="${ADMIN_HOSTS:-${ADMIN_API_HOSTS:-}}"

if [ "$(id -u)" -ne 0 ]; then
    echo ">>> 请使用 root 或 sudo 执行" >&2
    exit 1
fi

ensure_pkg_lib() {
    if [ -n "$LIB_SH" ]; then
        return 0
    fi
    if [ -f "/opt/tk/bootstrap-pkg-lib.sh" ]; then
        LIB_SH="/opt/tk/bootstrap-pkg-lib.sh"
        export TK_SIGN_PUBKEY="${TK_SIGN_PUBKEY:-/opt/tk/certs/master-sign-public.pem}"
        # shellcheck source=/dev/null
        . "$LIB_SH"
        return 0
    fi
    LIB_TMP="/tmp/tk-bootstrap-pkg-lib-$$.sh"
    PUBKEY_TMP="/tmp/tk-master-sign-public-$$.pem"
    echo ">>> 下载验签组件 ..."
    curl -fsSL "${INSTALL_BASE_URL%/}/bootstrap-pkg-lib.sh" -o "$LIB_TMP"
    curl -fsSL "${INSTALL_BASE_URL%/}/certs/master-sign-public.pem" -o "$PUBKEY_TMP"
    chmod +x "$LIB_TMP"
    export TK_SIGN_PUBKEY="$PUBKEY_TMP"
    # shellcheck source=/dev/null
    . "$LIB_TMP"
    LIB_SH="$LIB_TMP"
}

detect_public_ip() {
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

mkdir -p "$TK_DATA"
DEPLOY_ENV="$TK_DATA/deploy.env"
MASTER_PKG_FILE="$TK_DATA/master.endpoint.pkg"
BOOTSTRAP_PKG_FILE="$TK_DATA/bootstrap.secrets.pkg"

if [ "$UPGRADE_ONLY" = "1" ] && [ ! -f "$DEPLOY_ENV" ]; then
    echo ">>> 错误: --upgrade-only 但不存在 $DEPLOY_ENV，请先完整安装" >&2
    exit 1
fi

apply_secrets_pkg() {
    local pkg="$1"
    if [ -z "$LIB_SH" ]; then
        echo ">>> 错误: 缺少 bootstrap-pkg-lib.sh，无法验签" >&2
        exit 1
    fi
    tk_parse_bootstrap_secrets_pkg "$pkg" || exit 1
    if [ -n "$ADMIN_HOSTS" ]; then
        :
    elif [ -n "${BOOTSTRAP_ADMIN_HOSTS:-}" ]; then
        ADMIN_HOSTS="$BOOTSTRAP_ADMIN_HOSTS"
    elif detected="$(detect_public_ip)"; then
        ADMIN_HOSTS="$detected"
        echo ">>> 已自动探测公网 IP 作为 ADMIN_API_HOSTS: $ADMIN_HOSTS"
    elif [ "$NON_INTERACTIVE" = "1" ]; then
        echo ">>> 错误: 签名包未含 adminHosts 且无法探测公网 IP" >&2
        exit 1
    else
        read -r -p ">>> 管理端访问 Host（通常为公网 IP）: " ADMIN_HOSTS
    fi
    if [ -n "${BOOTSTRAP_IMAGE_TAG:-}" ]; then TAG="$BOOTSTRAP_IMAGE_TAG"; fi
    if [ -n "${BOOTSTRAP_IMAGE_REGISTRY:-}" ]; then REGISTRY="$BOOTSTRAP_IMAGE_REGISTRY"; fi
    tk_write_deploy_env_from_bootstrap "$DEPLOY_ENV" "$ADMIN_HOSTS" "${BOOTSTRAP_TOKEN_SECRET:-}"
    echo ">>> 已从签名包写入 $DEPLOY_ENV"
}

if [ ! -f "$DEPLOY_ENV" ] || [ "$REWRITE_ENV" = "1" ]; then
    if [ -f "$DEPLOY_ENV" ] && [ "$REWRITE_ENV" = "1" ]; then
        cp -f "$DEPLOY_ENV" "${DEPLOY_ENV}.bak.$(date +%Y%m%d%H%M%S)"
        echo ">>> 已备份原 deploy.env"
    fi

    resolved_pkg=""

    if [ -n "$SECRETS_FILE" ] || [ "$FROM_MASTER" = "1" ] || [ -f "$BOOTSTRAP_PKG_FILE" ]; then
        ensure_pkg_lib
    fi

    if [ -n "$SECRETS_FILE" ]; then
        [ -f "$SECRETS_FILE" ] || { echo ">>> 错误: 未找到 $SECRETS_FILE" >&2; exit 1; }
        resolved_pkg="$(tk_read_pkg_file "$SECRETS_FILE")"
    elif [ -f "$BOOTSTRAP_PKG_FILE" ]; then
        echo ">>> 使用已有 $BOOTSTRAP_PKG_FILE"
        resolved_pkg="$(tk_read_pkg_file "$BOOTSTRAP_PKG_FILE")"
    elif [ "$FROM_MASTER" = "1" ]; then
        if [ -z "$LIB_SH" ]; then
            echo ">>> 错误: --from-master 需要 bootstrap-pkg-lib.sh" >&2
            exit 1
        fi
        if [ ! -f "$MASTER_PKG_FILE" ]; then
            echo ">>> 错误: --from-master 需要 $MASTER_PKG_FILE（首次安装请用安装器镜像或 --secrets-file）" >&2
            exit 1
        fi
        tk_parse_master_endpoint_pkg "$(tk_read_pkg_file "$MASTER_PKG_FILE")" || exit 1
        echo ">>> 从总台拉取 bootstrap 配置包 ..."
        resolved_pkg="$(tk_fetch_bootstrap_secrets_from_master "$BOOTSTRAP_PKG_FILE")"
        echo ">>> 已保存 $BOOTSTRAP_PKG_FILE"
    fi

    if [ -n "$resolved_pkg" ]; then
        apply_secrets_pkg "$resolved_pkg"
    else
        if [ -z "$CF_TOKEN" ]; then
            if [ "$NON_INTERACTIVE" = "1" ]; then
                echo ">>> 错误: 须 --from-master、--secrets-file 或 --cf-token" >&2
                exit 1
            fi
            read -r -p ">>> Cloudflare API Token (DNS-01): " CF_TOKEN
        fi
        if [ -z "$CF_TOKEN" ]; then
            echo ">>> 错误: Cloudflare API Token 不能为空" >&2
            exit 1
        fi

        if [ -z "$ADMIN_HOSTS" ]; then
            if detected="$(detect_public_ip)"; then
                ADMIN_HOSTS="$detected"
                echo ">>> 已自动探测公网 IP 作为 ADMIN_API_HOSTS: $ADMIN_HOSTS"
            else
                if [ "$NON_INTERACTIVE" = "1" ]; then
                    echo ">>> 错误: 无法探测公网 IP，请 --admin-host 指定" >&2
                    exit 1
                fi
                read -r -p ">>> 管理端访问 Host（通常为公网 IP）: " ADMIN_HOSTS
            fi
        fi

        TOKEN_SECRET_VAL="${TOKEN_SECRET:-}"
        if [ -z "$TOKEN_SECRET_VAL" ] && [ -f "$DEPLOY_ENV" ]; then
            # shellcheck source=/dev/null
            . "$DEPLOY_ENV" 2>/dev/null || true
            TOKEN_SECRET_VAL="${TOKEN_SECRET:-}"
        fi
        if [ -z "$TOKEN_SECRET_VAL" ]; then
            TOKEN_SECRET_VAL="$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
        fi

        umask 077
        cat > "$DEPLOY_ENV" <<EOF
# TK 子台生产配置（由 bootstrap.sh 生成，$(date -Iseconds 2>/dev/null || date))
ADMIN_API_HOSTS=${ADMIN_HOSTS}
SUBSTATION_SSL_CHALLENGE_TYPE=dns-cloudflare
CLOUDFLARE_API_TOKEN=${CF_TOKEN}
SSL_HTTP01_ENABLED=0
CDN_ENABLED=1
CDN_PROVIDER=cloudflare
IMAGE_TAG=${TAG}
IMAGE_REGISTRY=${REGISTRY}
TOKEN_SECRET=${TOKEN_SECRET_VAL}
EOF
        chmod 600 "$DEPLOY_ENV"
        echo ">>> 已写入 $DEPLOY_ENV"
    fi
else
    echo ">>> 使用已有 $DEPLOY_ENV（升级模式）"
    set -a
    # shellcheck source=/dev/null
    . "$DEPLOY_ENV"
    set +a
fi

INSTALL_SH=""
if [ -n "$SCRIPT_SELF" ] && [ -f "$(dirname "$SCRIPT_SELF")/install.sh" ]; then
    INSTALL_SH="$(cd "$(dirname "$SCRIPT_SELF")" && pwd)/install.sh"
else
    INSTALL_SH="/tmp/tk-install-$$.sh"
    echo ">>> 下载 install.sh ..."
    curl -fsSL "${INSTALL_BASE_URL%/}/install.sh" -o "$INSTALL_SH"
    chmod +x "$INSTALL_SH"
    ensure_pkg_lib
fi

export TK_DATA IMAGE_REGISTRY="$REGISTRY" IMAGE_TAG="$TAG"
set -a
# shellcheck source=/dev/null
. "$DEPLOY_ENV"
set +a

echo "=============================================="
echo " TK 子台一键部署"
echo " 数据目录: $TK_DATA"
echo " 镜像: ${REGISTRY}/tk-substation-*:${TAG}"
echo " 管理 API Host: ${ADMIN_API_HOSTS:-（见 deploy.env）}"
echo "=============================================="

exec bash "$INSTALL_SH"
