#!/bin/bash
# 打包可分发的 DMG，并自动递增版本号：
#   bash package.sh            小更新：最新 tag + 0.0.1（手动打包的默认行为，如 1.0.1 → 1.0.2）
#   bash package.sh minor      中型更新：+0.1，补丁位归零（1.0.2 → 1.1.0）
#   bash package.sh major      大型更新：+1，其余归零（1.1.0 → 2.0.0）
#   bash package.sh 1.2.3      直接指定版本
#   bash package.sh --current  不递增，按最新 tag 重新打包（补打丢失的 DMG）
#
# 递增时：工作区必须干净（DMG 必须与已提交的代码一致），HEAD 不能已带版本 tag；
# DMG 打包成功后才在 HEAD 上建本地 tag v<version>（失败不会留下半截 tag），推送由发布流程负责。
# tag 说明可用 KA_TAG_MSG 覆盖，默认 "KeepAliveBar v<version>"。
# 产物：KeepAliveBar-v<version>.dmg（项目根目录，已 gitignore）。
# DMG 里是 KeepAliveBar.app + 指向 /Applications 的快捷方式，拖进去即装好——
# 和 install-app.sh 装的是同一个位置，所以无论哪种方式装/更新，全盘都只有一份 App。
#
# ad-hoc 签名、未经 Apple 公证：用户首次打开需右键「打开」，或 xattr -dr com.apple.quarantine。
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

APP_NAME="KeepAliveBar"
BUMP="${1:-patch}"
# 最新版本取所有 vX.Y.Z tag 里最大的那个，不依赖 HEAD 能否 describe 到。
LATEST="$(git tag -l 'v[0-9]*.[0-9]*.[0-9]*' | sed 's/^v//' | sort -V | tail -1)"
LATEST="${LATEST:-0.0.0}"
IFS=. read -r MAJOR MINOR PATCH <<< "$LATEST"

NEW_TAG=1
case "$BUMP" in
    patch) VERSION="$MAJOR.$MINOR.$((PATCH + 1))" ;;
    minor) VERSION="$MAJOR.$((MINOR + 1)).0" ;;
    major) VERSION="$((MAJOR + 1)).0.0" ;;
    --current) VERSION="$LATEST"; NEW_TAG=0 ;;
    [0-9]*.[0-9]*.[0-9]*) VERSION="$BUMP" ;;
    *) echo "用法: bash package.sh [patch|minor|major|<x.y.z>|--current]" >&2; exit 2 ;;
esac

if [[ "$NEW_TAG" == 1 ]]; then
    if git rev-parse -q --verify "refs/tags/v${VERSION}" >/dev/null; then
        echo "✗ tag v${VERSION} 已存在" >&2; exit 1
    fi
    if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
        echo "✗ 工作区有未提交的改动：先提交，DMG 必须与 tag 指向的代码一致" >&2; exit 1
    fi
    HEAD_TAG="$(git tag --points-at HEAD -l 'v[0-9]*' | head -1)"
    if [[ -n "$HEAD_TAG" ]]; then
        echo "✗ HEAD 已是 ${HEAD_TAG}，没有新提交可发；要重新打包请用 bash package.sh --current" >&2; exit 1
    fi
    echo "==> 版本 v${LATEST} → v${VERSION}（${BUMP}）"
fi
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

if [[ "$NEW_TAG" == 1 ]]; then
    git tag -a "v${VERSION}" -m "${KA_TAG_MSG:-$APP_NAME v${VERSION}}"
    echo "==> 已在 HEAD 建本地 tag v${VERSION}（推送：git push origin v${VERSION}）"
fi
echo "==> 完成: $DMG"
