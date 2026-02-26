#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  sing-box 一键部署脚本 (HK ECS)
#  适用于: Ubuntu 22.04 / Debian 12 / CentOS Stream 9
# ============================================================

SING_BOX_VERSION="1.10.7"
CONFIG_DIR="/etc/sing-box"
LOG_DIR="/var/log/sing-box"
DATA_DIR="/var/lib/sing-box"
CERT_DIR="${CONFIG_DIR}/cert"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ---------- 检测系统 ----------
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        error "无法检测操作系统"
    fi
}

# ---------- 安装依赖 ----------
install_deps() {
    info "安装基础依赖..."
    case $OS in
        ubuntu|debian)
            apt-get update -qq
            apt-get install -y -qq curl wget jq unzip
            ;;
        centos|rhel|almalinux|rocky)
            yum install -y -q curl wget jq unzip
            ;;
        *)
            error "不支持的系统: $OS"
            ;;
    esac
}

# ---------- 安装 sing-box ----------
install_singbox() {
    if command -v sing-box &>/dev/null; then
        local current_ver
        current_ver=$(sing-box version 2>/dev/null | head -1 | awk '{print $NF}')
        info "sing-box 已安装，版本: ${current_ver}"
        read -p "是否重新安装 v${SING_BOX_VERSION}? [y/N] " -r
        [[ ! $REPLY =~ ^[Yy]$ ]] && return 0
    fi

    info "安装 sing-box v${SING_BOX_VERSION}..."

    local ARCH
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *)       error "不支持的架构: $ARCH" ;;
    esac

    local URL="https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/sing-box-${SING_BOX_VERSION}-linux-${ARCH}.tar.gz"
    local TMP_DIR
    TMP_DIR=$(mktemp -d)

    wget -q --show-progress -O "${TMP_DIR}/sing-box.tar.gz" "$URL"
    tar -xzf "${TMP_DIR}/sing-box.tar.gz" -C "${TMP_DIR}"
    install -m 755 "${TMP_DIR}/sing-box-${SING_BOX_VERSION}-linux-${ARCH}/sing-box" /usr/local/bin/sing-box
    rm -rf "${TMP_DIR}"

    info "sing-box v${SING_BOX_VERSION} 安装完成"
}

# ---------- 创建目录 ----------
setup_dirs() {
    info "创建目录结构..."
    mkdir -p "${CONFIG_DIR}" "${LOG_DIR}" "${DATA_DIR}" "${CERT_DIR}"
}

# ---------- 生成凭据 ----------
generate_credentials() {
    info "========================================="
    info "  生成服务端凭据"
    info "========================================="

    echo ""

    # UUID
    local UUID
    UUID=$(sing-box generate uuid)
    info "UUID: ${UUID}"

    # Reality 密钥对
    local KEYPAIR
    KEYPAIR=$(sing-box generate reality-keypair)
    local PRIVATE_KEY PUBLIC_KEY
    PRIVATE_KEY=$(echo "$KEYPAIR" | grep "PrivateKey" | awk '{print $NF}')
    PUBLIC_KEY=$(echo "$KEYPAIR" | grep "PublicKey" | awk '{print $NF}')
    info "Reality PrivateKey (服务端用): ${PRIVATE_KEY}"
    info "Reality PublicKey  (客户端用): ${PUBLIC_KEY}"

    # Short ID
    local SHORT_ID
    SHORT_ID=$(sing-box generate rand --hex 8)
    info "Short ID: ${SHORT_ID}"

    # Hysteria2 密码
    local HY2_PASS
    HY2_PASS=$(sing-box generate rand --hex 16)
    info "Hysteria2 Password: ${HY2_PASS}"

    echo ""
    info "========================================="
    info "  请记录以上信息，用于填写配置文件和客户端"
    info "========================================="
    echo ""

    # 写入凭据文件（方便后续引用）
    cat > "${CONFIG_DIR}/credentials.env" <<EOF
# sing-box 凭据 - 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# !! 注意: 此文件包含敏感信息，请妥善保管 !!

UUID=${UUID}
REALITY_PRIVATE_KEY=${PRIVATE_KEY}
REALITY_PUBLIC_KEY=${PUBLIC_KEY}
SHORT_ID=${SHORT_ID}
HY2_PASSWORD=${HY2_PASS}
EOF
    chmod 600 "${CONFIG_DIR}/credentials.env"
    info "凭据已保存到 ${CONFIG_DIR}/credentials.env"
}

# ---------- 部署配置文件 ----------
deploy_config() {
    if [ -f "${CONFIG_DIR}/config.json" ]; then
        warn "配置文件已存在: ${CONFIG_DIR}/config.json"
        read -p "是否覆盖? [y/N] " -r
        [[ ! $REPLY =~ ^[Yy]$ ]] && return 0
    fi

    if [ -f "./config.json" ]; then
        cp ./config.json "${CONFIG_DIR}/config.json"
        info "配置文件已部署到 ${CONFIG_DIR}/config.json"
    else
        error "当前目录下找不到 config.json，请确认文件位置"
    fi
}

# ---------- 配置 Surfshark WireGuard ----------
setup_surfshark() {
    info "========================================="
    info "  配置 Surfshark WireGuard 出口"
    info "========================================="
    echo ""
    info "sing-box 内置 WireGuard 实现，无需安装 wireguard-tools"
    echo ""

    # 部署管理脚本
    local SF_SCRIPT="/opt/sing-box/surfshark-config.sh"
    mkdir -p /opt/sing-box
    if [ -f "./surfshark-config.sh" ]; then
        cp ./surfshark-config.sh "$SF_SCRIPT"
        chmod +x "$SF_SCRIPT"
        info "Surfshark 管理脚本已部署到 ${SF_SCRIPT}"
    else
        warn "当前目录下找不到 surfshark-config.sh"
    fi

    # 先用 jq 替换本机凭据（UUID / Reality / Hy2）
    local CONFIG="${CONFIG_DIR}/config.json"
    if [ -f "${CONFIG_DIR}/credentials.env" ] && [ -f "$CONFIG" ]; then
        source "${CONFIG_DIR}/credentials.env"

        if [ -n "${UUID:-}" ] && command -v jq &>/dev/null; then
            local tmp
            tmp=$(mktemp)

            # 替换所有 VLESS inbound 的 UUID
            jq --arg uuid "$UUID" '
                (.inbounds[] | select(.type == "vless") | .users[0].uuid) = $uuid
            ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"

            # 替换 Hysteria2 密码
            if [ -n "${HY2_PASSWORD:-}" ]; then
                tmp=$(mktemp)
                jq --arg pass "$HY2_PASSWORD" '
                    (.inbounds[] | select(.type == "hysteria2") | .users[0].password) = $pass
                ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
            fi

            # 替换 Reality 密钥
            if [ -n "${REALITY_PRIVATE_KEY:-}" ]; then
                tmp=$(mktemp)
                jq --arg key "$REALITY_PRIVATE_KEY" '
                    (.inbounds[] | select(.type == "vless") |
                     select(.tls.reality.enabled == true) |
                     .tls.reality.private_key) = $key
                ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
            fi

            if [ -n "${SHORT_ID:-}" ]; then
                tmp=$(mktemp)
                jq --arg sid "$SHORT_ID" '
                    (.inbounds[] | select(.type == "vless") |
                     select(.tls.reality.enabled == true) |
                     .tls.reality.short_id) = [$sid]
                ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
            fi

            info "本机凭据 (UUID/Reality/Hy2) 已写入配置"
        fi
    fi

    # 交互式配置 Surfshark
    read -p "是否现在配置 Surfshark WireGuard? [Y/n] " -r
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        if [ -f "$SF_SCRIPT" ]; then
            "$SF_SCRIPT" setup-all
        else
            warn "管理脚本不可用，请稍后手动配置"
            warn "配置命令: /opt/sing-box/surfshark-config.sh setup-all"
        fi
    else
        warn "跳过 Surfshark 配置"
        info "稍后配置: /opt/sing-box/surfshark-config.sh setup-all"
    fi
}

# ---------- 申请 TLS 证书 (Hysteria2 用) ----------
setup_cert() {
    echo ""
    read -p "是否为 Hysteria2 申请 TLS 证书? (需要域名指向本机) [y/N] " -r
    [[ ! $REPLY =~ ^[Yy]$ ]] && return 0

    read -p "请输入域名: " -r DOMAIN
    [ -z "$DOMAIN" ] && error "域名不能为空"

    # 安装 acme.sh
    if [ ! -f ~/.acme.sh/acme.sh ]; then
        info "安装 acme.sh..."
        curl -fsSL https://get.acme.sh | sh -s email=acme@example.com
    fi

    info "申请证书: ${DOMAIN}"
    ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256

    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
        --fullchain-file "${CERT_DIR}/fullchain.pem" \
        --key-file "${CERT_DIR}/privkey.pem" \
        --reloadcmd "systemctl reload sing-box 2>/dev/null || true"

    info "证书已安装到 ${CERT_DIR}/"
}

# ---------- 配置 systemd ----------
setup_systemd() {
    info "配置 systemd 服务..."
    cat > /etc/systemd/system/sing-box.service <<'EOF'
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
LimitNOFILE=1048576

# ---- 自动重启策略 ----
Restart=always
RestartSec=5s

# ---- OOM 保护 (不要被 OOM Killer 杀掉) ----
OOMScoreAdjust=-500

# ---- 资源限制 ----
MemoryMax=1G
TasksMax=65535

# ---- 安全加固 ----
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/etc/sing-box /var/log/sing-box /var/lib/sing-box
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    info "systemd 服务配置完成 (含自动重启/OOM 保护/安全加固)"
}

# ---------- 配置防火墙 ----------
setup_firewall() {
    info "配置防火墙..."

    if command -v ufw &>/dev/null; then
        ufw allow 80/tcp comment "ACME + HTTP redirect"
        ufw allow 443/tcp comment "Nginx HTTPS (VLESS WS + Panel)"
        ufw allow 40443/tcp comment "VLESS Reality"
        ufw allow 8443/udp comment "Hysteria2"
        ufw reload 2>/dev/null || true
        info "ufw 规则已添加"
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port=80/tcp
        firewall-cmd --permanent --add-port=443/tcp
        firewall-cmd --permanent --add-port=40443/tcp
        firewall-cmd --permanent --add-port=8443/udp
        firewall-cmd --reload
        info "firewalld 规则已添加"
    else
        warn "未检测到防火墙管理工具，请手动放行 80/443/40443/tcp 和 8443/udp"
    fi

    # 阿里云安全组提醒
    echo ""
    warn "========================================="
    warn "  请确认阿里云安全组已放行以下端口:"
    warn "  - 80/tcp    (ACME 验证 + HTTPS 重定向)"
    warn "  - 443/tcp   (Nginx: VLESS WS+TLS + 面板)"
    warn "  - 40443/tcp (VLESS Reality 备用入口)"
    warn "  - 8443/udp  (Hysteria2)"
    warn "  - 51820/udp (WireGuard 出站，通常默认放行)"
    warn "========================================="
}

# ---------- 内核优化 ----------
optimize_kernel() {
    info "应用内核参数优化..."
    cat > /etc/sysctl.d/99-sing-box.conf <<'EOF'
# ---- 网络性能优化 ----
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ---- 连接数优化 ----
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535

# ---- 内存优化 ----
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# ---- 连接复用 ----
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# ---- 转发（WireGuard 需要） ----
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
    sysctl -p /etc/sysctl.d/99-sing-box.conf >/dev/null 2>&1
    info "内核参数优化完成 (BBR + 连接优化)"
}

# ---------- 看门狗 (监控 + 自动重启) ----------
setup_watchdog() {
    info "配置看门狗服务..."

    # 复制 watchdog 脚本
    local WD_SCRIPT="/opt/sing-box/watchdog.sh"
    mkdir -p /opt/sing-box /var/lib/sing-box/watchdog
    if [ -f "./watchdog.sh" ]; then
        cp ./watchdog.sh "$WD_SCRIPT"
        chmod +x "$WD_SCRIPT"
    else
        warn "当前目录下找不到 watchdog.sh，跳过看门狗配置"
        return 0
    fi

    # systemd service（oneshot 类型，被 timer 触发）
    cat > /etc/systemd/system/sing-box-watchdog.service <<EOF
[Unit]
Description=sing-box Watchdog (monitor & auto-restart)

[Service]
Type=oneshot
ExecStart=${WD_SCRIPT} auto
# 不影响其他服务
Nice=19
IOSchedulingClass=idle
EOF

    # systemd timer（每 2 分钟执行一次）
    cat > /etc/systemd/system/sing-box-watchdog.timer <<'EOF'
[Unit]
Description=sing-box Watchdog Timer

[Timer]
# 启动后 1 分钟开始首次巡检
OnBootSec=1min
# 之后每 2 分钟巡检一次
OnUnitActiveSec=2min
# 随机延迟 0-15 秒，避免多台机器同时告警
RandomizedDelaySec=15
# 即使错过了触发时间也要补跑
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # 快速巡检 timer（每 30 秒，仅检查进程存活）
    cat > /etc/systemd/system/sing-box-watchdog-quick.service <<EOF
[Unit]
Description=sing-box Watchdog Quick Check

[Service]
Type=oneshot
ExecStart=${WD_SCRIPT} quick
Nice=19
IOSchedulingClass=idle
EOF

    cat > /etc/systemd/system/sing-box-watchdog-quick.timer <<'EOF'
[Unit]
Description=sing-box Watchdog Quick Timer

[Timer]
OnBootSec=30s
OnUnitActiveSec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now sing-box-watchdog.timer
    systemctl enable --now sing-box-watchdog-quick.timer
    info "看门狗已启用:"
    info "  - 完整巡检: 每 2 分钟 (服务+隧道+证书+资源)"
    info "  - 快速巡检: 每 30 秒 (仅进程存活)"
    info "  - 日志: /var/log/sing-box/watchdog.log"
    info "  - 查看状态: ${WD_SCRIPT} status"
}

# ---------- 日志轮转 ----------
setup_logrotate() {
    info "配置日志轮转..."
    cat > /etc/logrotate.d/sing-box <<'EOF'
/var/log/sing-box/sing-box.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    size 50M
    postrotate
        systemctl reload sing-box 2>/dev/null || true
    endscript
}

/var/log/sing-box/watchdog.log /var/log/sing-box/health.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    size 10M
}
EOF
    info "日志轮转配置完成 (sing-box 50M/7天, watchdog 10M/7天)"
}

# ---------- 验证配置 ----------
check_config() {
    info "验证配置文件..."
    if sing-box check -c "${CONFIG_DIR}/config.json" 2>&1; then
        info "配置文件验证通过"
    else
        error "配置文件验证失败，请检查 ${CONFIG_DIR}/config.json"
    fi
}

# ---------- 主流程 ----------
main() {
    echo ""
    echo "============================================"
    echo "  sing-box 跨境中转节点 一键部署"
    echo "  适用于 HK ECS-A / ECS-B"
    echo "============================================"
    echo ""

    [ "$(id -u)" -ne 0 ] && error "请使用 root 权限运行此脚本"

    detect_os
    install_deps
    install_singbox
    setup_dirs
    generate_credentials
    deploy_config
    setup_surfshark
    setup_cert
    setup_systemd
    setup_firewall
    optimize_kernel
    setup_logrotate
    setup_watchdog

    # --- 尝试自动验证配置 ---
    echo ""
    local remaining_ph
    remaining_ph=$(grep -cE '<[A-Z_]+>' "${CONFIG_DIR}/config.json" 2>/dev/null || echo "0")

    info "========================================="
    info "  部署完成！"
    info "========================================="
    echo ""

    if [ "$remaining_ph" -gt 0 ]; then
        warn "配置文件中仍有 ${remaining_ph} 个占位符未填写"
        warn "请编辑: vim ${CONFIG_DIR}/config.json"
        warn "搜索 '<' 即可找到所有待填项"
        echo ""
        info "后续步骤:"
        info "  1. 补充配置文件中的占位符"
        info "  2. 验证: sing-box check -c ${CONFIG_DIR}/config.json"
        info "  3. 启动: systemctl enable --now sing-box"
    else
        info "所有占位符已填写，正在验证配置..."
        if sing-box check -c "${CONFIG_DIR}/config.json" 2>&1; then
            info "配置验证通过！"
            echo ""
            info "启动服务:"
            info "  systemctl enable --now sing-box"
        else
            warn "配置验证失败，请检查后重试:"
            warn "  vim ${CONFIG_DIR}/config.json"
            warn "  sing-box check -c ${CONFIG_DIR}/config.json"
        fi
    fi

    echo ""
    info "常用命令:"
    info "  查看凭据:   cat ${CONFIG_DIR}/credentials.env"
    info "  服务状态:   systemctl status sing-box"
    info "  实时日志:   journalctl -u sing-box -f"
    info "  看门狗状态: /opt/sing-box/watchdog.sh status"
    info "  Timer 状态: systemctl list-timers sing-box-watchdog*"
    echo ""
}

main "$@"
