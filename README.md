<div align="center">

# Discord × Copilot — Discord Autopilot

**Chat with an autonomous AI coding agent — right from Discord.**

[![CI](https://github.com/epantke/discord-autopilot/actions/workflows/ci.yml/badge.svg)](https://github.com/epantke/discord-autopilot/actions/workflows/ci.yml)
[![GitHub Release](https://img.shields.io/github/v/release/epantke/discord-autopilot?logo=github)](https://github.com/epantke/discord-autopilot/releases/latest)
[![GitHub Stars](https://img.shields.io/github/stars/epantke/discord-autopilot?style=flat&logo=github)](https://github.com/epantke/discord-autopilot/stargazers)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Pages](https://img.shields.io/badge/docs-GitHub%20Pages-5865F2?logo=github)](https://epantke.github.io/discord-autopilot/)

</div>

---

Send a DM or @mention in Discord — the agent edits files, runs tests, commits, and streams progress live. `git push` always requires your approval first. No slash commands needed.

> **📖 [Full documentation & interactive guide →](https://epantke.github.io/discord-autopilot/)**

## ⚠️ Disclaimer

> **Experimental software — use at your own risk.** This grants an AI agent autonomous access to edit files, run commands, and commit in your repo. The authors assume no liability. Do not run on production systems without understanding the risks. Review all agent changes before merging. See [full notice](https://epantke.github.io/discord-autopilot/#security).

## Quick Start

**Prerequisites:** Git, Node.js ≥ 18, npm, [Copilot CLI](https://docs.github.com/en/copilot/github-copilot-in-the-cli) (authenticated)

#### Linux / macOS

```bash
curl -fsSL https://github.com/epantke/discord-autopilot/releases/latest/download/agent.sh -o agent.sh && bash agent.sh
```

#### Windows (PowerShell)

```powershell
irm https://github.com/epantke/discord-autopilot/releases/latest/download/agent.ps1 -OutFile agent.ps1; .\agent.ps1
```

> **That's it.** Both scripts include an interactive setup wizard — just paste and run. You'll be guided through token setup, repo selection, and optional config. Everything is saved to a `.env` file for next time.

## Discord Bot Setup

1. [Discord Developer Portal](https://discord.com/developers/applications) → New Application → Bot → copy token
2. Enable **Message Content Intent** under Bot settings
3. Bot Permissions: `Send Messages`, `Embed Links`, `Attach Files`, `Read Message History`, `Use Slash Commands`, `Create Public Threads`, `Send Messages in Threads`
4. OAuth2 → URL Generator → scopes: `bot`, `applications.commands` → invite

## Usage

**@mention** the bot in any channel or **DM** it directly — the agent creates a thread, works autonomously, and streams output live. Reply in the thread for follow-ups.

<details>
<summary><strong>Slash commands</strong> (Manage Guild permission required)</summary>

| Command | Description |
|---------|-------------|
| `/stop` | Abort running task (optionally clear queue) |
| `/reset` | Reset the agent session and workspace |
| `/model [current\|list\|set]` | View or change the AI model |
| `/config` | View current bot configuration |
| `/grant path mode:[ro\|rw] ttl:<min>` | Grant access outside workspace |
| `/revoke path` | Revoke a path grant |
| `/update [check\|apply]` | Check for and apply bot updates |
| `/pause` / `/resume` | Pause/resume queue processing |
| `/responders [add\|remove\|list]` | Manage who can answer agent questions |
| `/repo [set\|current\|reset]` | Switch repo for this channel |
| `/branch [set\|current\|reset]` | Set base branch for new worktrees |

</details>

## Features

🤖 **Autonomous Agent** — Edits, tests, commits — no hand-holding required<br>
📡 **Live Streaming** — Real-time output in per-task Discord threads<br>
🔒 **Push Approval** — `git push` always requires human approval via buttons<br>
💬 **Conversational** — @mention or DM the bot, reply in threads for follow-ups<br>
👥 **Multi-Channel** — Each channel gets its own isolated git worktree<br>
❓ **Ask-User** — Agent asks clarifying questions and waits for your answer<br>
🛡️ **Deny-by-Default** — All access outside workspace blocked unless granted<br>
🔑 **Secret Scanner** — Auto-redacts tokens & keys before posting to Discord<br>
💾 **Session Recovery** — Sessions & grants survive restarts (SQLite)<br>
🔄 **Auto-Updater** — Checks for new releases, downloads & restarts automatically<br>
📂 **Multi-Repo** — Switch repos per channel with `/repo` — clones on demand<br>
🌿 **Branch Overrides** — Set a custom base branch per channel with `/branch`

## Security

Deny-by-default — all file/shell access outside the workspace is blocked. Push requires Discord button approval. Secrets are auto-redacted (11 patterns). Grants are temporary with auto-revoke. All SQL uses prepared statements. [Full security breakdown →](https://epantke.github.io/discord-autopilot/#security)

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `DISCORD_TOKEN` | **required** | Discord bot token |
| `REPO_URL` | _(prompted)_ | Repository to clone |
| `GITHUB_TOKEN` | _(none)_ | Fine-grained PAT — Contents (r/w), Pull requests (r/w) |
| `DEFAULT_MODEL` | `claude-opus-4.6` | AI model (e.g. `claude-sonnet-4.6`, `gpt-4o`) |
| `ADMIN_USER_ID` | _(none)_ | Your Discord user ID — always allowed in DMs |
| `ALLOWED_DM_USERS` | _(none)_ | Comma-separated user IDs allowed to DM |
| `ALLOWED_GUILDS` | _(all)_ | Comma-separated guild IDs |
| `ALLOWED_CHANNELS` | _(all)_ | Comma-separated channel IDs |

<details>
<summary><strong>More options</strong></summary>

| Variable | Default | Description |
|----------|---------|-------------|
| `ADMIN_ROLE_IDS` | _(all)_ | Comma-separated admin role IDs |
| `STARTUP_CHANNEL_ID` | _(none)_ | Channel for online/offline notifications |
| `MAX_QUEUE_SIZE` | `50` | Max queued tasks per session |
| `MAX_PROMPT_LENGTH` | `4000` | Max prompt length in characters |
| `TASK_TIMEOUT_MS` | `1800000` | Task timeout (30 min) |
| `AUTO_APPROVE_PUSH` | `false` | Auto-approve `git push` |
| `AUTO_RETRY_ON_CRASH` | `false` | Re-enqueue tasks after crash |
| `DEFAULT_BRANCH` | _(none)_ | Base branch for new worktrees (default: remote HEAD) |
| `SESSION_KEEPALIVE_MS` | `0` | Keepalive interval for Copilot sessions (0 = disabled) |
| `PAUSE_GRACE_MS` | `3600000` | Grace period before paused sessions are swept (1h) |
| `BASE_ROOT` | `~/.local/share/discord-agent` | Base directory for all data |
| `LOG_LEVEL` | `info` | `debug` / `info` / `warn` / `error` |

</details>

<details>
<summary><strong>Architecture</strong></summary>

```
src/
├── bot.mjs               # Discord client, slash commands, RBAC
├── config.mjs            # ENV parsing, defaults
├── copilot-client.mjs    # Copilot SDK session factory
├── session-manager.mjs   # Session lifecycle, task queue, worktrees
├── policy-engine.mjs     # Path security, push detection
├── grants.mjs            # Grant CRUD, TTL, auto-revoke
├── discord-output.mjs    # Streaming, throttling, chunking
├── push-approval.mjs     # Push gate, diff summary, buttons
├── secret-scanner.mjs    # Token redaction (11 patterns)
├── state.mjs             # SQLite (WAL), migrations
├── command-info.mjs      # Self-awareness prompt
├── updater.mjs           # Self-update checker
└── logger.mjs            # Structured JSON logging
```

</details>

## Build

```bash
node build.mjs     # → dist/agent.sh, dist/agent.ps1
```

Generates fully self-contained scripts — drop on any machine and run.

## License

[MIT](LICENSE)

---

<sub>This software is provided "as is" without warranty of any kind. See the [Disclaimer](#%EF%B8%8F-disclaimer) above.</sub>
