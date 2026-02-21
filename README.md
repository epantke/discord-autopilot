<div align="center">

# Discord Autopilot

**Delegate coding tasks to an autonomous AI agent — right from Discord.**

[![CI](https://github.com/epantke/discord-autopilot/actions/workflows/ci.yml/badge.svg)](https://github.com/epantke/discord-autopilot/actions/workflows/ci.yml)
[![GitHub Release](https://img.shields.io/github/v/release/epantke/discord-autopilot?logo=github)](https://github.com/epantke/discord-autopilot/releases/latest)
[![GitHub Stars](https://img.shields.io/github/stars/epantke/discord-autopilot?style=flat&logo=github)](https://github.com/epantke/discord-autopilot/stargazers)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Pages](https://img.shields.io/badge/docs-GitHub%20Pages-5865F2?logo=github)](https://epantke.github.io/discord-autopilot/)

</div>

---

Drop a `/task` in Discord and the agent edits files, runs tests, commits — and streams progress live into a thread. `git push` always requires your approval first.

> **📖 [Full documentation & interactive guide →](https://epantke.github.io/discord-autopilot/)**

## Highlights

- 🤖 **Autonomous agent** — edits, tests, commits without hand-holding
- 📡 **Live streaming** — output streams into per-task Discord threads
- 🔒 **Push approval gate** — `git push` & PR actions require human approval via buttons
- 🧵 **Thread & DM follow-ups** — reply in an agent thread or DM to send follow-up tasks
- 📁 **Task queue** — queue multiple tasks, pause/resume/clear at will
- ❓ **Ask-user** — agent can ask clarifying questions via Discord and wait for your answer
- 🛡️ **Deny-by-default** — all access outside workspace blocked unless explicitly granted
- 🔑 **Secret scanner** — auto-redacts tokens & keys before posting to Discord
- 💾 **Session recovery** — sessions, grants & history survive bot restarts (SQLite)
- 🏗️ **Workspace isolation** — each Discord channel / DM gets its own git worktree

## ⚠️ Security Notice & Disclaimer

> **This project is in active development and provided as-is, without any warranty or guarantee of any kind.**
>
> - This software is **experimental**. It grants an AI agent autonomous access to edit files, run shell commands, and make git commits in your repository. **Use at your own risk.**
> - The authors and contributors assume **no liability** for any damage, data loss, security incidents, unintended code changes, or other issues arising from the use of this software.
> - **Do not run this on production systems or repositories containing sensitive data** without understanding the risks.
> - While security measures are built in (deny-by-default policy, push approval gates, secret redaction), **no software is immune to vulnerabilities**. The AI agent may produce unexpected or incorrect results.
> - You are solely responsible for reviewing all changes made by the agent before merging or deploying them.
> - By using this software, you accept full responsibility for any consequences.

## Quick Start

**Prerequisites:** Git, Node.js ≥ 18, npm, [Copilot CLI](https://docs.github.com/en/copilot/github-copilot-in-the-cli) (authenticated)

<table>
<tr><th>Linux / macOS</th><th>Windows (PowerShell)</th></tr>
<tr><td>

```bash
export DISCORD_TOKEN="your-token"
chmod +x agent.sh
./agent.sh          # prompts for repo URL
```

</td><td>

```powershell
.\agent.ps1         # interactive setup wizard
                    # validates tokens, clones repo, starts bot
```

</td></tr>
</table>

Or create a `.env` file:

```env
DISCORD_TOKEN=your-bot-token
REPO_URL=https://github.com/user/repo.git
```

## Discord Bot Setup

1. [Discord Developer Portal](https://discord.com/developers/applications) → New Application → Bot → copy token
2. Enable **Message Content Intent** under Bot settings
3. Bot Permissions: `Send Messages`, `Embed Links`, `Attach Files`, `Use Slash Commands`, `Create Public Threads`, `Send Messages in Threads`
4. OAuth2 → URL Generator → scopes: `bot`, `applications.commands` → invite
5. Set `DISCORD_TOKEN` and run `./agent.sh` or `.\agent.ps1`

## Commands

| Command | Description |
|---------|-------------|
| `/task prompt:<text>` | Send a coding task to the agent |
| `/stop` | Abort running task (optionally clear queue) |
| `/pause` / `/resume` | Pause / resume queue processing |
| `/queue [list\|clear]` | View or clear pending tasks |
| `/history [limit]` | Show recent task history |
| `/status` | Session status, queue & active grants |
| `/diff [stat\|full\|staged]` | Show git diff in workspace |
| `/branch [list\|current\|create\|switch]` | Manage agent branches |
| `/grant path mode:[ro\|rw] ttl:<min>` | Grant access outside workspace |
| `/revoke path` | Revoke a path grant |
| `/approve_push` | Approve a pending git push |
| `/config` | View current bot configuration |
| `/reset` | Reset the agent session |
| `/help` | List all available commands |
| `/stats` | Show uptime, task counts, active sessions |

## How It Works

1. **`/task`** → bot creates a thread (or replies in DM) → session manager provisions a git worktree
2. **Agent works** — Copilot agent works autonomously; every tool call passes through the policy engine
3. **Live stream** — output streams into the thread/DM; secrets are redacted before posting
4. **Push gate** — `git push` triggers an approval gate with buttons; you review and decide

## Architecture

```
agent.sh / agent.ps1      # Deployment scripts (standalone after build)
build.mjs                  # Generates standalone scripts → dist/
src/
├── bot.mjs               # Discord client, slash commands, RBAC
├── config.mjs            # ENV parsing, defaults
├── state.mjs             # SQLite (WAL), migrations
├── policy-engine.mjs     # Path security, push detection
├── grants.mjs            # Grant CRUD, TTL, auto-revoke
├── copilot-client.mjs    # SDK session factory
├── session-manager.mjs   # Session lifecycle, task queue, worktrees
├── discord-output.mjs    # Streaming, throttling, chunking
├── push-approval.mjs     # Push gate, diff summary, buttons
├── secret-scanner.mjs    # Token redaction (9 patterns)
└── logger.mjs            # Structured JSON logging
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `DISCORD_TOKEN` | **required** | Discord bot token |
| `REPO_URL` | _(prompted)_ | Repository to clone |
| `GITHUB_TOKEN` | _(none)_ | Fine-grained PAT — permissions: Contents (r/w), Pull requests (r/w) |
| `ALLOWED_GUILDS` | _(all)_ | Comma-separated guild IDs |
| `ALLOWED_CHANNELS` | _(all)_ | Comma-separated channel IDs |
| `ADMIN_ROLE_IDS` | _(all)_ | Comma-separated admin role IDs |

<details>
<summary><strong>More options</strong></summary>

| Variable | Default | Description |
|----------|---------|-------------|
| `STARTUP_CHANNEL_ID` | _(none)_ | Channel for online/offline/reconnect notifications |
| `ADMIN_USER_ID` | _(none)_ | User ID for admin DMs on startup/shutdown |
| `MAX_QUEUE_SIZE` | `50` | Maximum number of queued tasks per session |
| `MAX_PROMPT_LENGTH` | `4000` | Maximum prompt length in characters |
| `TASK_TIMEOUT_MS` | `1800000` | Task timeout (default: 30 min) |
| `DISCORD_EDIT_THROTTLE_MS` | `1500` | Throttle interval for Discord message edits |
| `RATE_LIMIT_WINDOW_MS` | `60000` | Rate limit window per user |
| `RATE_LIMIT_MAX` | `10` | Max commands per window (admins exempt) |
| `BASE_ROOT` | `~/.local/share/discord-agent` | Base directory for all data |
| `WORKSPACES_ROOT` | `$BASE_ROOT/workspaces` | Worktree directory |
| `LOG_LEVEL` | `info` | `debug` / `info` / `warn` / `error` |

</details>

## Security

The agent enforces **deny-by-default** security: all file/shell access outside the workspace is blocked, `git push` requires button approval, and secrets are auto-redacted before posting to Discord. Additional layers include symlink-safe path resolution, compound command scanning, RBAC, grant TTL with auto-revoke, and per-channel workspace isolation.

See the [full security breakdown](https://epantke.github.io/discord-autopilot/#security) for details.

## Standalone Build

```bash
node build.mjs     # → dist/agent.sh, dist/agent.ps1
```

The generated scripts are fully self-contained — drop them on any machine and run.

## License

[MIT](LICENSE)

---

<sub>This software is provided "as is" without warranty of any kind. See the [Security Notice](#%EF%B8%8F-security-notice--disclaimer) above.</sub>
