# 跨境网络中转方案 — 部署指南

## 架构概览

```
Client (中国内地)
    │
    │  ① VLESS WS+TLS (主力，走域名 + Nginx)
    │  ② VLESS Reality  (备用，直连 IP:40443)
    │  ③ Hysteria2      (备用，UDP:8443)
    │  (Clash Meta fallback: ECS-A ↔ ECS-B)
    ▼
Nginx (443/tcp) ──→ sing-box VLESS WS (127.0.0.1:10001)
    │
HK ECS-A / ECS-B  (sing-box)
    │
    ├─ CN 域名 → 直连
    ├─ 广告域名 → 拦截
    ├─ AI 服务 (ChatGPT/Claude/Gemini/Grok...) → Surfshark auto-best
    ├─ Netflix/Disney/HBO → WireGuard → Surfshark SG
    ├─ BBC → WireGuard → Surfshark UK
    ├─ Google/YouTube/GitHub/Twitter/Telegram → HK 直出 ← 更快!
    └─ 其他外网（默认）→ HK 直出

管理面板 (https://panel.example.com)
    │
    ├─ 用户管理 (CRUD + 同步到 sing-box)
    ├─ 订阅分发 (/sub/<token>)
    ├─ 证书管理 (acme.sh + Let's Encrypt)
    └─ 隧道监控
```

### 分流策略（三层出口）

| 流量类型 | 服务端出口 | DNS 解析 | 原因 |
|----------|-----------|---------|------|
| CN 域名/IP | 直连 | AliDNS (223.5.5.5) | 国内流量无需代理 |
| AI 服务 (ChatGPT/Claude/Gemini/Grok等) | **Surfshark auto-best** | Cloudflare via Surfshark | 封锁中国/HK IP |
| 流媒体 (Netflix/Disney+/HBO) | **Surfshark SG** | Cloudflare via SG | 地区内容解锁 |
| 流媒体 (BBC) | **Surfshark UK** | Cloudflare via UK | UK 地区解锁 |
| Google/YouTube/GitHub | **HK 直出** | Cloudflare via HK | HK IP 可正常访问，更快 |
| Twitter/Telegram/Facebook/Reddit | **HK 直出** | Cloudflare via HK | HK IP 可正常访问，更快 |
| 其他外网（默认） | **HK 直出** | Cloudflare via HK | 减少一跳，降低延迟 |

> **设计思路**：只有真正需要伪装 IP 的流量（AI 服务 + 地区锁定流媒体）才走 Surfshark；Google/YouTube 等对 HK IP 无限制的站点直接从 HK ECS 出去，少一跳 WireGuard 隧道，延迟更低、带宽更大。

#### AI 域名清单（持续更新）

服务端和客户端同步维护以下域名，命中后走 Surfshark 出口：

- **OpenAI**: `openai.com`, `chatgpt.com`, `ai.com`, `oaiusercontent.com`, `oaistatic.com`
- **Anthropic**: `anthropic.com`, `claude.ai`
- **Google AI**: `gemini.google.com`, `bard.google.com`, `aistudio.google.com`, `makersuite.google.com`, `ai.google.dev`, `deepmind.google`, `notebooklm.google.com`, `generativelanguage.googleapis.com`, `deepmind.com`
- **xAI**: `x.ai`, `grok.com`
- **Microsoft**: `copilot.microsoft.com`
- **Mistral**: `mistral.ai`
- **Perplexity**: `perplexity.ai`
- **Meta AI**: `meta.ai`
- **图像/视频**: `midjourney.com`, `pika.art`, `runway.com`, `runwayml.com`, `luma.ai`, `stability.ai`
- **聊天**: `character.ai`, `poe.com`
- **音频**: `suno.ai`, `suno.com`, `elevenlabs.io`
- **开发**: `cursor.sh`, `cursor.com`, `v0.dev`, `bolt.new`, `huggingface.co`, `replicate.com`
- **推理 API**: `together.ai`, `groq.com`, `fireworks.ai`, `anyscale.com`, `cohere.com`, `cohere.ai`
- **其他**: `dify.ai`, `flowith.io`

### 端口分配

| 端口 | 协议 | 服务 | 说明 |
|------|------|------|------|
| 80/tcp | HTTP | Nginx | ACME 验证 + HTTPS 重定向 |
| 443/tcp | HTTPS | Nginx | VLESS WS+TLS 反代 + 面板反代 |
| 40443/tcp | VLESS | sing-box | Reality 备用入口 |
| 8443/udp | Hysteria2 | sing-box | UDP 加速入口 |
| 10001/tcp | WS | sing-box | 本地监听，Nginx 反代目标 |
| 8080/tcp | HTTP | Panel | 本地监听，Nginx 反代目标 |
| 9090/tcp | HTTP | sing-box | Clash API（仅 localhost） |

## 前置准备

### 1. 获取 Surfshark WireGuard 配置

登录 Surfshark 后台 → Manual Setup → WireGuard：

- **为每个出口国家 × 每台 ECS 生成独立的 Key Pair**
  - 共需 6 组（3 国家 × 2 ECS），如果 Surfshark 账号支持
  - 如果 Key Pair 数量有限，两台 ECS 可共用同一组（同一时刻只有一台活跃时无冲突）
- 记录每组的：
  - `PrivateKey`
  - `PublicKey`（Surfshark 端的）
  - `Address`（分配给你的隧道 IP，如 `10.14.0.2`）
  - `Endpoint`（如 `jp-tok.prod.surfshark.com:51820`）

### 2. ECS 环境要求

| 项目 | 要求 |
|------|------|
| 系统 | Ubuntu 22.04 / Debian 12 / CentOS Stream 9 |
| 架构 | x86_64 或 arm64 |
| 内存 | ≥ 1GB |
| 内核 | ≥ 5.4（BBR + WireGuard 内核支持） |
| 网络 | 公网 IP，安全组放行 80/443/tcp、8443/udp、40443/tcp |

### 3. 域名规划

| 域名 | 指向 | 用途 |
|------|------|------|
| `proxy-a.example.com` | ECS-A IP | VLESS WS+TLS 入口 + Hysteria2 |
| `proxy-b.example.com` | ECS-B IP | VLESS WS+TLS 入口 + Hysteria2 |
| `panel.example.com` | ECS-A 或 ECS-B | 管理面板 + 订阅分发 |

> 也可以使用通配符证书 `*.example.com`，简化证书管理。

---

## 域名与证书配置

### 一键设置（推荐）

```bash
# 上传 cert-manager.sh 到 ECS
scp server/cert-manager.sh root@<ECS_IP>:/opt/sing-box/

# SSH 登录并执行
ssh root@<ECS_IP>
cd /opt/sing-box
chmod +x cert-manager.sh

# 一键完成: 安装 acme.sh + Nginx + 签发证书 + 部署站点配置
./cert-manager.sh setup-all
```

交互式引导会要求输入：
- 代理域名（如 `proxy-a.example.com`）
- 面板域名（如 `panel.example.com`，可选）
- acme.sh 通知邮箱

### 手动步骤

```bash
# 1. 安装 acme.sh 和 Nginx
./cert-manager.sh install-acme
./cert-manager.sh install-nginx

# 2. 签发证书（域名需已解析到本机）
./cert-manager.sh issue proxy-a.example.com
./cert-manager.sh issue panel.example.com

# 3. 部署 Nginx 站点配置
./cert-manager.sh deploy-nginx proxy-a.example.com panel.example.com

# 4. 查看证书状态
./cert-manager.sh status
```

### 证书自动续期

acme.sh 安装时会自动配置 cron job，在证书到期前 30 天自动续期。续期后自动 reload Nginx 和 sing-box。

也可以在管理面板的「证书管理」页面手动查看状态和触发续期。

### ECS-B 重复配置

```bash
# ECS-B 需要独立签发自己域名的证书
ssh root@<ECS_B_IP>
./cert-manager.sh issue proxy-b.example.com
./cert-manager.sh deploy-nginx proxy-b.example.com
```

### 域名变更

更换代理域名或面板域名时，按以下步骤操作（以「旧域名 → 新域名」为例）。

**1. DNS**  
将新域名解析到对应 ECS IP，等生效后再在服务器上操作。

**2. 在每台 ECS 上（按当前角色）**

- **代理域名变更**（如 `proxy-a.example.com` → `proxy-a.new.com`）：
  ```bash
  cd /opt/sing-box
  ./cert-manager.sh issue proxy-a.new.com
  ./cert-manager.sh deploy proxy-a.new.com
  ./cert-manager.sh deploy-nginx proxy-a.new.com
  # 删除旧站点配置，避免 Nginx 仍响应旧域名
  rm -f /etc/nginx/conf.d/proxy-a.example.com.conf
  nginx -t && systemctl reload nginx
  systemctl reload sing-box
  ```
- **仅面板域名变更**（如 `panel.example.com` → `panel.new.com`）：
  ```bash
  ./cert-manager.sh issue panel.new.com
  ./cert-manager.sh deploy panel.new.com
  ./cert-manager.sh deploy-nginx '<当前代理域名>' panel.new.com
  rm -f /etc/nginx/conf.d/panel.example.com.conf
  nginx -t && systemctl reload nginx
  ```
- **代理 + 面板都换**：先 `issue` + `deploy` 两个新域名，再执行一次：
  ```bash
  ./cert-manager.sh deploy-nginx 新代理域名 新面板域名
  rm -f /etc/nginx/conf.d/旧代理域名.conf /etc/nginx/conf.d/旧面板域名.conf
  nginx -t && systemctl reload nginx
  systemctl reload sing-box
  ```

**3. 面板 .env**  
若面板域名变更，修改 `/opt/sing-box-panel/.env`：

- `SUB_BASE_URL=https://新面板域名`
- 如有 `PANEL_DOMAIN` 或 `PROXY_DOMAIN` 也改为新值  

然后 `systemctl restart sing-box-panel`。

**4. 客户端**  
- 使用 **clash-meta.yaml** 直连：把其中的 `<YOUR_DOMAIN>` / 代理域名（VLESS WS 的地址、Hysteria2 的 `sni`）改成新代理域名，重新导入配置。  
- 使用 **面板订阅**：订阅链接会随 `SUB_BASE_URL` 变化，用户重新拉取或更新订阅即可。

**5. 旧证书（可选）**  
不再使用的域名可在 acme.sh 中移除：  
`~/.acme.sh/acme.sh --remove -d 旧域名 --ecc`。  
并删除 `/etc/nginx/ssl/旧域名/` 目录（如有）。

---

## 部署步骤

### Step 1: 部署 ECS-A

```bash
# 上传文件到服务器
scp -r server/ root@<ECS_A_IP>:/opt/sing-box/

# SSH 登录
ssh root@<ECS_A_IP>

# 执行安装
cd /opt/sing-box
chmod +x install.sh health-check.sh
./install.sh
```

安装脚本会自动：
- 安装 sing-box
- 生成 UUID、Reality 密钥对、Short ID、Hysteria2 密码
- 部署配置文件到 `/etc/sing-box/config.json`
- 配置 systemd 服务
- 优化内核参数（BBR）
- 配置防火墙和日志轮转

### Step 2: 填写配置占位符

```bash
# 查看生成的凭据
cat /etc/sing-box/credentials.env

# 编辑配置
vim /etc/sing-box/config.json
```

需要替换的占位符：

| 占位符 | 说明 | 来源 |
|--------|------|------|
| `<YOUR_UUID>` | 用户 UUID | `credentials.env` |
| `<REALITY_PRIVATE_KEY>` | Reality 私钥 | `credentials.env` |
| `<SHORT_ID>` | Reality Short ID | `credentials.env` |
| `<HY2_PASSWORD>` | Hysteria2 密码 | `credentials.env` |
| `<SURFSHARK_JP_ENDPOINT>` | Surfshark JP 服务器地址 | Surfshark 后台，如 `jp-tok.prod.surfshark.com` |
| `<SURFSHARK_JP_ADDRESS>` | JP 隧道分配 IP | Surfshark WireGuard 配置的 Address 字段 |
| `<SURFSHARK_WG_PRIVATE_KEY_JP>` | JP WireGuard 私钥 | Surfshark 生成的 PrivateKey |
| `<SURFSHARK_WG_PUBLIC_KEY_JP>` | JP 对端公钥 | Surfshark 配置中的 PublicKey |
| 同上 SG / UK 版本 | 新加坡 / 英国出口 | 同上 |

### Step 3: 验证并启动

```bash
# 验证配置语法
sing-box check -c /etc/sing-box/config.json

# 启动服务
systemctl enable --now sing-box

# 查看日志
journalctl -u sing-box -f

# 确认监听端口
ss -tlnp | grep sing-box
ss -ulnp | grep sing-box
```

### Step 4: 部署 ECS-B

**完全重复 Step 1-3**，使用相同的配置（UUID、密钥等保持一致），确保两台 ECS 对等。

> 注意：如果 Surfshark 要求每个 Key Pair 只能同时连一个端点，则 ECS-B 需要使用不同的 WireGuard Key Pair。

### Step 5: 配置客户端

编辑 `client/clash-meta.yaml`，替换以下占位符：

| 占位符 | 说明 |
|--------|------|
| `<ECS_A_IP>` | ECS-A 公网 IP |
| `<ECS_B_IP>` | ECS-B 公网 IP |
| `<YOUR_UUID>` | 与服务端相同的 UUID |
| `<REALITY_PUBLIC_KEY>` | Reality **公钥**（注意是 PublicKey） |
| `<SHORT_ID>` | 与服务端相同 |
| `<HY2_PASSWORD>` | Hysteria2 密码 |
| `<YOUR_DOMAIN>` | Hysteria2 证书域名 |

将配置导入 Clash Meta / Clash Verge / Stash / Shadowrocket。

---

## 配置同步（双 ECS）

两台 ECS 配置应保持一致。推荐使用 Git 管理：

```bash
# 在任一台 ECS 上初始化
cd /etc/sing-box
git init
git add config.json
git commit -m "initial config"
git remote add origin <YOUR_GIT_REPO>
git push -u origin main

# 另一台 ECS 拉取
cd /etc/sing-box
git clone <YOUR_GIT_REPO> .
systemctl restart sing-box
```

或使用 rsync 定时同步：

```bash
# crontab (ECS-A → ECS-B)
*/30 * * * * rsync -avz -e ssh /etc/sing-box/config.json root@<ECS_B_IP>:/etc/sing-box/config.json && ssh root@<ECS_B_IP> 'systemctl reload sing-box'
```

---

## 健康检查

```bash
# 部署健康检查脚本
cp health-check.sh /opt/sing-box/
chmod +x /opt/sing-box/health-check.sh

# 完整报告
/opt/sing-box/health-check.sh report

# 快速检查
/opt/sing-box/health-check.sh quick

# 仅检查隧道
/opt/sing-box/health-check.sh tunnel

# 加入 crontab (每 5 分钟)
crontab -e
# 添加:
# */5 * * * * /opt/sing-box/health-check.sh report >> /var/log/sing-box/health.log 2>&1
```

### 告警配置（可选）

编辑 `health-check.sh` 头部：

```bash
# 钉钉机器人
ALERT_WEBHOOK="https://oapi.dingtalk.com/robot/send?access_token=xxx"
ALERT_TYPE="dingtalk"

# 或 Telegram Bot
ALERT_WEBHOOK="https://api.telegram.org/bot<TOKEN>/sendMessage"
ALERT_TYPE="telegram"
TELEGRAM_CHAT_ID="<CHAT_ID>"
```

---

## 运维手册

### 服务自愈体系

系统包含三层自愈机制，确保服务异常时自动恢复：

```
┌─ 第 1 层: systemd 原生重启 ──────────────────────────────┐
│  Restart=always, 异常退出 5 秒后自动重启                    │
│  60 秒内最多 5 次，超限进入 failed 状态                      │
├─ 第 2 层: Watchdog 快速巡检 (每 30 秒) ─────────────────────┤
│  检查 sing-box / panel / nginx 进程存活                     │
│  systemd failed 后由 watchdog 接管二次拉起                  │
├─ 第 3 层: Watchdog 完整巡检 (每 2 分钟) ────────────────────┤
│  进程存活 + 端口可达 + WireGuard 隧道 + 证书过期 + 系统资源   │
│  所有隧道异常时自动 reload 触发 WireGuard 重连              │
│  连续重启达 5 次上限 → 停止自动重启 + 发送告警               │
└──────────────────────────────────────────────────────────┘
```

#### systemd 服务加固

| 参数 | sing-box | Panel |
|------|----------|-------|
| `Restart` | `always` | `always` |
| `RestartSec` | `5s` | `3s` |
| `StartLimitBurst` | `5 / 60s` | `5 / 60s` |
| `OOMScoreAdjust` | `-500` (高优先) | `-200` |
| `MemoryMax` | `1G` | `512M` |
| `ProtectSystem` | `strict` | — |

#### Watchdog 命令

```bash
# 查看监控状态
/opt/sing-box/watchdog.sh status

# 手动执行完整巡检
/opt/sing-box/watchdog.sh auto

# 仅检查隧道
/opt/sing-box/watchdog.sh tunnel

# 仅检查证书
/opt/sing-box/watchdog.sh cert

# 重置重启计数器（人工修复后执行）
/opt/sing-box/watchdog.sh reset

# 查看 watchdog 日志
tail -50 /var/log/sing-box/watchdog.log

# 查看 timer 调度状态
systemctl list-timers sing-box-watchdog*
```

#### 配置告警推送（可选）

编辑 watchdog.sh 头部或设置环境变量：

```bash
# 钉钉机器人
export WATCHDOG_ALERT_WEBHOOK="https://oapi.dingtalk.com/robot/send?access_token=xxx"
export WATCHDOG_ALERT_TYPE="dingtalk"

# Telegram Bot
export WATCHDOG_ALERT_WEBHOOK="https://api.telegram.org/bot<TOKEN>/sendMessage"
export WATCHDOG_ALERT_TYPE="telegram"
export WATCHDOG_TELEGRAM_CHAT_ID="<CHAT_ID>"
```

### 常用命令

```bash
# 服务管理
systemctl start sing-box
systemctl stop sing-box
systemctl restart sing-box
systemctl reload sing-box          # 热重载配置
systemctl status sing-box

# 面板管理
systemctl status sing-box-panel
systemctl restart sing-box-panel

# 日志查看
journalctl -u sing-box -f          # 实时日志
journalctl -u sing-box --since "1 hour ago"
journalctl -u sing-box-panel -f    # 面板日志

# 配置验证
sing-box check -c /etc/sing-box/config.json

# 查看连接数
ss -tnp | grep sing-box | wc -l

# 查看 WireGuard 流量
sing-box tools wg show
```

### Surfshark WireGuard 管理

使用独立的管理脚本操作 Surfshark 配置，支持查看/修改/添加/回滚/测试：

```bash
# 查看所有出口配置
/opt/sing-box/surfshark-config.sh show

# 修改指定出口（交互式，显示当前值，回车保持不变）
/opt/sing-box/surfshark-config.sh set wg-jp

# 配置所有出口（JP/SG/UK 逐个配置）
/opt/sing-box/surfshark-config.sh setup-all

# 测试隧道延迟（通过 Clash API）
/opt/sing-box/surfshark-config.sh test

# 添加新国家（如 US）
/opt/sing-box/surfshark-config.sh add

# 回滚到历史备份
/opt/sing-box/surfshark-config.sh rollback
```

特性：
- 用 `jq` 精确修改 JSON 字段，不是 `sed` 文本替换
- 每次修改前自动备份到 `/etc/sing-box/backups/`
- 修改完自动验证配置 + 询问是否热重载
- 交互式编辑时显示当前值，回车保持不变
- 凭据同步写入 `credentials.env`

### 切换出口国家

修改 `config.json` 中 `route.rules` 的 `outbound` 字段即可。例如把 YouTube 从 HK 直出改为走 SG：

```json
{
  "rule_set": ["geosite-youtube"],
  "outbound": "wg-sg"
}
```

然后 `systemctl reload sing-box`。

### 添加地区限制站点走 Surfshark

发现某个新网站有地区限制（例如仅限美区、或封锁香港 IP）时，让该站点的流量走 Surfshark 即可。需在 **服务端** `config.json` 里改两处（且顺序要在「HK 直出」规则之前）：

**1. 路由规则 `route.rules`**  
在「AI 服务」规则块之后、「流媒体」规则块之前，增加一条（出口任选其一）：

- **`auto-best`**：在 JP/SG/UK 中自动选延迟最低的出口，适合「任意 VPN 国家即可」的站点。
- **`wg-sg` / `wg-uk` / `wg-jp`**：固定走新加坡/英国/日本，适合「必须某国 IP」的站点。

示例（走 auto-best）：

```json
{
  "_comment": "=== 地区限制站点 → Surfshark ===",
  "domain_suffix": ["限制站点的主域名.com", "可选子域.api.限制站点.com"],
  "outbound": "auto-best"
}
```

**2. DNS 规则 `dns.rules`**  
让该域名的解析也走 Surfshark，避免 DNS 泄漏或解析到错误地区。在「AI 服务」的 `domain_suffix` 块之后增加一条，`server` 与出口对应：

- 出口用 `auto-best` → `"server": "dns-auto"`
- 出口用 `wg-sg` → `"server": "dns-sg"`
- 出口用 `wg-uk` → `"server": "dns-uk"`
- 出口用 `wg-jp` → `"server": "dns-jp"`

示例（与上面 auto-best 对应）：

```json
{
  "_comment": "地区限制站点 DNS — 走 Surfshark 解析",
  "domain_suffix": ["限制站点的主域名.com", "可选子域.api.限制站点.com"],
  "server": "dns-auto"
}
```

保存后执行：

```bash
sing-box check -c /etc/sing-box/config.json
systemctl reload sing-box
```

双 ECS 时请同步更新另一台的 `config.json` 并 reload。若使用面板同步配置，请在仓库里的 `server/config.json` 模板中一并加上上述规则，再按项目文档做配置同步。

### 添加新的 Surfshark 出口

推荐使用管理脚本一键添加：

```bash
/opt/sing-box/surfshark-config.sh add
# 按提示输入 tag (如 wg-us)、Endpoint、Key 等
# 脚本会自动写入 config.json 并加入 auto-best 选择池
```

添加后还需手动补充：
1. 在 `dns.servers` 中添加对应的 DNS 服务器
2. 在 `dns.rules` 和 `route.rules` 中添加路由规则
3. 同步客户端 `clash-meta.yaml`

### 排障检查清单

| 问题 | 排查方式 |
|------|----------|
| 客户端连不上 | 检查安全组、`ss -tlnp`、`journalctl -u sing-box` |
| 出口 IP 不对 | `curl --interface wg0 https://httpbin.org/ip`、检查 DNS 规则 |
| 速度慢 | 检查 BBR 是否生效：`sysctl net.ipv4.tcp_congestion_control` |
| WireGuard 不通 | 检查 Surfshark Key 是否过期、Endpoint 是否可达 |
| DNS 泄漏 | 访问 dnsleaktest.com 检查 DNS 出口 |
| 规则不生效 | 检查 `rule_set` 是否下载成功：`ls /var/lib/sing-box/` |

---

## 安全注意事项

1. **credentials.env** 包含敏感密钥，已设为 600 权限，切勿泄漏
2. **config.json** 包含 WireGuard 私钥，注意权限控制
3. 如使用 Git 同步配置，确保仓库为 **private**
4. 定期检查 Surfshark WireGuard Key 有效期，及时轮转
5. 定期更新 sing-box 版本以获取安全补丁

---

## Web 管理面板

### 功能概览

| 功能 | 说明 |
|------|------|
| 用户管理 | 增删改查、启用/禁用、流量限制、到期时间 |
| 配置同步 | 用户变更自动同步到 sing-box config.json 并 reload |
| 订阅链接 | 每个用户独立订阅 URL，支持 Clash Meta / Base64 格式 |
| 仪表盘 | 实时连接数、流量统计、隧道状态 |
| 节点测速 | 一键检测各出口隧道延迟 |
| 系统控制 | Reload / 重启 sing-box |
| 操作日志 | 所有管理操作可追溯 |

### 部署管理面板

```bash
# 上传面板文件到 ECS
scp -r panel/ root@<ECS_IP>:/opt/sing-box-panel-src/

# SSH 登录并安装
ssh root@<ECS_IP>
cd /opt/sing-box-panel-src
chmod +x install.sh
./install.sh
```

安装脚本会：
1. 检测 Python 3.10+ 环境
2. 创建虚拟环境并安装依赖
3. 生成 `.env` 配置文件（含随机 admin 密码）
4. 配置 systemd 服务
5. 放行防火墙端口

### 配置面板

```bash
# 编辑配置，填写节点信息
vim /opt/sing-box-panel/.env
```

关键配置项：

| 变量 | 说明 | 示例 |
|------|------|------|
| `ADMIN_PASSWORD` | 管理员密码 | 安装时自动生成 |
| `ECS_A_IP` / `ECS_B_IP` | 两台 ECS 公网 IP | `1.2.3.4` |
| `REALITY_PUBLIC_KEY` | Reality 公钥 | 从 `credentials.env` 获取 |
| `REALITY_SHORT_ID` | Reality Short ID | 从 `credentials.env` 获取 |
| `HY2_SNI` | Hysteria2 域名（留空不生成 Hy2 节点）| `hy2.example.com` |
| `SUB_BASE_URL` | 面板外部访问地址 | `http://1.2.3.4:8080` |
| `SINGBOX_API` | sing-box Clash API 地址 | `http://127.0.0.1:9090` |

### 启动面板

```bash
systemctl enable --now sing-box-panel
# 访问: http://<ECS_IP>:8080
```

### 用户管理流程

```
管理员在面板创建用户
    │
    ├── 自动生成 UUID + Hy2 密码 + 订阅 Token
    ├── 写入 SQLite 数据库
    ├── 同步更新 sing-box config.json 的 inbounds.users
    ├── 自动 sing-box check + reload
    │
    └── 将订阅链接发给用户
            │
            用户在 Clash Meta 中添加订阅 URL
            │
            └── 自动下载包含其 UUID 的完整配置
```

### 订阅链接格式

每个用户拥有独立的订阅 Token，支持两种格式：

- **Clash Meta**: `http://<PANEL>/sub/<TOKEN>?type=clash`
- **Base64 通用**: `http://<PANEL>/sub/<TOKEN>?type=base64`

订阅响应包含 `subscription-userinfo` header，客户端可自动显示流量用量和到期时间。

### 安全建议

- 面板端口（默认 8080）仅对管理员 IP 开放
- 建议使用 Nginx 反代 + HTTPS 保护面板
- `.env` 文件权限已设为 600
- 订阅链接中使用独立 Token，不暴露 UUID
- **HTTP 安全头**：CSP / X-Frame / X-Content-Type 等由 **面板 app.py 中间件**统一设置；Nginx 层仅设置 HSTS。修改安全策略时只需改 app.py，避免在 Nginx 重复配置。

---

## 开发与 Agent 约束

本项目使用 **CONTEXT.md** 和 **AGENTS.md** 约定架构与行为边界，供人工协作或 AI Agent（如 Claude Code、Agent Teams）执行任务时遵守：

| 文档 | 用途 |
|------|------|
| [CONTEXT.md](CONTEXT.md) | 架构约束、禁止修改的核心文件、安全头分层策略、各角色允许改进范围 |
| [AGENTS.md](AGENTS.md) | Agent 红线（禁止删文件/移动核心文件）、关键约束摘要 |

**红线**：禁止删除或清空已有文件、禁止移动/重命名核心文件。修改前请先阅读上述文档。

---

## 文件清单

```
get_route/
├── README.md                  ← 本文件
├── server/
│   ├── config.json            ← sing-box 配置 (三层出口分流 + Clash API)
│   ├── install.sh             ← sing-box 一键部署 (含 watchdog 安装)
│   ├── watchdog.sh            ← 看门狗 (监控 + 自动重启 + 告警)
│   ├── surfshark-config.sh    ← Surfshark WireGuard 配置管理
│   ├── health-check.sh        ← 隧道健康检查 (手动巡检)
│   ├── cert-manager.sh        ← SSL 证书管理 (acme.sh + Nginx)
│   ├── ecs-sync.sh            ← ECS 单向同步 (A→B，不同步数据库)
│   └── nginx/
│       ├── proxy.conf         ← Nginx 代理站点配置模板
│       └── panel.conf         ← Nginx 面板站点配置模板 (仅 HSTS，其余安全头在 app.py)
├── client/
│   └── clash-meta.yaml        ← Clash Meta 客户端配置模板
└── panel/
    ├── app.py                 ← 管理面板后端 (FastAPI + 证书管理 API)
    ├── templates/
    │   └── index.html         ← 管理面板前端 (含二维码订阅 + 证书管理)
    ├── requirements.txt       ← Python 依赖
    └── install.sh             ← 面板一键部署 (含 systemd 加固)
```
