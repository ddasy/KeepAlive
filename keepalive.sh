#!/bin/bash
# =============================================================================
# Claude Code / Codex 5 小时窗口 · 精确保活 (keep-alive)
# -----------------------------------------------------------------------------
# 原理：
#   1. 读 macOS Keychain 里的 Claude Code OAuth token（服务名 "Claude Code-credentials"）
#   2. GET https://api.anthropic.com/api/oauth/usage  →  拿到 five_hour.resets_at
#      （这是服务端**真实**的 5 小时窗口重置时刻，秒级精确，比 ccusage 的整点取整准）
#   3. 若当前窗口已过重置时刻（窗口已关）→ 直连 POST /v1/messages 发一条极小的推理请求
#      （实测 8 input / 1 output token），从而开启一个**全新的 5 小时窗口**；
#      发完回读 usage 自证确实开出了窗口。**不做自动降级**：直连失效就明确报错并重试，
#      不用 CLI 悄悄补上（否则问题会被掩盖成"一切正常"）。手动退回：KA_CLAUDE_DIRECT=0。
#      窗口没关就什么都不做，等下一次轮询。
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
KEYCHAIN_SERVICE="${KA_KEYCHAIN_SERVICE:-Claude Code-credentials}"
USAGE_URL="https://api.anthropic.com/api/oauth/usage"
MODEL="${KA_MODEL:-haiku}"          # 用最便宜的模型保活，尽量少占周限额
PROMPT="${KA_PROMPT:-Reply OK}"     # 保活消息内容（越短越好）
BUFFER_SEC="${KA_BUFFER_SEC:-90}"   # 在真实重置时刻之后再等这么久才发（确保旧窗口彻底关闭）
MIN_REFIRE_SEC="${KA_MIN_REFIRE_SEC:-17400}"  # 防抖：两次保活至少间隔 4h50m
# Codex 的窗口状态查 GET /backend-api/wham/usage（服务端真值、免费）；该接口不可达时
# 才退回扫 rollout 日志里的 rate_limits 快照，两者都拿不到才用"连续 5 小时"时间兜底。
CODEX_BIN="${KA_CODEX_BIN:-}"
if [ -z "$CODEX_BIN" ]; then
  for candidate in "$HOME/.local/bin/codex" /opt/homebrew/bin/codex /usr/local/bin/codex; do
    if [ -x "$candidate" ]; then CODEX_BIN="$candidate"; break; fi
  done
fi
CODEX_MODEL="${KA_CODEX_MODEL:-gpt-5.4-mini}"
CODEX_EFFORT="${KA_CODEX_EFFORT:-low}"
CODEX_PROMPT="${KA_CODEX_PROMPT:-Reply OK}"
CODEX_FALLBACK_SEC="${KA_CODEX_FALLBACK_SEC:-18000}"  # 没有 reset 快照时的 5 小时兜底
CODEX_BUFFER_SEC="${KA_CODEX_BUFFER_SEC:-90}"
CODEX_MIN_REFIRE_SEC="${KA_CODEX_MIN_REFIRE_SEC:-17400}"
# 可选：周限额保护——当周用量≥此百分比时不再保活（默认 101=永不触发）
WEEKLY_GUARD_PCT="${KA_WEEKLY_GUARD_PCT:-101}"

# ---- 直连保活（默认开启）----------------------------------------------------
# 保活只需要"一条计费到订阅的推理请求"。CLI 会额外背上工具定义、系统提示词、全局
# CLAUDE.md/AGENTS.md、skills 清单等——这些对"开窗"没有任何贡献，却占了 99.9% 的 token。
# 实测（2026-09-06，同机同账号）：
#   Claude  claude -p 'Reply OK' --model haiku  →  22,698 in / 51 out
#           直连 POST /v1/messages              →       8 in /  1 out
#   Codex   codex exec 'Reply OK'               →  13,871 in / 16 out
#           直连 POST /backend-api/.../responses →      14 in / 16 out
# Codex 侧已实证：一条 30 token 的裸 HTTP 请求确实开出完整的新 5 小时窗口
#   （发消息前 reset_at 随时间滚动；发出后立即锚定在"请求时刻+5h"并不再变化）。
# 置 0 可随时手动退回旧的 CLI 写法。注意：**没有自动降级** —— 直连失败或"发了但没开出窗口"
# 时会明确报错并按原节奏重试，好让问题第一时间暴露，而不是被 CLI 补发掩盖。
CLAUDE_DIRECT="${KA_CLAUDE_DIRECT:-1}"
CODEX_DIRECT="${KA_CODEX_DIRECT:-1}"
CLAUDE_API_URL="https://api.anthropic.com/v1/messages"
CLAUDE_API_MODEL="${KA_API_MODEL:-claude-haiku-4-5-20251001}"  # CLI 收别名(haiku)，HTTP 要完整 id
CODEX_RESPONSES_URL="https://chatgpt.com/backend-api/codex/responses"
CODEX_USAGE_URL="https://chatgpt.com/backend-api/wham/usage"   # Codex 版的 /api/oauth/usage，免费、服务端真值

LOG="${KA_LOG:-$KA_HOME/keepalive.log}"
STATE="${KA_STATE:-$KA_HOME/state.json}"
CODEX_STATE="${KA_CODEX_STATE:-$KA_HOME/codex-state.json}"

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

# 每次保活都创建独立的系统临时空目录。调用方在命令结束后立即清理，避免留下
# CLAUDE.md、git 元数据或上一次保活产生的任何文件供后续命令读取。
make_temporary_workdir() {
  /usr/bin/mktemp -d "${TMPDIR:-/tmp}/keepalive.XXXXXX"
}

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
# 旧路径：起一个完整的 claude 会话。仍作为直连失败时的回落，也可用 KA_CLAUDE_DIRECT=0 强制走它。
fire_keepalive_cli() {
  # 从一次性空目录发起，禁用所有 MCP，强制走订阅(OAuth)而非 API key，把上下文压到最小：
  #   - cd 到临时目录 → 无目录列表 / 无本地 CLAUDE.md / 无 git 上下文
  #   - --strict-mcp-config（且不传 --mcp-config）→ 不加载任何 MCP 工具定义
  #   - env -u ANTHROPIC_API_KEY → 确保走订阅额度而非 API 账单
  local workdir
  workdir="$(make_temporary_workdir)" || { log "❌ Claude 保活失败：无法创建临时目录"; return 1; }
  local out
  out="$(trap '/bin/rm -rf -- "$workdir"' EXIT
        cd "$workdir" && env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
        "$CLAUDE_BIN" -p "$PROMPT" --model "$MODEL" --strict-mcp-config 2>&1)"
  local rc=$?
  if [ $rc -eq 0 ]; then
    log "🔔 FIRED keep-alive (CLI, model=$MODEL) -> 已开启新的 5 小时窗口。回复: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-60)"
  else
    log "❌ keep-alive 失败 rc=$rc: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
  fi
  return $rc
}

# 直连一条最小推理请求。用的就是钥匙串里那张订阅 OAuth token（与查 usage 同一张），
# 因此和 claude -p 一样计入订阅的 5h/周限额，只是不再附带工具定义与系统提示词。
# 只回显 HTTP 状态码；响应体里没有需要的信息，也不该进日志。
claude_fire_direct() {  # $1=token → 输出 HTTP 状态码
  curl -s --max-time 30 -o /dev/null -w '%{http_code}' "$CLAUDE_API_URL" \
    -H "Authorization: Bearer $1" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -H "x-app: cli" \
    -H "User-Agent: claude-cli/2.1 (external, cli)" \
    --data-binary "{\"model\":\"$CLAUDE_API_MODEL\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\".\"}]}" \
    2>/dev/null
}

# 回读 five_hour.resets_at 的 epoch（没有活动窗口时接口返回 null → 输出空串）。
claude_window_reset() {  # $1=token
  curl -s --max-time 20 "$USAGE_URL" \
    -H "Authorization: Bearer $1" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "User-Agent: claude-code/2.1" 2>/dev/null | python3 -c '
import json,sys
from datetime import datetime
try:
    ra=(json.load(sys.stdin).get("five_hour") or {}).get("resets_at")
    print(int(datetime.fromisoformat(ra).timestamp()) if ra else "")
except Exception:
    print("")'
}

# 直连 + 自证。**故意不做自动降级**：直连一旦失效，就让它明明白白地失败、每轮重试都刷一条
# ❌ 日志，而不是被 CLI 悄悄补上导致"看起来一切正常、其实早已回到 22,698 tokens"。
# 自证是让问题显形的关键一步：即便 HTTP 200，也要回读 usage 确认 five_hour.resets_at
# 真的落到了未来（= 新窗口已开），没开出来照样算失败。
# 要手动退回旧写法：KA_CLAUDE_DIRECT=0（那是显式开关，不是自动降级）。
fire_keepalive() {
  [ "$CLAUDE_DIRECT" = "1" ] || { fire_keepalive_cli; return $?; }

  local tok; tok="$(get_token)"
  if [ -z "$tok" ]; then
    log "❌ 直连保活失败：取不到 Keychain token（窗口未续，下次轮询重试）"
    return 1
  fi

  local code; code="$(claude_fire_direct "$tok")"
  if [ "$code" != "200" ]; then
    log "❌ 直连保活失败 HTTP ${code:-无响应}（窗口未续，下次轮询重试）"
    return 1
  fi

  # 自证要轮询等待，不能看一眼就下结论：/api/oauth/usage 对新窗口有传播延迟。
  # 实测 2026-09-07 03:31:36 发出请求，03:31:42（6s）时接口仍是 resets_at=null，
  # 到 03:32:48（约 70s）才出现新窗口 08:30:00。只等 3 秒会稳定误报失败。
  # 累计约 125s 仍拿不到未来的 resets_at 才算真失败（下一轮 launchd 轮询在 300s 后，来得及）。
  local reset now2 w
  for w in 5 10 20 30 60; do
    sleep "$w"
    reset="$(claude_window_reset "$tok")"
    now2=$(date +%s)
    if [ -n "$reset" ] && [ "$reset" -gt "$now2" ] 2>/dev/null; then
      log "🔔 FIRED keep-alive (直连 /v1/messages, ~8 tokens) -> 新窗口 reset=$(date -r "$reset" '+%Y-%m-%d %H:%M:%S')"
      return 0
    fi
  done
  log "❌ 直连 HTTP 200 但 125s 内未见新窗口 (resets_at=${reset:-null}) —— 直连开窗可能已失效，需要人工判断；临时退回：KA_CLAUDE_DIRECT=0"
  return 1
}

# ---- Codex 保活：使用 OAuth 登录的非交互 exec，只发送 Reply OK ----------------
fire_codex_keepalive_cli() {
  if [ -z "$CODEX_BIN" ] || [ ! -x "$CODEX_BIN" ]; then
    log "❌ Codex keep-alive 失败：找不到可执行的 codex（可用 KA_CODEX_BIN 指定）"
    return 127
  fi
  local workdir
  workdir="$(make_temporary_workdir)" || { log "❌ Codex 保活失败：无法创建临时目录"; return 1; }
  local out
  # 空目录 + 忽略用户配置/规则 + 只读沙箱，避免加载 MCP、插件和项目上下文。
  # 去掉 OPENAI_API_KEY，确保使用 Codex 登录态而不是 API key 计费。
  # 强制直连 HTTP(responses)、跳过 websocket：codex 默认先连 wss://chatgpt.com/.../responses，
  # 网络不稳时该步常 403/超时才降级，白等一截。内置 openai provider 不可覆盖，故另起自定义 provider：
  # requires_openai_auth=true 复用 ChatGPT 订阅登录态，supports_websockets=false 关掉 websocket。
  out="$(trap '/bin/rm -rf -- "$workdir"' EXIT
        cd "$workdir" && env -u OPENAI_API_KEY -u OPENAI_BASE_URL \
        "$CODEX_BIN" --ask-for-approval never exec --model "$CODEX_MODEL" \
        -c "model_reasoning_effort=$CODEX_EFFORT" \
        -c "model_provider=chatgpt-httponly" \
        -c "model_providers.chatgpt-httponly.name=chatgpt-httponly" \
        -c "model_providers.chatgpt-httponly.base_url=https://chatgpt.com/backend-api/codex" \
        -c "model_providers.chatgpt-httponly.wire_api=responses" \
        -c "model_providers.chatgpt-httponly.requires_openai_auth=true" \
        -c "model_providers.chatgpt-httponly.supports_websockets=false" \
        --cd "$workdir" --skip-git-repo-check --ignore-user-config --ignore-rules \
        --sandbox read-only "$CODEX_PROMPT" 2>&1)"
  local rc=$?
  if [ $rc -eq 0 ]; then
    log "🔔 CODEX FIRED keep-alive (CLI, model=$CODEX_MODEL effort=$CODEX_EFFORT) -> 已发送 Reply OK。回复: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-100)"
  else
    log "❌ CODEX keep-alive 失败 rc=$rc: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-180)"
  fi
  return $rc
}

# ---- Codex 直连：ChatGPT 登录态 + /backend-api/codex/responses ----------------
# token 取自 ~/.codex/auth.json（codex CLI 自己维护、自己轮换）。这里只读不写：
# token 过期 → 直连 401 → 自动回落 CLI，而 CLI 会顺手把 auth.json 刷新好，下次直连又能用。
codex_auth() {  # 输出一行 "access_token account_id"（任一缺失则输出空行）
  python3 -c '
import json,os
try:
    t=json.load(open(os.path.expanduser("~/.codex/auth.json")))["tokens"]
    a,b=t.get("access_token") or "", t.get("account_id") or ""
    print(f"{a} {b}" if a and b else "")
except Exception:
    print("")'
}

# 请求体与 codex CLI 发的完全同构，只是 tools=[]、instructions 换成一句话。
codex_fire_direct() {  # $1=access_token $2=account_id → 输出 HTTP 状态码
  curl -s --max-time 60 -o /dev/null -w '%{http_code}' "$CODEX_RESPONSES_URL" \
    -H "Authorization: Bearer $1" \
    -H "chatgpt-account-id: $2" \
    -H "OpenAI-Beta: responses=experimental" \
    -H "originator: codex_cli_rs" \
    -H "session_id: $(/usr/bin/uuidgen)" \
    -H "content-type: application/json" \
    -H "accept: text/event-stream" \
    --data-binary "{\"model\":\"$CODEX_MODEL\",\"instructions\":\"Reply OK.\",\"input\":[{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"hi\"}]}],\"tools\":[],\"tool_choice\":\"auto\",\"parallel_tool_calls\":false,\"reasoning\":{\"effort\":\"$CODEX_EFFORT\",\"summary\":\"auto\"},\"store\":false,\"stream\":true,\"include\":[]}" \
    2>/dev/null
}

# 查 wham/usage，输出三行：状态(OPEN|CLOSED|ERR) / primary reset epoch / used_percent
#
# ⚠️ 关键语义：**空闲时 reset_at 是滚动的"此刻 + 窗口长度"**，不是一个已锚定的窗口末端。
#    实测（2026-09-06 23:13）：窗口刚重置、无任何用量时两次读数都是 reset_after_seconds=18000；
#    发出一条请求后立刻变成 17991 → 17972，且 reset_at 的绝对值固定不动 = 窗口被锚定在请求时刻。
#    所以判据是 reset_after_seconds 是否已明显小于窗口总长：
#      reset_after < limit_window - 5  → OPEN  （窗口已锚定，reset epoch 可信）
#      否则                            → CLOSED（当前没有活动窗口，该开火了）
#    若把滚动值当成"窗口开着"，保活会永远不触发——这是本函数最容易踩的坑。
codex_usage_remote() {  # $1=access_token $2=account_id
  curl -s --max-time 20 "$CODEX_USAGE_URL" \
    -H "Authorization: Bearer $1" \
    -H "chatgpt-account-id: $2" \
    -H "originator: codex_cli_rs" 2>/dev/null | python3 -c '
import json,sys
try:
    p=json.load(sys.stdin)["rate_limit"]["primary_window"]
    after=float(p["reset_after_seconds"]); win=float(p["limit_window_seconds"])
    print("OPEN" if after < win - 5 else "CLOSED")
    print(int(p["reset_at"]))
    print(p.get("used_percent",""))
except Exception:
    print("ERR"); print(""); print("")'
}

# 直连 + 自证，逻辑与 Claude 侧一致，同样**不做自动降级**（见 fire_keepalive 注释）。
# 注意：codex 的 token 由 CLI 维护，过期后直连会 401。因为不再自动回落到 CLI，
# 也就不会顺手把 auth.json 刷新好 —— 401 会持续刷日志直到你自己跑一次 codex 或重新登录。
# 这是刻意的：宁可吵，也不要"看起来正常"。
fire_codex_keepalive() {
  [ "$CODEX_DIRECT" = "1" ] || { fire_codex_keepalive_cli; return $?; }

  local auth at acc
  auth="$(codex_auth)"; at="${auth%% *}"; acc="${auth##* }"
  if [ -z "$auth" ] || [ -z "$at" ] || [ -z "$acc" ]; then
    log "❌ Codex 直连失败：~/.codex/auth.json 里没有可用登录态（窗口未续）"
    return 1
  fi

  local code; code="$(codex_fire_direct "$at" "$acc")"
  if [ "$code" != "200" ]; then
    log "❌ Codex 直连失败 HTTP ${code:-无响应}（窗口未续；401 多半是登录态过期，跑一次 codex 或重新登录即可）"
    return 1
  fi

  # 同样轮询等待。第一次 sleep 还兼作"让 reset_after 明显偏离窗口总长"，好判定锚定。
  # wham/usage 实测比 Claude 的 usage 快得多（发完 10s 就已锚定），但仍留出重试余量。
  local parsed st ep w
  for w in 8 15 30; do
    sleep "$w"
    parsed="$(codex_usage_remote "$at" "$acc")"
    st=$(printf '%s' "$parsed" | sed -n 1p)
    ep=$(printf '%s' "$parsed" | sed -n 2p)
    if [ "$st" = "OPEN" ] && [ -n "$ep" ]; then
      log "🔔 CODEX FIRED keep-alive (直连 responses, ~30 tokens) -> 新窗口 reset=$(date -r "$ep" '+%Y-%m-%d %H:%M:%S')"
      return 0
    fi
  done
  log "❌ Codex 直连 HTTP 200 但 53s 内未见新窗口 (状态=$st) —— 直连开窗可能已失效，需要人工判断；临时退回：KA_CODEX_DIRECT=0"
  return 1
}

# 输出三行：状态(OPEN|CLOSED|NONE) / primary reset epoch / 来源说明。
#   OPEN   = 确有活动 5h 窗口，第二行是它真实的重置时刻
#   CLOSED = 服务端明确当前没有活动窗口 → 该开火
#   NONE   = 取不到状态（离线/未登录）→ 由上层退回"连续 5 小时"时间兜底
# 优先问 wham/usage（服务端真值、免费、无需 codex 跑过）；拿不到才退回扫 rollout 日志。
codex_snapshot() {
  if [ "$CODEX_DIRECT" = "1" ]; then
    local auth at acc parsed st ep
    auth="$(codex_auth)"; at="${auth%% *}"; acc="${auth##* }"
    if [ -n "$auth" ] && [ -n "$at" ] && [ -n "$acc" ]; then
      parsed="$(codex_usage_remote "$at" "$acc")"
      st=$(printf '%s' "$parsed" | sed -n 1p)
      ep=$(printf '%s' "$parsed" | sed -n 2p)
      if [ "$st" = "OPEN" ] || [ "$st" = "CLOSED" ]; then
        printf '%s\n%s\nwham/usage\n' "$st" "$ep"
        return
      fi
    fi
  fi
  codex_snapshot_rollout
}

# 离线兜底：扫最近 20 个 rollout 里最后一条 rate_limits。
# 只能给出 OPEN/NONE——本地日志无法区分"窗口关着"和"没记录"，那一路交给时间兜底。
codex_snapshot_rollout() {
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
    # 空闲（仅 Reply OK）快照往往只有周窗口、没有 5h 窗口 → 5h reset 输出空串 → 上层走时间兜底续窗，
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
    print("OPEN" if ep else "NONE")
    print(ep)
    print("rollout " + (d.get("timestamp") or ""))
except Exception:
    print("NONE\n\n")'
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

  local parsed status reset_epoch source
  parsed=$(codex_snapshot)
  status=$(printf '%s' "$parsed" | sed -n '1p')
  reset_epoch=$(printf '%s' "$parsed" | sed -n '2p')
  source=$(printf '%s' "$parsed" | sed -n '3p')

  if [ "$status" = "OPEN" ] && [ -n "$reset_epoch" ]; then
    # 有活动窗口：用服务端 reset；恢复正常后清掉“无时间”计时。
    no_since=0
    last_reset="$source"
    if [ "$now" -lt $(( reset_epoch + CODEX_BUFFER_SEC )) ]; then
      write_codex_state "$last_fire" "$last_attempt" "$last_reset" "$no_since"
      return 0
    fi
    log "Codex 5 小时窗口已到期 (reset=$(date -r "$reset_epoch" '+%H:%M:%S') via $source) → 准备发送 Reply OK"
  elif [ "$status" = "CLOSED" ]; then
    # 服务端明确当前没有活动窗口（reset_at 还在随时间滚动）→ 直接开火，不必再等 5 小时。
    no_since=0
    last_reset="$source"
    log "Codex 当前无活动 5 小时窗口 (via $source) → 准备发送 Reply OK"
  else
    # 取不到状态（离线/未登录）：首次观察先开始计时，满 5 小时才激活。
    if [ "${no_since:-0}" -le 0 ] 2>/dev/null; then
      no_since="$now"
      log "Codex 尚无可用 reset 时间，开始 5 小时激活计时"
    fi
    if [ $(( now - no_since )) -lt "$CODEX_FALLBACK_SEC" ]; then
      write_codex_state "$last_fire" "$last_attempt" "$last_reset" "$no_since"
      return 0
    fi
    log "Codex 已连续 5 小时没有 reset 时间 → 准备发送 Reply OK"
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
