#!/bin/bash
# 安装并启动 launchd 保活服务（LaunchAgent，随登录自动运行）。
set -euo pipefail
KA_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.iu.claude-keepalive"
PLIST_SRC="$KA_HOME/$LABEL.plist"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"

chmod +x "$KA_HOME/keepalive.sh" "$KA_HOME/status.sh"

mkdir -p "$HOME/Library/LaunchAgents"
# 把占位符替换成真实路径后写入
sed -e "s|__KA_HOME__|$KA_HOME|g" -e "s|__HOME__|$HOME|g" "$PLIST_SRC" > "$PLIST_DST"

# 若已加载则先卸载
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"
launchctl enable "gui/$(id -u)/$LABEL" 2>/dev/null || true

echo "✅ 已安装并启动：$LABEL"
echo "   plist: $PLIST_DST"
echo "   日志:  $KA_HOME/keepalive.log"
echo
echo "查看状态:   bash $KA_HOME/status.sh"
echo "查看是否在跑: launchctl list | grep claude-keepalive"
echo "停止卸载:   bash $KA_HOME/uninstall.sh"
