#!/bin/sh
# 前端构建脚本：优先使用 bun，缺失时回退到 npm。
# 应用运行时不需要 Node，仅构建期使用。
set -e

cd "$(dirname "$0")/../frontend"

if command -v bun >/dev/null 2>&1; then
  echo "[build-frontend] 使用 bun"
  bun run build
elif command -v npm >/dev/null 2>&1; then
  echo "[build-frontend] 使用 npm"
  npm run build
else
  echo "[build-frontend] 错误：未找到 bun 或 npm，无法构建前端" >&2
  exit 1
fi
