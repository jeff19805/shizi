#!/bin/sh
# 克隆后跑一次：让 git 用仓库里的 .githooks（提交前检查 CHANGELOG、版本号 +1）。
set -e
cd "$(dirname "$0")/.."
git config core.hooksPath .githooks
chmod +x .githooks/*
echo "提交钩子已启用（core.hooksPath = .githooks）"
