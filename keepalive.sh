#!/bin/bash
# =============================================================================
# Claude Code 5 小时窗口 · 精确保活 (keep-alive)
# -----------------------------------------------------------------------------
# 原理：
#   1. 读 macOS Keychain 里的 Claude Code OAuth token（服务名 "Claude Code-credentials"）
#   2. GET https://api.anthropic.com/api/oauth/usage  →  拿到 five_hour.resets_at
#      （这是服务端**真实**的 5 小时窗口重置时刻，秒级精确，比 ccusage 的整点取整准）
#   3. 若当前窗口已过重置时刻（窗口已关）→ 发一条极小的 `claude -p` 消息，
#      从而开启一个**全新的 5 小时窗口**；否则什么都不做，等下一次轮询。
#
# 本脚本被 launchd 每隔 KA_INTERVAL 秒调用一次（无状态轮询，睡眠/重启后自愈）。
# 单次运行只读+至多发一条消息，然后退出。
#
# ⚠️ 前提（2026-07 现状）：Anthropic 曾计划把 `claude -p`/headless 用量从订阅限额里
#    拆出去单独计费，但该改动已于 2026-06-15 被官方暂停 —— 目前 `claude -p` 仍计入
#    订阅的 5 小时+周限额，所以本方案有效。此政策可能变动，见 README。
# =============================================================================

set -uo pipefail

# ---- 配置（可用环境变量覆盖）------------------------------------------------
KA_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_BIN="${KA_CLAUDE_BIN:-$HOME/.local/bin/claude}"
# 保活消息从这个**项目内空目录**发起：避免读入任何目录内容/CLAUDE.md/git 上下文
KA_WORKDIR="${KA_WORKDIR:-$KA_HOME/null}"
KEYCHAIN_SERVICE="${KA_KEYCHAIN_SERVICE:-Claude Code-credentials}"
USAGE_URL="https://api.anthropic.com/api/oauth/usage"
MODEL="${KA_MODEL:-haiku}"          # 用最便宜的模型保活，尽量少占周限额
PROMPT="${KA_PROMPT:-hi}"           # 保活消息内容（越短越好）
BUFFER_SEC="${KA_BUFFER_SEC:-90}"   # 在真实重置时刻之后再等这么久才发（确保旧窗口彻底关闭）
MIN_REFIRE_SEC="${KA_MIN_REFIRE_SEC:-17400}"  # 防抖：两次保活至少间隔 4h50m
# 可选：周限额保护——当周用量≥此百分比时不再保活（默认 101=永不触发）
WEEKLY_GUARD_PCT="${KA_WEEKLY_GUARD_PCT:-101}"

LOG="$KA_HOME/keepalive.log"
STATE="$KA_HOME/state.json"

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

# ---- 取 OAuth access token（只放进变量，绝不写日志）--------------------------
get_token() {
  security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin); o=d.get("claudeAiOauth") or d
    print(o.get("accessToken",""))
except Exception:
    print("")'
}

# ---- 读状态 ----------------------------------------------------------------
read_last_fire() {
  python3 -c '
import json,sys
try:
    print(int(json.load(open(sys.argv[1])).get("last_fire",0)))
except Exception:
    print(0)' "$STATE" 2>/dev/null || echo 0
}

write_state() {  # $1=last_fire_epoch  $2=last_reset_iso
  python3 -c '
import json,sys
json.dump({"last_fire":int(sys.argv[2]),"last_reset":sys.argv[3]}, open(sys.argv[1],"w"))
' "$STATE" "$1" "${2:-}" 2>/dev/null
}

# ---- 发保活消息（开启新窗口）------------------------------------------------
fire_keepalive() {
  # 从空目录发起，禁用所有 MCP，强制走订阅(OAuth)而非 API key，把上下文压到最小：
  #   - cd 到 KA_WORKDIR（空目录）→ 无目录列表 / 无本地 CLAUDE.md / 无 git 上下文
  #   - --strict-mcp-config（且不传 --mcp-config）→ 不加载任何 MCP 工具定义
  #   - env -u ANTHROPIC_API_KEY → 确保走订阅额度而非 API 账单
  mkdir -p "$KA_WORKDIR" 2>/dev/null
  local out
  out="$(cd "$KA_WORKDIR" && env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
        "$CLAUDE_BIN" -p "$PROMPT" --model "$MODEL" --strict-mcp-config 2>&1)"
  local rc=$?
  if [ $rc -eq 0 ]; then
    log "🔔 FIRED keep-alive (model=$MODEL) -> 已开启新的 5 小时窗口。回复: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-60)"
  else
    log "❌ keep-alive 失败 rc=$rc: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
  fi
  return $rc
}

# ============================================================================
now=$(date +%s)
last_fire=$(read_last_fire)

token=$(get_token)
if [ -z "$token" ]; then
  # 拿不到 token（可能是 API-key 用户 / Keychain 未授权）→ 退化为纯时间间隔模式
  if [ $(( now - last_fire )) -ge $(( 18000 + BUFFER_SEC )) ]; then
    log "⚠️  无法读取 usage（Keychain 取 token 失败）→ 按 5h 间隔兜底保活"
    fire_keepalive && write_state "$now" ""
  fi
  exit 0
fi

# ---- 查 usage ---------------------------------------------------------------
resp=$(curl -s --max-time 20 "$USAGE_URL" \
        -H "Authorization: Bearer $token" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "User-Agent: claude-code/2.1")

parsed=$(printf '%s' "$resp" | python3 -c '
import json,sys
from datetime import datetime,timezone
try:
    d=json.load(sys.stdin)
    fh=d.get("five_hour") or {}
    sd=d.get("seven_day") or {}
    ra=fh.get("resets_at")
    ep=""
    if ra:
        ep=str(int(datetime.fromisoformat(ra).timestamp()))
    print("OK")
    print(ep)                                  # five_hour reset epoch ("" 若无)
    print(fh.get("utilization",""))            # 5h 用量%
    print(sd.get("utilization",""))            # 周 用量%
    print(ra or "")                            # reset iso 原文
except Exception as e:
    print("ERR"); print(""); print(""); print(""); print("")')

status=$(printf '%s' "$parsed" | sed -n 1p)
reset_epoch=$(printf '%s' "$parsed" | sed -n 2p)
five_util=$(printf '%s' "$parsed" | sed -n 3p)
seven_util=$(printf '%s' "$parsed" | sed -n 4p)
reset_iso=$(printf '%s' "$parsed" | sed -n 5p)

if [ "$status" != "OK" ]; then
  # API 异常 → 时间间隔兜底
  if [ $(( now - last_fire )) -ge $(( 18000 + BUFFER_SEC )) ]; then
    log "⚠️  usage 接口异常 → 按 5h 间隔兜底保活"
    fire_keepalive && write_state "$now" ""
  fi
  exit 0
fi

# ---- 周限额保护 -------------------------------------------------------------
if [ -n "$seven_util" ]; then
  # 用整数比较（去掉小数）
  su_int=${seven_util%.*}
  if [ "${su_int:-0}" -ge "$WEEKLY_GUARD_PCT" ] 2>/dev/null; then
    log "⏸  周用量 ${seven_util}% ≥ ${WEEKLY_GUARD_PCT}% → 暂停保活（省额度）"
    exit 0
  fi
fi

# ---- 决策：窗口是否已关？----------------------------------------------------
should_fire=0
if [ -z "$reset_epoch" ]; then
  # 没有窗口信息 → 建立一个（受防抖约束）
  [ $(( now - last_fire )) -ge "$MIN_REFIRE_SEC" ] && should_fire=1
elif [ "$now" -ge $(( reset_epoch + BUFFER_SEC )) ]; then
  # 已过真实重置时刻 → 窗口已关，可开新窗口（受防抖约束）
  [ $(( now - last_fire )) -ge "$MIN_REFIRE_SEC" ] && should_fire=1
else
  # 窗口仍开着（reset 在未来）→ 等待，不打扰
  should_fire=0
fi

if [ "$should_fire" -eq 1 ]; then
  log "窗口已关 (5h用量=${five_util}% 周用量=${seven_util}% 上个reset=${reset_iso}) → 触发保活"
  if fire_keepalive; then
    write_state "$now" "$reset_iso"
  fi
else
  # 安静运行；如需观察可解除下面注释
  : # log "窗口开启中，reset@${reset_iso}（5h=${five_util}% 周=${seven_util}%），跳过"
fi
