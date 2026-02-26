#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  sing-box 管理面板 一键部署脚本
# ============================================================

PANEL_DIR="/opt/sing-box-panel"
DATA_DIR="/var/lib/sing-box-panel"
VENV_DIR="${PANEL_DIR}/venv"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[ "$(id -u)" -ne 0 ] && error "请使用 root 权限运行"

# ---------- 检测 Python ----------
detect_python() {
    for cmd in python3.12 python3.11 python3.10 python3; do
        if command -v "$cmd" &>/dev/null; then
            PYTHON_CMD="$cmd"
            PYTHON_VER=$($cmd -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
            if [[ $(echo "$PYTHON_VER >= 3.10" | bc -l 2>/dev/null || python3 -c "print(1 if $PYTHON_VER >= 3.10 else 0)") == "1" ]]; then
                info "Python: ${cmd} (${PYTHON_VER})"
                return 0
            fi
        fi
    done
    error "需要 Python 3.10+，请先安装: apt install python3.11 python3.11-venv"
}

# ---------- 安装系统依赖 ----------
install_deps() {
    info "安装系统依赖..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        apt-get install -y -qq python3-venv python3-pip
    elif command -v yum &>/dev/null; then
        yum install -y -q python3-pip
    fi
}

# ---------- 部署面板文件 ----------
deploy_files() {
    info "部署面板文件..."
    mkdir -p "${PANEL_DIR}/templates" "${DATA_DIR}"

    # 复制文件
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    cp "${SCRIPT_DIR}/app.py" "${PANEL_DIR}/app.py"
    cp "${SCRIPT_DIR}/requirements.txt" "${PANEL_DIR}/requirements.txt"
    cp -r "${SCRIPT_DIR}/templates/"* "${PANEL_DIR}/templates/"

    info "面板文件已部署到 ${PANEL_DIR}"
}

# ---------- 创建虚拟环境 ----------
setup_venv() {
    if [ -d "${VENV_DIR}" ]; then
        info "虚拟环境已存在，跳过创建"
    else
        info "创建 Python 虚拟环境..."
        ${PYTHON_CMD} -m venv "${VENV_DIR}"
    fi

    info "安装 Python 依赖..."
    "${VENV_DIR}/bin/pip" install -q --upgrade pip
    "${VENV_DIR}/bin/pip" install -q -r "${PANEL_DIR}/requirements.txt"
    info "依赖安装完成"
}

# ---------- 生成 .env 配置 ----------
generate_env() {
    ENV_FILE="${PANEL_DIR}/.env"

    if [ -f "$ENV_FILE" ]; then
        warn ".env 已存在，跳过生成"
        return 0
    fi

    # 生成随机密码和密钥
    ADMIN_PASS=$(head -c 12 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 16)
    JWT_SECRET=$(head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 64)

    # 尝试从 sing-box credentials.env 自动读取凭据
    local CRED_FILE="/etc/sing-box/credentials.env"
    local AUTO_REALITY_PUB="" AUTO_REALITY_SID="" AUTO_HY2_PASS=""
    if [ -f "$CRED_FILE" ]; then
        AUTO_REALITY_PUB=$(grep -oP 'REALITY_PUBLIC_KEY=\K.*' "$CRED_FILE" 2>/dev/null || true)
        AUTO_REALITY_SID=$(grep -oP 'SHORT_ID=\K.*' "$CRED_FILE" 2>/dev/null || true)
        AUTO_HY2_PASS=$(grep -oP 'HY2_PASSWORD=\K.*' "$CRED_FILE" 2>/dev/null || true)
        [ -n "$AUTO_REALITY_PUB" ] && info "从 credentials.env 读取到 Reality 公钥"
    fi

    # 交互式填写关键配置
    echo ""
    info "请填写节点信息（用于订阅生成，留空可稍后编辑 .env）"
    echo ""
    read -p "ECS-A 公网 IP: " -r INPUT_ECS_A_IP
    read -p "ECS-B 公网 IP（没有留空）: " -r INPUT_ECS_B_IP
    read -p "代理域名（如 proxy.example.com）: " -r INPUT_PROXY_DOMAIN
    read -p "面板域名（如 panel.example.com）: " -r INPUT_PANEL_DOMAIN

    if [ -z "$AUTO_REALITY_PUB" ]; then
        read -p "Reality 公钥: " -r AUTO_REALITY_PUB
    fi
    if [ -z "$AUTO_REALITY_SID" ]; then
        read -p "Reality Short ID: " -r AUTO_REALITY_SID
    fi

    local INPUT_HY2_SNI="${INPUT_PROXY_DOMAIN}"
    local INPUT_SUB_BASE_URL=""
    [ -n "$INPUT_PANEL_DOMAIN" ] && INPUT_SUB_BASE_URL="https://${INPUT_PANEL_DOMAIN}"

    cat > "$ENV_FILE" <<EOF
# sing-box Panel 配置 (auto-generated)
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')

# ---- 面板 ----
PANEL_HOST=0.0.0.0
PANEL_PORT=8080
ADMIN_USERNAME=admin
ADMIN_PASSWORD=${ADMIN_PASS}
JWT_SECRET=${JWT_SECRET}

# ---- sing-box ----
SINGBOX_CONFIG=/etc/sing-box/config.json
SINGBOX_API=http://127.0.0.1:9090
SINGBOX_API_SECRET=

# ---- 数据库 ----
DB_PATH=${DATA_DIR}/panel.db

# ---- 节点信息（用于订阅生成）----
ECS_A_IP=${INPUT_ECS_A_IP}
ECS_A_NAME=HK-A
ECS_B_IP=${INPUT_ECS_B_IP}
ECS_B_NAME=HK-B
VLESS_PORT=443
HY2_PORT=8443
REALITY_PUBLIC_KEY=${AUTO_REALITY_PUB}
REALITY_SHORT_ID=${AUTO_REALITY_SID}
REALITY_SNI=www.microsoft.com
REALITY_PORT=40443
HY2_SNI=${INPUT_HY2_SNI}
PROXY_DOMAIN=${INPUT_PROXY_DOMAIN}
PANEL_DOMAIN=${INPUT_PANEL_DOMAIN}

# ---- 订阅 ----
SUB_BASE_URL=${INPUT_SUB_BASE_URL}
EOF

    chmod 600 "$ENV_FILE"

    info "========================================="
    info "  管理面板初始凭据:"
    info "  用户名: admin"
    info "  密码:   ${ADMIN_PASS}"
    info "========================================="
    info "配置文件: ${ENV_FILE}"
    [ -z "$AUTO_REALITY_PUB" ] && warn "REALITY_PUBLIC_KEY 未填写，请稍后编辑 .env"
    [ -z "$INPUT_ECS_A_IP" ] && warn "ECS_A_IP 未填写，请稍后编辑 .env"
}

# ---------- systemd 服务 ----------
setup_systemd() {
    info "配置 systemd 服务..."
    cat > /etc/systemd/system/sing-box-panel.service <<EOF
[Unit]
Description=sing-box Management Panel
After=network.target sing-box.service
Wants=sing-box.service

[Service]
Type=simple
User=root
WorkingDirectory=${PANEL_DIR}
ExecStart=${VENV_DIR}/bin/python ${PANEL_DIR}/app.py
Environment=PATH=${VENV_DIR}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin

# ---- 自动重启策略 ----
Restart=always
RestartSec=3s
StartLimitIntervalSec=60
StartLimitBurst=5

# ---- OOM 保护 ----
OOMScoreAdjust=-200

# ---- 资源限制 ----
MemoryMax=512M
TasksMax=256

# ---- 安全加固 ----
NoNewPrivileges=yes
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    info "systemd 服务 sing-box-panel 已配置"
}

# ---------- 防火墙 ----------
setup_firewall() {
    local PORT
    PORT=$(grep "^PANEL_PORT=" "${PANEL_DIR}/.env" 2>/dev/null | cut -d= -f2 || echo "8080")

    if command -v ufw &>/dev/null; then
        ufw allow "${PORT}/tcp" comment "sing-box panel"
        info "ufw 已放行 ${PORT}/tcp"
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port="${PORT}/tcp"
        firewall-cmd --reload
        info "firewalld 已放行 ${PORT}/tcp"
    fi

    warn "请确认阿里云安全组已放行 ${PORT}/tcp"
    warn "建议: 仅对管理员 IP 开放此端口"
}

# ---------- 主流程 ----------
main() {
    echo ""
    echo "============================================"
    echo "  sing-box 管理面板 部署"
    echo "============================================"
    echo ""

    detect_python
    install_deps
    deploy_files
    setup_venv
    generate_env
    setup_systemd
    setup_firewall

    echo ""
    info "========================================="
    info "  部署完成！"
    info "========================================="
    echo ""
    info "1. 编辑面板配置:"
    info "   vim ${PANEL_DIR}/.env"
    echo ""
    info "2. 启动面板:"
    info "   systemctl enable --now sing-box-panel"
    echo ""
    info "3. 访问面板:"
    info "   http://<ECS_IP>:8080"
    echo ""
    info "4. 查看状态:"
    info "   systemctl status sing-box-panel"
    info "   journalctl -u sing-box-panel -f"
    echo ""
}

main "$@"
