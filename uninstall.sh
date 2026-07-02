#!/bin/bash
# 停止并卸载 launchd 保活服务。
set -uo pipefail
LABEL="com.iu.claude-keepalive"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST_DST"
echo "🛑 已停止并卸载：$LABEL"
