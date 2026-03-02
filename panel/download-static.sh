#!/usr/bin/env bash
set -euo pipefail

# 下载面板前端依赖到 static/ 目录（在 ECS 上执行，无墙）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATIC_DIR="${SCRIPT_DIR}/static"
mkdir -p "$STATIC_DIR"

echo "下载 Tailwind CSS Play CDN..."
curl -fsSL "https://cdn.tailwindcss.com" -o "$STATIC_DIR/tailwind.min.js"

echo "下载 Alpine.js..."
curl -fsSL "https://cdn.jsdelivr.net/npm/alpinejs@3.14.8/dist/cdn.min.js" -o "$STATIC_DIR/alpine.min.js"

echo "下载 QRCode Generator..."
curl -fsSL "https://cdn.jsdelivr.net/npm/qrcode-generator@1.4.4/qrcode.min.js" -o "$STATIC_DIR/qrcode.min.js"

echo "下载 Google Fonts (Inter + JetBrains Mono)..."
curl -fsSL "https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&family=JetBrains+Mono:wght@400;500&display=swap" -o "$STATIC_DIR/fonts.css"

# 下载字体文件并替换 CSS 中的 URL 为本地路径
grep -oP 'url\(\K[^)]+' "$STATIC_DIR/fonts.css" | while read -r url; do
    filename=$(echo "$url" | sed 's|.*/||')
    echo "  下载字体: $filename"
    curl -fsSL "$url" -o "$STATIC_DIR/$filename" 2>/dev/null || true
    sed -i "s|$url|/static/$filename|g" "$STATIC_DIR/fonts.css" 2>/dev/null || true
done

echo ""
echo "完成！所有静态文件已保存到: $STATIC_DIR"
ls -lh "$STATIC_DIR"
