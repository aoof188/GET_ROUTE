#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  ECS 配置同步脚本 (GitOps 方案)
#
#  功能:
#   - bidirectional sync between ECS-A and ECS-B
#   - 支持 sing-box 配置、证书、Nginx 配置同步
#   - 支持 Git 仓库自动 push/pull
#   - 支持 webhook 触发同步
#
#  使用:
#   ./ecs-sync.sh status          # 查看同步状态
#   ./ecs-sync.sh push            # 推送到另一台 ECS
#   ./ecs-sync.sh pull            # 从另一台 ECS 拉取
#   ./ecs-sync.sh sync            # 双向同步（自动合并）
#   ./ecs-sync.sh init-git        # 初始化 Git 仓库
#   ./ecs-sync.sh webhook         # 供 webhook 调用
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
header(){ echo -e "\n${CYAN}======== $* ========${NC}\n"; }

# 配置
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SSH_KEY="${SSH_KEY:-/root/.ssh/id_rsa}"
SSH_USER="${SSH_USER:-root}"
SSH_PORT="${SSH_PORT:-22}"

# 对方 ECS 信息（通过环境变量或本地配置获取）
REMOTE_HOST="${REMOTE_HOST:-}"  # ECS-B 的 IP（从 ECS-A 执行）
LOCAL_NAME="${LOCAL_NAME:-ECS-A}"
REMOTE_NAME="${REMOTE_NAME:-ECS-B}"

# 要同步的目录/文件（注意：不包含数据库，面板只在 ECS-A 运行）
SYNC_PATTERNS=(
    "/etc/sing-box/config.json"
    "/etc/nginx/conf.d/"
    "/etc/nginx/ssl/"
    "/opt/sing-box/"
    # "/var/lib/sing-box-panel/"  # 不同步，面板只在 ECS-A 运行
)

# Git 仓库配置（可选）
GIT_REPO="${GIT_REPO:-}"
GIT_BRANCH="${GIT_BRANCH:-main}"
GIT_COMMIT_USER="${GIT_COMMIT_USER:-ECS Sync}"
GIT_COMMIT_EMAIL="${GIT_COMMIT_EMAIL:-sync@aoof188.cn}"

# ============================================================
#  SSH 连接测试
# ============================================================
test_ssh_connection() {
    if [ -z "$REMOTE_HOST" ]; then
        # 尝试从配置文件读取
        if [ -f "${SCRIPT_DIR}/../.ecs-config" ]; then
            REMOTE_HOST=$(grep "REMOTE_IP=" "${SCRIPT_DIR}/../.ecs-config" 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "")
        fi
    fi

    if [ -z "$REMOTE_HOST" ]; then
        error "未设置 REMOTE_HOST 环境变量，请先配置"
    fi

    info "测试到 ${REMOTE_NAME} (${REMOTE_HOST}) 的 SSH 连接..."

    # 检查 SSH 密钥是否存在
    if [ ! -f "$SSH_KEY" ]; then
        warn "SSH 密钥不存在: $SSH_KEY"
        info "生成新密钥对..."
        ssh-keygen -t rsa -b 4096 -f "$SSH_KEY" -N "" -q
        info "公钥已生成: ${SSH_KEY}.pub"
        info "请将以下公钥添加到 ${REMOTE_NAME} 的 /root/.ssh/authorized_keys:"
        cat "${SSH_KEY}.pub"
        error "请手动配置 SSH 密钥后重试"
    fi

    # 测试连接
    if ssh -i "$SSH_KEY" -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
           -p "${SSH_PORT}" "${SSH_USER}@${REMOTE_HOST}" "echo 'SSH OK'" 2>/dev/null; then
        info "SSH 连接成功"
        return 0
    else
        error "SSH 连接失败，请检查网络或 SSH 密钥配置"
    fi
}

# ============================================================
#  Rsync 同步
# ============================================================
do_rsync() {
    local direction="$1"  # "push" or "pull"
    local source_host="$LOCAL_NAME"
    local target_host="$REMOTE_NAME"

    if [ "$direction" = "push" ]; then
        source_host="$LOCAL_NAME"
        target_host="$REMOTE_NAME"
        source_ip="127.0.0.1"
        target_ip="$REMOTE_HOST"
    else
        source_host="$REMOTE_NAME"
        target_host="$LOCAL_NAME"
        source_ip="$REMOTE_HOST"
        target_ip="127.0.0.1"
    fi

    header "同步: ${source_host} -> ${target_host}"

    test_ssh_connection

    local ssh_cmd="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -p $SSH_PORT"
    local rsync_args="-az --progress --delete --backup --backup-dir=/tmp/sync-backup"

    # 同步每个模式
    local success_count=0
    local fail_count=0

    for pattern in "${SYNC_PATTERNS[@]}"; do
        local source_path
        local target_path

        if [ "$direction" = "push" ]; then
            source_path="$pattern"
            target_path="${SSH_USER}@${target_ip}:${pattern}"
        else
            source_path="${SSH_USER}@${source_ip}:${pattern}"
            target_path="$pattern"
        fi

        # 确保目标目录存在（如果是 pull，先在本地创建）
        if [ "$direction" = "pull" ]; then
            local target_dir
            target_dir=$(dirname "$pattern")
            mkdir -p "$target_dir" 2>/dev/null || true
        fi

        info "同步: $pattern"

        if rsync $rsync_args -e "$ssh_cmd" "$source_path" "$target_path" 2>&1; then
            ((success_count++))
        else
            ((fail_count++))
            warn "同步失败: $pattern"
        fi
    done

    echo ""
    if [ "$fail_count" -eq 0 ]; then
        info "同步完成: $success_count 个项目成功"
        return 0
    else
        warn "同步完成: $success_count 成功, $fail_count 失败"
        return 1
    fi
}

# ============================================================
#  单向同步（主 -> 从）
# 注意: ECS-A 是主节点，ECS-B 是从节点
# 只有 ECS-A 需要执行同步推送到 ECS-B
# ============================================================
cmd_sync() {
    # 检查是否是主节点（ECS-A）
    if [ "$LOCAL_NAME" != "ECS-A" ]; then
        warn "同步方向错误: 只有 ECS-A（主）可以推送到 ECS-B"
        info "从节点 ECS-B 只能拉取配置，不能主动推送"
        info "请在 ECS-A 上执行此命令"
        return 1
    fi

    header "单向同步: ${LOCAL_NAME} -> ${REMOTE_NAME}"

    # 只执行 push
    if do_rsync "push"; then
        info "同步成功"
    else
        warn "同步部分失败，请检查日志"
        return 1
    fi

    # 重载服务（只在 ECS-A 执行）
    header "重载服务"
    systemctl reload sing-box 2>/dev/null || true
    nginx -t && systemctl reload nginx 2>/dev/null || true

    info "同步完成"
}

# ============================================================
#  Git 初始化
# ============================================================
cmd_init_git() {
    header "初始化 Git 仓库"

    local repo_dir="${1:-/opt/sing-box}"

    if [ ! -d "$repo_dir/.git" ]; then
        info "初始化 Git 仓库: $repo_dir"
        git init "$repo_dir"
        git -C "$repo_dir" config user.name "$GIT_COMMIT_USER"
        git -C "$repo_dir" config user.email "$GIT_COMMIT_EMAIL"

        # 添加同步文件
        git -C "$repo_dir" add "${SYNC_PATTERNS[@]}" 2>/dev/null || true

        # 创建初始提交
        if git -C "$repo_dir" commit -m "Initial sync configuration" 2>/dev/null; then
            info "初始提交创建成功"
        else
            info "暂无变更需要提交"
        fi
    else
        info "Git 仓库已存在: $repo_dir"
    fi

    # 配置 remote（如果提供了仓库地址）
    if [ -n "$GIT_REPO" ]; then
        git -C "$repo_dir" remote add origin "$GIT_REPO" 2>/dev/null || true
        info "已添加 remote: origin -> $GIT_REPO"
    fi
}

# ============================================================
#  Git Push（推送到远程仓库）
# ============================================================
cmd_git_push() {
    local repo_dir="${1:-/opt/sing-box}"

    header "Git Push: $repo_dir"

    if [ ! -d "$repo_dir/.git" ]; then
        error "目录不是 Git 仓库: $repo_dir"
    fi

    cd "$repo_dir"

    # 添加变更
    git add "${SYNC_PATTERNS[@]}" 2>/dev/null || true

    # 检查是否有变更
    if git status --porcelain | grep -q .; then
        local commit_msg="Sync $(date '+%Y-%m-%d %H:%M:%S')"

        git commit -m "$commit_msg"
        info "已提交: $commit_msg"
    else
        info "暂无变更"
    fi

    # Push
    if [ -n "$GIT_REPO" ]; then
        git push -u origin "$GIT_BRANCH"
        info "已推送到远程仓库"
    else
        warn "未配置 GIT_REPO，跳过远程推送"
        info "可配置环境变量: GIT_REPO=<仓库地址>"
    fi
}

# ============================================================
#  Git Pull（从远程仓库拉取）
# ============================================================
cmd_git_pull() {
    local repo_dir="${1:-/opt/sing-box}"

    header "Git Pull: $repo_dir"

    if [ ! -d "$repo_dir/.git" ]; then
        error "目录不是 Git 仓库: $repo_dir"
    fi

    cd "$repo_dir"

    if [ -n "$GIT_REPO" ]; then
        git pull origin "$GIT_BRANCH"
        info "已从远程仓库拉取"
    else
        warn "未配置 GIT_REPO"
    fi
}

# ============================================================
#  Webhook 触发同步（供 CI/CD 或外部调用）
# ============================================================
cmd_webhook() {
    header "Webhook 触发同步"

    local action="${1:-sync}"

    echo "Webhook 同步: $(date)" >> /var/log/ecs-sync.log

    case "$action" in
        push)
            do_rsync "push"
            ;;
        pull)
            do_rsync "pull"
            ;;
        sync|*)
            cmd_sync
            ;;
    esac

    echo "完成: $(date)" >> /var/log/ecs-sync.log
}

# ============================================================
#  查看同步状态
# ============================================================
cmd_status() {
    header "ECS 同步状态"

    echo -e "${CYAN}本机: ${NC}${LOCAL_NAME}"
    echo -e "${CYAN}远程: ${NC}${REMOTE_NAME:-（未配置）}"
    echo -e "${CYAN}SSH 密钥: ${NC}${SSH_KEY}"
    echo ""

    echo -e "${CYAN}同步模式:${NC}"
    for pattern in "${SYNC_PATTERNS[@]}"; do
        echo "  - $pattern"
    done

    echo ""
    echo -e "${CYAN}环境变量:${NC}"
    echo "  REMOTE_HOST=${REMOTE_HOST:-（未设置）}"
    echo "  GIT_REPO=${GIT_REPO:-（未设置）}"

    # 测试 SSH
    if [ -n "$REMOTE_HOST" ]; then
        echo ""
        echo -e "${CYAN}SSH 连接测试:${NC}"
        if ssh -i "$SSH_KEY" -o ConnectTimeout=3 -o StrictHostKeyChecking=no \
               -p "$SSH_PORT" "${SSH_USER}@${REMOTE_HOST}" "echo 'OK'" 2>/dev/null; then
            echo -e "  ${GREEN}已连接${NC}"
        else
            echo -e "  ${RED}连接失败${NC}"
        fi
    fi
}

# ============================================================
#  单向推送（主 -> 从）
# ============================================================
cmd_push() {
    # 检查是否是主节点
    if [ "$LOCAL_NAME" != "ECS-A" ]; then
        error "只有 ECS-A（主节点）可以执行推送，请确认 .ecs-config 配置正确"
    fi

    header "单向推送: ${LOCAL_NAME} -> ${REMOTE_NAME}"
    test_ssh_connection
    do_rsync "push"

    # 重载服务
    header "重载服务"
    systemctl reload sing-box 2>/dev/null && info "sing-box 已重载" || warn "sing-box 重载失败"
    nginx -t && systemctl reload nginx 2>/dev/null && info "Nginx 已重载" || warn "Nginx 重载失败"

    info "推送完成"
}

# ============================================================
#  单向拉取（从主节点拉取）
# ============================================================
cmd_pull() {
    # 检查是否是从节点（ECS-B）
    if [ "$LOCAL_NAME" != "ECS-B" ]; then
        error "只有 ECS-B（从节点）可以从 ECS-A 拉取，请确认 .ecs-config 配置正确"
    fi

    header "单向拉取: ${REMOTE_NAME} -> ${LOCAL_NAME}"
    test_ssh_connection
    do_rsync "pull"

    # 重载服务
    header "重载服务"
    systemctl reload sing-box 2>/dev/null && info "sing-box 已重载" || warn "sing-box 重载失败"
    nginx -t && systemctl reload nginx 2>/dev/null && info "Nginx 已重载" || warn "Nginx 重载失败"

    info "拉取完成"
}

# ============================================================
#  主入口
# ============================================================
main() {
    [ "$(id -u)" -ne 0 ] && error "请使用 root 权限运行"

    # 根据 .ecs-config 设置 LOCAL_NAME
    if [ -f "${SCRIPT_DIR}/../.ecs-config" ]; then
        source "${SCRIPT_DIR}/../.ecs-config" 2>/dev/null || true
    fi

    echo "ECS 配置同步工具 (单向: ECS-A -> ECS-B)"
    echo "本机: ${LOCAL_NAME}"

    case "${1:-status}" in
        status)          cmd_status ;;
        push)            cmd_push ;;
        pull)            cmd_pull ;;
        sync)            cmd_sync ;;
        init-git)        cmd_init_git "${2:-/opt/sing-box}" ;;
        git-push)        cmd_git_push "${2:-/opt/sing-box}" ;;
        git-pull)        cmd_git_pull "${2:-/opt/sing-box}" ;;
        webhook)         cmd_webhook "${2:-push}" ;;
        test-ssh)        test_ssh_connection ;;
        *)
            echo ""
            echo "用法: $0 <command> [options]"
            echo ""
            echo "命令 (注意: ECS-A 是主节点, ECS-B 是从节点):"
            echo "  status               查看同步状态"
            echo "  push                单向推送到远程 ECS (ECS-A 主节点专用)"
            echo "  pull                从远程 ECS 拉取 (ECS-B 从节点使用)"
            echo "  sync                单向同步 (ECS-A 专用, 推送后重载服务)"
            echo "  init-git [dir]      初始化 Git 仓库"
            echo "  git-push [dir]      Git Push"
            echo "  git-pull [dir]      Git Pull"
            echo "  webhook [action]     Webhook 触发推送"
            echo "  test-ssh            测试 SSH 连接"
            echo ""
            echo "说明:"
            echo "  - ECS-A (主): ./ecs-sync.sh push 推送到 ECS-B"
            echo "  - ECS-B (从): ./ecs-sync.sh pull 从 ECS-A 拉取"
            echo "  - 不同步数据库，面板只在 ECS-A 运行"
            echo ""
            echo "环境变量:"
            echo "  REMOTE_HOST         远程 ECS IP"
            echo "  SSH_KEY             SSH 密钥路径"
            echo "  SSH_USER            SSH 用户名"
            echo "  SSH_PORT            SSH 端口"
            echo "  GIT_REPO            Git 仓库地址"
            ;;
    esac
}

main "$@"
