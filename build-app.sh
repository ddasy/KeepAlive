#!/bin/bash
# 编译 Sources/KeepAliveBar 并安装到 /Applications/KeepAliveBar.app（菜单栏 Agent，无 Dock 图标）。
#
# 为什么不在项目目录里留 .app：
#   以前 build-app.sh 在项目目录产出一份、install-app.sh 再拷一份到 /Applications，
#   磁盘上就有两个同名 App —— 聚焦搜索并排列出两个一模一样的图标，还容易误点项目里那份，
#   跑出第二个实例（两个都会保活、共用同一份 UserDefaults 和日志）。
#   现在一律在临时目录组包，成功后整包替换到 /Applications，全盘只留一份。
#
# 只想编译试跑、不动已安装的那份：KA_DEST=/tmp/ka/KeepAliveBar.app bash build-app.sh
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/scripts/swift-sources.sh"
DEST="${KA_DEST:-/Applications/KeepAliveBar.app}"
BUNDLE_ID="com.iu.keepalivebar"

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
STAGE="$TMPROOT/KeepAliveBar.app"

echo "▶ 组包（临时目录）"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"

echo "▶ 写 Info.plist"
cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>KeepAliveBar</string>
    <key>CFBundleDisplayName</key>     <string>KeepAliveBar</string>
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
    "${KA_LIBRARY_SOURCES[@]}" "$KA_APP_ENTRY" \
    -o "$STAGE/Contents/MacOS/KeepAliveBar"

echo "▶ 拷贝资源（Clawd 菜单栏图标 + App 图标）"
cp "$DIR/assets/clawd.png" "$STAGE/Contents/Resources/clawd.png"
cp "$DIR/assets/codex.png" "$STAGE/Contents/Resources/codex.png"
cp "$DIR/assets/AppIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns"

echo "▶ ad-hoc 签名"
codesign --force --sign - "$STAGE"
codesign --verify --strict "$STAGE"

# CI / 开发验证：完成编译、资源组包及签名验证，随后由 trap 清理临时包。
if [[ "${KA_VERIFY_ONLY:-0}" == "1" ]]; then
    echo "✅ 构建验证通过（未安装、未启动）"
    exit 0
fi

# 编译签名全部成功后才动已安装的那份：编译失败不会把你正在用的 App 删掉。
echo "▶ 退出旧实例（按完整可执行路径匹配，不会误伤其它进程）"
pkill -f "^$DEST/Contents/MacOS/KeepAliveBar$" 2>/dev/null || true
sleep 1

echo "▶ 替换 $DEST"
mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
mv "$STAGE" "$DEST"

echo "▶ 启动"
open "$DEST"
echo "✅ 已安装并启动: ${DEST}（全盘只此一份）"   # 花括号必须留：紧跟全角括号会被当成变量名的一部分
echo "   要开机自启：bash install-app.sh，或在弹窗里打开「开机自启」开关"
