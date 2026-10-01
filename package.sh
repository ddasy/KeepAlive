#!/bin/bash
# 打包可分发的 DMG：bash package.sh [version]   例如 bash package.sh 1.0.0
#
# 不给版本号时取最近的 vX.Y.Z tag。产物：KeepAliveBar-v<version>.dmg（项目根目录，已 gitignore）。
# DMG 里是 KeepAliveBar.app + 指向 /Applications 的快捷方式，拖进去即装好——
# 和 install-app.sh 装的是同一个位置，所以无论哪种方式装/更新，全盘都只有一份 App。
#
# ad-hoc 签名、未经 Apple 公证：用户首次打开需右键「打开」，或 xattr -dr com.apple.quarantine。
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

APP_NAME="KeepAliveBar"
VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-1.0.0}"
DMG="$DIR/$APP_NAME-v$VERSION.dmg"

# 全程在 $TMPDIR（/var/folders/…）里组包：Spotlight 不索引那里。
# 若在项目目录里留一份 .app，LaunchServices 会把它当成已安装的 App，聚焦/启动台出现两个图标。
WORK="$(mktemp -d)"
trap 'hdiutil detach "$WORK/mnt" -quiet 2>/dev/null || true; rm -rf "$WORK"' EXIT

echo "==> 打包 $APP_NAME v$VERSION"
KA_VERSION="$VERSION" KA_EXPORT="$WORK/out" bash "$DIR/build-app.sh"
APP="$WORK/out/$APP_NAME.app"
ICNS="$DIR/assets/AppIcon.icns"

echo "==> 组装 DMG 内容"
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$ICNS" "$STAGE/.VolumeIcon.icns"   # 挂载后卷的图标

# 不让 Spotlight/LaunchServices 把镜像里的 App 当成已安装：否则拖进 /Applications 后
# 启动台和聚焦里会出现两个 KeepAliveBar（弹出镜像后记录还残留在 LaunchServices 里）。
touch "$STAGE/.metadata_never_index"
mkdir -p "$STAGE/.fseventsd"
touch "$STAGE/.fseventsd/no_log"

# 先建可写镜像以设置卷的自定义图标位，再转成压缩只读镜像。
echo "==> 生成 DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDRW "$WORK/rw.dmg" >/dev/null
mkdir -p "$WORK/mnt"
hdiutil attach "$WORK/rw.dmg" -mountpoint "$WORK/mnt" -nobrowse -noverify -noautoopen >/dev/null
SetFile -a C "$WORK/mnt" 2>/dev/null || echo "   (SetFile 不可用，跳过卷图标)"
hdiutil detach "$WORK/mnt" -quiet
rm -f "$DMG"
hdiutil convert "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null

# 给 .dmg 文件本身设 Finder 图标（「下载」文件夹里看到的那个）。
swift - "$ICNS" "$DMG" <<'SWIFT' || echo "   (DMG 文件图标跳过)"
import AppKit
let a = CommandLine.arguments
guard a.count >= 3, let img = NSImage(contentsOfFile: a[1]) else { exit(1) }
exit(NSWorkspace.shared.setIcon(img, forFile: a[2], options: []) ? 0 : 1)
SWIFT

echo "==> 完成: $DMG"
