# get_route 项目完善方案

> 最终版本: v1.0
> 日期: 2026-02-11

---

## 需求确认

**核心目标**: 稳定、快速访问全球各地网站（含中国限制的网络）

**可用资源**:
- 2x 阿里云香港 ECS (固定IP, 100M带宽)
- 域名: aoof188.cn
- Surfshark 账号 (支持所有国家)

---

## 架构总览

```
用户客户端
    │
    ├── Clash Meta / Stash / Shadowrocket / Surge
    │
    ▼
┌─────────────────────────────────────────────────────────┐
│                   DNS 负载均衡                          │
│        a.aoof188.cn ←→ b.aoof188.cn (轮询)            │
└────────────────────────┬────────────────────────────────┘
                         │
         ┌───────────────┴───────────────┐
         ▼                               ▼
┌─────────────────┐           ┌─────────────────┐
│   ECS-A (主)    │           │   ECS-B (从)   │
│   香港          │  ←→       │   香港          │
│   100M          │  同步      │   100M          │
└─────────────────┘           └─────────────────┘
         │                               │
         └── VLESS WS+TLS (443) ────────┘
             VLESS Reality (40443)
             Hysteria2 (8443)
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│                      出口选择                            │
├─────────────────────────────────────────────────────────┤
│  国内直连 → DIRECT                                      │
│  AI服务 → Surfshark auto-best (封锁HK IP)              │
│  Netflix/Disney+ → Surfshark SG                        │
│  BBC → Surfshark UK                                    │
│  Google/YouTube/GitHub → HK 直出 (更快!)                │
│  Twitter/Telegram/Reddit → HK 直出                      │
│  兜底(默认) → HK 直出 (不走Surfshark,减少一跳)          │
└─────────────────────────────────────────────────────────┘
```

---

## Surfshark 出口配置

| 优先级 | 国家 | 用途 | 备注 |
|--------|------|------|------|
| P0 | 🇯🇵 日本 (JP) | AI首选 | 延迟最低 |
| P0 | 🇸🇬 新加坡 (SG) | AI + Netflix | 综合最优 |
| P1 | 🇺🇸 美国 (US) | Disney+ / 兜底 | 内容最全 |
| P1 | 🇬🇧 英国 (UK) | BBC | 欧洲内容 |
| P2 | 🇦🇺 澳大利亚 (AU) | 备用 | 亚太第二 |
| P2 | 🇩🇪 德国 (DE) | 欧洲备用 | 欧洲内容 |

**最终: 4个国家 (JP/SG/US/UK)**

---

## 域名规划

| 域名 | 指向 | 用途 | 证书 |
|------|------|------|------|
| `a.aoof188.cn` | ECS-A | VLESS WS+TLS | Let's Encrypt |
| `b.aoof188.cn` | ECS-B | VLESS WS+TLS | Let's Encrypt |
| `panel.aoof188.cn` | ECS-A | 管理面板 | Let's Encrypt |
| `sub.aoof188.cn` | ECS-A | 订阅分发 | Let's Encrypt |

**证书方案**: acme.sh + Let's Encrypt (免费, 60天, 自动续期)

---

## 客户端支持

| 客户端 | 支持情况 | 备注 |
|--------|----------|------|
| Clash Meta | ✅ 主用 | 功能最全 |
| Stash | ✅ | iOS/Mac |
| Shadowrocket | ✅ | iOS |
| Surge | ✅ | iOS/Mac |

**订阅格式**:
- Clash Meta YAML (推荐)
- Base64 通用链接
- 节点二维码 (Shadowrocket)

---

## 功能增强 (待实现)

### Phase 1: 安全加固 (P0)

- [ ] CORS 限制 (只允许 panel.aoof188.cn)
- [ ] JWT Secret 持久化 (从环境变量读取)
- [ ] watchdog 命令注入修复
- [ ] 改用包管理器安装 acme.sh

### Phase 2: 运维增强 (P1)

- [ ] 证书自动续期监控 (提前14天告警)
- [ ] Telegram/钉钉 告警通知
- [ ] 双 ECS 配置 GitOps 同步
- [ ] 客户端健康检查增强

### Phase 3: 监控完善 (P2)

- [ ] Grafana 仪表盘 (可选)
- [ ] 流量统计可视化
- [ ] 延迟热力图

---

## 任务分配

| 角色 | Agent | 任务 |
|------|-------|------|
| Security Engineer | qwen3-max | 安全加固 + 审计 |
| Backend Architect | Qwen Coder | 代码重构 + 证书管理 |
| SRE | MiniMax-M2 | 监控 + 同步方案 |
| Oversight | qwen3-max | 方案评审 + 风险评估 |
| Project Lead | MiniMax-M2 | 协调 + 质量把控 |

---

## 下一步

1. ✅ 方案评审完成
2. ⏳ Phase 1: 安全加固
3. ⏳ Phase 2: 运维增强
4. ⏳ Phase 3: 监控完善

---

## 附录: 端口规划

| 端口 | 协议 | 服务 | ECS |
|------|------|------|-----|
| 80 | TCP | ACME验证 + HTTP跳转 | A+B |
| 443 | TCP | VLESS WS+TLS + 面板 | A+B |
| 40443 | TCP | VLESS Reality | A+B |
| 8443 | UDP | Hysteria2 | A+B |
| 8080 | TCP | 面板 (本地) | A |
| 51820 | UDP | Surfshark WireGuard | A+B |
