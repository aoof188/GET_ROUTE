"""
sing-box 多用户管理面板
功能: 用户 CRUD / sing-box 配置同步 / 订阅链接生成 / 隧道健康检查 / 系统控制
"""

import os
import json
import secrets
import subprocess
import time
import shutil
import asyncio
import logging
from uuid import uuid4
from datetime import datetime, timedelta, timezone
from ipaddress import ip_address
from pathlib import Path
from typing import Optional, List
from contextlib import asynccontextmanager

from fastapi import FastAPI, Depends, HTTPException, Request, Query, Header
from fastapi.responses import HTMLResponse, PlainTextResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field, validator
from sqlalchemy import (
    create_engine, Column, Integer, String, Boolean,
    DateTime, BigInteger, Text, Date, event, func, UniqueConstraint
)
from sqlalchemy.orm import declarative_base, sessionmaker, Session
from passlib.context import CryptContext
from jose import jwt, JWTError
import httpx
import yaml
import uvicorn


# ================================================================
#  Security Utilities
# ================================================================


class Settings:
    """从环境变量加载配置，支持 .env 文件"""

    def __init__(self):
        self._load_env_file()

        # ---- 面板 ----
        self.PANEL_HOST = os.getenv("PANEL_HOST", "0.0.0.0")
        self.PANEL_PORT = int(os.getenv("PANEL_PORT", "8080"))
        self.ADMIN_USERNAME = os.getenv("ADMIN_USERNAME", "admin")
        self.ADMIN_PASSWORD = os.getenv("ADMIN_PASSWORD", "changeme")
        self.JWT_EXPIRE_HOURS = int(os.getenv("JWT_EXPIRE_HOURS", "24"))

        # ---- sing-box ----
        self.SINGBOX_CONFIG = os.getenv("SINGBOX_CONFIG", "/etc/sing-box/config.json")
        self.SINGBOX_API = os.getenv("SINGBOX_API", "http://127.0.0.1:9090")
        self.SINGBOX_API_SECRET = os.getenv("SINGBOX_API_SECRET", "")

        # ---- 数据库 ----
        self.DB_PATH = os.getenv("DB_PATH", "/var/lib/sing-box-panel/panel.db")

        # ---- 节点信息（用于生成订阅） ----
        self.ECS_A_IP = os.getenv("ECS_A_IP", "")
        self.ECS_A_NAME = os.getenv("ECS_A_NAME", "HK-A")
        self.ECS_B_IP = os.getenv("ECS_B_IP", "")
        self.ECS_B_NAME = os.getenv("ECS_B_NAME", "HK-B")
        self.VLESS_PORT = int(os.getenv("VLESS_PORT", "443"))
        self.HY2_PORT = int(os.getenv("HY2_PORT", "8443"))
        self.REALITY_PUBLIC_KEY = os.getenv("REALITY_PUBLIC_KEY", "")
        self.REALITY_SHORT_ID = os.getenv("REALITY_SHORT_ID", "")
        self.REALITY_SNI = os.getenv("REALITY_SNI", "www.microsoft.com")
        self.REALITY_PORT = int(os.getenv("REALITY_PORT", "40443"))
        self.HY2_SNI = os.getenv("HY2_SNI", "")
        self.SUB_BASE_URL = os.getenv("SUB_BASE_URL", "")

        # ---- 域名与证书 ----
        self.PANEL_DOMAIN = os.getenv("PANEL_DOMAIN", "")
        legacy_proxy_domain = os.getenv("PROXY_DOMAIN", "")
        self.PROXY_DOMAIN = legacy_proxy_domain
        self.PROXY_DOMAIN_A = os.getenv("PROXY_DOMAIN_A", legacy_proxy_domain)
        self.PROXY_DOMAIN_B = os.getenv(
            "PROXY_DOMAIN_B",
            self.PROXY_DOMAIN_A or legacy_proxy_domain
        )
        self.CERT_BASE_DIR = os.getenv("CERT_BASE_DIR", "/etc/nginx/ssl")
        self.CERT_MANAGER_PATH = os.getenv("CERT_MANAGER_PATH", "/opt/sing-box/cert-manager.sh")

        # ---- CORS ----
        cors_env = os.getenv("CORS_ALLOW_ORIGINS", "")
        if cors_env:
            self.CORS_ALLOW_ORIGINS = [o.strip() for o in cors_env.split(",") if o.strip()]
        else:
            self.CORS_ALLOW_ORIGINS = ["http://localhost:8080"]

        # ---- JWT Secret (只从 .env 读取) ----
        self.JWT_SECRET = os.getenv("JWT_SECRET", "").strip()
        if not self.JWT_SECRET:
            raise RuntimeError("JWT_SECRET 未配置，请在 panel/.env 中设置固定值")

        # ---- 受信任代理 ----
        trusted_proxies = os.getenv("TRUSTED_PROXY_IPS", "127.0.0.1,::1")
        self.TRUSTED_PROXY_IPS = tuple(
            ip.strip() for ip in trusted_proxies.split(",") if ip.strip()
        )

    def _load_env_file(self):
        env_file = Path(__file__).parent / ".env"
        if env_file.exists():
            for line in env_file.read_text().splitlines():
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, _, value = line.partition("=")
                    os.environ.setdefault(key.strip(), value.strip())


settings = Settings()

# ================================================================
#  Database & Models
# ================================================================

Base = declarative_base()


class User(Base):
    __tablename__ = "users"

    id = Column(Integer, primary_key=True, autoincrement=True)
    username = Column(String(64), unique=True, nullable=False, index=True)
    uuid = Column(String(36), unique=True, nullable=False)
    hy2_password = Column(String(64), nullable=False)
    sub_token = Column(String(32), unique=True, nullable=False)
    enabled = Column(Boolean, default=True)
    traffic_limit = Column(BigInteger, default=0)  # bytes, 0=无限
    traffic_used = Column(BigInteger, default=0)
    expire_at = Column(DateTime, nullable=True)  # None=永不过期
    note = Column(Text, default="")
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))
    updated_at = Column(DateTime, default=lambda: datetime.now(timezone.utc),
                        onupdate=lambda: datetime.now(timezone.utc))


class TrafficLog(Base):
    """每日流量日志：按 (日期, 用户, 出口) 三维度聚合"""
    __tablename__ = "traffic_logs"

    id = Column(Integer, primary_key=True, autoincrement=True)
    log_date = Column(Date, nullable=False, index=True)
    user_id = Column(Integer, nullable=True, index=True)
    outbound = Column(String(64), nullable=False)
    upload = Column(BigInteger, default=0)
    download = Column(BigInteger, default=0)

    __table_args__ = (
        UniqueConstraint("log_date", "user_id", "outbound", name="uq_date_user_outbound"),
    )


class SystemLog(Base):
    __tablename__ = "system_logs"

    id = Column(Integer, primary_key=True, autoincrement=True)
    action = Column(String(64), nullable=False)
    detail = Column(Text, default="")
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))


# 创建数据库目录和引擎
Path(settings.DB_PATH).parent.mkdir(parents=True, exist_ok=True)
engine = create_engine(f"sqlite:///{settings.DB_PATH}", echo=False)
SessionLocal = sessionmaker(bind=engine)
Base.metadata.create_all(engine)


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


# ================================================================
#  Auth
# ================================================================

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")


def create_token(username: str) -> str:
    expire = datetime.now(timezone.utc) + timedelta(hours=settings.JWT_EXPIRE_HOURS)
    return jwt.encode(
        {"sub": username, "exp": expire},
        settings.JWT_SECRET,
        algorithm="HS256"
    )


def verify_token(authorization: Optional[str] = Header(None)) -> str:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="未登录")
    token = authorization.split(" ", 1)[1]
    try:
        payload = jwt.decode(token, settings.JWT_SECRET, algorithms=["HS256"])
        username = payload.get("sub")
        if username != settings.ADMIN_USERNAME:
            raise HTTPException(status_code=401, detail="无效凭据")
        return username
    except JWTError:
        raise HTTPException(status_code=401, detail="Token 已过期或无效")


def get_client_ip(request: Request) -> str:
    """仅在请求来自受信任反代时才使用 X-Forwarded-For。"""
    peer_ip = request.client.host if request.client else ""
    forwarded_for = request.headers.get("X-Forwarded-For", "")
    if peer_ip in settings.TRUSTED_PROXY_IPS and forwarded_for:
        client_ip = forwarded_for.split(",")[0].strip()
        if client_ip:
            return client_ip
    return peer_ip or "unknown"


def is_private_or_loopback_ip(value: str) -> bool:
    try:
        addr = ip_address(value)
    except ValueError:
        return False
    return addr.is_private or addr.is_loopback


# ================================================================
#  sing-box Management
# ================================================================

def get_active_users(db: Session) -> List[User]:
    """获取所有有效用户（启用 + 未过期 + 未超流量）"""
    now = datetime.now(timezone.utc)
    users = db.query(User).filter(User.enabled == True).all()
    active = []
    for u in users:
        if u.expire_at and u.expire_at.replace(tzinfo=timezone.utc) < now:
            continue
        if u.traffic_limit > 0 and u.traffic_used >= u.traffic_limit:
            continue
        active.append(u)
    return active


def sync_users_to_singbox(db: Session) -> dict:
    """
    将数据库中的活跃用户同步到 sing-box config.json 的 inbounds.users 中，
    然后 reload sing-box。
    """
    config_path = Path(settings.SINGBOX_CONFIG)
    if not config_path.exists():
        return {"ok": False, "message": f"配置文件不存在: {config_path}"}

    # 备份
    backup_path = config_path.with_suffix(".json.bak")
    shutil.copy2(config_path, backup_path)

    try:
        config = json.loads(config_path.read_text())
        active_users = get_active_users(db)

        # 更新 inbound 用户列表
        for inbound in config.get("inbounds", []):
            if inbound.get("type") == "vless":
                # Reality 入站需要 flow，WS 入站不需要
                has_reality = (
                    inbound.get("tls", {}).get("reality", {}).get("enabled", False)
                )
                if has_reality:
                    inbound["users"] = [
                        {"uuid": u.uuid, "flow": "xtls-rprx-vision"}
                        for u in active_users
                    ]
                else:
                    inbound["users"] = [
                        {"uuid": u.uuid}
                        for u in active_users
                    ]
            elif inbound.get("type") == "hysteria2":
                inbound["users"] = [
                    {"password": u.hy2_password}
                    for u in active_users
                ]

        # 写回
        config_path.write_text(json.dumps(config, indent=2, ensure_ascii=False))

        # 验证配置
        result = subprocess.run(
            ["sing-box", "check", "-c", str(config_path)],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode != 0:
            # 回滚
            shutil.copy2(backup_path, config_path)
            return {"ok": False, "message": f"配置验证失败: {result.stderr}"}

        # Reload
        result = subprocess.run(
            ["systemctl", "reload", "sing-box"],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode != 0:
            shutil.copy2(backup_path, config_path)
            return {"ok": False, "message": f"reload 失败: {result.stderr}"}

        # 记录日志
        log = SystemLog(action="sync_users", detail=f"同步 {len(active_users)} 个活跃用户")
        db.add(log)
        db.commit()

        return {"ok": True, "active_users": len(active_users)}

    except Exception as e:
        # 回滚
        if backup_path.exists():
            shutil.copy2(backup_path, config_path)
        return {"ok": False, "message": str(e)}


async def get_singbox_stats() -> dict:
    """通过 Clash API 获取 sing-box 运行状态"""
    headers = {}
    if settings.SINGBOX_API_SECRET:
        headers["Authorization"] = f"Bearer {settings.SINGBOX_API_SECRET}"

    stats = {
        "running": False,
        "connections": 0,
        "upload_total": 0,
        "download_total": 0,
        "memory": 0,
    }

    try:
        async with httpx.AsyncClient(timeout=5) as client:
            # 连接数和流量
            resp = await client.get(f"{settings.SINGBOX_API}/connections", headers=headers)
            if resp.status_code == 200:
                data = resp.json()
                stats["running"] = True
                stats["connections"] = len(data.get("connections", []))
                stats["upload_total"] = data.get("uploadTotal", 0)
                stats["download_total"] = data.get("downloadTotal", 0)

            # 内存
            resp = await client.get(f"{settings.SINGBOX_API}/memory", headers=headers)
            if resp.status_code == 200:
                stats["memory"] = resp.json().get("inuse", 0)

    except Exception:
        pass

    return stats


# ================================================================
#  Per-user & Per-outbound Traffic Collection (background task)
# ================================================================

_traffic_logger = logging.getLogger("panel.traffic")
_conn_tracker: dict = {}
_outbound_traffic: dict = {}


def _load_outbound_traffic_from_db():
    """启动时从数据库加载当天已有的出口流量数据到内存缓存。"""
    global _outbound_traffic
    db = SessionLocal()
    try:
        today = datetime.now(timezone.utc).date()
        rows = (
            db.query(TrafficLog.outbound, func.sum(TrafficLog.upload), func.sum(TrafficLog.download))
            .filter(TrafficLog.log_date == today)
            .group_by(TrafficLog.outbound)
            .all()
        )
        for outbound, up, down in rows:
            _outbound_traffic[outbound] = {"upload": up or 0, "download": down or 0}
    except Exception as e:
        _traffic_logger.warning("Failed to load outbound traffic from DB: %s", e)
    finally:
        db.close()


def get_outbound_traffic() -> dict:
    """返回各出口节点的累计流量（当天，持久化 + 内存增量）。"""
    return dict(_outbound_traffic)


def _upsert_traffic_log(db: Session, log_date, user_db_id: Optional[int], outbound: str,
                         up_delta: int, down_delta: int):
    """向 traffic_logs 表 upsert 一条记录。"""
    row = (
        db.query(TrafficLog)
        .filter(
            TrafficLog.log_date == log_date,
            TrafficLog.user_id == user_db_id,
            TrafficLog.outbound == outbound,
        )
        .first()
    )
    if row:
        row.upload = (row.upload or 0) + up_delta
        row.download = (row.download or 0) + down_delta
    else:
        db.add(TrafficLog(
            log_date=log_date,
            user_id=user_db_id,
            outbound=outbound,
            upload=up_delta,
            download=down_delta,
        ))


async def _collect_traffic():
    """定期轮询 Clash API /connections，按用户和出口节点归集流量并持久化。"""
    global _conn_tracker
    await asyncio.sleep(10)

    _load_outbound_traffic_from_db()

    while True:
        try:
            headers = {}
            if settings.SINGBOX_API_SECRET:
                headers["Authorization"] = f"Bearer {settings.SINGBOX_API_SECRET}"

            async with httpx.AsyncClient(timeout=5) as client:
                resp = await client.get(
                    f"{settings.SINGBOX_API}/connections", headers=headers
                )
                if resp.status_code != 200:
                    await asyncio.sleep(60)
                    continue

                data = resp.json()
                connections = data.get("connections") or []

            current_conns: dict = {}
            # key: (user_credential, outbound), value: {up, down}
            detail_deltas: dict[tuple[str, str], dict[str, int]] = {}

            for conn in connections:
                conn_id = conn.get("id", "")
                upload = conn.get("upload", 0)
                download = conn.get("download", 0)

                metadata = conn.get("metadata", {})
                user_id = metadata.get("user", "")

                chains = conn.get("chains", [])
                outbound = chains[-1] if chains else ""

                if not conn_id:
                    continue

                current_conns[conn_id] = {
                    "upload": upload,
                    "download": download,
                    "user": user_id,
                    "outbound": outbound,
                }

                prev = _conn_tracker.get(conn_id)
                if prev:
                    up_delta = upload - prev["upload"]
                    down_delta = download - prev["download"]
                else:
                    up_delta = upload
                    down_delta = download

                up_delta = max(up_delta, 0)
                down_delta = max(down_delta, 0)

                if (up_delta > 0 or down_delta > 0) and outbound:
                    if outbound not in _outbound_traffic:
                        _outbound_traffic[outbound] = {"upload": 0, "download": 0}
                    _outbound_traffic[outbound]["upload"] += up_delta
                    _outbound_traffic[outbound]["download"] += down_delta

                if (up_delta > 0 or down_delta > 0) and (user_id or outbound):
                    key = (user_id or "", outbound or "unknown")
                    if key not in detail_deltas:
                        detail_deltas[key] = {"up": 0, "down": 0}
                    detail_deltas[key]["up"] += up_delta
                    detail_deltas[key]["down"] += down_delta

            _conn_tracker = current_conns

            if detail_deltas:
                db = SessionLocal()
                try:
                    today = datetime.now(timezone.utc).date()
                    user_totals: dict[str, int] = {}

                    for (uid, outbound), delta in detail_deltas.items():
                        user_db_id = None
                        if uid:
                            user = (
                                db.query(User)
                                .filter((User.uuid == uid) | (User.hy2_password == uid))
                                .first()
                            )
                            if user:
                                user_db_id = user.id
                                user_totals[uid] = user_totals.get(uid, 0) + delta["up"] + delta["down"]

                        _upsert_traffic_log(db, today, user_db_id, outbound,
                                            delta["up"], delta["down"])

                    for uid, total in user_totals.items():
                        user = (
                            db.query(User)
                            .filter((User.uuid == uid) | (User.hy2_password == uid))
                            .first()
                        )
                        if user:
                            user.traffic_used = (user.traffic_used or 0) + total

                    db.commit()
                except Exception as e:
                    _traffic_logger.warning("Failed to persist traffic: %s", e)
                    db.rollback()
                finally:
                    db.close()

        except asyncio.CancelledError:
            break
        except Exception as e:
            _traffic_logger.warning("Traffic collector error: %s", e)

        await asyncio.sleep(60)


async def check_tunnel_health() -> List[dict]:
    """通过 Clash API 检查各出口隧道状态（自动发现所有出口节点）"""
    headers = {}
    if settings.SINGBOX_API_SECRET:
        headers["Authorization"] = f"Bearer {settings.SINGBOX_API_SECRET}"

    tunnels = []
    _SKIP_TYPES = {"dns", "block", "selector"}
    _SKIP_TAGS = {"dns-out"}
    _INBOUND_SUFFIXES = ("-in",)

    try:
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.get(f"{settings.SINGBOX_API}/proxies", headers=headers)
            if resp.status_code != 200:
                return tunnels

            proxies = resp.json().get("proxies", {})

            tunnel_tags = [
                tag for tag, p in proxies.items()
                if p.get("type", "") not in _SKIP_TYPES
                and tag not in _SKIP_TAGS
                and not any(tag.endswith(s) for s in _INBOUND_SUFFIXES)
            ]
            tunnel_tags.sort(key=lambda t: (
                0 if t.startswith("wg-") else 1 if t == "auto-best" else 2 if t == "direct" else 3
            ))

            for tag in tunnel_tags:
                proxy = proxies[tag]
                info = {
                    "tag": tag,
                    "type": proxy.get("type", "unknown"),
                    "alive": proxy.get("alive", False),
                    "delay": proxy.get("history", [{}])[-1].get("delay", 0)
                    if proxy.get("history") else 0,
                }

                try:
                    delay_resp = await client.get(
                        f"{settings.SINGBOX_API}/proxies/{tag}/delay",
                        params={"url": "https://www.gstatic.com/generate_204", "timeout": 5000},
                        headers=headers,
                        timeout=10
                    )
                    if delay_resp.status_code == 200:
                        info["delay"] = delay_resp.json().get("delay", 0)
                        info["alive"] = True
                    else:
                        info["alive"] = False
                except Exception:
                    pass

                tunnels.append(info)

    except Exception:
        pass

    return tunnels


# ================================================================
#  Subscription Config Generator
# ================================================================

def generate_clash_config(user: User) -> str:
    """为指定用户生成完整的 Clash Meta YAML 配置"""

    proxies = []
    proxy_names = []

    # ---- VLESS WS+TLS (主力，走域名 + Nginx 反代) ----
    ws_nodes = [
        (settings.ECS_A_IP, settings.ECS_A_NAME, settings.PROXY_DOMAIN_A),
        (settings.ECS_B_IP, settings.ECS_B_NAME, settings.PROXY_DOMAIN_B),
    ]
    ws_domains_seen = set()
    for ecs_ip, ecs_name, proxy_domain in ws_nodes:
        if not ecs_ip or not proxy_domain or proxy_domain in ws_domains_seen:
            continue
        name = f"{ecs_name}-WS"
        proxies.append({
            "name": name,
            "type": "vless",
            "server": proxy_domain,
            "port": settings.VLESS_PORT,
            "uuid": user.uuid,
            "network": "ws",
            "tls": True,
            "udp": True,
            "servername": proxy_domain,
            "ws-opts": {
                "path": "/ws",
                "headers": {"Host": proxy_domain},
            },
            "client-fingerprint": "chrome",
        })
        proxy_names.append(name)
        ws_domains_seen.add(proxy_domain)

    # ---- VLESS Reality (备用，直连 IP，无需域名) ----
    for ecs_ip, ecs_name in [(settings.ECS_A_IP, settings.ECS_A_NAME),
                              (settings.ECS_B_IP, settings.ECS_B_NAME)]:
        if not ecs_ip:
            continue
        name = f"{ecs_name}-Reality"
        proxies.append({
            "name": name,
            "type": "vless",
            "server": ecs_ip,
            "port": settings.REALITY_PORT,
            "uuid": user.uuid,
            "network": "tcp",
            "tls": True,
            "udp": True,
            "flow": "xtls-rprx-vision",
            "servername": settings.REALITY_SNI,
            "reality-opts": {
                "public-key": settings.REALITY_PUBLIC_KEY,
                "short-id": settings.REALITY_SHORT_ID,
            },
            "client-fingerprint": "chrome",
        })
        proxy_names.append(name)

    # ECS-A Hysteria2
    if settings.ECS_A_IP and settings.HY2_SNI:
        name = f"{settings.ECS_A_NAME}-Hy2"
        proxies.append({
            "name": name,
            "type": "hysteria2",
            "server": settings.ECS_A_IP,
            "port": settings.HY2_PORT,
            "password": user.hy2_password,
            "alpn": ["h3"],
            "sni": settings.HY2_SNI,
        })
        proxy_names.append(name)

    # ECS-B Hysteria2
    if settings.ECS_B_IP and settings.HY2_SNI:
        name = f"{settings.ECS_B_NAME}-Hy2"
        proxies.append({
            "name": name,
            "type": "hysteria2",
            "server": settings.ECS_B_IP,
            "port": settings.HY2_PORT,
            "password": user.hy2_password,
            "alpn": ["h3"],
            "sni": settings.HY2_SNI,
        })
        proxy_names.append(name)

    config = {
        "mixed-port": 7890,
        "allow-lan": True,
        "mode": "rule",
        "log-level": "info",
        "unified-delay": True,
        "tcp-concurrent": True,
        "global-client-fingerprint": "chrome",
        "geodata-mode": True,
        "geox-url": {
            "geoip": "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip-lite.dat",
            "geosite": "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat",
            "mmdb": "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country-lite.mmdb",
        },
        "dns": {
            "enable": True,
            "ipv6": False,
            "enhanced-mode": "fake-ip",
            "fake-ip-range": "198.18.0.1/16",
            "fake-ip-filter": [
                "*.lan", "*.local", "dns.msftncsi.com",
                "+.stun.*.*", "localhost.ptlogin2.qq.com",
                "time.*.com", "time.*.gov", "ntp.*.com", "+.pool.ntp.org",
            ],
            "default-nameserver": ["223.5.5.5", "119.29.29.29"],
            "nameserver": ["https://dns.alidns.com/dns-query"],
            "nameserver-policy": {
                "geosite:cn,private": ["https://dns.alidns.com/dns-query"],
                "geosite:geolocation-!cn": ["https://dns.cloudflare.com/dns-query#proxy"],
            },
        },
        "tun": {
            "enable": True,
            "stack": "system",
            "dns-hijack": ["any:53"],
            "auto-route": True,
            "auto-detect-interface": True,
        },
        "proxies": proxies,
        "proxy-groups": [
            {
                "name": "入口选择",
                "type": "fallback",
                "proxies": proxy_names,
                "url": "https://www.gstatic.com/generate_204",
                "interval": 180,
                "lazy": False,
            },
            {
                "name": "自动选择",
                "type": "url-test",
                "proxies": proxy_names,
                "url": "https://www.gstatic.com/generate_204",
                "interval": 300,
                "tolerance": 50,
            },
            {
                "name": "手动选择",
                "type": "select",
                "proxies": ["入口选择", "自动选择"] + proxy_names,
            },
            {
                "name": "proxy",
                "type": "select",
                "proxies": ["入口选择", "自动选择", "手动选择"],
            },
            {
                "name": "Streaming",
                "type": "select",
                "proxies": ["proxy", "入口选择", "自动选择"],
            },
            {
                "name": "AI",
                "type": "select",
                "proxies": ["proxy", "入口选择", "自动选择"],
            },
            {
                "name": "Global",
                "type": "select",
                "proxies": ["proxy", "入口选择", "自动选择", "DIRECT"],
            },
            {
                "name": "Final",
                "type": "select",
                "proxies": ["proxy", "DIRECT"],
            },
        ],
        "rules": [
            # 本地 & 局域网
            "DOMAIN-SUFFIX,local,DIRECT",
            "DOMAIN-SUFFIX,localhost,DIRECT",
            "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
            "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
            "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve",
            "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
            "IP-CIDR,100.64.0.0/10,DIRECT,no-resolve",
            # 广告拦截
            "GEOSITE,category-ads-all,REJECT",
            # AI 服务
            "DOMAIN-SUFFIX,openai.com,AI",
            "DOMAIN-SUFFIX,chatgpt.com,AI",
            "DOMAIN-SUFFIX,ai.com,AI",
            "DOMAIN-SUFFIX,oaiusercontent.com,AI",
            "DOMAIN-SUFFIX,oaistatic.com,AI",
            "DOMAIN-SUFFIX,anthropic.com,AI",
            "DOMAIN-SUFFIX,claude.ai,AI",
            "DOMAIN-SUFFIX,gemini.google.com,AI",
            "DOMAIN-SUFFIX,bard.google.com,AI",
            "DOMAIN-SUFFIX,aistudio.google.com,AI",
            "DOMAIN-SUFFIX,makersuite.google.com,AI",
            "DOMAIN-SUFFIX,ai.google.dev,AI",
            "DOMAIN-SUFFIX,deepmind.google,AI",
            "DOMAIN-SUFFIX,notebooklm.google.com,AI",
            "DOMAIN-SUFFIX,notebooklm.google,AI",
            "DOMAIN-SUFFIX,generativelanguage.googleapis.com,AI",
            "DOMAIN-SUFFIX,deepmind.com,AI",
            "DOMAIN-SUFFIX,x.ai,AI",
            "DOMAIN-SUFFIX,grok.com,AI",
            "DOMAIN-SUFFIX,copilot.microsoft.com,AI",
            "DOMAIN-SUFFIX,mistral.ai,AI",
            "DOMAIN-SUFFIX,perplexity.ai,AI",
            "DOMAIN-SUFFIX,meta.ai,AI",
            "DOMAIN-SUFFIX,midjourney.com,AI",
            "DOMAIN-SUFFIX,pika.art,AI",
            "DOMAIN-SUFFIX,runway.com,AI",
            "DOMAIN-SUFFIX,runwayml.com,AI",
            "DOMAIN-SUFFIX,luma.ai,AI",
            "DOMAIN-SUFFIX,stability.ai,AI",
            "DOMAIN-SUFFIX,character.ai,AI",
            "DOMAIN-SUFFIX,poe.com,AI",
            "DOMAIN-SUFFIX,suno.ai,AI",
            "DOMAIN-SUFFIX,suno.com,AI",
            "DOMAIN-SUFFIX,elevenlabs.io,AI",
            "DOMAIN-SUFFIX,cursor.sh,AI",
            "DOMAIN-SUFFIX,cursor.com,AI",
            "DOMAIN-SUFFIX,v0.dev,AI",
            "DOMAIN-SUFFIX,bolt.new,AI",
            "DOMAIN-SUFFIX,huggingface.co,AI",
            "DOMAIN-SUFFIX,replicate.com,AI",
            "DOMAIN-SUFFIX,together.ai,AI",
            "DOMAIN-SUFFIX,groq.com,AI",
            "DOMAIN-SUFFIX,fireworks.ai,AI",
            "DOMAIN-SUFFIX,anyscale.com,AI",
            "DOMAIN-SUFFIX,cohere.com,AI",
            "DOMAIN-SUFFIX,cohere.ai,AI",
            "DOMAIN-SUFFIX,dify.ai,AI",
            "DOMAIN-SUFFIX,flowith.io,AI",
            # 流媒体
            "GEOSITE,netflix,Streaming",
            "GEOSITE,disney,Streaming",
            "GEOSITE,hbo,Streaming",
            "GEOSITE,tiktok,Streaming",
            "GEOSITE,bbc,Streaming",
            "GEOSITE,spotify,Streaming",
            "GEOSITE,primevideo,Streaming",
            # 国外常用
            "GEOSITE,youtube,Global",
            "GEOSITE,google,Global",
            "GEOSITE,github,Global",
            "GEOSITE,twitter,Global",
            "GEOSITE,facebook,Global",
            "GEOSITE,instagram,Global",
            "GEOSITE,telegram,Global",
            "GEOSITE,whatsapp,Global",
            "GEOSITE,wikipedia,Global",
            "GEOSITE,reddit,Global",
            "GEOSITE,steam,Global",
            "GEOSITE,apple-cn,DIRECT",
            "GEOSITE,microsoft@cn,DIRECT",
            # 国内直连
            "GEOSITE,cn,DIRECT",
            "GEOIP,cn,DIRECT,no-resolve",
            "GEOIP,private,DIRECT,no-resolve",
            # 兜底
            "MATCH,Final",
        ],
    }

    return yaml.dump(config, default_flow_style=False, allow_unicode=True, sort_keys=False)


def generate_base64_links(user: User) -> str:
    """生成 Base64 编码的节点链接（用于通用客户端）"""
    import base64
    links = []

    # VLESS WS+TLS 链接（主力）
    ws_links = [
        (settings.ECS_A_NAME, settings.PROXY_DOMAIN_A),
        (settings.ECS_B_NAME, settings.PROXY_DOMAIN_B),
    ]
    ws_domains_seen = set()
    for ecs_name, proxy_domain in ws_links:
        if not proxy_domain or proxy_domain in ws_domains_seen:
            continue
        params = (
            f"encryption=none&security=tls"
            f"&sni={proxy_domain}&fp=chrome"
            f"&type=ws&path=%2Fws&host={proxy_domain}"
        )
        link = f"vless://{user.uuid}@{proxy_domain}:{settings.VLESS_PORT}?{params}#{ecs_name}-WS"
        links.append(link)
        ws_domains_seen.add(proxy_domain)

    # VLESS Reality 链接（备用）
    for ip, name in [(settings.ECS_A_IP, settings.ECS_A_NAME),
                     (settings.ECS_B_IP, settings.ECS_B_NAME)]:
        if not ip:
            continue
        params = (
            f"encryption=none&flow=xtls-rprx-vision&security=reality"
            f"&sni={settings.REALITY_SNI}&fp=chrome"
            f"&pbk={settings.REALITY_PUBLIC_KEY}&sid={settings.REALITY_SHORT_ID}"
            f"&type=tcp"
        )
        link = f"vless://{user.uuid}@{ip}:{settings.REALITY_PORT}?{params}#{name}-Reality"
        links.append(link)

    return base64.b64encode("\n".join(links).encode()).decode()


# ================================================================
#  Pydantic Schemas
# ================================================================

class LoginRequest(BaseModel):
    username: str
    password: str


class UserCreate(BaseModel):
    username: str = Field(..., min_length=1, max_length=64)
    note: str = ""
    traffic_limit: int = 0  # bytes, 0=无限
    expire_days: Optional[int] = None  # None=永不过期


class UserUpdate(BaseModel):
    username: Optional[str] = None
    note: Optional[str] = None
    enabled: Optional[bool] = None
    traffic_limit: Optional[int] = None
    expire_days: Optional[int] = None  # -1=清除过期时间


class SettingsUpdate(BaseModel):
    ecs_a_ip: Optional[str] = None
    ecs_a_name: Optional[str] = None
    ecs_b_ip: Optional[str] = None
    ecs_b_name: Optional[str] = None
    reality_public_key: Optional[str] = None
    reality_short_id: Optional[str] = None
    reality_sni: Optional[str] = None
    reality_port: Optional[int] = None
    hy2_sni: Optional[str] = None
    sub_base_url: Optional[str] = None
    panel_domain: Optional[str] = None
    proxy_domain: Optional[str] = None
    proxy_domain_a: Optional[str] = None
    proxy_domain_b: Optional[str] = None


class CertIssueRequest(BaseModel):
    domain: str


# ================================================================
#  Rate Limiting (登录防暴力破解)
# ================================================================

# 简单的内存级限流：{IP: (last_attempt_time, attempt_count)}
_login_rate_limit: dict = {}
_LOGIN_MAX_ATTEMPTS = 5  # 5 次
_LOGIN_WINDOW_SECONDS = 300  # 5 分钟窗口


def check_login_rate_limit(client_ip: str) -> tuple:
    """
    检查登录频率限制
    返回: (is_allowed, remaining_attempts, wait_seconds)
    """
    now = time.time()
    if client_ip not in _login_rate_limit:
        _login_rate_limit[client_ip] = (now, 1)
        return (True, _LOGIN_MAX_ATTEMPTS - 1, 0)

    last_time, count = _login_rate_limit[client_ip]

    # 窗口期已过，重置
    if now - last_time > _LOGIN_WINDOW_SECONDS:
        _login_rate_limit[client_ip] = (now, 1)
        return (True, _LOGIN_MAX_ATTEMPTS - 1, 0)

    # 超过限制
    if count >= _LOGIN_MAX_ATTEMPTS:
        wait_seconds = int(_LOGIN_WINDOW_SECONDS - (now - last_time))
        return (False, 0, wait_seconds)

    # 更新计数
    _login_rate_limit[client_ip] = (last_time, count + 1)
    return (True, _LOGIN_MAX_ATTEMPTS - count - 1, 0)


# ================================================================
#  HTTP Security Headers
# ================================================================

async def add_security_headers(request: Request, call_next):
    """添加 HTTP 安全响应头"""
    response = await call_next(request)

    # X-Frame-Options: 防止点击劫持
    response.headers["X-Frame-Options"] = "SAMEORIGIN"

    # X-Content-Type-Options: 防止 MIME 类型嗅探
    response.headers["X-Content-Type-Options"] = "nosniff"

    # X-XSS-Protection: 旧版浏览器防护（现代浏览器已忽略，但保留无妨）
    response.headers["X-XSS-Protection"] = "1; mode=block"

    # Referrer-Policy: 控制 Referer 头泄露
    response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"

    # Content-Security-Policy: 限制资源加载来源
    csp = (
        "default-src 'self'; "
        "script-src 'self' 'unsafe-inline' 'unsafe-eval'; "
        "style-src 'self' 'unsafe-inline'; "
        "img-src 'self' data: https:; "
        "font-src 'self' data:; "
        "connect-src 'self' https:; "
        "frame-ancestors 'self';"
    )
    response.headers["Content-Security-Policy"] = csp

    # Strict-Transport-Security: 强制 HTTPS（生产环境建议开启）
    # hsts_max_age = int(os.getenv("HSTS_MAX_SECONDS", "0"))
    # if hsts_max_age > 0:
    #     response.headers["Strict-Transport-Security"] = f"max-age={hsts_max_age}; includeSubDomains"

    return response


# ================================================================
#  FastAPI App
# ================================================================

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup
    print(f"🚀 sing-box 管理面板启动: http://{settings.PANEL_HOST}:{settings.PANEL_PORT}")
    print(f"📦 数据库: {settings.DB_PATH}")
    print(f"⚙️  sing-box 配置: {settings.SINGBOX_CONFIG}")

    db = SessionLocal()
    try:
        active = get_active_users(db)
        if active:
            result = sync_users_to_singbox(db)
            if result.get("ok"):
                print(f"✅ 启动同步: {result.get('active_users', 0)} 个用户已写入 config.json")
            else:
                print(f"⚠️  启动同步失败: {result.get('message', '未知错误')}")
    except Exception as e:
        print(f"⚠️  启动同步异常: {e}")
    finally:
        db.close()

    collector = asyncio.create_task(_collect_traffic())

    yield

    # Shutdown
    collector.cancel()
    try:
        await collector
    except asyncio.CancelledError:
        pass


app = FastAPI(title="sing-box Panel", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.CORS_ALLOW_ORIGINS,
    allow_methods=["*"],
    allow_headers=["*"],
)

# 添加 HTTP 安全响应头
app.middleware("http")(add_security_headers)

templates = Jinja2Templates(directory=str(Path(__file__).parent / "templates"))

_static_dir = Path(__file__).parent / "static"
if _static_dir.is_dir():
    app.mount("/static", StaticFiles(directory=str(_static_dir)), name="static")


# ---- 页面路由 ----

@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    return templates.TemplateResponse("index.html", {"request": request})


# ---- 认证 ----

@app.post("/api/login")
async def login(req: LoginRequest, request: Request):
    # 获取客户端 IP（考虑代理）
    client_ip = get_client_ip(request)

    # Rate Limiting 检查
    allowed, remaining, wait_seconds = check_login_rate_limit(client_ip)
    if not allowed:
        raise HTTPException(
            status_code=429,
            detail=f"登录尝试过于频繁，请 {wait_seconds} 秒后重试"
        )

    if req.username != settings.ADMIN_USERNAME or req.password != settings.ADMIN_PASSWORD:
        raise HTTPException(status_code=401, detail="用户名或密码错误")

    # 登录成功，立即清除该 IP 的限流记录
    _login_rate_limit.pop(client_ip, None)
    token = create_token(req.username)
    return {"ok": True, "token": token}


# ---- Dashboard ----

@app.get("/api/dashboard")
async def dashboard(admin: str = Depends(verify_token), db: Session = Depends(get_db)):
    total = db.query(User).count()
    active = len(get_active_users(db))
    stats = await get_singbox_stats()
    tunnels = await check_tunnel_health()

    return {
        "ok": True,
        "data": {
            "users_total": total,
            "users_active": active,
            "singbox": stats,
            "tunnels": tunnels,
            "outbound_traffic": get_outbound_traffic(),
        }
    }


# ---- 系统状态（仅限本机 / 内网访问）----

@app.get("/api/metrics")
async def get_metrics(request: Request):
    """
    获取 Prometheus 格式的监控指标
    仅允许本机和内网 IP 访问
    """
    client_ip = get_client_ip(request)

    if not is_private_or_loopback_ip(client_ip):
        raise HTTPException(status_code=403, detail="Forbidden: metrics 仅允许内网访问")

    import subprocess

    metrics_lines = []

    # 时间戳
    timestamp = int(datetime.now(timezone.utc).timestamp())
    metrics_lines.append(f"# HELP singbox_check_timestamp 检查时间戳")
    metrics_lines.append(f"# TYPE singbox_check_timestamp counter")
    metrics_lines.append(f"singbox_check_timestamp {timestamp}")
    metrics_lines.append("")

    # 服务状态
    try:
        result = subprocess.run(
            ["systemctl", "is-active", "sing-box"],
            capture_output=True, text=True, timeout=5
        )
        service_status = 1 if result.returncode == 0 and result.stdout.strip() == "active" else 0
    except Exception:
        service_status = 0

    metrics_lines.append("# HELP singbox_service_status sing-box 服务状态")
    metrics_lines.append("# TYPE singbox_service_status gauge")
    metrics_lines.append(f"singbox_service_status{{service=\"sing-box\"}} {service_status}")
    metrics_lines.append("")

    # 内存使用率
    try:
        result = subprocess.run(
            ["free", "-m"],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0:
            lines = result.stdout.strip().split("\n")
            if len(lines) > 1:
                parts = lines[1].split()
                total_mem = float(parts[1])
                used_mem = float(parts[2])
                mem_percent = round(used_mem / total_mem * 100, 1)
                metrics_lines.append("# HELP singbox_memory_usage_percent 内存使用率")
                metrics_lines.append("# TYPE singbox_memory_usage_percent gauge")
                metrics_lines.append(f"singbox_memory_usage_percent {mem_percent}")
    except Exception:
        pass
    metrics_lines.append("")

    # 磁盘使用率
    try:
        result = subprocess.run(
            ["df", "-h", "/"],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0:
            parts = result.stdout.strip().split("\n")[-1].split()
            disk_percent = float(parts[4].rstrip('%'))
            metrics_lines.append("# HELP singbox_disk_usage_percent 磁盘使用率")
            metrics_lines.append("# TYPE singbox_disk_usage_percent gauge")
            metrics_lines.append(f"singbox_disk_usage_percent {disk_percent}")
    except Exception:
        pass
    metrics_lines.append("")

    # 连接数
    try:
        result = subprocess.run(
            ["ss", "-tnp"],
            capture_output=True, text=True, timeout=5
        )
        conn_count = result.stdout.count("sing-box")
        metrics_lines.append("# HELP singbox_connections 当前活跃连接数")
        metrics_lines.append("# TYPE singbox_connections gauge")
        metrics_lines.append(f"singbox_connections {conn_count}")
    except Exception:
        pass
    metrics_lines.append("")

    # 隧道延迟（从 sing-box API，自动发现所有出口）
    api_headers = {"Authorization": f"Bearer {settings.SINGBOX_API_SECRET}"} if settings.SINGBOX_API_SECRET else {}
    try:
        async with httpx.AsyncClient(timeout=5) as client:
            proxies_resp = await client.get(f"{settings.SINGBOX_API}/proxies", headers=api_headers)
            if proxies_resp.status_code == 200:
                proxies_data = proxies_resp.json().get("proxies", {})
                _skip = {"dns", "block", "selector", "dns-out"}
                tags = [t for t, p in proxies_data.items()
                        if p.get("type", "") not in _skip and t not in _skip
                        and not t.endswith("-in")]
                for tag in tags:
                    try:
                        resp = await client.get(
                            f"{settings.SINGBOX_API}/proxies/{tag}/delay",
                            params={"url": "https://www.gstatic.com/generate_204", "timeout": 5000},
                            headers=api_headers
                        )
                        if resp.status_code == 200:
                            delay = resp.json().get("delay", 0)
                            metrics_lines.append(f"# HELP singbox_tunnel_delay_ms {tag} 隧道延迟")
                            metrics_lines.append(f"# TYPE singbox_tunnel_delay_ms gauge")
                            metrics_lines.append(f'singbox_tunnel_delay_ms{{outbound="{tag}"}} {delay}')
                    except Exception:
                        pass
    except Exception:
        pass

    return PlainTextResponse("\n".join(metrics_lines), media_type="text/plain; charset=utf-8")


# ---- 用户管理 ----

@app.get("/api/users")
async def list_users(
    admin: str = Depends(verify_token),
    db: Session = Depends(get_db),
    search: str = Query("", description="搜索用户名或备注"),
):
    query = db.query(User)
    if search:
        query = query.filter(
            User.username.contains(search) | User.note.contains(search)
        )
    users = query.order_by(User.id.desc()).all()

    now = datetime.now(timezone.utc)
    result = []
    for u in users:
        expired = bool(u.expire_at and u.expire_at.replace(tzinfo=timezone.utc) < now)
        over_limit = bool(u.traffic_limit > 0 and u.traffic_used >= u.traffic_limit)
        sub_url = ""
        if settings.SUB_BASE_URL:
            sub_url = f"{settings.SUB_BASE_URL.rstrip('/')}/sub/{u.sub_token}"

        result.append({
            "id": u.id,
            "username": u.username,
            "uuid": u.uuid,
            "hy2_password": u.hy2_password,
            "sub_token": u.sub_token,
            "sub_url": sub_url,
            "enabled": u.enabled,
            "status": "disabled" if not u.enabled
                      else "expired" if expired
                      else "over_limit" if over_limit
                      else "active",
            "traffic_limit": u.traffic_limit,
            "traffic_used": u.traffic_used,
            "expire_at": u.expire_at.isoformat() if u.expire_at else None,
            "note": u.note,
            "created_at": u.created_at.isoformat() if u.created_at else None,
        })

    return {"ok": True, "data": result}


@app.post("/api/users")
async def create_user(
    req: UserCreate,
    admin: str = Depends(verify_token),
    db: Session = Depends(get_db),
):
    # 检查用户名重复
    if db.query(User).filter(User.username == req.username).first():
        raise HTTPException(status_code=400, detail="用户名已存在")

    expire_at = None
    if req.expire_days and req.expire_days > 0:
        expire_at = datetime.now(timezone.utc) + timedelta(days=req.expire_days)

    user = User(
        username=req.username,
        uuid=str(uuid4()),
        hy2_password=secrets.token_hex(16),
        sub_token=secrets.token_urlsafe(16),
        enabled=True,
        traffic_limit=req.traffic_limit,
        expire_at=expire_at,
        note=req.note,
    )
    db.add(user)
    db.flush()

    # 同步到 sing-box
    sync_result = sync_users_to_singbox(db)
    if not sync_result.get("ok"):
        db.rollback()
        raise HTTPException(status_code=500, detail=f"同步 sing-box 失败: {sync_result.get('message', '未知错误')}")

    # 记录日志
    log = SystemLog(action="create_user", detail=f"创建用户: {user.username}")
    db.add(log)
    db.commit()

    return {"ok": True, "user_id": user.id, "sync": sync_result}


@app.put("/api/users/{user_id}")
async def update_user(
    user_id: int,
    req: UserUpdate,
    admin: str = Depends(verify_token),
    db: Session = Depends(get_db),
):
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")

    if req.username is not None:
        existing = db.query(User).filter(
            User.username == req.username, User.id != user_id
        ).first()
        if existing:
            raise HTTPException(status_code=400, detail="用户名已存在")
        user.username = req.username

    if req.note is not None:
        user.note = req.note
    if req.enabled is not None:
        user.enabled = req.enabled
    if req.traffic_limit is not None:
        user.traffic_limit = req.traffic_limit
    if req.expire_days is not None:
        if req.expire_days < 0:
            user.expire_at = None
        else:
            user.expire_at = datetime.now(timezone.utc) + timedelta(days=req.expire_days)

    user.updated_at = datetime.now(timezone.utc)
    db.flush()

    sync_result = sync_users_to_singbox(db)
    if not sync_result.get("ok"):
        db.rollback()
        raise HTTPException(status_code=500, detail=f"同步 sing-box 失败: {sync_result.get('message', '未知错误')}")

    return {"ok": True, "sync": sync_result}


@app.delete("/api/users/{user_id}")
async def delete_user(
    user_id: int,
    admin: str = Depends(verify_token),
    db: Session = Depends(get_db),
):
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")

    username = user.username
    db.delete(user)
    db.flush()

    sync_result = sync_users_to_singbox(db)
    if not sync_result.get("ok"):
        db.rollback()
        raise HTTPException(status_code=500, detail=f"同步 sing-box 失败: {sync_result.get('message', '未知错误')}")

    log = SystemLog(action="delete_user", detail=f"删除用户: {username}")
    db.add(log)
    db.commit()

    return {"ok": True, "sync": sync_result}


@app.post("/api/users/{user_id}/toggle")
async def toggle_user(
    user_id: int,
    admin: str = Depends(verify_token),
    db: Session = Depends(get_db),
):
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")

    user.enabled = not user.enabled
    user.updated_at = datetime.now(timezone.utc)
    db.flush()

    sync_result = sync_users_to_singbox(db)
    if not sync_result.get("ok"):
        db.rollback()
        raise HTTPException(status_code=500, detail=f"同步 sing-box 失败: {sync_result.get('message', '未知错误')}")

    return {"ok": True, "enabled": user.enabled, "sync": sync_result}


@app.post("/api/users/{user_id}/reset-traffic")
async def reset_traffic(
    user_id: int,
    admin: str = Depends(verify_token),
    db: Session = Depends(get_db),
):
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")

    user.traffic_used = 0
    user.updated_at = datetime.now(timezone.utc)
    db.flush()

    sync_result = sync_users_to_singbox(db)
    if not sync_result.get("ok"):
        db.rollback()
        raise HTTPException(status_code=500, detail=f"同步 sing-box 失败: {sync_result.get('message', '未知错误')}")

    return {"ok": True, "sync": sync_result}


# ---- 流量历史 ----

@app.get("/api/traffic/daily")
async def traffic_daily(
    admin: str = Depends(verify_token),
    db: Session = Depends(get_db),
    days: int = Query(30, le=365, description="查询天数"),
):
    """按天汇总全局出口流量（最近 N 天）"""
    since = datetime.now(timezone.utc).date() - timedelta(days=days)
    rows = (
        db.query(TrafficLog.log_date, TrafficLog.outbound,
                 func.sum(TrafficLog.upload), func.sum(TrafficLog.download))
        .filter(TrafficLog.log_date >= since)
        .group_by(TrafficLog.log_date, TrafficLog.outbound)
        .order_by(TrafficLog.log_date)
        .all()
    )
    result: dict = {}
    for log_date, outbound, up, down in rows:
        day_str = log_date.isoformat()
        if day_str not in result:
            result[day_str] = {}
        result[day_str][outbound] = {"upload": up or 0, "download": down or 0}

    return {"ok": True, "data": result}


@app.get("/api/traffic/users")
async def traffic_users(
    admin: str = Depends(verify_token),
    db: Session = Depends(get_db),
    days: int = Query(30, le=365),
):
    """按用户汇总流量（最近 N 天）"""
    since = datetime.now(timezone.utc).date() - timedelta(days=days)
    rows = (
        db.query(TrafficLog.user_id,
                 func.sum(TrafficLog.upload), func.sum(TrafficLog.download))
        .filter(TrafficLog.log_date >= since, TrafficLog.user_id.isnot(None))
        .group_by(TrafficLog.user_id)
        .all()
    )
    user_ids = [r[0] for r in rows if r[0]]
    users_map = {}
    if user_ids:
        users = db.query(User).filter(User.id.in_(user_ids)).all()
        users_map = {u.id: u.username for u in users}

    result = []
    for uid, up, down in rows:
        if not uid:
            continue
        result.append({
            "user_id": uid,
            "username": users_map.get(uid, f"已删除({uid})"),
            "upload": up or 0,
            "download": down or 0,
            "total": (up or 0) + (down or 0),
        })
    result.sort(key=lambda x: x["total"], reverse=True)

    return {"ok": True, "data": result}


@app.get("/api/traffic/user/{user_id}")
async def traffic_user_detail(
    user_id: int,
    admin: str = Depends(verify_token),
    db: Session = Depends(get_db),
    days: int = Query(30, le=365),
):
    """单用户流量明细：按天+出口"""
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")

    since = datetime.now(timezone.utc).date() - timedelta(days=days)
    rows = (
        db.query(TrafficLog.log_date, TrafficLog.outbound,
                 TrafficLog.upload, TrafficLog.download)
        .filter(TrafficLog.user_id == user_id, TrafficLog.log_date >= since)
        .order_by(TrafficLog.log_date)
        .all()
    )
    daily: dict = {}
    by_outbound: dict = {}
    for log_date, outbound, up, down in rows:
        day_str = log_date.isoformat()
        up = up or 0
        down = down or 0
        if day_str not in daily:
            daily[day_str] = {"upload": 0, "download": 0}
        daily[day_str]["upload"] += up
        daily[day_str]["download"] += down
        if outbound not in by_outbound:
            by_outbound[outbound] = {"upload": 0, "download": 0}
        by_outbound[outbound]["upload"] += up
        by_outbound[outbound]["download"] += down

    return {
        "ok": True,
        "data": {
            "username": user.username,
            "traffic_used": user.traffic_used,
            "traffic_limit": user.traffic_limit,
            "daily": daily,
            "by_outbound": by_outbound,
        }
    }


# ---- 订阅链接（公开接口，无需认证）----

@app.get("/sub/{token}")
async def subscription(
    token: str,
    type: str = Query("clash", description="clash / base64"),
    db: Session = Depends(get_db),
):
    user = db.query(User).filter(User.sub_token == token).first()
    if not user:
        raise HTTPException(status_code=404, detail="订阅链接无效")

    if not user.enabled:
        raise HTTPException(status_code=403, detail="账户已禁用")

    now = datetime.now(timezone.utc)
    if user.expire_at and user.expire_at.replace(tzinfo=timezone.utc) < now:
        raise HTTPException(status_code=403, detail="账户已过期")

    if user.traffic_limit > 0 and user.traffic_used >= user.traffic_limit:
        raise HTTPException(status_code=403, detail="流量已用尽")

    if type == "clash":
        content = generate_clash_config(user)
        return PlainTextResponse(
            content,
            headers={
                "Content-Disposition": f"attachment; filename={user.username}.yaml",
                "Content-Type": "text/yaml; charset=utf-8",
                "subscription-userinfo": _build_sub_userinfo(user),
                "profile-update-interval": "12",
            }
        )
    elif type == "base64":
        content = generate_base64_links(user)
        return PlainTextResponse(
            content,
            headers={
                "Content-Type": "text/plain; charset=utf-8",
                "subscription-userinfo": _build_sub_userinfo(user),
            }
        )
    else:
        raise HTTPException(status_code=400, detail="不支持的订阅类型，请使用 clash 或 base64")


def _build_sub_userinfo(user: User) -> str:
    """构建 subscription-userinfo header（Clash 等客户端读取）"""
    parts = [f"upload=0", f"download={user.traffic_used}"]
    if user.traffic_limit > 0:
        parts.append(f"total={user.traffic_limit}")
    if user.expire_at:
        ts = int(user.expire_at.replace(tzinfo=timezone.utc).timestamp())
        parts.append(f"expire={ts}")
    return "; ".join(parts)


# ---- 节点状态 ----

@app.get("/api/nodes")
async def get_nodes(admin: str = Depends(verify_token)):
    tunnels = await check_tunnel_health()
    return {"ok": True, "data": tunnels}


@app.post("/api/nodes/health-check")
async def run_health_check(admin: str = Depends(verify_token)):
    tunnels = await check_tunnel_health()
    return {"ok": True, "data": tunnels}


# ---- 系统 ----

@app.post("/api/system/reload")
async def system_reload(admin: str = Depends(verify_token), db: Session = Depends(get_db)):
    sync_result = sync_users_to_singbox(db)
    return {"ok": sync_result.get("ok", False), "sync": sync_result, "message": sync_result.get("message", "")}


@app.post("/api/system/restart")
async def system_restart(admin: str = Depends(verify_token), db: Session = Depends(get_db)):
    try:
        result = subprocess.run(
            ["systemctl", "restart", "sing-box"],
            capture_output=True, text=True, timeout=15
        )
        log = SystemLog(action="restart", detail=f"exit_code={result.returncode}")
        db.add(log)
        db.commit()
        return {"ok": result.returncode == 0, "message": result.stderr or "已重启"}
    except Exception as e:
        return {"ok": False, "message": str(e)}


@app.get("/api/system/logs")
async def system_logs(
    admin: str = Depends(verify_token),
    db: Session = Depends(get_db),
    limit: int = Query(50, le=200),
):
    logs = db.query(SystemLog).order_by(SystemLog.id.desc()).limit(limit).all()
    return {
        "ok": True,
        "data": [
            {
                "id": l.id,
                "action": l.action,
                "detail": l.detail,
                "created_at": l.created_at.isoformat() if l.created_at else None,
            }
            for l in logs
        ]
    }


@app.get("/api/settings")
async def get_settings(admin: str = Depends(verify_token)):
    return {
        "ok": True,
        "data": {
            "ecs_a_ip": settings.ECS_A_IP,
            "ecs_a_name": settings.ECS_A_NAME,
            "ecs_b_ip": settings.ECS_B_IP,
            "ecs_b_name": settings.ECS_B_NAME,
            "reality_public_key": settings.REALITY_PUBLIC_KEY,
            "reality_short_id": settings.REALITY_SHORT_ID,
            "reality_sni": settings.REALITY_SNI,
            "reality_port": settings.REALITY_PORT,
            "hy2_sni": settings.HY2_SNI,
            "sub_base_url": settings.SUB_BASE_URL,
            "vless_port": settings.VLESS_PORT,
            "hy2_port": settings.HY2_PORT,
            "panel_domain": settings.PANEL_DOMAIN,
            "proxy_domain": settings.PROXY_DOMAIN,
            "proxy_domain_a": settings.PROXY_DOMAIN_A,
            "proxy_domain_b": settings.PROXY_DOMAIN_B,
        }
    }


@app.put("/api/settings")
async def update_settings(req: SettingsUpdate, admin: str = Depends(verify_token)):
    """更新面板设置（写入 .env 文件）"""
    env_path = Path(__file__).parent / ".env"
    env_vars = {}

    # 读取现有 .env
    if env_path.exists():
        for line in env_path.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, _, v = line.partition("=")
                env_vars[k.strip()] = v.strip()

    mapping = {
        "ecs_a_ip": "ECS_A_IP", "ecs_a_name": "ECS_A_NAME",
        "ecs_b_ip": "ECS_B_IP", "ecs_b_name": "ECS_B_NAME",
        "reality_public_key": "REALITY_PUBLIC_KEY",
        "reality_short_id": "REALITY_SHORT_ID",
        "reality_sni": "REALITY_SNI",
        "reality_port": "REALITY_PORT",
        "hy2_sni": "HY2_SNI",
        "sub_base_url": "SUB_BASE_URL",
        "panel_domain": "PANEL_DOMAIN",
        "proxy_domain": "PROXY_DOMAIN",
        "proxy_domain_a": "PROXY_DOMAIN_A",
        "proxy_domain_b": "PROXY_DOMAIN_B",
    }

    for field, env_key in mapping.items():
        value = getattr(req, field, None)
        if value is not None:
            env_vars[env_key] = str(value)
            setattr(settings, env_key, value)

    if req.proxy_domain is not None and req.proxy_domain_a is None:
        settings.PROXY_DOMAIN_A = settings.PROXY_DOMAIN
        env_vars["PROXY_DOMAIN_A"] = settings.PROXY_DOMAIN_A

    if req.proxy_domain_a is not None:
        settings.PROXY_DOMAIN = settings.PROXY_DOMAIN_A
        env_vars["PROXY_DOMAIN"] = settings.PROXY_DOMAIN
    elif "PROXY_DOMAIN_A" not in env_vars and "PROXY_DOMAIN" in env_vars:
        env_vars["PROXY_DOMAIN_A"] = env_vars["PROXY_DOMAIN"]

    if req.proxy_domain_b is not None and not settings.PROXY_DOMAIN_B:
        settings.PROXY_DOMAIN_B = settings.PROXY_DOMAIN_A
        env_vars["PROXY_DOMAIN_B"] = settings.PROXY_DOMAIN_B

    # 写回 .env
    lines = [f"# sing-box Panel 配置 (auto-generated)"]
    for k, v in env_vars.items():
        lines.append(f"{k}={v}")
    env_path.write_text("\n".join(lines) + "\n")

    return {"ok": True}


# ---- 证书管理 ----

def _get_cert_info(domain: str) -> dict:
    """读取证书文件，解析有效期等信息"""
    cert_dir = Path(settings.CERT_BASE_DIR) / domain
    cert_file = cert_dir / "fullchain.pem"
    info = {
        "domain": domain,
        "exists": cert_file.exists(),
        "expiry": None,
        "days_left": None,
        "issuer": None,
        "cert_path": str(cert_dir),
        "valid": False,
    }
    if not cert_file.exists():
        return info

    try:
        result = subprocess.run(
            ["openssl", "x509", "-in", str(cert_file), "-noout",
             "-enddate", "-issuer"],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0:
            for line in result.stdout.strip().splitlines():
                if line.startswith("notAfter="):
                    date_str = line.split("=", 1)[1]
                    from email.utils import parsedate_tz, mktime_tz
                    # openssl 输出格式: "Mar 10 12:00:00 2026 GMT"
                    try:
                        expiry = datetime.strptime(date_str.strip(), "%b %d %H:%M:%S %Y %Z")
                    except ValueError:
                        expiry = datetime.strptime(date_str.strip(), "%b  %d %H:%M:%S %Y %Z")
                    info["expiry"] = expiry.isoformat()
                    info["days_left"] = (expiry - datetime.utcnow()).days
                    info["valid"] = info["days_left"] > 0
                elif line.startswith("issuer="):
                    info["issuer"] = line.split("=", 1)[1].strip()
    except Exception:
        pass

    return info


@app.get("/api/certs")
async def list_certs(admin: str = Depends(verify_token)):
    """查看所有域名的证书状态"""
    certs = []
    domains = set()

    # 从设置中收集域名
    if settings.PANEL_DOMAIN:
        domains.add(settings.PANEL_DOMAIN)
    if settings.PROXY_DOMAIN:
        domains.add(settings.PROXY_DOMAIN)

    # 同时扫描证书目录中已有的证书
    cert_base = Path(settings.CERT_BASE_DIR)
    if cert_base.exists():
        for d in cert_base.iterdir():
            if d.is_dir() and (d / "fullchain.pem").exists():
                domains.add(d.name)

    for domain in sorted(domains):
        certs.append(_get_cert_info(domain))

    return {"ok": True, "data": certs}


@app.post("/api/certs/issue")
async def issue_cert(req: CertIssueRequest, admin: str = Depends(verify_token)):
    """签发新证书（调用 cert-manager.sh）"""
    if not req.domain:
        raise HTTPException(status_code=400, detail="域名不能为空")

    cert_mgr = Path(settings.CERT_MANAGER_PATH)
    if not cert_mgr.exists():
        raise HTTPException(status_code=500, detail=f"cert-manager.sh 不存在: {cert_mgr}")

    try:
        result = subprocess.run(
            [str(cert_mgr), "issue", req.domain],
            capture_output=True, text=True, timeout=120
        )
        return {
            "ok": result.returncode == 0,
            "output": result.stdout[-2000:] if result.stdout else "",
            "error": result.stderr[-1000:] if result.stderr else "",
        }
    except subprocess.TimeoutExpired:
        return {"ok": False, "output": "", "error": "签发超时（120s）"}
    except Exception as e:
        return {"ok": False, "output": "", "error": str(e)}


@app.post("/api/certs/renew")
async def renew_cert(
    req: CertIssueRequest,
    admin: str = Depends(verify_token),
):
    """续期证书"""
    cert_mgr = Path(settings.CERT_MANAGER_PATH)
    if not cert_mgr.exists():
        raise HTTPException(status_code=500, detail="cert-manager.sh 不存在")

    try:
        result = subprocess.run(
            [str(cert_mgr), "renew", req.domain],
            capture_output=True, text=True, timeout=120
        )
        return {
            "ok": result.returncode == 0,
            "output": result.stdout[-2000:] if result.stdout else "",
            "error": result.stderr[-1000:] if result.stderr else "",
        }
    except subprocess.TimeoutExpired:
        return {"ok": False, "output": "", "error": "续期超时（120s）"}
    except Exception as e:
        return {"ok": False, "output": "", "error": str(e)}


# ================================================================
#  Entry Point
# ================================================================

if __name__ == "__main__":
    uvicorn.run(
        "app:app",
        host=settings.PANEL_HOST,
        port=settings.PANEL_PORT,
        reload=False,
        access_log=True,
    )
