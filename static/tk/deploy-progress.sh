# TK 部署进度（默认纯文本逐行输出，不占用备用屏、不清历史；DEPLOY_PROGRESS_UI=1 可开条形进度）
# 模块：MySQL / Redis / tk-shield / Backend / Frontend

PROGRESS_MODULE_IDS=(mysql redis tk-shield backend frontend)
PROGRESS_MODULE_LABELS=("MySQL" "Redis" "tk-shield" "Backend" "Frontend")
PROGRESS_MODULE_STATUS=()
PROGRESS_MODULE_MSG=()
PROGRESS_MODULE_PCT=()
_PROGRESS_ACTIVE=0
_PROGRESS_LAST_PRINTED=()

if ! declare -f deploy_log >/dev/null 2>&1; then
    deploy_log() {
        local log="${DEPLOY_LOG:-${INSTALL_LOG:-}}"
        [ -n "$log" ] || return 0
        mkdir -p "$(dirname "$log")" 2>/dev/null || true
        echo -e "$@" >>"$log" 2>/dev/null || true
    }
fi
if ! declare -f deploy_err >/dev/null 2>&1; then
    deploy_err() { echo -e "$@" >&2; }
fi
if ! declare -f deploy_user >/dev/null 2>&1; then
    deploy_user() { echo -e "$@"; }
fi

progress_enabled() {
    [ "${DEPLOY_PROGRESS:-1}" = "1" ] && [ "${DEPLOY_VERBOSE:-0}" != "1" ]
}

progress_ui_enabled() {
    progress_enabled && [ "${DEPLOY_PROGRESS_UI:-0}" = "1" ] && [ -t 1 ]
}

progress_ui_quiet() {
    progress_ui_enabled && [ "${_PROGRESS_ACTIVE:-0}" = "1" ]
}

progress_log() {
    deploy_log "$@"
}

progress_reset_modules() {
    local i
    for i in "${!PROGRESS_MODULE_IDS[@]}"; do
        PROGRESS_MODULE_STATUS[$i]="pending"
        PROGRESS_MODULE_MSG[$i]="等待"
        PROGRESS_MODULE_PCT[$i]=0
        _PROGRESS_LAST_PRINTED[$i]=""
    done
}

progress_init() {
    if [ "${_PROGRESS_ACTIVE:-0}" = "1" ]; then
        return 0
    fi
    progress_reset_modules
    _PROGRESS_ACTIVE=1
    if progress_enabled; then
        deploy_user "${BLUE}>>> 启动 TK 服务模块（MySQL → Redis → tk-shield → Backend → Frontend）${NC}"
    fi
}

progress_handoff_init() {
    progress_init
}

progress_set() {
    local id="$1" status="$2" msg="${3:-}" pct="${4:--1}" defer_render="${5:-0}"
    local i idx=-1 old_status
    for i in "${!PROGRESS_MODULE_IDS[@]}"; do
        if [ "${PROGRESS_MODULE_IDS[$i]}" = "$id" ]; then
            idx=$i
            break
        fi
    done
    [ "$idx" -ge 0 ] || return 0

    old_status="${PROGRESS_MODULE_STATUS[$idx]}"
    PROGRESS_MODULE_STATUS[$idx]="$status"
    PROGRESS_MODULE_MSG[$idx]="$msg"
    if [ "$pct" -ge 0 ] 2>/dev/null; then
        PROGRESS_MODULE_PCT[$idx]="$pct"
    else
        case "$status" in
            pending) PROGRESS_MODULE_PCT[$idx]=0 ;;
            running) PROGRESS_MODULE_PCT[$idx]=45 ;;
            ok) PROGRESS_MODULE_PCT[$idx]=100 ;;
            skip) PROGRESS_MODULE_PCT[$idx]=100 ;;
            failed) PROGRESS_MODULE_PCT[$idx]=100 ;;
            *) PROGRESS_MODULE_PCT[$idx]=0 ;;
        esac
    fi

    progress_log "[progress] ${PROGRESS_MODULE_LABELS[$idx]}: $status — $msg"

    if [ "$defer_render" = "1" ]; then
        return 0
    fi
    if progress_ui_enabled; then
        progress_render_bars
    elif progress_enabled; then
        progress_print_plain "$idx" "$old_status"
    fi
}

progress_print_plain() {
    local idx="$1" old_status="${2:-}"
    local status="${PROGRESS_MODULE_STATUS[$idx]}"
    local msg="${PROGRESS_MODULE_MSG[$idx]}"
    local label="${PROGRESS_MODULE_LABELS[$idx]}"
    local key="${status}|${msg}"

    case "$status" in
        ok)
            [ "${_PROGRESS_LAST_PRINTED[$idx]}" = "$key" ] && return 0
            _PROGRESS_LAST_PRINTED[$idx]="$key"
            deploy_user "  ${GREEN}✓${NC} ${label}  ${msg}"
            ;;
        skip)
            [ "${_PROGRESS_LAST_PRINTED[$idx]}" = "$key" ] && return 0
            _PROGRESS_LAST_PRINTED[$idx]="$key"
            deploy_user "  ${YELLOW}–${NC} ${label}  ${msg}"
            ;;
        failed)
            [ "${_PROGRESS_LAST_PRINTED[$idx]}" = "$key" ] && return 0
            _PROGRESS_LAST_PRINTED[$idx]="$key"
            deploy_err "  ${RED}✗${NC} ${label}  ${msg}"
            ;;
        running)
            # 同一模块 running 只打一行，避免刷屏
            [ "${old_status}" = "running" ] && return 0
            [ "${_PROGRESS_LAST_PRINTED[$idx]}" = "running|" ] && return 0
            _PROGRESS_LAST_PRINTED[$idx]="running|"
            deploy_user "  ${YELLOW}…${NC} ${label}  ${msg}"
            ;;
    esac
}

_progress_bar_glyphs() {
    local pct="$1" width=20
    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local i bar=""
    for ((i = 0; i < filled; i++)); do bar+='█'; done
    for ((i = 0; i < empty; i++)); do bar+='░'; done
    printf '%s' "$bar"
}

progress_render_bars() {
    progress_ui_enabled || return 0
    local i status msg pct glyphs label
    echo ""
    echo "  TK 服务模块"
    echo "  ─────────────────────────────────────────"
    for i in "${!PROGRESS_MODULE_IDS[@]}"; do
        status="${PROGRESS_MODULE_STATUS[$i]}"
        msg="${PROGRESS_MODULE_MSG[$i]}"
        pct="${PROGRESS_MODULE_PCT[$i]}"
        label="${PROGRESS_MODULE_LABELS[$i]}"
        glyphs=$(_progress_bar_glyphs "$pct")
        case "$status" in
            ok)    printf '  \033[0;32m%-10s [%s] %3s%%  %s\033[0m\n' "$label" "$glyphs" "$pct" "$msg" ;;
            failed) printf '  \033[0;31m%-10s [%s] %3s%%  %s\033[0m\n' "$label" "$glyphs" "$pct" "$msg" ;;
            skip)  printf '  \033[0;90m%-10s [%s] %3s%%  %s\033[0m\n' "$label" "$glyphs" "$pct" "$msg" ;;
            running) printf '  \033[0;33m%-10s [%s] %3s%%  %s\033[0m\n' "$label" "$glyphs" "$pct" "$msg" ;;
            *)     printf '  \033[0;90m%-10s [%s] %3s%%  %s\033[0m\n' "$label" "$glyphs" "$pct" "$msg" ;;
        esac
    done
    echo ""
}

progress_finish() {
    progress_enabled || return 0
    if progress_ui_enabled; then
        progress_render_bars
    fi
    _PROGRESS_ACTIVE=0
}

progress_fail_module() {
    local id="$1" msg="${2:-启动失败}"
    progress_set "$id" failed "$msg" 100
}

progress_abort() {
    local summary="${1:-服务模块启动失败}"
    progress_finish
    deploy_err "${RED}>>> ${summary}${NC}"
    deploy_err "${YELLOW}>>> 详细日志: ${DEPLOY_LOG:-${INSTALL_LOG:-}}${NC}"
    exit 1
}

progress_pull_quiet() {
    local image="$1" log_file="${2:-${DEPLOY_LOG:-${INSTALL_LOG:-}}}" tries="${3:-3}"
    local n=1
    while [ "$n" -le "$tries" ]; do
        if [ "${DEPLOY_VERBOSE:-0}" = "1" ]; then
            docker pull "$image" && return 0
        elif docker pull "$image" >>"$log_file" 2>&1; then
            return 0
        fi
        progress_log "${YELLOW}>>> 拉取失败 (${n}/${tries}): ${image}${NC}"
        sleep 5
        n=$((n + 1))
    done
    return 1
}

_mysql_ready() {
    local hs
    hs="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' app-deploy-mysql-1 2>/dev/null || echo none)"
    if [ "$hs" = "healthy" ]; then
        return 0
    fi
    docker exec app-deploy-mysql-1 \
        mysqladmin ping -h 127.0.0.1 -uroot -p"${MYSQL_PWD}" --silent >/dev/null 2>&1
}

_container_running() {
    [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || echo false)" = "true" ]
}

_backend_ready() {
    if ! _container_running app-deploy-backend-1; then
        return 1
    fi
    if docker logs app-deploy-backend-1 2>&1 | tail -300 | grep -qE 'TK启动成功|若依启动成功'; then
        return 0
    fi
    local code
    code="$(docker exec app-deploy-backend-1 sh -c \
        'curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://127.0.0.1:8080/ 2>/dev/null || echo 000')" || code="000"
    case "$code" in
        200|302|401|403|404) return 0 ;;
    esac
    return 1
}

_frontend_ready() {
    if ! _container_running app-deploy-frontend-1; then
        return 1
    fi
    if [ -n "${ADMIN_ENTRY:-}" ]; then
        local code
        code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 \
            "http://127.0.0.1/${ADMIN_ENTRY}/" 2>/dev/null || echo 000)"
        case "$code" in
            200|301|302) return 0 ;;
        esac
    fi
    docker exec app-deploy-frontend-1 nginx -t >>"${DEPLOY_LOG:-/dev/null}" 2>&1
}

_all_services_ready() {
    local shield_ok=1
    if [ "${TK_SHIELD_ENABLED:-0}" = "1" ]; then
        _container_running app-deploy-tk-shield-1 || shield_ok=0
    fi
    _mysql_ready && _container_running app-deploy-redis-1 && [ "$shield_ok" -eq 1 ] \
        && _backend_ready && _frontend_ready
}

progress_wait_all_services() {
    local i max=90
    local mysql_ok=0 redis_ok=0 shield_ok=0 backend_ok=0 frontend_ok=0
    local shield_skip=0 pulse

    if [ "$TK_SHIELD_ENABLED" != "1" ]; then
        shield_skip=1
        shield_ok=1
        progress_set tk-shield skip "未启用" -1
    fi

    progress_set mysql running "启动中" 15
    progress_set redis running "启动中" 15
    if [ "$shield_skip" -eq 0 ]; then
        progress_set tk-shield running "启动中" 15
    fi
    progress_set backend running "等待依赖" 10
    progress_set frontend running "等待 Backend" 5

    for i in $(seq 1 "$max"); do
        pulse=$(( 25 + (i % 6) * 10 ))
        [ "$pulse" -gt 85 ] && pulse=85

        if [ "$mysql_ok" -eq 0 ] && _mysql_ready; then
            mysql_ok=1
            mysql_ensure_beijing_timezone
            progress_set mysql ok "健康检查通过" 100
        elif [ "$mysql_ok" -eq 0 ]; then
            progress_set mysql running "启动中 (${i}/${max})" "$pulse" 1
        fi

        if [ "$redis_ok" -eq 0 ] && _container_running app-deploy-redis-1; then
            redis_ok=1
            progress_set redis ok "已运行" 100
        elif [ "$redis_ok" -eq 0 ]; then
            progress_set redis running "启动中 (${i}/${max})" "$pulse" 1
        fi

        if [ "$shield_skip" -eq 0 ] && [ "$shield_ok" -eq 0 ] && _container_running app-deploy-tk-shield-1; then
            shield_ok=1
            progress_set tk-shield ok "已运行" 100
        elif [ "$shield_skip" -eq 0 ] && [ "$shield_ok" -eq 0 ]; then
            progress_set tk-shield running "启动中 (${i}/${max})" "$pulse" 1
        fi

        if [ "$backend_ok" -eq 0 ] && [ "$mysql_ok" -eq 1 ]; then
            if _backend_ready; then
                backend_ok=1
                progress_set backend ok "TK 已启动" 100
            else
                progress_set backend running "JVM 启动中 (${i}/${max})" "$pulse" 1
            fi
        fi

        if [ "$frontend_ok" -eq 0 ] && [ "$backend_ok" -eq 1 ]; then
            if _frontend_ready; then
                frontend_ok=1
                progress_set frontend ok "Nginx 就绪" 100
            else
                progress_set frontend running "Nginx 配置中 (${i}/${max})" "$pulse" 1
            fi
        fi

        if [ "$mysql_ok" -eq 1 ] && [ "$redis_ok" -eq 1 ] && [ "$shield_ok" -eq 1 ] \
            && [ "$backend_ok" -eq 1 ] && [ "$frontend_ok" -eq 1 ]; then
            progress_finish
            return 0
        fi
        sleep 2
    done

    if _all_services_ready; then
        [ "$mysql_ok" -eq 0 ] && progress_set mysql ok "健康检查通过" 100
        [ "$redis_ok" -eq 0 ] && progress_set redis ok "已运行" 100
        if [ "$shield_skip" -eq 0 ] && [ "$shield_ok" -eq 0 ]; then
            progress_set tk-shield ok "已运行" 100
        fi
        [ "$backend_ok" -eq 0 ] && progress_set backend ok "TK 已启动" 100
        [ "$frontend_ok" -eq 0 ] && progress_set frontend ok "Nginx 就绪" 100
        deploy_user "${YELLOW}>>> 进度检测超时，但各模块探针已通过，继续完成 SQL 与 Nginx 配置...${NC}"
        progress_log "[progress] wait timeout (${max} rounds) but probes ok — continuing deploy"
        progress_finish
        return 0
    fi

    [ "$mysql_ok" -eq 1 ] || progress_fail_module mysql "超时未就绪"
    [ "$redis_ok" -eq 1 ] || progress_fail_module redis "超时未就绪"
    if [ "$shield_skip" -eq 0 ] && [ "$shield_ok" -eq 0 ]; then
        progress_fail_module tk-shield "超时未就绪"
    fi
    [ "$backend_ok" -eq 1 ] || progress_fail_module backend "超时未就绪"
    [ "$frontend_ok" -eq 1 ] || progress_fail_module frontend "超时未就绪"
    progress_abort "服务模块启动超时（${max} 轮）"
}
