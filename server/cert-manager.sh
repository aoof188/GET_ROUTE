#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  SSL 证书管理脚本 (acme.sh + Nginx + sing-box)
#
#  功能:
#    install-acme    安装 acme.sh
#    install-nginx   安装并初始化 Nginx
#    issue <domain>  签发证书
#    deploy <domain> 安装证书到 Nginx + sing-box
#    renew [domain]  续期证书（不指定则续期全部）
#    status          查看所有证书状态
#    setup-all       一键完整设置
#
#  使用:
#    ./cert-manager.sh setup-all
#    ./cert-manager.sh issue proxy.example.com
#    ./cert-manager.sh status
# ============================================================

ACME_HOME="${HOME}/.acme.sh"
ACME_BIN="${ACME_HOME}/acme.sh"
WEBROOT="/var/www/acme"
SSL_DIR="/etc/nginx/ssl"
SINGBOX_CERT_DIR="/etc/sing-box/cert"
ACME_EMAIL="${ACME_EMAIL:-acme@example.com}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
header(){ echo -e "\n${CYAN}======== $* ========${NC}\n"; }

# ============================================================
#  安装 acme.sh
# ============================================================
cmd_install_acme() {
    header "安装 acme.sh"

    if [ -f "${ACME_BIN}" ]; then
        info "acme.sh 已安装: $(${ACME_BIN} --version 2>&1 | head -1)"
        ${ACME_BIN} --upgrade
        info "已更新到最新版本"
        return 0
    fi

    info "下载并安装 acme.sh..."
    curl -fsSL https://get.acme.sh | sh -s email="${ACME_EMAIL}"

    # 设置默认 CA 为 Let's Encrypt
    ${ACME_BIN} --set-default-ca --server letsencrypt

    info "acme.sh 安装完成"
    info "自动续期已通过 cron 配置（acme.sh 自带）"
}

# ============================================================
#  安装 Nginx
# ============================================================
cmd_install_nginx() {
    header "安装 Nginx"

    if command -v nginx &>/dev/null; then
        info "Nginx 已安装: $(nginx -v 2>&1)"
    else
        if command -v apt-get &>/dev/null; then
            apt-get update -qq
            apt-get install -y -qq nginx
        elif command -v yum &>/dev/null; then
            yum install -y -q nginx
        else
            error "无法自动安装 Nginx，请手动安装"
        fi
        info "Nginx 安装完成"
    fi

    # 创建必要目录
    mkdir -p "${WEBROOT}" "${SSL_DIR}" "${SINGBOX_CERT_DIR}"
    mkdir -p /var/www/html

    # 创建伪装首页
    if [ ! -f /var/www/html/index.html ]; then
        cat > /var/www/html/index.html <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Welcome</title>
<style>body{font-family:-apple-system,sans-serif;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#f5f5f5;color:#333}
.c{text-align:center}.c h1{font-size:2em;margin-bottom:.5em}.c p{color:#666}</style>
</head>
<body><div class="c"><h1>Welcome</h1><p>The server is running normally.</p></div></body>
</html>
HTMLEOF
        info "伪装首页已创建"
    fi

    # 移除默认站点
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    rm -f /etc/nginx/conf.d/default.conf 2>/dev/null || true

    # 确保 Nginx 运行
    systemctl enable nginx
    systemctl start nginx 2>/dev/null || true

    info "Nginx 配置完成"
}

# ============================================================
#  签发证书
# ============================================================
cmd_issue() {
    local DOMAIN="${1:-}"
    [ -z "$DOMAIN" ] && error "用法: $0 issue <domain>"

    header "签发证书: ${DOMAIN}"

    [ ! -f "${ACME_BIN}" ] && error "acme.sh 未安装，请先运行: $0 install-acme"

    # 确保 webroot 存在
    mkdir -p "${WEBROOT}"

    # 确保 Nginx 有 ACME 验证的最小配置
    _ensure_acme_nginx_config "${DOMAIN}"

    # Nginx reload 使配置生效
    nginx -t && systemctl reload nginx

    # 签发
    info "正在签发证书（webroot 模式）..."
    ${ACME_BIN} --issue \
        -d "${DOMAIN}" \
        --webroot "${WEBROOT}" \
        --keylength ec-256 \
        --force \
        || {
            warn "webroot 模式失败，尝试 standalone 模式..."
            systemctl stop nginx
            ${ACME_BIN} --issue \
                -d "${DOMAIN}" \
                --standalone \
                --keylength ec-256 \
                --force
            systemctl start nginx
        }

    info "证书签发成功: ${DOMAIN}"

    # 自动部署
    cmd_deploy "${DOMAIN}"
}

# ============================================================
#  部署证书到 Nginx + sing-box
# ============================================================
cmd_deploy() {
    local DOMAIN="${1:-}"
    [ -z "$DOMAIN" ] && error "用法: $0 deploy <domain>"

    header "部署证书: ${DOMAIN}"

    local CERT_DIR="${SSL_DIR}/${DOMAIN}"
    mkdir -p "${CERT_DIR}"

    # 安装证书到 Nginx SSL 目录
    ${ACME_BIN} --install-cert -d "${DOMAIN}" --ecc \
        --fullchain-file "${CERT_DIR}/fullchain.pem" \
        --key-file "${CERT_DIR}/privkey.pem" \
        --reloadcmd "_reload_services"

    chmod 644 "${CERT_DIR}/fullchain.pem"
    chmod 600 "${CERT_DIR}/privkey.pem"

    # 同步到 sing-box 证书目录（Hysteria2 用）
    cp -f "${CERT_DIR}/fullchain.pem" "${SINGBOX_CERT_DIR}/fullchain.pem"
    cp -f "${CERT_DIR}/privkey.pem" "${SINGBOX_CERT_DIR}/privkey.pem"
    chmod 644 "${SINGBOX_CERT_DIR}/fullchain.pem"
    chmod 600 "${SINGBOX_CERT_DIR}/privkey.pem"

    info "证书已部署:"
    info "  Nginx:    ${CERT_DIR}/"
    info "  sing-box: ${SINGBOX_CERT_DIR}/"
}

# 证书续期后 reload 服务
_reload_services() {
    nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
    systemctl reload sing-box 2>/dev/null || true
}
export -f _reload_services 2>/dev/null || true

# ============================================================
#  续期证书
# ============================================================
cmd_renew() {
    local DOMAIN="${1:-}"

    header "续期证书"

    [ ! -f "${ACME_BIN}" ] && error "acme.sh 未安装"

    if [ -n "$DOMAIN" ]; then
        info "强制续期: ${DOMAIN}"
        ${ACME_BIN} --renew -d "${DOMAIN}" --ecc --force
        cmd_deploy "${DOMAIN}"
    else
        info "续期所有证书..."
        ${ACME_BIN} --renew-all --ecc
        # 重新部署所有
        for dir in "${SSL_DIR}"/*/; do
            local d
            d=$(basename "$dir")
            [ -d "${ACME_HOME}/${d}_ecc" ] && cmd_deploy "$d"
        done
    fi

    info "续期完成"
}

# ============================================================
#  查看证书状态
# ============================================================
cmd_status() {
    header "证书状态"

    local found=0

    for cert_dir in "${SSL_DIR}"/*/; do
        [ ! -d "$cert_dir" ] && continue
        local domain
        domain=$(basename "$cert_dir")
        local cert_file="${cert_dir}/fullchain.pem"

        if [ ! -f "$cert_file" ]; then
            warn "[${domain}] 证书文件不存在"
            continue
        fi

        found=1

        # 读取证书信息
        local subject issuer not_after serial
        subject=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null | sed 's/subject=//')
        issuer=$(openssl x509 -in "$cert_file" -noout -issuer 2>/dev/null | sed 's/issuer=//' | sed 's/.*O = //' | sed 's/,.*//')
        not_after=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | sed 's/notAfter=//')
        serial=$(openssl x509 -in "$cert_file" -noout -serial 2>/dev/null | sed 's/serial=//')

        # 计算剩余天数
        local expiry_epoch now_epoch days_left
        expiry_epoch=$(date -d "$not_after" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$not_after" +%s 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

        # 状态判断
        local status_color status_text
        if [ "$days_left" -le 0 ]; then
            status_color="${RED}"
            status_text="已过期"
        elif [ "$days_left" -le 7 ]; then
            status_color="${RED}"
            status_text="即将过期"
        elif [ "$days_left" -le 30 ]; then
            status_color="${YELLOW}"
            status_text="注意"
        else
            status_color="${GREEN}"
            status_text="正常"
        fi

        echo -e "  域名:   ${CYAN}${domain}${NC}"
        echo -e "  状态:   ${status_color}${status_text}${NC} (剩余 ${days_left} 天)"
        echo -e "  到期:   ${not_after}"
        echo -e "  签发:   ${issuer}"
        echo -e "  路径:   ${cert_dir}"
        echo ""
    done

    if [ "$found" -eq 0 ]; then
        warn "未找到任何已安装的证书"
        info "运行 '$0 issue <domain>' 签发证书"
    fi

    # acme.sh 管理的证书
    if [ -f "${ACME_BIN}" ]; then
        echo -e "${CYAN}---- acme.sh 托管证书 ----${NC}"
        ${ACME_BIN} --list 2>/dev/null || true
    fi
}

# ============================================================
#  部署 Nginx 站点配置
# ============================================================
cmd_deploy_nginx() {
    local PROXY_DOMAIN="${1:-}"
    local PANEL_DOMAIN="${2:-}"

    header "部署 Nginx 站点配置"

    local SCRIPT_DIR
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

    # 代理域名配置
    if [ -n "$PROXY_DOMAIN" ]; then
        if [ -f "${SCRIPT_DIR}/nginx/proxy.conf" ]; then
            sed "s/<PROXY_DOMAIN>/${PROXY_DOMAIN}/g" \
                "${SCRIPT_DIR}/nginx/proxy.conf" > "/etc/nginx/conf.d/${PROXY_DOMAIN}.conf"
            info "代理站点配置已部署: /etc/nginx/conf.d/${PROXY_DOMAIN}.conf"
        else
            warn "找不到 nginx/proxy.conf 模板"
        fi
    fi

    # 面板域名配置
    if [ -n "$PANEL_DOMAIN" ]; then
        if [ -f "${SCRIPT_DIR}/nginx/panel.conf" ]; then
            sed "s/<PANEL_DOMAIN>/${PANEL_DOMAIN}/g" \
                "${SCRIPT_DIR}/nginx/panel.conf" > "/etc/nginx/conf.d/${PANEL_DOMAIN}.conf"
            info "面板站点配置已部署: /etc/nginx/conf.d/${PANEL_DOMAIN}.conf"
        else
            warn "找不到 nginx/panel.conf 模板"
        fi
    fi

    # 验证并 reload
    if nginx -t 2>&1; then
        systemctl reload nginx
        info "Nginx 配置验证通过并已 reload"
    else
        error "Nginx 配置验证失败，请检查配置文件"
    fi
}

# ============================================================
#  确保有 ACME 验证用的最小 Nginx 配置
# ============================================================
_ensure_acme_nginx_config() {
    local DOMAIN="$1"
    local CONF="/etc/nginx/conf.d/${DOMAIN}.conf"

    # 如果已有完整配置，不覆盖
    [ -f "$CONF" ] && return 0

    # 写一个最小的 HTTP-only 配置用于 ACME 验证
    cat > "$CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root ${WEBROOT};
        try_files \$uri =404;
    }

    location / {
        return 444;
    }
}
EOF
    info "临时 ACME 验证配置已创建: ${CONF}"
}

# ============================================================
#  一键完整设置
# ============================================================
cmd_setup_all() {
    header "一键证书 + Nginx 设置"

    echo ""
    read -p "请输入代理域名 (如 proxy.example.com): " -r PROXY_DOMAIN
    read -p "请输入面板域名 (如 panel.example.com，留空则跳过): " -r PANEL_DOMAIN
    read -p "请输入 acme.sh 通知邮箱 [${ACME_EMAIL}]: " -r INPUT_EMAIL
    [ -n "$INPUT_EMAIL" ] && ACME_EMAIL="$INPUT_EMAIL"

    echo ""
    info "代理域名:  ${PROXY_DOMAIN}"
    info "面板域名:  ${PANEL_DOMAIN:-（不配置）}"
    info "通知邮箱:  ${ACME_EMAIL}"
    echo ""
    read -p "确认继续? [Y/n] " -r
    [[ $REPLY =~ ^[Nn]$ ]] && exit 0

    # 1. 安装基础
    cmd_install_acme
    cmd_install_nginx

    # 2. 部署 Nginx 配置（先用临时配置签发证书）
    # 签发代理域名证书
    if [ -n "$PROXY_DOMAIN" ]; then
        cmd_issue "$PROXY_DOMAIN"
    fi

    # 签发面板域名证书
    if [ -n "$PANEL_DOMAIN" ]; then
        cmd_issue "$PANEL_DOMAIN"
    fi

    # 3. 部署完整 Nginx 站点配置
    cmd_deploy_nginx "$PROXY_DOMAIN" "$PANEL_DOMAIN"

    # 4. 最终 reload
    nginx -t && systemctl reload nginx

    echo ""
    info "========================================="
    info "  证书 + Nginx 设置完成!"
    info "========================================="
    echo ""
    info "证书路径:"
    [ -n "$PROXY_DOMAIN" ] && info "  代理: ${SSL_DIR}/${PROXY_DOMAIN}/"
    [ -n "$PANEL_DOMAIN" ] && info "  面板: ${SSL_DIR}/${PANEL_DOMAIN}/"
    info "  sing-box: ${SINGBOX_CERT_DIR}/"
    echo ""
    info "自动续期: acme.sh cron 已自动配置"
    info "手动续期: $0 renew"
    info "查看状态: $0 status"
    echo ""

    if [ -n "$PANEL_DOMAIN" ]; then
        info "请在面板 .env 中更新:"
        info "  PANEL_DOMAIN=${PANEL_DOMAIN}"
        info "  SUB_BASE_URL=https://${PANEL_DOMAIN}"
    fi
    if [ -n "$PROXY_DOMAIN" ]; then
        info "请在面板 .env 中更新:"
        info "  PROXY_DOMAIN=${PROXY_DOMAIN}"
    fi
}

# ============================================================
#  JSON 状态输出（供面板 API 调用）
# ============================================================
cmd_status_json() {
    echo "["
    local first=1
    for cert_dir in "${SSL_DIR}"/*/; do
        [ ! -d "$cert_dir" ] && continue
        local domain
        domain=$(basename "$cert_dir")
        local cert_file="${cert_dir}/fullchain.pem"
        [ ! -f "$cert_file" ] && continue

        local not_after issuer
        not_after=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | sed 's/notAfter=//')
        issuer=$(openssl x509 -in "$cert_file" -noout -issuer 2>/dev/null | sed 's/issuer=//' | sed 's/.*O = //' | sed 's/,.*//')

        local expiry_epoch now_epoch days_left
        expiry_epoch=$(date -d "$not_after" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$not_after" +%s 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

        [ $first -eq 0 ] && echo ","
        first=0

        cat <<EOF
  {
    "domain": "${domain}",
    "expiry": "${not_after}",
    "days_left": ${days_left},
    "issuer": "${issuer}",
    "cert_path": "${cert_dir}",
    "valid": $([ "$days_left" -gt 0 ] && echo "true" || echo "false")
  }
EOF
    done
    echo "]"
}

# ============================================================
#  通知功能
# ============================================================

# 环境变量（可自定义）
NOTIFICATION_EMAIL="${NOTIFICATION_EMAIL:-}"
NOTIFICATION_WEBHOOK="${NOTIFICATION_WEBHOOK:-}"

_send_notification() {
    local title="$1"
    local body="$2"
    local level="${3:-info}"  # info, warning, error

    # Webhook 通知
    if [ -n "$NOTIFICATION_WEBHOOK" ]; then
        local payload
        payload=$(cat <<EOF
{
    "title": "$title",
    "body": "$body",
    "level": "$level",
    "timestamp": "$(date -Iseconds)"
}
EOF
)
        curl -s -X POST "$NOTIFICATION_WEBHOOK" \
            -H "Content-Type: application/json" \
            -d "$payload" >/dev/null 2>&1 || true
    fi

    # 邮件通知
    if [ -n "$NOTIFICATION_EMAIL" ]; then
        echo -e "$body" | mail -s "[$level] $title" "$NOTIFICATION_EMAIL" 2>/dev/null || true
    fi

    # 日志输出
    case "$level" in
        error)   error "$body" ;;
        warning)  warn "$body" ;;
        *)       info "$body" ;;
    esac
}

_send_renewal_failure_notification() {
    local domain="$1"
    local reason="$2"

    local title="证书续期失败"
    local body="域名: $domain\n原因: $reason\n时间: $(date -Iseconds)\n\n请手动检查证书状态并重新签发。"

    _send_notification "$title" "$body" "error"
}

# ============================================================
#  增强版 reload 服务
# ============================================================
_reload_services_enhanced() {
    info "正在重载服务..."

    # 验证 Nginx 配置
    if nginx -t 2>&1; then
        systemctl reload nginx
        info "Nginx 重载成功"
    else
        warn "Nginx 配置验证失败，跳过重载"
        return 1
    fi

    # 检查 sing-box 服务状态
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        systemctl reload sing-box
        info "sing-box 重载成功"
    else
        warn "sing-box 服务未运行，跳过重载"
    fi

    return 0
}

# ============================================================
#  证书监控命令
# ============================================================
cmd_monitor() {
    header "证书状态监控"

    local issue_count=0
    local warn_count=0
    local error_count=0
    local output=""

    for cert_dir in "${SSL_DIR}"/*/; do
        [ ! -d "$cert_dir" ] && continue
        local domain
        domain=$(basename "$cert_dir")
        local cert_file="${cert_dir}/fullchain.pem"

        [ ! -f "$cert_file" ] && continue

        # 读取证书信息
        local not_after days_left
        not_after=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | sed 's/notAfter=//')
        local expiry_epoch now_epoch
        expiry_epoch=$(date -d "$not_after" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$not_after" +%s 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

        # 分类处理
        if [ "$days_left" -le 0 ]; then
            output="${output}\n[${RED}ERROR${NC}] $domain: 已过期!"
            ((error_count++))
            _send_notification "证书已过期" "域名: $domain\n到期: $not_after" "error"
        elif [ "$days_left" -le 7 ]; then
            output="${output}\n[${RED}ERROR${NC}] $domain: 剩余 ${days_left} 天 (紧急!)"
            ((error_count++))
            _send_notification "证书即将过期（紧急）" "域名: $domain\n剩余: $days_left 天" "error"
        elif [ "$days_left" -le 14 ]; then
            output="${output}\n[${YELLOW}WARN${NC}] $domain: 剩余 ${days_left} 天"
            ((warn_count++))
            _send_notification "证书即将过期" "域名: $domain\n剩余: $days_left 天\n请及时续期" "warning"
        else
            output="${output}\n[${GREEN}OK${NC}] $domain: 剩余 ${days_left} 天"
            ((issue_count++))
        fi
    done

    echo -e "$output"
    echo ""
    echo "统计: $issue_count 正常, $warn_count 警告, $error_count 错误"

    if [ "$error_count" -gt 0 ]; then
        return 2
    elif [ "$warn_count" -gt 0 ]; then
        return 1
    fi
    return 0
}

# ============================================================
#  设置监控 Cron
# ============================================================
cmd_setup_monitor_cron() {
    header "设置证书监控自动任务"

    local cron_file="/etc/cron.d/ssl-cert-monitor"
    local script_path
    script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

    # 创建 cron 文件
    cat > "$cron_file" <<EOF
# SSL 证书监控 (每日 02:00)
0 2 * * * root $script_path monitor >> /var/log/ssl-cert-monitor.log 2>&1

# SSL 证书续期 (每日 03:00)
0 3 * * * root $script_path renew >> /var/log/ssl-cert-renewal.log 2>&1
EOF

    chmod 644 "$cron_file"
    info "Cron 任务已创建: $cron_file"
    info "  - 每日 02:00: 执行证书监控"
    info "  - 每日 03:00: 执行证书续期"

    # 创建日志文件
    touch /var/log/ssl-cert-monitor.log /var/log/ssl-cert-renewal.log

    # 重启 cron 服务
    systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null || true

    info "监控设置完成"
}

# ============================================================
#  增强版续期（含失败通知）
# ============================================================
cmd_renew_enhanced() {
    local DOMAIN="${1:-}"

    header "续期证书"

    [ ! -f "${ACME_BIN}" ] && error "acme.sh 未安装"

    local renew_failed=0
    local renew_success=0

    if [ -n "$DOMAIN" ]; then
        info "强制续期: ${DOMAIN}"
        if ${ACME_BIN} --renew -d "${DOMAIN}" --ecc --force >/dev/null 2>&1; then
            cmd_deploy "${DOMAIN}"
            ((renew_success++))
        else
            warn "续期失败: ${DOMAIN}"
            _send_renewal_failure_notification "$DOMAIN" "acme.sh 续期命令失败"
            ((renew_failed++))
        fi
    else
        info "续期所有证书..."
        for cert_dir in "${SSL_DIR}"/*/; do
            [ ! -d "$cert_dir" ] && continue
            local d
            d=$(basename "$cert_dir")

            if ${ACME_BIN} --renew -d "$d" --ecc --force >/dev/null 2>&1; then
                cmd_deploy "$d"
                ((renew_success++))
            else
                warn "续期失败: $d"
                _send_renewal_failure_notification "$d" "acme.sh 续期命令失败"
                ((renew_failed++))
            fi
        done
    fi

    echo ""
    info "续期完成: $renew_success 成功, $renew_failed 失败"

    if [ "$renew_failed" -gt 0 ]; then
        return 1
    fi
}

# ============================================================
#  主入口
# ============================================================
main() {
    [ "$(id -u)" -ne 0 ] && error "请使用 root 权限运行"

    case "${1:-help}" in
        install-acme)         cmd_install_acme ;;
        install-nginx)        cmd_install_nginx ;;
        issue)                cmd_issue "${2:-}" ;;
        deploy)               cmd_deploy "${2:-}" ;;
        renew)                cmd_renew_enhanced "${2:-}" ;;
        status)               cmd_status ;;
        status-json)          cmd_status_json ;;
        deploy-nginx)         cmd_deploy_nginx "${2:-}" "${3:-}" ;;
        setup-all)            cmd_setup_all ;;
        monitor)              cmd_monitor ;;
        setup-monitor-cron)   cmd_setup_monitor_cron ;;
        *)
            echo "SSL 证书管理工具"
            echo ""
            echo "用法: $0 <command> [options]"
            echo ""
            echo "命令:"
            echo "  install-acme                     安装/更新 acme.sh"
            echo "  install-nginx                    安装并初始化 Nginx"
            echo "  issue <domain>                   签发证书"
            echo "  deploy <domain>                  部署证书到 Nginx + sing-box"
            echo "  renew [domain]                   续期证书（不指定则全部）"
            echo "  status                           查看证书状态"
            echo "  status-json                      JSON 格式状态（面板用）"
            echo "  deploy-nginx <proxy> [panel]     部署 Nginx 站点配置"
            echo "  setup-all                        一键完整设置"
            echo "  monitor                          证书状态监控（带告警）"
            echo "  setup-monitor-cron               设置自动监控 Cron"
            echo ""
            echo "环境变量:"
            echo "  NOTIFICATION_EMAIL               通知邮箱"
            echo "  NOTIFICATION_WEBHOOK             Webhook URL"
            ;;
    esac
}

main "$@"
