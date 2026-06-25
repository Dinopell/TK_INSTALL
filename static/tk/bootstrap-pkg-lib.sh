#!/bin/bash
# RSA v2 签名包验签与 bootstrap.secrets.pkg → deploy.env（供 bootstrap.sh / deploy-internal.sh 复用）
set -euo pipefail

tk_b64url_decode() {
    local b64="$1"
    local pad=$((4 - ${#b64} % 4))
    if [ "$pad" -ne 4 ]; then
        b64="${b64}$(printf '%0.s=' $(seq 1 "$pad"))"
    fi
    printf '%s' "$b64" | tr '_-' '/+' | openssl base64 -d -A 2>/dev/null
}

tk_find_sign_pubkey() {
    local candidates=()
    if [ -n "${TK_SIGN_PUBKEY:-}" ] && [ -f "$TK_SIGN_PUBKEY" ]; then
        echo "$TK_SIGN_PUBKEY"
        return 0
    fi
    local script_dir=""
    if [ -n "${BASH_SOURCE[1]:-}" ]; then
        script_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
    fi
    candidates=(
        "${script_dir}/certs/master-sign-public.pem"
        "${script_dir}/../certs/master-sign-public.pem"
        "/opt/tk/certs/master-sign-public.pem"
        "/opt/tk/deploy/certs/master-sign-public.pem"
    )
    local c
    for c in "${candidates[@]}"; do
        if [ -f "$c" ]; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

# 验签 v2 包，成功时输出 payload JSON 到 stdout
tk_verify_v2_pkg() {
    local pkg line
    pkg="$(printf '%s' "$1" | tr -d '\n\r\t ')"
    if [[ ! "$pkg" =~ ^v2\.[^.]+\.[^.]+$ ]]; then
        echo ">>> 错误: 签名包格式无效（期望 v2.<payload>.<signature>）" >&2
        return 1
    fi
    local payload_b64 sig_b64 pubkey payload_bin sig_bin
    payload_b64="${pkg#v2.}"
    payload_b64="${payload_b64%.*}"
    sig_b64="${pkg##*.}"
    pubkey="$(tk_find_sign_pubkey)" || {
        echo ">>> 错误: 未找到验签公钥 master-sign-public.pem" >&2
        return 1
    }
    payload_bin="$(mktemp)"
    sig_bin="$(mktemp)"
    tk_b64url_decode "$payload_b64" > "$payload_bin"
    tk_b64url_decode "$sig_b64" > "$sig_bin"
    if ! openssl dgst -sha256 -verify "$pubkey" -signature "$sig_bin" "$payload_bin" >/dev/null 2>&1; then
        rm -f "$payload_bin" "$sig_bin"
        echo ">>> 错误: RSA 签名校验失败（可能被篡改或公钥不匹配）" >&2
        return 1
    fi
    cat "$payload_bin"
    rm -f "$payload_bin" "$sig_bin"
}

tk_json_get() {
    local json="$1" key="$2"
    TK_JSON_INPUT="$json" TK_JSON_KEY="$key" python3 - <<'PY'
import json, os, sys
raw = os.environ.get("TK_JSON_INPUT", "")
key = os.environ.get("TK_JSON_KEY", "")
try:
    obj = json.loads(raw)
except Exception:
    sys.exit(1)
val = obj.get(key, "")
if val is None:
    val = ""
if isinstance(val, bool):
    print("true" if val else "false")
elif isinstance(val, (int, float)):
    print(val)
else:
    print(val)
PY
}

# 解析 master.endpoint.pkg → MASTER_URL MASTER_API_KEY
tk_parse_master_endpoint_pkg() {
    local pkg="$1"
    local json url api_key ssl exp now
    json="$(tk_verify_v2_pkg "$pkg")" || return 1
    if [ "$(tk_json_get "$json" v)" != "2" ]; then
        echo ">>> 错误: 总台配置包版本无效" >&2
        return 1
    fi
    url="$(tk_json_get "$json" url)"
    api_key="$(tk_json_get "$json" apiKey)"
    ssl="$(tk_json_get "$json" sslInsecure)"
    exp="$(tk_json_get "$json" exp)"
    if [ -z "$url" ] || [ -z "$api_key" ]; then
        echo ">>> 错误: 总台配置包缺少 url 或 apiKey" >&2
        return 1
    fi
    if [ -n "$exp" ] && [ "$exp" != "0" ]; then
        now="$(date +%s)"
        if [ "$now" -gt "$exp" ]; then
            echo ">>> 错误: 总台配置包已过期" >&2
            return 1
        fi
    fi
    while [[ "$url" == */ ]]; do url="${url%/}"; done
    MASTER_URL="$url"
    MASTER_API_KEY="$api_key"
    MASTER_SSL_INSECURE="$ssl"
}

# 解析 bootstrap.secrets.pkg → BOOTSTRAP_CF_TOKEN 等
tk_parse_bootstrap_secrets_pkg() {
    local pkg="$1"
    local json kind exp now
    json="$(tk_verify_v2_pkg "$pkg")" || return 1
    if [ "$(tk_json_get "$json" v)" != "3" ]; then
        echo ">>> 错误: bootstrap 配置包版本无效" >&2
        return 1
    fi
    kind="$(tk_json_get "$json" kind)"
    if [ "$kind" != "bootstrap-secrets" ]; then
        echo ">>> 错误: bootstrap 配置包 kind 无效" >&2
        return 1
    fi
    exp="$(tk_json_get "$json" exp)"
    if [ -n "$exp" ] && [ "$exp" != "0" ]; then
        now="$(date +%s)"
        if [ "$now" -gt "$exp" ]; then
            echo ">>> 错误: bootstrap 配置包已过期，请在总台重新签发" >&2
            return 1
        fi
    fi
    BOOTSTRAP_CF_TOKEN="$(tk_json_get "$json" cfToken)"
  BOOTSTRAP_ADMIN_HOSTS="$(tk_json_get "$json" adminHosts)"
    BOOTSTRAP_IMAGE_TAG="$(tk_json_get "$json" imageTag)"
    BOOTSTRAP_IMAGE_REGISTRY="$(tk_json_get "$json" imageRegistry)"
    BOOTSTRAP_TOKEN_SECRET="$(tk_json_get "$json" tokenSecret)"
    if [ -z "$BOOTSTRAP_CF_TOKEN" ]; then
        echo ">>> 错误: bootstrap 配置包缺少 cfToken" >&2
        return 1
    fi
}

# 探测公网 IPv4（供 ADMIN_API_HOSTS 自动填充）
tk_detect_public_ip() {
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

# deploy.env 中未配置或为示例占位符时视为未设置
tk_admin_hosts_is_unset() {
    local v="${1:-}"
    v="$(echo "$v" | tr -d '[:space:]')"
    case "$v" in
        ""|你的服务器公网IP|你的公网IP|1.2.3.4)
            return 0
            ;;
    esac
    return 1
}

tk_patch_deploy_env_var() {
    local file="$1" key="$2" value="$3"
    umask 077
    if [ ! -f "$file" ]; then
        cat > "$file" <<EOF
# TK 子台配置（自动生成，$(date -Iseconds 2>/dev/null || date))
${key}=${value}
EOF
        chmod 600 "$file"
        return 0
    fi
    if grep -q "^${key}=" "$file"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$file"
    else
        echo "${key}=${value}" >> "$file"
    fi
    chmod 600 "$file"
}

# 确保 ADMIN_API_HOSTS 有值；可选写入 deploy.env
tk_ensure_admin_api_hosts() {
    local deploy_env="${1:-}"
    local detected=""

    if ! tk_admin_hosts_is_unset "${ADMIN_API_HOSTS:-}"; then
        return 0
    fi
    if detected="$(tk_detect_public_ip)"; then
        ADMIN_API_HOSTS="$detected"
        export ADMIN_API_HOSTS
        if [ -n "$deploy_env" ]; then
            tk_patch_deploy_env_var "$deploy_env" "ADMIN_API_HOSTS" "$detected"
        fi
        echo ">>> 已自动探测公网 IP 作为 ADMIN_API_HOSTS: $ADMIN_API_HOSTS"
        return 0
    fi
    echo ">>> 警告: 无法自动探测公网 IP，/prod-api/ 仅允许本机访问；请手动在 deploy.env 设置 ADMIN_API_HOSTS" >&2
    return 1
}

# 将已解析的 bootstrap 字段写入 deploy.env
tk_write_deploy_env_from_bootstrap() {
    local deploy_env="$1"
    local admin_hosts="${2:-}"
    local token_secret="${3:-}"

    if [ -z "$admin_hosts" ]; then
        admin_hosts="${BOOTSTRAP_ADMIN_HOSTS:-}"
    fi
    if tk_admin_hosts_is_unset "$admin_hosts"; then
        if detected="$(tk_detect_public_ip)"; then
            admin_hosts="$detected"
            echo ">>> 已自动探测公网 IP 作为 ADMIN_API_HOSTS: $admin_hosts"
        fi
    fi
    if [ -z "$token_secret" ]; then
        token_secret="${BOOTSTRAP_TOKEN_SECRET:-}"
    fi
    if [ -z "$token_secret" ]; then
        token_secret="$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    fi

    local tag="${BOOTSTRAP_IMAGE_TAG:-latest}"
    local registry="${BOOTSTRAP_IMAGE_REGISTRY:-ghcr.io/dinopell}"
    if [ -z "$tag" ]; then tag="latest"; fi
    if [ -z "$registry" ]; then registry="ghcr.io/dinopell"; fi

    umask 077
    cat > "$deploy_env" <<EOF
# TK 子台生产配置（由 bootstrap 签名包生成，$(date -Iseconds 2>/dev/null || date))
ADMIN_API_HOSTS=${admin_hosts}
SUBSTATION_SSL_CHALLENGE_TYPE=dns-cloudflare
CLOUDFLARE_API_TOKEN=${BOOTSTRAP_CF_TOKEN}
SSL_HTTP01_ENABLED=0
CDN_ENABLED=1
CDN_PROVIDER=cloudflare
IMAGE_TAG=${tag}
IMAGE_REGISTRY=${registry}
TOKEN_SECRET=${token_secret}
EOF
    chmod 600 "$deploy_env"
}

# 从文件读取单行 pkg
tk_read_pkg_file() {
    local f="$1"
    tr -d '\n\r\t ' < "$f"
}

# 总台拉取 bootstrap.secrets.pkg（须已解析 MASTER_URL / MASTER_API_KEY）
tk_fetch_bootstrap_secrets_from_master() {
    local out_file="${1:-}"
    local base url curl_opts tmp
    base="${MASTER_URL%/}"
    base="${base%/prod-api}"
    url="${base}/api/substation/bootstrap-secrets"
    curl_opts=(-fsS --max-time 30 -H "X-API-Key: ${MASTER_API_KEY}")
    if [ "${MASTER_SSL_INSECURE:-false}" = "true" ]; then
        curl_opts+=(-k)
    fi
    tmp="$(mktemp)"
    if ! curl "${curl_opts[@]}" "$url" -o "$tmp"; then
        rm -f "$tmp"
        echo ">>> 错误: 从总台拉取 bootstrap 配置包失败: $url" >&2
        return 1
    fi
    local pkg
    pkg="$(tr -d '\n\r\t ' < "$tmp")"
    rm -f "$tmp"
    if [ -z "$pkg" ]; then
        echo ">>> 错误: 总台返回空的 bootstrap 配置包" >&2
        return 1
    fi
    if [ -n "$out_file" ]; then
        umask 077
        printf '%s' "$pkg" > "$out_file"
        chmod 600 "$out_file"
    fi
    printf '%s' "$pkg"
}
