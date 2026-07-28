#!/bin/bash
# 编译安装 + 设为开机自启（登录项）。
# 安装动作本身在 build-app.sh 里（临时目录组包 → 整包替换 /Applications），
# 全盘只会有一份 KeepAliveBar.app；本脚本只额外做「固定 claude 副本」和「登录项」。
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="/Applications/KeepAliveBar.app"

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

echo "▶ 编译并安装到 $DEST"
KA_DEST="$DEST" bash "$DIR/build-app.sh"

# 先删同名旧登录项再加：否则每跑一次本脚本，「系统设置 ▸ 登录项」里就多出一条重复项。
echo "▶ 设为开机启动（登录项，隐藏）"
osascript -e 'tell application "System Events" to delete (every login item whose name is "KeepAliveBar")' >/dev/null 2>&1 || true
osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"$DEST\", hidden:true}" >/dev/null 2>&1 \
  && echo "  ✅ 已加入登录项（同名旧项已清理）" \
  || echo "  ⚠️ 自动加登录项失败——请到「系统设置 ▸ 通用 ▸ 登录项」手动添加 $DEST"

echo "✅ 完成，菜单栏应出现 Clawd 图标。"
