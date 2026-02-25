# 架构约束与设计决策（所有 Agent 必读）

> **重要**: 本文件记录了经过讨论确认的核心设计决策。任何 Agent 在修改代码前必须阅读并遵守。
> 违反以下约束的改动将被拒绝。

---

## 项目定位

- **个人技术研究项目**，不是商业 SaaS 产品
- 用户量：个位数（个人 + 少量朋友）
- 设计原则：**够用、稳定、好维护** > 炫技、过度工程化

---

## 禁止修改的核心文件

以下文件的**路由规则、DNS 规则、出口策略**已经过讨论确认，未经 Project Lead 批准禁止修改：

| 文件 | 保护范围 |
|------|----------|
| `server/config.json` | `dns.rules`、`route.rules`、`route.final`、`outbounds` 结构 |
| `client/clash-meta.yaml` | `rules` 分流规则、`proxy-groups` 策略组结构 |

如需调整分流策略，必须先提出方案由 Project Lead 确认。

## ⛔ 绝对禁止的操作

以下行为在任何情况下都**不允许**：

1. **禁止删除已有文件** — 不允许通过 `rm`、`Bash(rm ...)`、`Delete` 等任何方式删除项目中已有的文件。如果认为某个文件不再需要，必须提出建议由 Project Lead 手动处理。
2. **禁止清空文件内容** — 不允许将文件内容替换为空或只包含注释的内容。
3. **禁止移动/重命名核心文件** — 不允许改变 `panel/app.py`、`server/config.json`、`client/clash-meta.yaml`、`panel/templates/index.html` 以及所有 `server/*.sh` 脚本的路径。
4. **禁止创建替代性文件来架空现有文件** — 例如创建 `app_v2.py` 然后让 `install.sh` 指向新文件。

违反以上规则的改动将被**立即拒绝并回滚**。

---

## 核心架构决策

### 1. 三层出口策略（已确认，不可更改）

```
流量类型           服务端出口              原因
─────────────────────────────────────────────────────
国内流量           DIRECT (直连)          无需代理
AI 服务            Surfshark auto-best    封锁中国/HK IP
  (ChatGPT/Claude/Gemini/Grok/Mistral...)
流媒体地区解锁     Surfshark SG/UK        Netflix→SG, BBC→UK
Google/YouTube     HK 直出 (direct)       HK IP 可正常访问，更快
GitHub/Twitter     HK 直出 (direct)       HK IP 可正常访问，更快
Telegram/Reddit    HK 直出 (direct)       HK IP 可正常访问，更快
其他外网（默认）    HK 直出 (direct)       减少一跳，延迟更低
```

**关键点**：`route.final` = `"direct"`（HK 直出），**不是** Surfshark。
只有 AI 服务和地区锁定流媒体才走 Surfshark，其他一律 HK 直出。

### 2. 前端方案（已确认）

- **采用单文件 `panel/templates/index.html`**
- 技术栈：Alpine.js + Tailwind CSS CDN + 内联 JS
- 后端 Jinja2 模板直出，**零构建、零 CORS 问题**
- 已实现：Glassmorphism UI、二维码订阅、Tab 切换、证书管理页面

**禁止**：
- ❌ 不要重写为 React / Vue / Svelte 等 SPA 框架
- ❌ 不要引入 node_modules / npm build 流程
- ❌ 不要创建前后端分离架构（会引入 CORS 问题）

如果确实需要前端框架，必须作为 v2.0 在独立分支开发，不影响当前可用版本。

### 3. 入口协议优先级

| 优先级 | 协议 | 端口 | 说明 |
|--------|------|------|------|
| 主力 | VLESS WS+TLS | 443 (Nginx 反代) | 走域名，伪装性最强 |
| 备用 | VLESS Reality | 40443 | 直连 IP，无需域名 |
| 备用 | Hysteria2 | 8443/udp | UDP 加速 |

### 4. 高可用方案

- **无 SLB**，依赖客户端 Clash Meta 的 `fallback` / `url-test` 策略
- ECS-A 和 ECS-B 配置完全一致
- 域名：`a.aoof188.cn` → ECS-A，`b.aoof188.cn` → ECS-B

### 5. 域名规划

| 域名 | 指向 | 用途 |
|------|------|------|
| `a.aoof188.cn` | ECS-A | VLESS WS+TLS + Hysteria2 |
| `b.aoof188.cn` | ECS-B | VLESS WS+TLS + Hysteria2 |
| `panel.aoof188.cn` | ECS-A | 管理面板 + 订阅分发 |

**注意**：订阅分发 (`/sub/<token>`) 集成在 panel 后端中，不需要独立的 `sub.aoof188.cn` 域名。

---

## 已实现的功能清单（不要重复造轮子）

### 后端 (panel/app.py)
- [x] 用户 CRUD + UUID/Hy2 密码自动生成
- [x] sing-box config.json 动态同步用户列表
- [x] 订阅链接生成（Clash Meta YAML + Base64）
- [x] 证书管理 API（签发/续期/状态查询）
- [x] 隧道健康检查（通过 Clash API）
- [x] 系统控制（reload/restart sing-box）
- [x] 操作日志记录
- [x] JWT 认证
- [x] 登录 Rate Limiting（5次/5分钟窗口）
- [x] HTTP 安全头（CSP/X-Frame/XSS/Referrer-Policy）
- [x] Prometheus 指标 API（/api/metrics）

### 前端 (panel/templates/index.html)
- [x] 登录页（Glassmorphism 风格）
- [x] 仪表盘（Bento Grid 布局 + 实时状态）
- [x] 用户管理（CRUD + 搜索）
- [x] 订阅弹窗（链接 Tab + 二维码 Tab + 下载 PNG）
- [x] 节点状态（延迟/在线状态/测速）
- [x] 证书管理（签发/续期/状态/执行日志）
- [x] 系统设置（域名/端口/订阅配置）
- [x] 操作日志
- [x] 统一 Icon（盾牌+网络拓扑 SVG favicon）

### 服务端脚本
- [x] install.sh — 一键部署（含 Surfshark 交互式配置）
- [x] surfshark-config.sh — Surfshark WireGuard 独立管理（show/set/add/test/rollback）
- [x] watchdog.sh — 看门狗（30 秒快检 + 2 分钟全检 + 自动重启）
- [x] cert-manager.sh — SSL 证书管理（增强：监控告警/提前14天告警）
- [x] health-check.sh — 健康巡检（增强：Prometheus 指标/出口测速）
- [x] ecs-sync.sh — ECS 单向同步（ECS-A → ECS-B，不同步数据库）
- [x] Nginx 配置模板（proxy.conf + panel.conf）

### systemd 服务加固
- [x] sing-box: Restart=always, OOMScoreAdjust=-500, MemoryMax=1G, ProtectSystem=strict
- [x] panel: Restart=always, OOMScoreAdjust=-200, MemoryMax=512M
- [x] watchdog timer: 30 秒快检 + 2 分钟完整巡检

---

## 允许改进的方向

以下是可以安全改进的领域：

### Security Engineer 可以做的
- ✅ CORS 收紧（环境变量配置，默认兼容 localhost:8080）
- ✅ 命令注入修复（watchdog.sh JSON 转义）
- ✅ Rate limiting（登录 5 次/5 分钟窗口）
- ✅ HTTP 安全头（CSP/X-Frame/XSS/Referrer-Policy）
- ✅ JWT Secret：只从 `.env` 读取
- ⚠️ 密码强度校验：只在**创建/修改密码时**校验，不要在启动时校验

### Backend Architect 可以做的
- ✅ cert-manager.sh 增强（续期监控、提前14天告警、失败通知）
- ✅ API 输入验证加强
- ✅ 数据库迁移方案
- ❌ 不要重构前端架构
- ❌ 不要修改分流规则

### SRE 可以做的
- ✅ 双 ECS 配置同步方案（rsync 单向推送）
- ✅ Telegram/钉钉告警集成
- ✅ 监控指标增强（Prometheus 格式）
- ✅ 备份策略
- ❌ 不要修改 systemd 服务中已有的重启策略参数
- ✅ ECS 同步规则：
  - ECS-A（主）→ ECS-B（从），**单向推送**
  - 不要同步数据库文件（`/var/lib/sing-box-panel/`）
  - ECS-B 只能拉取，不能推送

### Frontend Engineer 可以做的
- ✅ 在现有 index.html 中优化交互
- ⚠️ 添加 LogsPage 的筛选/搜索功能（前端 JS 实现）
- ✅ 移动端响应式优化
- ✅ 暗色/亮色主题切换
- ❌ 不要引入 npm/构建工具链
- ❌ 不要拆分为 SPA 独立工程

---

## 安全头分层策略

HTTP 安全头由 **app.py 中间件统一管理**，Nginx 层仅负责 HSTS 和基础头，**不要在 Nginx 和 app.py 中重复设置 CSP**：

| 安全头 | 管理层 | 说明 |
|--------|--------|------|
| Content-Security-Policy | **app.py** | 需要和前端 CDN 引用保持同步，统一维护 |
| X-Frame-Options | **app.py** | 应用级控制 |
| X-Content-Type-Options | **app.py** | 应用级控制 |
| X-XSS-Protection | **app.py** | 应用级控制 |
| Referrer-Policy | **app.py** | 应用级控制 |
| Strict-Transport-Security | **Nginx** | 只有 Nginx 层知道是否启用了 TLS |

## 技术约束速查

| 约束 | 原因 |
|------|------|
| 不用 SLB | 没有，靠客户端 fallback |
| 不用 React/Vue | 个人项目，单文件够用 |
| 默认出口 = HK 直出 | Google/YouTube 等不需要 Surfshark |
| Surfshark 仅用于 AI + 流媒体 | 减少一跳，降低延迟 |
| sing-box 内置 WireGuard | 不需要安装 wireguard-tools |
| 证书用 acme.sh + Let's Encrypt | 免费，自动续期 |
| 订阅集成在 panel 中 | 不需要独立域名 |
| config.json 用 jq 修改 | 不用 sed 替换，防止破坏 JSON |
| 安全头统一由 app.py 管理 | 避免 Nginx 和 app.py 重复设置导致双重 header |
| 禁止删除已有文件 | 防止 Agent 误删核心文件（已发生过） |
