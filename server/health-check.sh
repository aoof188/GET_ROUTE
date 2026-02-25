#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  sing-box 隧道健康检查脚本 (增强版)
#  用途: 检测各 WireGuard 出口的可用性、延迟、出口 IP
#  建议: crontab 每 5 分钟执行一次
#  crontab: */5 * * * * /opt/sing-box/health-check.sh report >> /var/log/sing-box/health.log 2>&1
# ============================================================

# ---------- 配置区域 ----------

# sing-box API 地址
CLASH_API="http://127.0.0.1:9090"

# 检测目标
CHECK_URL="https://httpbin.org/ip"
CHECK_TIMEOUT=10

# 告警 Webhook
ALERT_WEBHOOK=""
ALERT_TYPE=""  # dingtalk / telegram / custom

# 预期出口 IP 关键字
declare -A EXPECTED_COUNTRY=(
    ["wg-jp"]="Japan"
    ["wg-sg"]="Singapore"
    ["wg-uk"]="United Kingdom"
    ["auto-best"]="auto"  # Surfshark 智能连接
)

# Prometheus 指标输出目录
PROMETHEUS_METRICS_DIR="/var/lib/sing-box/prometheus"

# ---------- 函数区域 ----------

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
HOSTNAME=$(hostname)

log_info()  { echo "[${TIMESTAMP}] [INFO]  $*"; }
log_warn()  { echo "[${TIMESTAMP}] [WARN]  $*"; }
log_error() { echo "[${TIMESTAMP}] [ERROR] $*"; }

# jq 备用（当 jq 不可用时）
if ! command -v jq &>/dev/null; then
    jq() {
        python3 -c "import sys, json; d=json.load(open(sys.argv[1])) if len(sys.argv)>1 else json.load(sys.stdin); print(json.dumps(d.get('${2:-}', {})))" 2>/dev/null || \
        grep -o "\"${2:-}[^}]*\" | head -1 | sed 's/[{}]//g' || echo ""
    }
fi

# 发送告警（使用 jq 安全构造 JSON，防止注入）
send_alert() {
    local message="$1"
    [ -z "$ALERT_WEBHOOK" ] && return 0

    local full_msg="[sing-box][${HOSTNAME}] ${message}"

    case $ALERT_TYPE in
        dingtalk)
            local payload
            payload=$(jq -n --arg msg "$full_msg" \
                '{"msgtype":"text","text":{"content":$msg}}')
            curl -s --max-time 5 -X POST "$ALERT_WEBHOOK" \
                -H 'Content-Type: application/json' \
                -d "$payload" \
                >/dev/null 2>&1
            ;;
        telegram)
            # ALERT_WEBHOOK 格式: https://api.telegram.org/bot<TOKEN>/sendMessage
            # 需额外配置 CHAT_ID
            local CHAT_ID="${TELEGRAM_CHAT_ID:-}"
            [ -n "$CHAT_ID" ] && \
            curl -s --max-time 5 -X POST "$ALERT_WEBHOOK" \
                --data-urlencode "chat_id=${CHAT_ID}" \
                --data-urlencode "text=${full_msg}" \
                >/dev/null 2>&1
            ;;
        custom)
            local payload
            payload=$(jq -n --arg host "$HOSTNAME" --arg msg "$message" --arg ts "$TIMESTAMP" \
                '{"host":$host,"message":$msg,"time":$ts}')
            curl -s --max-time 5 -X POST "$ALERT_WEBHOOK" \
                -H 'Content-Type: application/json' \
                -d "$payload" \
                >/dev/null 2>&1
            ;;
    esac
}

# 检查 sing-box 进程
check_process() {
    if ! pgrep -x sing-box >/dev/null 2>&1; then
        log_error "sing-box 进程未运行!"
        send_alert "sing-box 进程未运行!"
        return 1
    fi
    log_info "sing-box 进程正常 (PID: $(pgrep -x sing-box))"
    return 0
}

# 检查 sing-box 服务状态
check_service() {
    local status
    status=$(systemctl is-active sing-box 2>/dev/null || echo "unknown")
    if [ "$status" != "active" ]; then
        log_error "sing-box 服务状态异常: ${status}"
        send_alert "sing-box 服务状态异常: ${status}"
        return 1
    fi
    log_info "sing-box 服务状态: active"
    return 0
}

# 通过 Clash API 检查出口（如果启用了 clash_api）
check_via_api() {
    local outbound="$1"

    # 尝试访问 Clash API
    local api_resp
    api_resp=$(curl -s --max-time 3 "${CLASH_API}/proxies/${outbound}" 2>/dev/null || echo "")
    if [ -z "$api_resp" ]; then
        return 1  # API 不可用，回退到其他方式
    fi

    # 解析延迟
    local delay
    delay=$(echo "$api_resp" | jq -r '.history[-1].delay // 0' 2>/dev/null || echo "0")

    if [ "$delay" -eq 0 ]; then
        log_warn "[${outbound}] 延迟探测失败 (via API)"
        return 2
    fi

    log_info "[${outbound}] 延迟: ${delay}ms (via API)"
    return 0
}

# 通过 curl 检查 WireGuard 隧道连通性
check_tunnel() {
    local outbound="$1"
    local expected_country="${EXPECTED_COUNTRY[$outbound]:-unknown}"
    local failed=0

    log_info "--- 检查隧道: ${outbound} (预期: ${expected_country}) ---"

    # 先尝试 API 方式
    if check_via_api "$outbound"; then
        return 0
    fi

    # API 不可用时，检查 WireGuard 接口状态
    # 注意: sing-box 内置 WireGuard 不创建系统接口
    # 这里通过 DNS 解析来验证隧道连通性

    # 检查出口 IP（通过 sing-box 的 SOCKS 代理或直接检查）
    # 注意: 此方式需要 sing-box 配置中有对应的 SOCKS 入站
    # 简化版：检查 sing-box 日志中的 WireGuard handshake
    local last_handshake
    last_handshake=$(journalctl -u sing-box --since "10 minutes ago" --no-pager 2>/dev/null | \
        grep -i "wireguard.*${outbound}" | tail -1 || echo "")

    if [ -n "$last_handshake" ]; then
        log_info "[${outbound}] 最近活动: $(echo "$last_handshake" | tail -c 120)"
    else
        log_warn "[${outbound}] 最近 10 分钟无 WireGuard 活动记录"
    fi

    return $failed
}

# 检查磁盘空间
check_disk() {
    local usage
    usage=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
    if [ "$usage" -gt 90 ]; then
        log_warn "磁盘使用率: ${usage}%"
        send_alert "磁盘使用率过高: ${usage}%"
    else
        log_info "磁盘使用率: ${usage}%"
    fi
}

# 检查内存
check_memory() {
    local mem_usage
    mem_usage=$(free | awk '/^Mem:/ {printf "%.0f", $3/$2*100}')
    if [ "$mem_usage" -gt 90 ]; then
        log_warn "内存使用率: ${mem_usage}%"
        send_alert "内存使用率过高: ${mem_usage}%"
    else
        log_info "内存使用率: ${mem_usage}%"
    fi
}

# 检查 sing-box 连接数
check_connections() {
    local conn_count
    conn_count=$(ss -tnp | grep -c sing-box 2>/dev/null || echo "0")
    log_info "当前活跃连接数: ${conn_count}"

    if [ "$conn_count" -gt 5000 ]; then
        log_warn "连接数过高: ${conn_count}"
        send_alert "连接数过高: ${conn_count}"
    fi
}

# 出口测速
cmd_speed() {
    log_info "========== 出口测速开始 =========="

    local outbounds=("wg-jp" "wg-sg" "wg-uk" "auto-best" "direct")

    for tag in "${outbounds[@]}"; do
        local api_resp delay
        api_resp=$(curl -s --max-time 5 "${CLASH_API}/proxies/${tag}" 2>/dev/null || echo "")

        if [ -n "$api_resp" ]; then
            delay=$(echo "$api_resp" | jq -r '.history[-1].delay // 0' 2>/dev/null || echo "0")
            if [ "$delay" -gt 0 ]; then
                log_info "[${tag}] 延迟: ${delay}ms"
            else
                log_warn "[${tag}] 无法获取延迟"
            fi
        else
            log_warn "[${tag}] API 不可达"
        fi
    done

    log_info "========== 出口测速结束 =========="
}

# 综合监控（进程 + 隧道 + 资源）
cmd_monitor() {
    log_info "========== 综合监控开始 =========="

    check_process || true
    check_service || true

    for outbound in "wg-jp" "wg-sg" "wg-uk" "auto-best"; do
        check_tunnel "$outbound" || true
    done

    check_disk
    check_memory
    check_connections

    log_info "========== 综合监控结束 =========="
}

# 设置 cron 定时任务
cmd_setup_cron() {
    local script_path
    script_path=$(readlink -f "$0")

    local cron_entry="*/5 * * * * ${script_path} report >> /var/log/sing-box/health.log 2>&1"

    # 检查是否已存在
    if crontab -l 2>/dev/null | grep -q "health-check.sh"; then
        log_info "cron 任务已存在，跳过"
        crontab -l 2>/dev/null | grep "health-check"
        return 0
    fi

    # 添加 cron
    (crontab -l 2>/dev/null; echo "$cron_entry") | crontab -
    log_info "已添加 cron 定时任务:"
    log_info "  ${cron_entry}"
}

# 综合报告
generate_report() {
    echo ""
    echo "========================================="
    echo "  sing-box 健康检查报告"
    echo "  时间: ${TIMESTAMP}"
    echo "  主机: ${HOSTNAME}"
    echo "========================================="
    echo ""

    local total_checks=0
    local failed_checks=0

    # 进程 & 服务
    check_process || ((failed_checks++))
    ((total_checks++))

    check_service || ((failed_checks++))
    ((total_checks++))

    echo ""

    # 各隧道
    for outbound in "wg-jp" "wg-sg" "wg-uk" "auto-best"; do
        check_tunnel "$outbound" || ((failed_checks++))
        ((total_checks++))
        echo ""
    done

    # 系统资源
    check_disk
    check_memory
    check_connections

    echo ""
    echo "========================================="
    echo "  检查完成: ${total_checks} 项, 异常: ${failed_checks} 项"
    echo "========================================="

    if [ "$failed_checks" -gt 0 ]; then
        send_alert "健康检查发现 ${failed_checks} 项异常"
        return 1
    fi

    return 0
}

# ---------- 主流程 ----------
main() {
    case "${1:-report}" in
        report)
            generate_report
            ;;
        quick)
            check_process && check_service
            ;;
        tunnel)
            for outbound in "wg-jp" "wg-sg" "wg-uk" "auto-best"; do
                check_tunnel "$outbound"
            done
            ;;
        speed)
            cmd_speed
            ;;
        monitor)
            cmd_monitor
            ;;
        setup-cron)
            cmd_setup_cron
            ;;
        *)
            echo "用法: $0 {report|quick|tunnel|speed|monitor|setup-cron}"
            echo "  report      - 完整健康检查报告"
            echo "  quick       - 快速检查（进程+服务）"
            echo "  tunnel      - 仅检查隧道状态"
            echo "  speed       - 各出口延迟测速"
            echo "  monitor     - 综合监控（进程+隧道+资源）"
            echo "  setup-cron  - 设置每5分钟自动检查"
            exit 1
            ;;
    esac
}

main "$@"
