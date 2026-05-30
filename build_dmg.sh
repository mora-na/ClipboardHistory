#!/bin/bash
set -e

cd "$(dirname "$0")"

APP_NAME="ClipboardHistory"
BUILD_DIR="./build"
SOURCES_DIR="./Sources"

echo "📦 $APP_NAME DMG 打包"
echo "========================================"

# 1. 编译
echo ""
echo "🔨 Step 1/3: 编译..."

rm -rf "$BUILD_DIR/$APP_NAME.app"
mkdir -p "$BUILD_DIR/$APP_NAME.app/Contents/MacOS"

SDK_PATH=$(xcrun --show-sdk-path --sdk macosx 2>/dev/null || echo "")
ARCH=$(uname -m)

swiftc \
    -o "$BUILD_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME" \
    "$SOURCES_DIR/"*.swift \
    -framework AppKit \
    -framework SwiftUI \
    -framework Carbon \
    ${SDK_PATH:+-sdk "$SDK_PATH"} \
    -target "${ARCH}-apple-macosx13.0" \
    -O

cp ./Info.plist "$BUILD_DIR/$APP_NAME.app/Contents/Info.plist"
echo "✅ 编译完成"

# 2. 签名
echo ""
echo "🔐 Step 2/3: 签名..."

CERT=$(security find-identity -v -p codesigning 2>/dev/null | head -1 | sed 's/.*"\(.*\)"/\1/')

if [ -n "$CERT" ]; then
    echo "   证书: $CERT"
    codesign --force --deep --sign "$CERT" "$BUILD_DIR/$APP_NAME.app" 2>&1
else
    echo "   无可用证书，ad-hoc 签名"
    codesign --force --deep --sign - "$BUILD_DIR/$APP_NAME.app" 2>&1
fi
echo "✅ 签名完成"

# 3. 创建 DMG
echo ""
echo "💿 Step 3/3: 创建 DMG..."

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$BUILD_DIR/$APP_NAME.app/Contents/Info.plist" 2>/dev/null || echo "1.0")
DMG_FILE="$BUILD_DIR/$APP_NAME-${VERSION}.dmg"

rm -rf "$BUILD_DIR/dmg_tmp"
mkdir -p "$BUILD_DIR/dmg_tmp"
cp -R "$BUILD_DIR/$APP_NAME.app" "$BUILD_DIR/dmg_tmp/"
ln -sf /Applications "$BUILD_DIR/dmg_tmp/Applications"

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$BUILD_DIR/dmg_tmp" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_FILE" 2>&1 | tail -3

rm -rf "$BUILD_DIR/dmg_tmp"
echo "✅ DMG 创建完成"

echo ""
echo "========================================"
echo "✅ 打包完成!"
ls -lh "$DMG_FILE"
echo ""
echo "安装: open $DMG_FILE"
echo "启动后按 ⌘⇧V 打开剪切板历史窗口"
echo "========================================"
