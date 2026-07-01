# TK 部署进度条（Installer + MySQL / Redis / tk-shield / Backend / Frontend）
# 宿主机 install.sh 与 installer 内 deploy-internal.sh 共用；非 TTY 时退化为逐行文本。

PROGRESS_MODULE_IDS=(installer mysql redis tk-shield backend frontend)
PROGRESS_MODULE_LABELS=("Installer" "MySQL" "Redis" "tk-shield" "Backend" "Frontend")
PROGRESS_MODULE_STATUS=()
PROGRESS_MODULE_MSG=()
PROGRESS_MODULE_PCT=()
_PROGRESS_ACTIVE=0
_PROGRESS_ALT_SCREEN=0
_PROGRESS_TTY="/dev/tty"

# install.sh 单独 source 时提供默认日志函数
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

progress_tty_printf() {
    if [ -w "$_PROGRESS_TTY" ] 2>/dev/null; then
        printf "$@" >"$_PROGRESS_TTY"
    else
        printf "$@"
    fi
}

progress_enabled() {
    [ "${DEPLOY_PROGRESS:-1}" = "1" ] && [ "${DEPLOY_VERBOSE:-0}" != "1" ] \
        && { [ -t 1 ] || [ -w "$_PROGRESS_TTY" ] 2>/dev/null; }
}

progress_ui_quiet() {
    progress_enabled && [ "${_PROGRESS_ACTIVE:-0}" = "1" ]
}

progress_log() {
    deploy_log "$@"
}

progress_screen_enter() {
    progress_enabled || return 0
    [ "$_PROGRESS_ALT_SCREEN" = "1" ] && return 0
    progress_tty_printf '\033[?1049h\033[2J\033[H'
    _PROGRESS_ALT_SCREEN=1
}

progress_screen_leave() {
    progress_enabled || return 0
    [ "$_PROGRESS_ALT_SCREEN" = "1" ] || return 0
    progress_tty_printf '\033[?1049l'
    _PROGRESS_ALT_SCREEN=0
}

progress_reset_modules() {
    local i
    for i in "${!PROGRESS_MODULE_IDS[@]}"; do
        PROGRESS_MODULE_STATUS[$i]="pending"
        PROGRESS_MODULE_MSG[$i]="等待"
        PROGRESS_MODULE_PCT[$i]=0
    done
}

progress_init() {
    if [ "${_PROGRESS_ACTIVE:-0}" = "1" ]; then
        return 0
    fi
    progress_reset_modules
    if progress_enabled; then
        progress_screen_enter
        progress_render
        _PROGRESS_ACTIVE=1
    else
        deploy_user "${BLUE}>>> 启动: Installer → MySQL → Redis → tk-shield → Backend → Frontend${NC}"
    fi
}

# install.sh 拉完 installer 后进入容器，沿用同一块备用屏
progress_handoff_init() {
    if [ "${_PROGRESS_ACTIVE:-0}" = "1" ]; then
        return 0
    fi
    progress_reset_modules
    progress_set installer ok "已就绪" 100 1
    if progress_enabled; then
        _PROGRESS_ALT_SCREEN=1
        progress_render
        _PROGRESS_ACTIVE=1
    fi
}

progress_set() {
    local id="$1" status="$2" msg="${3:-}" pct="${4:--1}" defer_render="${5:-0}"
    local i idx=-1
    for i in "${!PROGRESS_MODULE_IDS[@]}"; do
        if [ "${PROGRESS_MODULE_IDS[$i]}" = "$id" ]; then
            idx=$i
            break
        fi
    done
    [ "$idx" -ge 0 ] || return 0

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
    if progress_enabled; then
        progress_render
    else
        case "$status" in
            ok|skip|failed)
                deploy_user "  • ${PROGRESS_MODULE_LABELS[$idx]}: $msg"
                ;;
        esac
    fi
}

_progress_bar_glyphs() {
    local pct="$1" width=22
    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local i bar="" space=""
    for ((i = 0; i < filled; i++)); do bar+="#"; done
    for ((i = 0; i < empty; i++)); do space+="-"; done
    printf '%s%s' "$bar" "$space"
}

_progress_trim_msg() {
    local text="$1"
    if [ "${#text}" -gt 32 ]; then
        text="${text:0:32}"
    fi
    printf '%s' "$text"
}

progress_render() {
    progress_enabled || return 0
    local i status msg pct glyphs label
    progress_screen_enter
    progress_tty_printf '\033[H'
    progress_tty_printf '\033[2K\r  TK 服务模块启动进度\033[K\n'
    progress_tty_printf '\033[2K\r  ─────────────────────────────────────────\033[K\n'
    for i in "${!PROGRESS_MODULE_IDS[@]}"; do
        status="${PROGRESS_MODULE_STATUS[$i]}"
        msg="$(_progress_trim_msg "${PROGRESS_MODULE_MSG[$i]}")"
        pct="${PROGRESS_MODULE_PCT[$i]}"
        label="${PROGRESS_MODULE_LABELS[$i]}"
        glyphs=$(_progress_bar_glyphs "$pct")
        case "$status" in
            ok)
                progress_tty_printf '\033[2K\r  \033[0;32m%-10s [%s] %3s%%  %-32s\033[0m\033[K\n' "$label" "$glyphs" "$pct" "$msg"
                ;;
            failed)
                progress_tty_printf '\033[2K\r  \033[0;31m%-10s [%s] %3s%%  %-32s\033[0m\033[K\n' "$label" "$glyphs" "$pct" "$msg"
                ;;
            skip)
                progress_tty_printf '\033[2K\r  \033[0;90m%-10s [%s] %3s%%  %-32s\033[0m\033[K\n' "$label" "$glyphs" "$pct" "$msg"
                ;;
            running)
                progress_tty_printf '\033[2K\r  \033[0;33m%-10s [%s] %3s%%  %-32s\033[0m\033[K\n' "$label" "$glyphs" "$pct" "$msg"
                ;;
            *)
                progress_tty_printf '\033[2K\r  \033[0;90m%-10s [%s] %3s%%  %-32s\033[0m\033[K\n' "$label" "$glyphs" "$pct" "$msg"
                ;;
        esac
    done
    progress_tty_printf '\033[J'
}

progress_finish() {
    progress_enabled || return 0
    if [ "$_PROGRESS_ACTIVE" = "1" ]; then
        progress_render
        progress_screen_leave
        _PROGRESS_ACTIVE=0
    fi
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

progress_pull_with_bar() {
    local id="$1" image="$2" log_file="${3:-${DEPLOY_LOG:-${INSTALL_LOG:-}}}" tries="${4:-3}"
    local n=1 pulse=20 pull_pid rc=0
    while [ "$n" -le "$tries" ]; do
        progress_set "$id" running "拉取镜像 (${n}/${tries})" "$pulse" 1
        progress_render
        if [ "${DEPLOY_VERBOSE:-0}" = "1" ]; then
            docker pull "$image" && return 0
        else
            docker pull "$image" >>"$log_file" 2>&1 &
            pull_pid=$!
            while kill -0 "$pull_pid" 2>/dev/null; do
                pulse=$((pulse + 3))
                [ "$pulse" -gt 88 ] && pulse=25
                progress_set "$id" running "拉取镜像中..." "$pulse" 1
                progress_render
                sleep 1
            done
            if wait "$pull_pid"; then
                return 0
            fi
        fi
        progress_log "${YELLOW}>>> 拉取失败 (${n}/${tries}): ${image}${NC}"
        sleep 5
        n=$((n + 1))
        pulse=20
    done
    return 1
}

_backend_startup_ok() {
    docker logs app-deploy-backend-1 2>&1 | tail -120 | grep -qE 'TK启动成功|若依启动成功'
}

progress_wait_all_services() {
    local i max=60
    local mysql_ok=0 redis_ok=0 shield_ok=0 backend_ok=0 frontend_ok=0
    local shield_skip=0 pulse

    if [ "$TK_SHIELD_ENABLED" != "1" ]; then
        shield_skip=1
        shield_ok=1
        progress_set tk-shield skip "未启用" -1 1
    fi

    progress_set mysql running "启动中" 15 1
    progress_set redis running "启动中" 15 1
    if [ "$shield_skip" -eq 0 ]; then
        progress_set tk-shield running "启动中" 15 1
    fi
    progress_set backend running "等待依赖" 10 1
    progress_set frontend running "等待 Backend" 5 1
    progress_render

    for i in $(seq 1 "$max"); do
        pulse=$(( 25 + (i % 6) * 10 ))
        [ "$pulse" -gt 85 ] && pulse=85

        if [ "$mysql_ok" -eq 0 ]; then
            if docker exec app-deploy-mysql-1 \
                mysqladmin ping -h localhost -uroot -p"${MYSQL_PWD}" --silent 2>/dev/null; then
                mysql_ok=1
                mysql_ensure_beijing_timezone
                progress_set mysql ok "健康检查通过" 100 1
            else
                progress_set mysql running "启动中 (${i}/${max})" "$pulse" 1
            fi
        fi

        if [ "$redis_ok" -eq 0 ]; then
            if [ "$(docker inspect -f '{{.State.Running}}' app-deploy-redis-1 2>/dev/null || echo false)" = "true" ]; then
                redis_ok=1
                progress_set redis ok "已运行" 100 1
            else
                progress_set redis running "启动中 (${i}/${max})" "$pulse" 1
            fi
        fi

        if [ "$shield_skip" -eq 0 ] && [ "$shield_ok" -eq 0 ]; then
            if [ "$(docker inspect -f '{{.State.Running}}' app-deploy-tk-shield-1 2>/dev/null || echo false)" = "true" ]; then
                shield_ok=1
                progress_set tk-shield ok "已运行" 100 1
            else
                progress_set tk-shield running "启动中 (${i}/${max})" "$pulse" 1
            fi
        fi

        if [ "$backend_ok" -eq 0 ] && [ "$mysql_ok" -eq 1 ]; then
            if [ "$(docker inspect -f '{{.State.Running}}' app-deploy-backend-1 2>/dev/null || echo false)" = "true" ]; then
                if _backend_startup_ok; then
                    backend_ok=1
                    progress_set backend ok "TK 已启动" 100 1
                else
                    progress_set backend running "JVM 启动中 (${i}/${max})" "$pulse" 1
                fi
            else
                progress_set backend running "等待容器 (${i}/${max})" "$((pulse / 2))" 1
            fi
        fi

        if [ "$frontend_ok" -eq 0 ] && [ "$backend_ok" -eq 1 ]; then
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^app-deploy-frontend-1$'; then
                if docker exec app-deploy-frontend-1 nginx -t >>"${DEPLOY_LOG}" 2>&1; then
                    frontend_ok=1
                    progress_set frontend ok "Nginx 就绪" 100 1
                else
                    progress_set frontend running "Nginx 配置中 (${i}/${max})" "$pulse" 1
                fi
            else
                progress_set frontend running "等待容器 (${i}/${max})" "$((pulse / 2))" 1
            fi
        fi

        progress_render

        if [ "$mysql_ok" -eq 1 ] && [ "$redis_ok" -eq 1 ] && [ "$shield_ok" -eq 1 ] \
            && [ "$backend_ok" -eq 1 ] && [ "$frontend_ok" -eq 1 ]; then
            progress_finish
            return 0
        fi
        sleep 2
    done

    [ "$mysql_ok" -eq 1 ] || progress_fail_module mysql "超时未就绪"
    [ "$redis_ok" -eq 1 ] || progress_fail_module redis "超时未就绪"
    if [ "$shield_skip" -eq 0 ] && [ "$shield_ok" -eq 0 ]; then
        progress_fail_module tk-shield "超时未就绪"
    fi
    [ "$backend_ok" -eq 1 ] || progress_fail_module backend "超时未就绪"
    [ "$frontend_ok" -eq 1 ] || progress_fail_module frontend "超时未就绪"
    progress_abort "服务模块启动超时（${max} 轮）"
}
