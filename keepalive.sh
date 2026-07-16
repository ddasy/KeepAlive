#!/bin/bash
# =============================================================================
# Claude Code / Codex 5 小时窗口 · 精确保活 (keep-alive)
# -----------------------------------------------------------------------------
# 原理：
#   1. 读 macOS Keychain 里的 Claude Code OAuth token（服务名 "Claude Code-credentials"）
#   2. GET https://api.anthropic.com/api/oauth/usage  →  拿到 five_hour.resets_at
#      （这是服务端**真实**的 5 小时窗口重置时刻，秒级精确，比 ccusage 的整点取整准）
#   3. 若当前窗口已过重置时刻（窗口已关）→ 发一条极小的 `claude -p` 消息，
#      从而开启一个**全新的 5 小时窗口**；否则什么都不做，等下一次轮询。
#
# 本脚本被 launchd 每隔 KA_INTERVAL 秒调用一次（无状态轮询，睡眠/重启后自愈）。
# 单次运行只读+至多各发一条消息，然后退出。
#
# ⚠️ 前提（2026-07 现状）：Anthropic 曾计划把 `claude -p`/headless 用量从订阅限额里
#    拆出去单独计费，但该改动已于 2026-06-15 被官方暂停 —— 目前 `claude -p` 仍计入
#    订阅的 5 小时+周限额，所以本方案有效。此政策可能变动，见 README。
# =============================================================================

set -uo pipefail

# ---- 配置（可用环境变量覆盖）------------------------------------------------
KA_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 优先用保活专用的固定路径副本（身份不随每日自动更新变 → 钥匙串“始终允许”长期有效，
# 不再每次到期弹版本号授权框）；副本缺失时退化为 PATH 里的 claude。可用 KA_CLAUDE_BIN 覆盖。
CLAUDE_BIN="${KA_CLAUDE_BIN:-}"
if [ -z "$CLAUDE_BIN" ]; then
  if [ -x "$HOME/.local/share/claude/keepalive-claude" ]; then
    CLAUDE_BIN="$HOME/.local/share/claude/keepalive-claude"
  else
    CLAUDE_BIN="$HOME/.local/bin/claude"
  fi
fi
# 保活消息从一个**空目录**发起：避免读入任何目录内容/CLAUDE.md/git 上下文。
# 该目录刻意放在 App Support（而非 ~/Desktop 项目内）——桌面/文稿/下载是 TCC 保护目录，
# 从那里跑 codex(=node 脚本)/claude 会弹“允许访问‘桌面’文件夹”授权框，且它钉在会漂移的
# node/claude 路径上（node 在 /opt/homebrew/Cellar/node/<版本>/bin/node），版本一变旧授权失效→重弹。
# 放到非保护目录后根本不触发该授权。可用 KA_WORKDIR 覆盖。与菜单栏 App 的 workdir 对齐。
KA_WORKDIR="${KA_WORKDIR:-$HOME/Library/Application Support/KeepAliveBar/null}"
KEYCHAIN_SERVICE="${KA_KEYCHAIN_SERVICE:-Claude Code-credentials}"
USAGE_URL="https://api.anthropic.com/api/oauth/usage"
MODEL="${KA_MODEL:-haiku}"          # 用最便宜的模型保活，尽量少占周限额
PROMPT="${KA_PROMPT:-hi}"           # 保活消息内容（越短越好）
BUFFER_SEC="${KA_BUFFER_SEC:-90}"   # 在真实重置时刻之后再等这么久才发（确保旧窗口彻底关闭）
MIN_REFIRE_SEC="${KA_MIN_REFIRE_SEC:-17400}"  # 防抖：两次保活至少间隔 4h50m
# Codex 没有公开的 usage HTTP 接口；从 rollout 日志里的 rate_limits 快照取 reset。
# 没有快照时，先等待 5 小时再用一次 hi 激活，之后按快照的 reset 精确续窗。
CODEX_BIN="${KA_CODEX_BIN:-}"
if [ -z "$CODEX_BIN" ]; then
  for candidate in "$HOME/.local/bin/codex" /opt/homebrew/bin/codex /usr/local/bin/codex; do
    if [ -x "$candidate" ]; then CODEX_BIN="$candidate"; break; fi
  done
fi
CODEX_MODEL="${KA_CODEX_MODEL:-gpt-5.4-mini}"
CODEX_EFFORT="${KA_CODEX_EFFORT:-low}"
CODEX_PROMPT="${KA_CODEX_PROMPT:-hi}"
CODEX_FALLBACK_SEC="${KA_CODEX_FALLBACK_SEC:-18000}"  # 没有 reset 快照时的 5 小时兜底
CODEX_BUFFER_SEC="${KA_CODEX_BUFFER_SEC:-90}"
CODEX_MIN_REFIRE_SEC="${KA_CODEX_MIN_REFIRE_SEC:-17400}"
# 可选：周限额保护——当周用量≥此百分比时不再保活（默认 101=永不触发）
WEEKLY_GUARD_PCT="${KA_WEEKLY_GUARD_PCT:-101}"

LOG="${KA_LOG:-$KA_HOME/keepalive.log}"
STATE="${KA_STATE:-$KA_HOME/state.json}"
CODEX_STATE="${KA_CODEX_STATE:-$KA_HOME/codex-state.json}"

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

read_codex_state() {  # $1=key
  python3 -c '
import json,sys
try:
    d=json.load(open(sys.argv[1])); v=d.get(sys.argv[2],0)
    print(v if v is not None else 0)
except Exception:
    print(0)' "$CODEX_STATE" "$1" 2>/dev/null || echo 0
}

write_codex_state() {  # $1=last_fire $2=last_attempt $3=last_reset $4=no_snapshot_since
  python3 -c '
import json,sys
json.dump({"last_fire":int(float(sys.argv[2] or 0)),
           "last_attempt":int(float(sys.argv[3] or 0)),
           "last_reset":sys.argv[4] or "",
           "no_snapshot_since":int(float(sys.argv[5] or 0))},
          open(sys.argv[1],"w"))
' "$CODEX_STATE" "$1" "$2" "${3:-}" "${4:-0}" 2>/dev/null
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

# ---- Codex 保活：使用 OAuth 登录的非交互 exec，只发送 hi ---------------------
fire_codex_keepalive() {
  if [ -z "$CODEX_BIN" ] || [ ! -x "$CODEX_BIN" ]; then
    log "❌ Codex keep-alive 失败：找不到可执行的 codex（可用 KA_CODEX_BIN 指定）"
    return 127
  fi
  mkdir -p "$KA_WORKDIR" 2>/dev/null
  local out
  # 空目录 + 忽略用户配置/规则 + 只读沙箱，避免加载 MCP、插件和项目上下文。
  # 去掉 OPENAI_API_KEY，确保使用 Codex 登录态而不是 API key 计费。
  # 强制直连 HTTP(responses)、跳过 websocket：codex 默认先连 wss://chatgpt.com/.../responses，
  # 网络不稳时该步常 403/超时才降级，白等一截。内置 openai provider 不可覆盖，故另起自定义 provider：
  # requires_openai_auth=true 复用 ChatGPT 订阅登录态，supports_websockets=false 关掉 websocket。
  out="$(cd "$KA_WORKDIR" && env -u OPENAI_API_KEY -u OPENAI_BASE_URL \
        "$CODEX_BIN" --ask-for-approval never exec --model "$CODEX_MODEL" \
        -c "model_reasoning_effort=$CODEX_EFFORT" \
        -c "model_provider=chatgpt-httponly" \
        -c "model_providers.chatgpt-httponly.name=chatgpt-httponly" \
        -c "model_providers.chatgpt-httponly.base_url=https://chatgpt.com/backend-api/codex" \
        -c "model_providers.chatgpt-httponly.wire_api=responses" \
        -c "model_providers.chatgpt-httponly.requires_openai_auth=true" \
        -c "model_providers.chatgpt-httponly.supports_websockets=false" \
        --cd "$KA_WORKDIR" --skip-git-repo-check --ignore-user-config --ignore-rules \
        --sandbox read-only "$CODEX_PROMPT" 2>&1)"
  local rc=$?
  if [ $rc -eq 0 ]; then
    log "🔔 CODEX FIRED keep-alive (model=$CODEX_MODEL effort=$CODEX_EFFORT) -> 已发送 hi。回复: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-100)"
  else
    log "❌ CODEX keep-alive 失败 rc=$rc: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-180)"
  fi
  return $rc
}

# 找到最新的 Codex rate_limits 快照，输出：状态 / primary reset epoch / 快照时间。
# 每次只检查最近 20 个 rollout，避免历史日志过多时拖慢 launchd 轮询。
codex_snapshot() {
  local f line
  for f in $(find "$HOME/.codex/sessions" -type f -name 'rollout-*.jsonl' -print 2>/dev/null | xargs ls -t 2>/dev/null | head -20); do
    line=$(grep -a 'rate_limits' "$f" 2>/dev/null | tail -1)
    if [ -n "$line" ]; then
      printf '%s' "$line" | python3 -c '
import json,sys
from datetime import datetime
try:
    d=json.load(sys.stdin)
    rl=((d.get("payload") or {}).get("rate_limits") or {})
    # primary/secondary 槽位不固定对应 5h/周——按 window_minutes 判定(≈300=5h, ≈10080=周)。
    # 空闲(仅 hi)快照往往只有周窗口、没有 5h 窗口 → 5h reset 输出空串 → 上层走时间兜底续窗，
    # 绝不能把周 reset 当 5h reset(否则会以为一周后才重置、7 天不续窗)。
    buckets=[b for b in (rl.get("primary"), rl.get("secondary")) if isinstance(b,dict)]
    has_win=any(isinstance(b.get("window_minutes"),(int,float)) for b in buckets)
    five=None
    if has_win:
        for b in buckets:
            w=b.get("window_minutes")
            if isinstance(w,(int,float)) and w<=360:
                five=b; break
    else:
        five=rl.get("primary") or {}
    reset=(five or {}).get("resets_at")
    ep=""
    if reset is not None:
        ep=str(int(float(reset)))
    print("OK")
    print(ep)
    print(d.get("timestamp") or "")
except Exception:
    print("ERR\n\n")'
      return
    fi
  done
  printf 'NONE\n\n\n'
}

maybe_fire_codex() {
  local now="$1"
  local last_fire last_attempt last_reset no_since
  last_fire=$(read_codex_state last_fire)
  last_attempt=$(read_codex_state last_attempt)
  last_reset=$(read_codex_state last_reset)
  no_since=$(read_codex_state no_snapshot_since)

  local parsed status reset_epoch snapshot_at
  parsed=$(codex_snapshot)
  status=$(printf '%s' "$parsed" | sed -n '1p')
  reset_epoch=$(printf '%s' "$parsed" | sed -n '2p')
  snapshot_at=$(printf '%s' "$parsed" | sed -n '3p')

  if [ "$status" = "OK" ] && [ -n "$reset_epoch" ]; then
    # 有快照时使用服务端 reset；恢复正常后清掉“无时间”计时。
    no_since=0
    last_reset="$snapshot_at"
    if [ "$now" -lt $(( reset_epoch + CODEX_BUFFER_SEC )) ]; then
      write_codex_state "$last_fire" "$last_attempt" "$last_reset" "$no_since"
      return 0
    fi
    log "Codex 5 小时窗口已到期 (reset=$snapshot_at) → 准备发送 hi"
  else
    # 没有快照/没有 reset：首次观察先开始计时，满 5 小时才激活。
    if [ "${no_since:-0}" -le 0 ] 2>/dev/null; then
      no_since="$now"
      log "Codex 尚无可用 reset 时间，开始 5 小时激活计时"
    fi
    if [ $(( now - no_since )) -lt "$CODEX_FALLBACK_SEC" ]; then
      write_codex_state "$last_fire" "$last_attempt" "$last_reset" "$no_since"
      return 0
    fi
    log "Codex 已连续 5 小时没有 reset 时间 → 准备发送 hi"
  fi

  # 失败重试退避；成功后至少 4h50m 不会重复发送。
  [ $(( now - last_attempt )) -lt 300 ] && return 0
  [ $(( now - last_fire )) -lt "$CODEX_MIN_REFIRE_SEC" ] && return 0
  write_codex_state "$last_fire" "$now" "$last_reset" "$no_since"
  if fire_codex_keepalive; then
    write_codex_state "$now" "$now" "$last_reset" "$no_since"
  fi
}

# ---- 前置条件：代理是否开启 ------------------------------------------------
# api.anthropic.com 需经代理才可达；未开代理时查 usage / 续窗都会失败或超时，
# 故本次轮询直接跳过。两种模式都算"开启"：
#   1) 系统代理：scutil 里 HTTP / HTTPS / SOCKS 任一 Enable : 1
#   2) 纯 TUN/代理模式：默认路由走某个 utun 口，且该口持有 fake-IP（198.18.0.0/15）
proxy_enabled() {
  if /usr/sbin/scutil --proxy 2>/dev/null \
       | grep -qE '^[[:space:]]*(HTTPEnable|HTTPSEnable|SOCKSEnable)[[:space:]]*:[[:space:]]*1$'; then
    return 0
  fi
  local dev
  dev=$(/sbin/route -n get default 2>/dev/null | awk '/interface:/{print $2}')
  case "$dev" in
    utun*) /sbin/ifconfig "$dev" 2>/dev/null | grep -qE 'inet 198\.(18|19)\.' && return 0 ;;
  esac
  return 1
}

# ============================================================================
now=$(date +%s)
last_fire=$(read_last_fire)

# Codex 与 Claude 独立判断/独立状态；Claude 的代理、Keychain 或 usage 状态不阻塞 Codex。
maybe_fire_codex "$now"

if ! proxy_enabled; then
  # 代理未开启 → 跳过本次（不查用量、不续窗）。保持安静，避免每次轮询刷日志。
  : # log "🛑 代理未开启，跳过本次保活轮询"
  exit 0
fi

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
