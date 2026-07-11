#!/bin/bash
# 可选：把 App 装到 /Applications 并设为开机自启（登录项）。
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="/Applications/KeepAliveBar.app"

[ -d "$DIR/KeepAliveBar.app" ] || bash "$DIR/build-app.sh"

# 生成/刷新保活专用的固定路径 claude 副本：身份不随每日自动更新变，
# 让钥匙串“始终允许”长期生效，避免每次到期弹版本号授权框。
PINNED="$HOME/.local/share/claude/keepalive-claude"
SRC="$(readlink -f "$HOME/.local/bin/claude" 2>/dev/null || true)"
if [ -n "$SRC" ] && [ -x "$SRC" ]; then
  if [ ! -x "$PINNED" ]; then
    echo "▶ 生成保活专用固定副本 keepalive-claude（源：$SRC）"
    cp -p "$SRC" "$PINNED" && echo "  ✅ $PINNED"
  else
    echo "▶ 保活固定副本已存在，跳过（如需升级：rm '$PINNED' 后重跑本脚本，再在下次到期点一次“始终允许”）"
  fi
else
  echo "  ⚠️ 未找到 ~/.local/bin/claude，跳过固定副本；保活会退化为 PATH 里的 claude（会恢复每次弹框）"
fi

echo "▶ 复制到 /Applications"
rm -rf "$DEST"
cp -R "$DIR/KeepAliveBar.app" "$DEST"

echo "▶ 设为开机启动（登录项，隐藏）"
osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"$DEST\", hidden:true}" >/dev/null 2>&1 \
  && echo "  ✅ 已加入登录项" \
  || echo "  ⚠️ 自动加登录项失败——请到「系统设置 ▸ 通用 ▸ 登录项」手动添加 $DEST"

echo "▶ 启动"
open "$DEST"
echo "✅ 完成，菜单栏应出现 ⚡︎ 图标。（若之前从项目目录启动过，先在其菜单里点“退出”避免两个实例）"
