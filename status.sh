#!/bin/bash
# 只读：打印当前 5小时/周 用量 + 真实重置时间 + 下次保活预计时间。不发任何消息。
set -uo pipefail
KA_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYCHAIN_SERVICE="${KA_KEYCHAIN_SERVICE:-Claude Code-credentials}"

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
