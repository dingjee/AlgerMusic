#!/bin/sh
# 前端开发服务器启动脚本：优先使用 bun，缺失时回退到 npm。
set -e

cd "$(dirname "$0")/../frontend"

if command -v bun >/dev/null 2>&1; then
  exec bun run dev
elif command -v npm >/dev/null 2>&1; then
  exec npm run dev
else
  echo "[dev-frontend] 错误：未找到 bun 或 npm" >&2
  exit 1
fi
