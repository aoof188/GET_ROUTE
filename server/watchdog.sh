#!/usr/bin/env bash
# ============================================================
#  sing-box 服务看门狗 (Watchdog)
#  功能: 监控 sing-box / panel / nginx，异常自动重启
#  部署: systemd timer 每 2 分钟执行一次
#  日志: /var/log/sing-box/watchdog.log
# ============================================================

set -uo pipefail

# ---------- 配置 ----------

STATE_DIR="/var/lib/sing-box/watchdog"
LOG_FILE="/var/log/sing-box/watchdog.log"
MAX_LOG_LINES=5000

# 每个服务的连续重启上限（达到后停止重启，只告警）
MAX_RESTART_COUNT=5
# 重启计数器重置周期（秒），连续成功运行超过此时间则清零
RESTART_RESET_WINDOW=1800  # 30 分钟

# 告警 Webhook（可选）
ALERT_WEBHOOK="${WATCHDOG_ALERT_WEBHOOK:-}"
ALERT_TYPE="${WATCHDOG_ALERT_TYPE:-}"  # dingtalk / telegram / custom
TELEGRAM_CHAT_ID="${WATCHDOG_TELEGRAM_CHAT_ID:-}"

# 要监控的服务列表
# 格式: "systemd_unit|check_host:check_port|display_name"
SERVICES=(
    "sing-box|127.0.0.1:9090|sing-box 核心"
    "sing-box-panel|127.0.0.1:8080|管理面板"
    "nginx|127.0.0.1:80|Nginx 反代"
)

# WireGuard 隧道检查（通过 Clash API）
CLASH_API="http://127.0.0.1:9090"
TUNNELS=("wg-jp" "wg-sg" "wg-uk")

# 证书检查
CERT_WARN_DAYS=14
CERT_DIRS=("/etc/sing-box/cert" "/etc/nginx/ssl")

# ---------- 初始化 ----------

mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
HOSTNAME_SHORT=$(hostname -s)

# ---------- 日志函数 ----------

log() {
    local level="$1"; shift
    local msg="[${TIMESTAMP}] [${level}] $*"
    echo "$msg" >> "$LOG_FILE"
    # 只在终端交互时输出到 stdout
    [ -t 1 ] && echo "$msg"
}

log_info()  { log "INFO " "$@"; }
log_warn()  { log "WARN " "$@"; }
log_error() { log "ERROR" "$@"; }
log_ok()    { log " OK  " "$@"; }

# 日志轮转（保持文件不会无限增长）
rotate_log() {
    if [ -f "$LOG_FILE" ]; then
        local lines
        lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo "0")
        if [ "$lines" -gt "$MAX_LOG_LINES" ]; then
            tail -n $((MAX_LOG_LINES / 2)) "$LOG_FILE" > "${LOG_FILE}.tmp"
            mv "${LOG_FILE}.tmp" "$LOG_FILE"
        fi
    fi
}

# ---------- 告警 ----------

# 安全转义 JSON 字符串 (使用 jq 避免注入)
escape_json_str() {
    local str="$1"
    # 使用 jq 安全转义，返回纯字符串
    printf '%s' "$str" | jq -Rs '.' | sed 's/^"//;s/"$//'
}

send_alert() {
    local raw_msg="$1"
    local message="[WD][${HOSTNAME_SHORT}] ${raw_msg}"

    log_warn "告警: $message"
    [ -z "$ALERT_WEBHOOK" ] && return 0

    # 转义特殊字符防止注入
    local escaped_msg escaped_host escaped_time
    escaped_msg=$(escape_json_str "$message")
    escaped_host=$(escape_json_str "$HOSTNAME_SHORT")
    escaped_time=$(escape_json_str "$TIMESTAMP")

    case $ALERT_TYPE in
        dingtalk)
            local payload
            payload=$(jq -n --arg msg "$escaped_msg" \
                '{"msgtype":"text","text":{"content":$msg}}')
            curl -s --max-time 5 -X POST "$ALERT_WEBHOOK" \
                -H 'Content-Type: application/json' \
                -d "$payload" \
                >/dev/null 2>&1 || true
            ;;
        telegram)
            [ -n "$TELEGRAM_CHAT_ID" ] && \
            curl -s --max-time 5 -X POST "$ALERT_WEBHOOK" \
                -d "chat_id=${TELEGRAM_CHAT_ID}&text=${escaped_msg}" \
                >/dev/null 2>&1 || true
            ;;
        custom)
            local payload
            payload=$(jq -n --arg host "$escaped_host" \
                --arg msg "$escaped_msg" \
                --arg time "$escaped_time" \
                '{"host":$host,"message":$msg,"time":$time}')
            curl -s --max-time 5 -X POST "$ALERT_WEBHOOK" \
                -H 'Content-Type: application/json' \
                -d "$payload" \
                >/dev/null 2>&1 || true
            ;;
    esac
}

# ---------- 状态管理 ----------

# 获取服务的连续重启次数
get_restart_count() {
    local unit="$1"
    local file="${STATE_DIR}/${unit}.restart_count"
    [ -f "$file" ] && cat "$file" || echo "0"
}

# 增加重启计数
incr_restart_count() {
    local unit="$1"
    local file="${STATE_DIR}/${unit}.restart_count"
    local count
    count=$(get_restart_count "$unit")
    echo $((count + 1)) > "$file"
    # 记录最后重启时间
    date +%s > "${STATE_DIR}/${unit}.last_restart"
}

# 重置重启计数（服务持续运行正常时）
maybe_reset_restart_count() {
    local unit="$1"
    local count_file="${STATE_DIR}/${unit}.restart_count"
    local time_file="${STATE_DIR}/${unit}.last_restart"

    [ ! -f "$time_file" ] && return 0
    [ ! -f "$count_file" ] && return 0

    local last_restart
    last_restart=$(cat "$time_file")
    local now
    now=$(date +%s)
    local elapsed=$((now - last_restart))

    if [ "$elapsed" -gt "$RESTART_RESET_WINDOW" ]; then
        echo "0" > "$count_file"
        rm -f "$time_file"
        log_info "[${unit}] 已持续运行 $((elapsed / 60)) 分钟，重启计数器已清零"
    fi
}

# ---------- 检查函数 ----------

# 检查端口是否可达
check_port() {
    local host_port="$1"
    local host="${host_port%%:*}"
    local port="${host_port##*:}"

    # 使用多种方式检查端口
    if command -v ss &>/dev/null; then
        ss -tlnp 2>/dev/null | grep -q ":${port} " && return 0
    fi
    # 回退到 /dev/tcp
    (echo >/dev/tcp/"$host"/"$port") 2>/dev/null && return 0

    return 1
}

# 检查 systemd 服务状态
check_systemd_unit() {
    local unit="$1"
    systemctl is-active "$unit" >/dev/null 2>&1
}

# 重启服务
restart_service() {
    local unit="$1"
    local name="$2"

    local count
    count=$(get_restart_count "$unit")

    if [ "$count" -ge "$MAX_RESTART_COUNT" ]; then
        log_error "[${name}] 连续重启已达上限 (${count}/${MAX_RESTART_COUNT})，停止自动重启"
        send_alert "${name} 连续重启 ${count} 次已达上限，需人工介入！"
        return 1
    fi

    log_warn "[${name}] 执行自动重启 (第 $((count + 1)) 次)..."

    systemctl restart "$unit" 2>/dev/null

    # 等待启动
    sleep 3

    if check_systemd_unit "$unit"; then
        incr_restart_count "$unit"
        log_ok "[${name}] 重启成功"
        send_alert "${name} 已自动重启恢复 (第 $((count + 1)) 次)"
        return 0
    else
        incr_restart_count "$unit"
        log_error "[${name}] 重启后仍未正常运行"
        send_alert "${name} 重启失败 (第 $((count + 1)) 次)，需人工介入"
        return 1
    fi
}

# ---------- 核心监控逻辑 ----------

# 监控单个服务
watch_service() {
    local spec="$1"
    local unit="${spec%%|*}"; spec="${spec#*|}"
    local host_port="${spec%%|*}"; spec="${spec#*|}"
    local name="$spec"

    local need_restart=false
    local reason=""

    # 1) 先尝试重置计数器
    maybe_reset_restart_count "$unit"

    # 2) 检查 systemd 单元是否 enabled（未安装的服务跳过）
    if ! systemctl list-unit-files "${unit}.service" >/dev/null 2>&1; then
        return 0  # 服务未安装，跳过
    fi
    if ! systemctl is-enabled "$unit" >/dev/null 2>&1; then
        return 0  # 服务未启用，跳过
    fi

    # 3) 检查 systemd 状态
    if ! check_systemd_unit "$unit"; then
        need_restart=true
        reason="systemd 状态异常 ($(systemctl is-active "$unit" 2>/dev/null || echo 'unknown'))"
    fi

    # 4) 检查端口可达性（即使 systemd 显示 active，端口可能还没起来或卡死）
    if [ "$need_restart" = false ] && [ -n "$host_port" ]; then
        if ! check_port "$host_port"; then
            # 端口不通，再等 5 秒重试（避免误判）
            sleep 5
            if ! check_port "$host_port"; then
                need_restart=true
                reason="端口 ${host_port} 不可达"
            fi
        fi
    fi

    # 5) 执行重启或标记正常
    if [ "$need_restart" = true ]; then
        log_error "[${name}] 异常: ${reason}"
        restart_service "$unit" "$name"
    else
        log_ok "[${name}] 运行正常"
    fi
}

# 检查 WireGuard 隧道
watch_tunnels() {
    # 先检查 sing-box 是否在运行
    if ! check_systemd_unit "sing-box"; then
        return 0  # sing-box 都没跑，检查隧道无意义
    fi

    # 通过 Clash API 获取代理状态
    local api_ok=false
    local proxies_json
    proxies_json=$(curl -s --max-time 5 "${CLASH_API}/proxies" 2>/dev/null || echo "")
    [ -n "$proxies_json" ] && api_ok=true

    if [ "$api_ok" = false ]; then
        log_warn "[隧道] Clash API 无响应，跳过隧道检查"
        return 0
    fi

    local down_tunnels=()

    for tunnel in "${TUNNELS[@]}"; do
        local tunnel_data
        tunnel_data=$(echo "$proxies_json" | jq -r ".proxies[\"${tunnel}\"] // empty" 2>/dev/null)

        if [ -z "$tunnel_data" ]; then
            log_warn "[隧道] ${tunnel} 不存在于 sing-box 配置中"
            continue
        fi

        # 检查最近的延迟历史
        local last_delay
        last_delay=$(echo "$tunnel_data" | jq -r '.history[-1].delay // 0' 2>/dev/null || echo "0")

        if [ "$last_delay" -eq 0 ]; then
            log_warn "[隧道] ${tunnel} 延迟探测失败 (可能离线)"
            down_tunnels+=("$tunnel")
        elif [ "$last_delay" -gt 2000 ]; then
            log_warn "[隧道] ${tunnel} 延迟过高: ${last_delay}ms"
        else
            log_ok "[隧道] ${tunnel} 延迟: ${last_delay}ms"
        fi
    done

    if [ ${#down_tunnels[@]} -gt 0 ]; then
        local down_list
        down_list=$(IFS=','; echo "${down_tunnels[*]}")
        send_alert "WireGuard 隧道异常: ${down_list}"

        # 如果所有隧道都挂了，尝试 reload sing-box 触发重连
        if [ ${#down_tunnels[@]} -eq ${#TUNNELS[@]} ]; then
            log_warn "[隧道] 所有隧道异常，执行 sing-box reload 触发 WireGuard 重连"
            systemctl reload sing-box 2>/dev/null || systemctl restart sing-box 2>/dev/null || true
        fi
    fi
}

# 检查证书过期
watch_certs() {
    for cert_dir in "${CERT_DIRS[@]}"; do
        local cert_file="${cert_dir}/fullchain.pem"
        [ ! -f "$cert_file" ] && continue

        local expiry_date
        expiry_date=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
        [ -z "$expiry_date" ] && continue

        local expiry_epoch
        expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$expiry_date" +%s 2>/dev/null || echo "0")
        [ "$expiry_epoch" -eq 0 ] && continue

        local now_epoch
        now_epoch=$(date +%s)
        local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

        if [ "$days_left" -lt 0 ]; then
            log_error "[证书] ${cert_file} 已过期!"
            send_alert "证书已过期: ${cert_file}"
        elif [ "$days_left" -lt "$CERT_WARN_DAYS" ]; then
            log_warn "[证书] ${cert_file} 将在 ${days_left} 天后过期"
            send_alert "证书即将过期 (${days_left}天): ${cert_file}"
        else
            log_ok "[证书] ${cert_file} 有效期剩余 ${days_left} 天"
        fi
    done
}

# 检查系统资源
watch_resources() {
    # 磁盘
    local disk_usage
    disk_usage=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
    disk_usage=${disk_usage:-0}
    if [ "$disk_usage" -gt 90 ]; then
        log_error "[资源] 磁盘使用率: ${disk_usage}%"
        send_alert "磁盘使用率过高: ${disk_usage}%"
        # 尝试清理日志
        journalctl --vacuum-time=3d --vacuum-size=100M >/dev/null 2>&1 || true
    elif [ "$disk_usage" -gt 80 ]; then
        log_warn "[资源] 磁盘使用率: ${disk_usage}%"
    fi

    # 内存
    local mem_usage
    mem_usage=$(free | awk '/^Mem:/ {printf "%.0f", $3/$2*100}')
    mem_usage=${mem_usage:-0}
    if [ "$mem_usage" -gt 90 ]; then
        log_error "[资源] 内存使用率: ${mem_usage}%"
        send_alert "内存使用率危险: ${mem_usage}%"
    elif [ "$mem_usage" -gt 80 ]; then
        log_warn "[资源] 内存使用率: ${mem_usage}%"
    fi

    # sing-box 进程内存
    local sb_rss
    sb_rss=$(ps -eo rss,comm 2>/dev/null | awk '/sing-box/ {sum+=$1} END {print sum+0}')
    sb_rss=${sb_rss:-0}  # 防护空值
    if [ "$sb_rss" -gt 0 ]; then
        local sb_mb=$((sb_rss / 1024))
        if [ "$sb_mb" -gt 256 ]; then
            log_warn "[资源] sing-box 内存占用: ${sb_mb}MB (偏高)"
        fi
    fi
}

# ---------- 主流程 ----------

main() {
    local mode="${1:-auto}"

    rotate_log

    log_info "========== 看门狗巡检开始 (模式: ${mode}) =========="

    case "$mode" in
        auto)
            # 完整巡检：服务 + 隧道 + 证书 + 资源
            for svc in "${SERVICES[@]}"; do
                watch_service "$svc"
            done
            watch_tunnels
            watch_certs
            watch_resources
            ;;
        quick)
            # 快速巡检：仅服务存活
            for svc in "${SERVICES[@]}"; do
                watch_service "$svc"
            done
            ;;
        tunnel)
            # 仅隧道检查
            watch_tunnels
            ;;
        cert)
            # 仅证书检查
            watch_certs
            ;;
        reset)
            # 重置所有重启计数器
            rm -f "${STATE_DIR}"/*.restart_count "${STATE_DIR}"/*.last_restart
            log_info "所有重启计数器已清零"
            ;;
        status)
            # 显示当前状态
            echo "=== 服务重启计数 ==="
            for svc in "${SERVICES[@]}"; do
                local unit="${svc%%|*}"
                local count
                count=$(get_restart_count "$unit")
                local active
                active=$(systemctl is-active "$unit" 2>/dev/null || echo "未安装")
                echo "  ${unit}: 状态=${active}, 重启次数=${count}/${MAX_RESTART_COUNT}"
            done
            echo ""
            echo "=== 最近日志 ==="
            tail -20 "$LOG_FILE" 2>/dev/null || echo "  暂无日志"
            ;;
        *)
            echo "用法: $0 {auto|quick|tunnel|cert|reset|status}"
            echo ""
            echo "  auto    - 完整巡检（服务+隧道+证书+资源）[默认]"
            echo "  quick   - 快速巡检（仅服务存活检查）"
            echo "  tunnel  - 仅 WireGuard 隧道检查"
            echo "  cert    - 仅证书过期检查"
            echo "  reset   - 重置所有重启计数器"
            echo "  status  - 查看当前监控状态"
            exit 1
            ;;
    esac

    log_info "========== 看门狗巡检结束 =========================="
}

main "$@"
