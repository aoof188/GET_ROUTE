#!/usr/bin/env bash
# ============================================================
#  Surfshark WireGuard 配置管理
#  用途: 查看/修改/验证 sing-box 中的 Surfshark 出口配置
#  支持: 初始配置 / 更新密钥 / 切换节点 / 热重载
# ============================================================

set -uo pipefail

CONFIG="/etc/sing-box/config.json"
CRED_FILE="/etc/sing-box/credentials.env"
BACKUP_DIR="/etc/sing-box/backups"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ---------- 前置检查 ----------
preflight() {
    if ! command -v jq &>/dev/null; then
        error "需要 jq，请先安装: apt install jq / yum install jq"
        exit 1
    fi
    if [ ! -f "$CONFIG" ]; then
        error "配置文件不存在: $CONFIG"
        exit 1
    fi
}

# ---------- 备份 ----------
backup_config() {
    mkdir -p "$BACKUP_DIR"
    local ts
    ts=$(date '+%Y%m%d_%H%M%S')
    cp "$CONFIG" "${BACKUP_DIR}/config.json.${ts}"
    info "已备份到 ${BACKUP_DIR}/config.json.${ts}"
}

# ---------- 读取当前 WireGuard 配置 ----------
# 用 jq 从 config.json 中精确提取
get_wg_config() {
    local tag="$1"
    jq -r --arg tag "$tag" '
        .outbounds[] | select(.tag == $tag) |
        "  Endpoint:   \(.server):\(.server_port)\n  PrivateKey:  \(.private_key)\n  PublicKey:   \(.peer_public_key)\n  Address:     \(.local_address[0] // "N/A")\n  MTU:         \(.mtu // 1280)"
    ' "$CONFIG" 2>/dev/null
}

get_wg_field() {
    local tag="$1" field="$2"
    jq -r --arg tag "$tag" --arg field "$field" '
        .outbounds[] | select(.tag == $tag) | .[$field] // empty
    ' "$CONFIG" 2>/dev/null
}

# ---------- 修改 WireGuard 配置 ----------
# 用 jq 精确修改，不是 sed 替换
set_wg_field() {
    local tag="$1" field="$2" value="$3"
    local tmp
    tmp=$(mktemp)
    jq --arg tag "$tag" --arg field "$field" --arg value "$value" '
        (.outbounds[] | select(.tag == $tag))[$field] = $value
    ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
}

set_wg_server() {
    local tag="$1" server="$2" port="$3"
    local tmp
    tmp=$(mktemp)
    jq --arg tag "$tag" --arg server "$server" --argjson port "$port" '
        (.outbounds[] | select(.tag == $tag)).server = $server |
        (.outbounds[] | select(.tag == $tag)).server_port = $port
    ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
}

set_wg_address() {
    local tag="$1" addr="$2"
    local tmp
    tmp=$(mktemp)
    jq --arg tag "$tag" --arg addr "$addr" '
        (.outbounds[] | select(.tag == $tag)).local_address = [$addr]
    ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
}

# ---------- 显示所有出口状态 ----------
cmd_show() {
    echo ""
    echo -e "${BOLD}=== Surfshark WireGuard 出口配置 ===${NC}"
    echo ""

    local tags=("wg-jp" "wg-sg" "wg-uk")
    local names=("🇯🇵 日本 (JP)" "🇸🇬 新加坡 (SG)" "🇬🇧 英国 (UK)")

    for i in "${!tags[@]}"; do
        local tag="${tags[$i]}"
        local name="${names[$i]}"
        local config_out
        config_out=$(get_wg_config "$tag")

        if [ -z "$config_out" ]; then
            echo -e "${DIM}─── ${name} [${tag}] ─── 未配置${NC}"
        else
            local server
            server=$(get_wg_field "$tag" "server")
            # 检查是否还是占位符
            if [[ "$server" == *"SURFSHARK"* ]] || [[ "$server" == *"<"* ]]; then
                echo -e "${YELLOW}─── ${name} [${tag}] ─── 待配置${NC}"
            else
                echo -e "${GREEN}─── ${name} [${tag}] ─── 已配置${NC}"
            fi
            echo -e "$config_out"
        fi
        echo ""
    done

    # 显示 auto-best 选择
    local auto_out
    auto_out=$(jq -r '.outbounds[] | select(.tag == "auto-best") | "  策略: urltest\n  成员: \(.outbounds | join(", "))\n  间隔: \(.interval // "5m")\n  容差: \(.tolerance // 100)ms"' "$CONFIG" 2>/dev/null)
    if [ -n "$auto_out" ]; then
        echo -e "${BOLD}─── 自动选择 [auto-best] ───${NC}"
        echo -e "$auto_out"
        echo ""
    fi
}

# ---------- 交互式配置单个出口 ----------
cmd_set() {
    local tag="$1"
    local code="${tag#wg-}"
    local code_upper
    code_upper=$(echo "$code" | tr '[:lower:]' '[:upper:]')

    echo ""
    echo -e "${BOLD}=== 配置 ${tag} ===${NC}"
    echo ""

    # 显示当前值
    local current_server current_privkey current_pubkey current_addr
    current_server=$(get_wg_field "$tag" "server")
    current_privkey=$(get_wg_field "$tag" "private_key")
    current_pubkey=$(get_wg_field "$tag" "peer_public_key")
    current_addr=$(jq -r --arg tag "$tag" '.outbounds[] | select(.tag == $tag) | .local_address[0] // ""' "$CONFIG" 2>/dev/null)

    # 如果是占位符就显示为空
    [[ "$current_server" == *"<"* ]] && current_server=""
    [[ "$current_privkey" == *"<"* ]] && current_privkey=""
    [[ "$current_pubkey" == *"<"* ]] && current_pubkey=""
    [[ "$current_addr" == *"<"* ]] && current_addr=""

    echo -e "${DIM}(直接回车保持当前值不变)${NC}"
    echo ""

    # Endpoint
    if [ -n "$current_server" ]; then
        echo -e "  当前 Endpoint: ${CYAN}${current_server}${NC}"
    fi
    read -p "  Endpoint (如 jp-tok.prod.surfshark.com): " -r new_server
    new_server="${new_server:-$current_server}"

    # Port (默认 51820)
    local current_port
    current_port=$(jq -r --arg tag "$tag" '.outbounds[] | select(.tag == $tag) | .server_port // 51820' "$CONFIG" 2>/dev/null)
    read -p "  Port [${current_port}]: " -r new_port
    new_port="${new_port:-$current_port}"

    # PrivateKey
    if [ -n "$current_privkey" ]; then
        local masked="${current_privkey:0:8}...${current_privkey: -4}"
        echo -e "  当前 PrivateKey: ${CYAN}${masked}${NC}"
    fi
    read -p "  PrivateKey: " -r new_privkey
    new_privkey="${new_privkey:-$current_privkey}"

    # PublicKey
    if [ -n "$current_pubkey" ]; then
        local masked="${current_pubkey:0:8}...${current_pubkey: -4}"
        echo -e "  当前 PublicKey: ${CYAN}${masked}${NC}"
    fi
    read -p "  Surfshark PublicKey: " -r new_pubkey
    new_pubkey="${new_pubkey:-$current_pubkey}"

    # Address
    if [ -n "$current_addr" ]; then
        echo -e "  当前隧道 IP: ${CYAN}${current_addr}${NC}"
    fi
    read -p "  隧道 IP (如 10.14.0.2/32): " -r new_addr
    new_addr="${new_addr:-$current_addr}"
    # 确保有 /32 后缀
    [[ "$new_addr" != *"/"* ]] && new_addr="${new_addr}/32"

    # 确认
    echo ""
    echo -e "${BOLD}  即将写入:${NC}"
    echo -e "    Endpoint:   ${new_server}:${new_port}"
    echo -e "    PrivateKey:  ${new_privkey:0:8}...${new_privkey: -4}"
    echo -e "    PublicKey:   ${new_pubkey:0:8}...${new_pubkey: -4}"
    echo -e "    Address:     ${new_addr}"
    echo ""
    read -p "  确认写入? [Y/n] " -r
    [[ $REPLY =~ ^[Nn]$ ]] && { warn "已取消"; return 0; }

    # 备份
    backup_config

    # 写入
    set_wg_server "$tag" "$new_server" "$new_port"
    set_wg_field "$tag" "private_key" "$new_privkey"
    set_wg_field "$tag" "peer_public_key" "$new_pubkey"
    set_wg_address "$tag" "$new_addr"

    info "${tag} 配置已更新"

    # 更新凭据文件
    if [ -f "$CRED_FILE" ]; then
        # 移除旧的同国家配置
        sed -i "/^# Surfshark.*${code_upper}/,/^$/d" "$CRED_FILE" 2>/dev/null || true
        sed -i "/^SURFSHARK_${code_upper}_/d" "$CRED_FILE" 2>/dev/null || true
        # 追加新配置
        cat >> "$CRED_FILE" <<EOF

# Surfshark ${code_upper} - 更新于 $(date '+%Y-%m-%d %H:%M:%S')
SURFSHARK_${code_upper}_ENDPOINT=${new_server}
SURFSHARK_${code_upper}_PORT=${new_port}
SURFSHARK_${code_upper}_PRIVKEY=${new_privkey}
SURFSHARK_${code_upper}_PUBKEY=${new_pubkey}
SURFSHARK_${code_upper}_ADDR=${new_addr}
EOF
        info "凭据文件已同步更新"
    fi

    # 验证 + 重载
    cmd_verify_and_reload
}

# ---------- 配置所有出口 ----------
cmd_setup_all() {
    echo ""
    info "逐个配置所有 Surfshark 出口..."

    for tag in "wg-jp" "wg-sg" "wg-uk"; do
        cmd_set "$tag"
        echo ""
    done
}

# ---------- 验证配置并重载 ----------
cmd_verify_and_reload() {
    echo ""
    info "验证配置文件..."

    if sing-box check -c "$CONFIG" 2>&1; then
        info "配置验证通过"
        echo ""
        read -p "是否立即 reload sing-box? [Y/n] " -r
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            if systemctl is-active sing-box >/dev/null 2>&1; then
                systemctl reload sing-box 2>/dev/null || systemctl restart sing-box
                info "sing-box 已重载"
            else
                warn "sing-box 未运行，请手动启动: systemctl start sing-box"
            fi
        fi
    else
        error "配置验证失败！"
        warn "最近备份: ls ${BACKUP_DIR}/"
        warn "回滚命令: cp ${BACKUP_DIR}/config.json.<时间戳> ${CONFIG}"
    fi
}

# ---------- 回滚 ----------
cmd_rollback() {
    echo ""
    echo -e "${BOLD}=== 可用备份 ===${NC}"
    echo ""

    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
        warn "没有可用的备份"
        return 1
    fi

    # 列出备份
    local backups=()
    local i=1
    while IFS= read -r f; do
        backups+=("$f")
        local ts
        ts=$(echo "$f" | sed 's/config.json.//')
        local size
        size=$(du -h "${BACKUP_DIR}/${f}" | awk '{print $1}')
        echo "  ${i}) ${ts}  (${size})"
        ((i++))
    done < <(ls -1t "$BACKUP_DIR" 2>/dev/null)

    echo ""
    read -p "选择要回滚的备份编号 (或 q 取消): " -r choice
    [[ "$choice" == "q" || -z "$choice" ]] && return 0

    local idx=$((choice - 1))
    if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#backups[@]}" ]; then
        local selected="${backups[$idx]}"
        backup_config  # 回滚前也备份当前的
        cp "${BACKUP_DIR}/${selected}" "$CONFIG"
        info "已回滚到: ${selected}"
        cmd_verify_and_reload
    else
        error "无效的选择"
    fi
}

# ---------- 测试隧道连通性 ----------
cmd_test() {
    echo ""
    echo -e "${BOLD}=== 测试 WireGuard 隧道 ===${NC}"
    echo ""

    local CLASH_API="http://127.0.0.1:9090"

    # 检查 sing-box 是否运行
    if ! systemctl is-active sing-box >/dev/null 2>&1; then
        error "sing-box 未运行"
        return 1
    fi

    # 通过 Clash API 触发延迟测试
    for tag in "wg-jp" "wg-sg" "wg-uk"; do
        local server
        server=$(get_wg_field "$tag" "server")
        [[ "$server" == *"<"* ]] && { echo -e "  ${tag}: ${DIM}未配置${NC}"; continue; }

        echo -ne "  ${tag} (${server}): "

        # 触发延迟测试
        local delay_resp
        delay_resp=$(curl -s --max-time 10 -X PUT \
            "${CLASH_API}/proxies/${tag}/delay?url=https://www.gstatic.com/generate_204&timeout=5000" \
            2>/dev/null)

        local delay
        delay=$(echo "$delay_resp" | jq -r '.delay // 0' 2>/dev/null || echo "0")

        if [ "$delay" -gt 0 ]; then
            if [ "$delay" -lt 200 ]; then
                echo -e "${GREEN}${delay}ms${NC} ✓"
            elif [ "$delay" -lt 500 ]; then
                echo -e "${YELLOW}${delay}ms${NC}"
            else
                echo -e "${RED}${delay}ms${NC} (偏高)"
            fi
        else
            local err_msg
            err_msg=$(echo "$delay_resp" | jq -r '.message // "超时/不可达"' 2>/dev/null || echo "超时/不可达")
            echo -e "${RED}失败${NC} - ${err_msg}"
        fi
    done

    echo ""

    # auto-best 当前选择
    local auto_now
    auto_now=$(curl -s --max-time 3 "${CLASH_API}/proxies/auto-best" 2>/dev/null | jq -r '.now // "unknown"' 2>/dev/null)
    if [ "$auto_now" != "unknown" ] && [ -n "$auto_now" ]; then
        echo -e "  auto-best 当前选择: ${CYAN}${auto_now}${NC}"
    fi
    echo ""
}

# ---------- 添加新出口国家 ----------
cmd_add() {
    echo ""
    echo -e "${BOLD}=== 添加新的 Surfshark 出口 ===${NC}"
    echo ""

    read -p "  outbound tag (如 wg-us): " -r new_tag
    [ -z "$new_tag" ] && { error "tag 不能为空"; return 1; }

    # 检查是否已存在
    local exists
    exists=$(jq -r --arg tag "$new_tag" '.outbounds[] | select(.tag == $tag) | .tag' "$CONFIG" 2>/dev/null)
    if [ -n "$exists" ]; then
        error "${new_tag} 已存在，请使用 'set ${new_tag}' 修改"
        return 1
    fi

    read -p "  Endpoint 地址: " -r sf_server
    [ -z "$sf_server" ] && { error "Endpoint 不能为空"; return 1; }
    read -p "  Port [51820]: " -r sf_port
    sf_port="${sf_port:-51820}"
    read -p "  PrivateKey: " -r sf_privkey
    [ -z "$sf_privkey" ] && { error "PrivateKey 不能为空"; return 1; }
    read -p "  Surfshark PublicKey: " -r sf_pubkey
    [ -z "$sf_pubkey" ] && { error "PublicKey 不能为空"; return 1; }
    read -p "  隧道 IP (如 10.14.0.2/32): " -r sf_addr
    [ -z "$sf_addr" ] && { error "隧道 IP 不能为空"; return 1; }
    [[ "$sf_addr" != *"/"* ]] && sf_addr="${sf_addr}/32"

    backup_config

    # 用 jq 在 auto-best 之前插入新 outbound
    local tmp
    tmp=$(mktemp)
    jq --arg tag "$new_tag" \
       --arg server "$sf_server" \
       --argjson port "$sf_port" \
       --arg privkey "$sf_privkey" \
       --arg pubkey "$sf_pubkey" \
       --arg addr "$sf_addr" '
        # 找到 auto-best 的位置，在它前面插入
        (.outbounds | to_entries | map(
            if .value.tag == "auto-best" then
                {key: .key, value: {
                    "type": "wireguard",
                    "tag": $tag,
                    "server": $server,
                    "server_port": $port,
                    "local_address": [$addr],
                    "private_key": $privkey,
                    "peer_public_key": $pubkey,
                    "mtu": 1280
                }},
                .
            else . end
        ) | map(.value)) as $new_outbounds |
        .outbounds = $new_outbounds |
        # 加入 auto-best
        (.outbounds[] | select(.tag == "auto-best")).outbounds += [$tag]
    ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"

    info "${new_tag} 已添加"

    # 提示 DNS 配置
    echo ""
    warn "提示: 你可能还需要:"
    warn "  1. 在 dns.servers 中为新出口添加 DNS 服务器"
    warn "  2. 在 dns.rules 和 route.rules 中添加相应路由规则"
    warn "  3. 编辑 client/clash-meta.yaml 同步客户端配置"

    cmd_verify_and_reload
}

# ---------- 主流程 ----------
main() {
    preflight

    local cmd="${1:-}"
    local arg="${2:-}"

    case "$cmd" in
        show|s|"")
            cmd_show
            ;;
        set)
            if [ -z "$arg" ]; then
                echo "用法: $0 set <tag>"
                echo "可用: wg-jp, wg-sg, wg-uk"
                exit 1
            fi
            cmd_set "$arg"
            ;;
        setup-all|all)
            cmd_setup_all
            ;;
        test|t)
            cmd_test
            ;;
        add)
            cmd_add
            ;;
        rollback|rb)
            cmd_rollback
            ;;
        verify)
            cmd_verify_and_reload
            ;;
        help|h|-h|--help)
            echo ""
            echo -e "${BOLD}Surfshark WireGuard 配置管理${NC}"
            echo ""
            echo "用法: $0 <命令> [参数]"
            echo ""
            echo "命令:"
            echo "  show              查看所有出口配置 (默认)"
            echo "  set <tag>         修改指定出口 (如: set wg-jp)"
            echo "  setup-all         逐个配置所有出口 (JP/SG/UK)"
            echo "  test              测试所有隧道延迟"
            echo "  add               添加新的出口国家"
            echo "  rollback          回滚到历史备份"
            echo "  verify            验证配置并重载 sing-box"
            echo "  help              显示此帮助"
            echo ""
            echo "示例:"
            echo "  $0 show                # 查看当前配置"
            echo "  $0 set wg-jp           # 修改日本出口"
            echo "  $0 test                # 测试隧道延迟"
            echo "  $0 add                 # 添加新国家 (如 US)"
            echo "  $0 rollback            # 回滚配置"
            echo ""
            ;;
        *)
            error "未知命令: $cmd"
            echo "运行 '$0 help' 查看帮助"
            exit 1
            ;;
    esac
}

main "$@"
