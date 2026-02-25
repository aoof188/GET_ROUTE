# Agent 指令

在执行任何任务前，**必须先阅读 `CONTEXT.md`**。

该文件包含本项目的核心架构约束、禁止修改的文件清单、已实现功能清单，以及各角色的操作权限边界。

## ⛔ 绝对红线（违反即回滚）

1. **禁止删除任何已有文件** — 不允许 `rm`、`Delete`、清空文件等操作。如认为不需要，提出建议由 Project Lead 处理。
2. **禁止移动/重命名核心文件** — `panel/app.py`、`server/config.json`、`client/clash-meta.yaml`、`panel/templates/index.html`、`server/*.sh` 路径不可变。
3. **禁止创建替代文件架空现有文件** — 不要创建 `app_v2.py` 等替代方案。

## 关键约束摘要（完整内容见 CONTEXT.md）

1. **不要修改 `server/config.json` 的路由规则** — 三层出口策略已确认（默认 HK 直出）
2. **不要重写前端为 React/Vue** — 使用 `panel/templates/index.html` 单文件方案
3. **不要引入 npm 构建流程** — Alpine.js + Tailwind CDN 内联方案
4. **不要添加 sub.aoof188.cn 域名** — 订阅集成在 panel 中
5. **JWT Secret 只从 .env 读取** — 不要创建额外的 secret 文件
6. **密码强度校验只在用户操作时执行** — 不要在服务启动时校验
7. **安全头由 app.py 统一管理** — Nginx 只管 HSTS，不要在 Nginx 重复设置 CSP/X-Frame 等
