<div align="center">

# 🕒 KeepAliveBar

**A macOS menu bar app that keeps your Claude Code and Codex 5-hour windows alive — and shows the quota you have left, right in the menu bar.**

*Never sit down to a fresh 5-hour clock again: your windows are already open, and you can see exactly how much is left before you type a word.*

**English** · [简体中文](README.zh-CN.md)

![platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)
![language](https://img.shields.io/badge/built%20with-Swift-orange)
![license](https://img.shields.io/badge/license-MIT-green)
![tokens](https://img.shields.io/badge/keepalive%20cost-8%20tokens-success)

</div>

---

## What is this?

Claude Code and Codex subscriptions both meter you in **5-hour windows**. The window opens on your *first* message and closes five hours later, whether or not you used any of it. Walk away for an evening, come back at 22:00, send one message — and you have just burned a brand-new 5-hour window on a ten-minute task.

**KeepAliveBar** fixes both halves of that problem from your menu bar:

- It watches the **server's own reset timestamp** for each side and, the moment a window closes, sends one tiny message to open the next one. Your windows keep rolling while you sleep, so the window you walk into is already several hours old — not one you just started.
- It puts **how much quota you have left** in the menu bar. No `/usage`, no guessing: 5-hour and weekly usage for both Claude and Codex, plus the exact reset time, one glance away.
- With **cross keepalive**, you decide how far apart the two sides' windows sit — up to **2.5 hours**, exactly antiphase. Whichever tool you pick up, its window is already open and mid-flight.

The keepalive message is a **direct HTTP inference request** on your existing subscription credentials: **8 tokens** for Claude, ~30 for Codex — not the 22,698 / 13,871 a full `claude -p` / `codex exec` round trip costs.

## ✨ Features

- 📊 **Quota in the menu bar** — a live countdown to Claude's next 5-hour reset plus a usage bar, with an optional icon-only mode when you want it quiet.
- 🖱️ **Hover snapshot** — rest the pointer on the icon for 0.8 s and a read-only card drops out beneath it: Claude and Codex, 5-hour and weekly. **It sends no requests** — it just draws what's already in memory, with an "as of" line at the bottom.
- 🎯 **Server-truth precision** — reads the same endpoints the official clients use (`/api/oauth/usage` for Claude, `/backend-api/wham/usage` for Codex). No guessing at 5-hour offsets, no `ccusage`-style hour rounding that can be off by ~an hour.
- 🪶 **8-token keepalive** — a direct `POST /v1/messages` instead of a CLI round trip, so the message that opens your window costs essentially nothing against your weekly limit.
- ✅ **It proves it worked** — after every fire, it polls usage back until the new window actually appears. If it didn't, it says so loudly and retries. It deliberately **never silently falls back to the CLI**, because a silent fallback would hide a broken fast path behind 22,698-token requests.
- ↔️ **Cross keepalive** — keep the two windows staggered by a threshold you choose (30–145 min in 5-minute steps), or pick **Centered** to hold them ~150 minutes apart, the exact midpoint of two 5-hour cycles. The later side simply waits instead of firing early.
- 🔀 **Independent switches** — Claude keepalive and Codex keepalive are separate toggles; run one, the other, or both.
- ⏱️ **Tightened polling when it matters** — Codex anchors its window to the *message* moment, so every second late is a second lost. Polling drops from 5 minutes to 20 seconds as the deadline approaches, cutting the average loss from ~2.5 min to ~10 s. Claude's windows align to the half hour, so it doesn't need the rush.
- 🛡️ **Weekly-limit gate** — when the weekly quota is exhausted, keepalive stops instead of hammering a wall every few minutes, and resumes automatically after the weekly reset. The popover tells you why it's paused.
- 🔑 **Login-expiry warning** — shows the keychain's `refreshTokenExpiresAt`, warns 3 days ahead, and puts a `⚠︎` in the menu bar (kept even when the countdown is hidden) so a silently expired login doesn't quietly stop everything.
- 🎛️ **A menu bar you arrange** — reorder or hide individual controls, choose automatic or manual ordering of the Claude/Codex cards, and tune the menu-bar usage bar's fill and track opacity. Everything persists across restarts.
- 🤖 **Headless mode too** — prefer no UI? The same logic runs as a launchd agent (`keepalive.sh`), stateless and self-healing across sleep and reboot, with a read-only `status.sh` panel.

## 📸 Screenshots

| Popover — usage & keepalive | Hover snapshot (sends nothing) |
|:---:|:---:|
| ![KeepAliveBar popover showing Claude and Codex 5-hour and weekly usage](screenshots/popover.png) | ![KeepAliveBar hover snapshot of Claude and Codex quota](screenshots/hover.png) |

The menu bar itself carries the live countdown to the next reset (`1h20m`) with a usage bar underneath. The popover stacks Claude and Codex — 5-hour and weekly percentages, exact reset times, time remaining, and Claude's login expiry — then the cross-keepalive summary: the target spacing (`Centered ≈2h30m`), the spacing actually achieved right now (`2h 30m`), and the last fire time for each side.

<div align="center">
  <img src="screenshots/settings.png" alt="KeepAliveBar settings: control visibility, keepalive switches, menu bar progress bar" width="360">
</div>

Settings expand in place beneath the main view: hidden controls keep working and are checked back into their original place above, each control can be shown or hidden individually, and the menu bar progress bar's colors are tunable.

## 🚀 Installation

### Option 1 — Menu bar app (recommended)

```bash
git clone https://github.com/ddasy/KeepAlive.git
cd KeepAlive
bash install-app.sh
```

`install-app.sh` compiles the app, installs it as `/Applications/KeepAliveBar.app`, pins a keepalive-only copy of the `claude` binary (so the keychain's "Always Allow" keeps working across CLI auto-updates), and registers a login item. The icon appears in the menu bar right away.

Just want to build and install, without the login item:

```bash
bash build-app.sh
```

The build assembles the bundle in a temp directory and only swaps `/Applications/KeepAliveBar.app` once compiling and signing both succeed — a failed build never touches the copy you're using, and **exactly one `.app` ever exists on disk** (two copies would mean two instances, both firing keepalives over the same preferences and logs).

Build somewhere else to try it out: `KA_DEST=/tmp/ka/KeepAliveBar.app bash build-app.sh`.
Verify a build without installing: `KA_VERIFY_ONLY=1 bash build-app.sh`.

### Option 2 — Headless launchd agent

```bash
bash status.sh      # read-only: current usage and reset times, sends nothing
bash install.sh     # start the 24/7 background agent
bash uninstall.sh   # stop and remove it
```

> Run **one** of the two, not both — otherwise they'll both fire into the same account.

## 🖱️ Usage

Click the menu bar icon:

| Section | What it shows / does |
|---|---|
| **Usage** | Claude and Codex, 5-hour and weekly, with reset times and Claude's login expiry. Display only — no side effects |
| **Claude Keepalive** | Auto-open the next Claude window when the current one closes |
| **Codex Keepalive** | Same for Codex — independent switch |
| **Cross keepalive** | Under **Settings → Keepalive**: minimum spacing between the two sides' window starts (default 120 min), or **Centered** (~150 min apart) |
| **Keepalive log** | Last fire time and result per side, plus paused / weekly-limited / in-flight state |
| **Launch at Login** | Registers a login item via `SMAppService` |
| **Auto refresh** | Refresh usage automatically when the popover opens |
| **Hide countdown** | Icon only in the menu bar (a `⏸` still shows while paused, so you don't forget) |
| **Settings** | Expands in place under the main view: control visibility, ordering, menu-bar progress-bar colors |
| **Refresh / Quit** | |

### Cross keepalive, concretely

Two 5-hour cycles that are stably staggered always sum to 5 hours between adjacent starts — so the furthest apart they can be is **2.5 hours**, which is what **Centered** targets.

Say Claude starts a new window at 13:00 and Codex's window expires at 14:00. With a 120-minute threshold, Codex waits until after 15:00 to fire. The whole point: whenever you sit down, neither side is about to hand you a brand-new 5-hour clock for a short task.

- Whichever side expires first fires on its normal expiry buffer; the later side defers if it's within the threshold of the other side's window start.
- **Centered** aims at 150 minutes after the other side's latest window start. Codex waits for that exact moment; Claude rounds to the nearest point on the half-hour grid its `windowEnd` implies. If the target is already past, it fires immediately.
- From any starting offset, centering costs at most one wait per side; after that the spacing holds around 150 min (±15 min on Claude because of the grid).
- Cycle starts are derived from a confirmed reset time minus 5 hours, falling back to the last successful fire only when no server truth is available. Failed attempts never advance a cycle.
- While waiting, the popover shows "waiting until …", and the menu bar shows `↔` with the remaining time.
- Pause, single-side switches, weekly gating, and failure backoff all still apply. Cross mode skips the initial both-sides-at-once authorization warm-up.

This controls **when the app fires**. Your own manual messages and the platforms' own window-alignment rules can still shift the real reset times; the app recomputes from whatever the server reports next. The headless `keepalive.sh` uses the original schedule and ignores this setting.

## ⚙️ How it works

The whole design rests on one idea: **ask the server, don't guess.**

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <OAuth token from the macOS keychain, "Claude Code-credentials">
anthropic-beta: oauth-2025-04-20
```

`five_hour.resets_at` in the response is the real reset instant for the current window. The loop is: poll it → the moment it's crossed (window closed) → send one tiny message → new window opens → repeat.

| Piece | Under the hood |
|---|---|
| Claude usage | `GET /api/oauth/usage` (the endpoint Claude Code's own `/usage` uses) |
| Codex usage | `GET /backend-api/wham/usage`; falls back to scanning rollout logs only when unreachable |
| Claude keepalive | `POST /v1/messages` — **8** tokens in, 1 out |
| Codex keepalive | `POST /backend-api/codex/responses` — ~14 in, 16 out |
| Credentials | The same subscription OAuth token the CLIs already store; `ANTHROPIC_API_KEY` is cleared so nothing lands on an API bill |
| Verification | Usage is polled back after each fire until the new window appears (Claude needed ~70 s in testing, so a single check right after firing would falsely report failure) |
| Background mode | launchd `StartInterval=300` — stateless polling, so sleep and reboot heal themselves |

**Why 8 tokens instead of 22,698:** opening a window only needs *one inference request billed to the subscription*. `claude -p` / `codex exec` additionally carry tool definitions, system prompts, your global `CLAUDE.md` / `AGENTS.md`, and the skills list — none of which contribute anything to opening a window, yet account for 99.9% of the tokens. (In one 141 KB Claude request body, 29 tool definitions alone were 97 KB.)

| | Old (CLI) | Now (direct HTTP) |
|---|---|---|
| Claude | `claude -p 'Reply OK' --model haiku` → **22,698** in / 51 out | `POST /v1/messages` → **8** in / 1 out |
| Codex | `codex exec 'Reply OK'` → **13,871** in / 16 out | `POST /backend-api/codex/responses` → **14** in / 16 out |

*(Measured 2026-09-06, same machine, same account.)*

**Both sides are empirically confirmed to open windows this way.** For Codex, `reset_at` drifts while no window is anchored, then freezes at "request time + 5h" the instant a bare 30-token request lands. For Claude, a window closed at 03:29:59, a direct 8-token request went out at 03:31:36, and `five_hour.resets_at` went from `null` to `08:30:00` — the old window's end plus 5 h, because Claude's windows align to the half hour rather than starting at your message.

**No automatic fallback, on purpose.** If the direct path ever breaks, a silent CLI fallback would paper over it: everything would look fine while every keepalive quietly cost 22,698 tokens again. Better noisy than "looks normal." To switch back by hand: `KA_CLAUDE_DIRECT=0` / `KA_CODEX_DIRECT=0`, or `defaults write com.iu.keepalivebar directFire -bool false` for the app.

> Side effect worth knowing: Codex's login state is maintained by its CLI. Since there's no automatic CLI fallback, an expired token means the direct call just keeps returning 401 — run `codex` once or log in again. The log says so explicitly.

The CLI path (when you switch back manually) still runs inside an empty system temp directory that is deleted the moment the command finishes, so there is no file, `CLAUDE.md`, or git context to read or leave behind; Claude runs with `--model haiku --strict-mcp-config` and a cleared `ANTHROPIC_API_KEY`.

## 🔧 Configuration (headless mode)

Environment variables, settable in the plist's `EnvironmentVariables`:

| Variable | Default | Meaning |
|---|---|---|
| `KA_CLAUDE_DIRECT` | `1` | 1 = direct `POST /v1/messages` (8 tokens); 0 = manual fallback to `claude -p` (22,698). Never falls back on its own |
| `KA_CODEX_DIRECT` | `1` | 1 = direct `POST .../codex/responses` (30 tokens); 0 = manual fallback to `codex exec` (13,871) |
| `KA_API_MODEL` | `claude-haiku-4-5-20251001` | Full model id for the direct call (HTTP doesn't take CLI aliases) |
| `KA_MODEL` | `haiku` | Model used when falling back to the CLI |
| `KA_BUFFER_SEC` | `90` | Seconds to wait past the real reset instant before firing |
| `KA_MIN_REFIRE_SEC` | `17400` | Debounce: minimum gap between two keepalives (4h50m) |
| `KA_WEEKLY_GUARD_PCT` | `101` | Pause keepalive at or above this weekly percentage (default never; set 90 to conserve) |
| `KA_CODEX_BIN` | auto-detected | Path to the Codex CLI |
| `KA_CODEX_MODEL` | `gpt-5.6-luna` | Codex keepalive model |
| `KA_CODEX_EFFORT` | `low` | Codex reasoning effort |
| `KA_CODEX_PROMPT` | `Reply OK` | Codex keepalive message — best left alone |
| `KA_CODEX_FALLBACK_SEC` | `18000` | Without a Codex reset snapshot, wait 5 h before the first fire |
| `KA_CODEX_MIN_REFIRE_SEC` | `17400` | Minimum gap between Codex fires (4h50m) |
| Poll interval | plist `StartInterval=300` | Smaller = tighter window handoff, more requests |

## 📋 Requirements

- macOS 13 (Ventura) or later, Apple Silicon
- Xcode Command Line Tools (`xcode-select --install`)
- Claude Code and/or Codex CLI, **logged in with a subscription account** (the OAuth credentials in your keychain are what this reads)

## ⚠️ Read this before you rely on it

1. **It depends on a billing policy that is currently paused.** Anthropic planned to split `claude -p` / Agent SDK / headless usage out of the subscription's 5-hour and weekly limits from 2026-06-15 onward, into a separate monthly allowance. If that lands, that path no longer resets the interactive window. The change was **paused** on 6-15 and such usage still counts against subscription limits today — but Anthropic has said it will return. Watch whether `resets_at` actually moves after a keepalive (`bash status.sh`) to tell whether it still works.
2. **It only stops 5-hour windows from being wasted — it does not add weekly quota.** Your weekly limit is a hard ceiling. The keepalive messages themselves cost ≈0 against it, but they can't raise it either.
3. **It must run on subscription auth.** `ANTHROPIC_API_KEY` is unset before firing so nothing accidentally bills the API. If your machine forces an API key, keepalives land on the API bill instead of the subscription window.
4. **This is automation against a personal subscription — a gray area.** Use it only on your own account, and judge for yourself whether it fits the terms you agreed to. Future policy changes may restrict this kind of use.

## 🧪 Development

```bash
# Policy, presentation, scheduling and settings tests — compiles the production
# sources directly; no network, no inference requests, isolated preferences
bash tests/run-cross-keepalive.sh

# Compile, assemble, sign and verify without touching the installed copy
KA_VERIFY_ONLY=1 bash build-app.sh
```

Module layout, state constraints, and where new features belong: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

| Path | Role |
|---|---|
| `Sources/KeepAliveBar/` | The menu bar app, split by state / policy / provider / presentation / views |
| `scripts/swift-sources.sh` | The Swift source list shared by the build and the tests |
| `build-app.sh` | Compile → assemble in a temp dir → atomically replace `/Applications/KeepAliveBar.app` and restart |
| `install-app.sh` | `build-app.sh` + pinned `keepalive-claude` copy + login item |
| `keepalive.sh` | The launchd core: read usage → decide → fire if needed |
| `status.sh` | **Read-only** panel: usage, reset times, activation state. Safe to run anytime |
| `com.iu.claude-keepalive.plist` | LaunchAgent template |
| `install.sh` / `uninstall.sh` | Enable / disable the launchd service |
| `keepalive.log` / `state.json` | Log and state for the launchd mode |

App logs live in `~/Library/Application Support/KeepAliveBar/`.

## ❓ FAQ

**Q: How do I verify it really opened a new window?**
A: After an idle stretch, watch for `🔔 FIRED` in `keepalive.log`, then run `bash status.sh` — the 5-hour reset should jump to roughly five hours out and usage should drop.

**Q: Does it send anything to third parties?**
A: No. It talks only to Anthropic's and OpenAI's own endpoints, with your own credentials. No analytics, no telemetry.

**Q: Does it read my code or conversations?**
A: No. The keepalive is a bare HTTP request with a fixed two-word prompt. Even the manual CLI fallback runs in an empty temp directory that's deleted immediately afterward.

**Q: Can I run the app and the launchd agent together?**
A: Don't. Pick one — running both means two schedulers firing into the same account.

## 🔎 Topics

A macOS **menu bar** utility for **Claude Code** and **Codex** subscriptions: see **remaining quota** and the **5-hour window** reset at a glance, and **keep the window alive** automatically with an 8-token request — plus **cross keepalive** to stagger both tools' windows so you never restart a 5-hour clock just by sitting down.
