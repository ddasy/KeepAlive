#!/bin/bash
# 只读：打印当前 5小时/周 用量 + 真实重置时间 + 下次保活预计时间。不发任何消息。
set -uo pipefail
KA_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYCHAIN_SERVICE="${KA_KEYCHAIN_SERVICE:-Claude Code-credentials}"

# Codex 只读本地快照：即使 Claude Keychain 不可用，也先显示 Codex 状态。
codex_line=""
for f in $(find "$HOME/.codex/sessions" -type f -name 'rollout-*.jsonl' -print 2>/dev/null | xargs ls -t 2>/dev/null | head -20); do
  line=$(grep -a 'rate_limits' "$f" 2>/dev/null | tail -1)
  if [ -n "$line" ]; then codex_line="$line"; break; fi
done
echo "── Codex 订阅用量（本地快照）────────────────────────────────"
if [ -n "$codex_line" ]; then
  printf '%s' "$codex_line" | python3 -c '
import json,sys
from datetime import datetime,timezone
try:
    d=json.load(sys.stdin); rl=((d.get("payload") or {}).get("rate_limits") or {})
    # primary/secondary 槽位不固定对应 5h/周——按 window_minutes 判定(≈300=5h, ≈10080=周)。
    # 空闲(仅 hi 保活)快照往往只有周窗口、没有 5h 窗口，此时 5h 那行显示“—”，别把周 reset 当 5h。
    buckets=[b for b in (rl.get("primary"), rl.get("secondary")) if isinstance(b,dict)]
    has_win=any(isinstance(b.get("window_minutes"),(int,float)) for b in buckets)
    def pick(five):
        if not has_win:
            return (rl.get("primary") if five else rl.get("secondary")) or {}
        for b in buckets:
            w=b.get("window_minutes")
            if isinstance(w,(int,float)):
                if five and w<=360: return b
                if (not five) and w>=1440: return b
        return {}
    p=pick(True); s=pick(False)
    def fmt(x):
        if x is None: return "—"
        t=datetime.fromtimestamp(float(x), timezone.utc).astimezone()
        rem=float(x)-datetime.now(timezone.utc).timestamp()
        sign="还剩" if rem >= 0 else "已过"
        h=int(abs(rem)//3600); m=int((abs(rem)%3600)//60)
        return f"{t:%Y-%m-%d %H:%M:%S %Z}（{sign} {h}h{m:02d}m）"
    def cell(b):
        u=b.get("used_percent"); return (str(u)+chr(37)) if u is not None else "—"
    print("  5小时    用量 %7s   重置 %s" % (cell(p), fmt(p.get("resets_at"))))
    print("  周限      用量 %7s   重置 %s" % (cell(s), fmt(s.get("resets_at"))))
    print("  快照时间  %s" % (d.get("timestamp") or "—"))
except Exception:
    print("  快照格式无法识别")'
else
  echo "  暂无 Codex rate_limits 快照（自动激活计时会在 5 小时后发送 hi）"
fi
if [ -f "$KA_HOME/codex-state.json" ]; then
  python3 -c '
import json,sys
try:
    d=json.load(open(sys.argv[1])); f=int(d.get("last_fire",0)); n=int(d.get("no_snapshot_since",0))
    if f: print("  上次自动激活: " + __import__("datetime").datetime.fromtimestamp(f).astimezone().strftime("%Y-%m-%d %H:%M:%S"))
    if n: print("  无时间计时开始: " + __import__("datetime").datetime.fromtimestamp(n).astimezone().strftime("%Y-%m-%d %H:%M:%S"))
except Exception: pass' "$KA_HOME/codex-state.json"
fi
echo "────────────────────────────────────────────────────────────"

token=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin); o=d.get("claudeAiOauth") or d; print(o.get("accessToken",""))
except Exception: print("")')

if [ -z "$token" ]; then echo "❌ 取不到 OAuth token（API-key 用户？或 Keychain 未授权）"; exit 1; fi

curl -s --max-time 20 https://api.anthropic.com/api/oauth/usage \
  -H "Authorization: Bearer $token" \
  -H "anthropic-beta: oauth-2025-04-20" \
  -H "User-Agent: claude-code/2.1" | python3 -c '
import json,sys
from datetime import datetime,timezone
d=json.load(sys.stdin)
now=datetime.now(timezone.utc)
def fmt(iso):
    if not iso: return "—", None
    t=datetime.fromisoformat(iso)
    rem=(t-now).total_seconds()
    loc=t.astimezone()
    sign="还剩" if rem>=0 else "已过"
    h=abs(rem)//3600; m=(abs(rem)%3600)//60
    return f"{loc:%Y-%m-%d %H:%M:%S %Z}  ({sign} {int(h)}h{int(m):02d}m)", rem
def row(name,obj):
    obj=obj or {}
    u=obj.get("utilization")
    s,_=fmt(obj.get("resets_at"))
    print(f"  {name:<16} 用量 {str(u)+chr(37):>7}   重置 {s}")
print("── Claude 订阅用量 ─────────────────────────────────────────")
row("5小时会话", d.get("five_hour"))
row("周·全模型", d.get("seven_day"))
row("周·Opus",  d.get("seven_day_opus"))
row("周·Sonnet",d.get("seven_day_sonnet"))
# 下次保活预计：5h 窗口重置之后 + buffer
fh=d.get("five_hour") or {}
_,rem=fmt(fh.get("resets_at"))
print("────────────────────────────────────────────────────────────")
if rem is None:
    print("  下次保活: 立即（无活动窗口）")
elif rem>0:
    h=rem//3600; m=(rem%3600)//60
    print(f"  下次保活: 约 {int(h)}h{int(m):02d}m 后（当前窗口重置时）")
else:
    print("  下次保活: 立即（窗口已过重置时刻）")
'
