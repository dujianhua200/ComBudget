#!/bin/bash
# =============================================================================
# ComBudget 打包脚本
#   核心自检（纯 CLT 即可）：  ./build.sh --check
#   打包 .app（需要完整 Xcode）：./build.sh
#   SwiftUI 界面依赖 Xcode 自带的 SwiftUIMacros 插件；只有 Command Line Tools 时
#   无法编译 UI（缺 libSwiftUIMacros.dylib），可用 --check 验证核心层，
#   或走 GitHub Actions（macos-14 runner 自带 Xcode）出包。
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

if [ "${1:-}" = "--check" ]; then
  exec ./tools/check.sh "${@:2}"
fi

if ! xcode-select -p 2>/dev/null | grep -qE "Xcode(_[0-9.]+)?\.app"; then
  echo "⚠️  当前 xcode-select 指向 Command Line Tools，缺少 SwiftUI 宏插件，无法编译界面。"
  echo "    可选："
  echo "      1) sudo xcode-select -s /Applications/Xcode.app   （装好 Xcode 后）"
  echo "      2) ./build.sh --check                              （只验证核心层）"
  echo "      3) 走 .github/workflows/build.yml，在 macOS runner 上出包"
  exit 1
fi

echo "==> 编译 release（arm64）"
swift build -c release

APP="build/ComBudget.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ComBudget "$APP/Contents/MacOS/ComBudget"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
cp data/quota451.sqlite "$APP/Contents/Resources/quota451.sqlite"
cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || codesign --force --sign - "$APP"

echo "==> 产物"
lipo -info "$APP/Contents/MacOS/ComBudget"
echo "完成：$(pwd)/$APP"
echo "运行：open \"$APP\""
