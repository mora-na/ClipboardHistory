#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="ClipboardHistory"
BUILD_DIR="$PROJECT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"

echo "🔨 开始构建 $APP_NAME..."

# 清理旧构建
rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# 获取 SDK 路径
SDK_PATH=$(xcrun --show-sdk-path --sdk macosx 2>/dev/null || echo "")

# 构架参数
ARCH=$(uname -m)
TARGET="${ARCH}-apple-macosx13.0"

# 编译 Swift 源文件
echo "📦 编译源文件..."
if [ -n "$SDK_PATH" ]; then
    SDK_FLAG="-sdk $SDK_PATH"
else
    SDK_FLAG=""
fi

swiftc \
    -o "$MACOS_DIR/$APP_NAME" \
    "$PROJECT_DIR/Sources/"*.swift \
    -framework AppKit \
    -framework SwiftUI \
    -framework Carbon \
    -framework ApplicationServices \
    $SDK_FLAG \
    -target "$TARGET" \
    -O

echo "✅ 编译完成"

# 复制 Info.plist
cp "$PROJECT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Ad-hoc 签名（避免 macOS Gatekeeper 警告）
echo "🔐 签名..."
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || echo "⚠️  签名失败，应用仍可使用"

echo ""
echo "✅ 构建成功!"
echo "📂 应用路径: $APP_BUNDLE"
echo ""
echo "运行方式:"
echo "  open $APP_BUNDLE"
echo ""
echo "启动后按 ⌘⇧V 打开剪切板历史窗口"
echo "自动粘贴功能需要授予辅助功能权限（系统偏好设置 → 隐私与安全性 → 辅助功能）"
