#!/bin/bash
# =============================================================================
# 核心层本地自检（不需要 Xcode / 不需要 SwiftUI 宏插件）
#   SwiftUI 视图只能由 Xcode 编译；这里把「Core + 自检入口」单独用 swiftc 编成一个 CLI，
#   用于在纯 Command Line Tools 环境验证数据层/计算/Excel/PDF。
#   用法： ./tools/check.sh [--keep]
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=".build/combudget-cli"
mkdir -p .build
echo "==> 编译核心层（Core + selfcheck）"
swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 \
  -o "$OUT" \
  $(find Sources/ComBudget/Core -name '*.swift' | sort) \
  tools/selfcheck/SelfTest.swift tools/selfcheck/SampleOutput.swift tools/selfcheck/main.swift

echo "==> 运行自检"
"$OUT" --selftest "$@"
