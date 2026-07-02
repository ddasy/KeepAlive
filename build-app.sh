#!/bin/bash
# 编译 KeepAliveBar.swift 并打包成 KeepAliveBar.app（菜单栏 Agent，无 Dock 图标）。
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$DIR/KeepAliveBar.app"
BUNDLE_ID="com.iu.keepalivebar"

echo "▶ 清理旧包"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▶ 写 Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>KeepAliveBar</string>
    <key>CFBundleDisplayName</key>     <string>Claude 保活</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>         <string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleExecutable</key>      <string>KeepAliveBar</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

echo "▶ 编译 (swiftc)"
swiftc -O -parse-as-library \
    -target arm64-apple-macos13.0 \
    "$DIR/KeepAliveBar.swift" \
    -o "$APP/Contents/MacOS/KeepAliveBar"

echo "▶ 拷贝资源（Clawd 菜单栏图标 + App 图标）"
cp "$DIR/assets/clawd.png" "$APP/Contents/Resources/clawd.png"
cp "$DIR/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "▶ ad-hoc 签名"
codesign --force --sign - "$APP"

echo "✅ 已生成: $APP"
echo "   启动:   open \"$APP\"   （之后可拖到 /Applications，并在“系统设置▸通用▸登录项”里设为开机启动）"
