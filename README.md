<div align="center">

# Discord × Copilot — Remote Coding Agent

**Delegate coding tasks to an autonomous AI agent — right from Discord.**

[![Node.js](https://img.shields.io/badge/node-%3E%3D18-brightgreen?logo=node.js)](https://nodejs.org)
[![Discord.js](https://img.shields.io/badge/discord.js-v14-5865F2?logo=discord&logoColor=white)](https://discord.js.org)
[![Copilot SDK](https://img.shields.io/badge/built%20with-Copilot%20SDK-000?logo=github)](https://github.com/github/copilot-sdk)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

</div>

---

Drop a `/task` in Discord and the agent edits files, runs tests, commits — and streams progress live into a thread. `git push` always requires your approval first.

## Highlights

- 🤖 **Autonomous agent** — edits, tests, commits without hand-holding
- 📡 **Live streaming** — output streams into per-task Discord threads
- 🔒 **Push approval gate** — `git push` & PR actions require human approval via buttons
- 🧵 **Thread follow-ups** — reply in an agent thread to send follow-up tasks
- 🗂️ **Task queue** — queue multiple tasks, pause/resume/clear at will
- ❓ **Ask-user** — agent can ask clarifying questions via Discord and wait for your answer
- 🛡️ **Deny-by-default** — all access outside workspace blocked unless explicitly granted
- 🔑 **Secret scanner** — auto-redacts tokens & keys before posting to Discord
- 💾 **Session recovery** — sessions, grants & history survive bot restarts (SQLite)
- 🏗️ **Workspace isolation** — each Discord channel gets its own git worktree

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

```
Discord (slash commands, buttons, threads)
    ↕
  Bot  ←→  Policy Engine  ←→  Push Approval Gate
    ↕         (path security,       (embed + buttons,
  Session     compound cmd scan)     10 min timeout)
  Manager
    ↕
  Copilot SDK  ←→  copilot CLI (ACP / stdio)
    ↕
  Discord Output (throttled streaming, secret redaction)
```

1. `/task` → bot creates a thread → session manager provisions a git worktree
2. Copilot agent works autonomously; every tool call passes through the policy engine
3. Output streams live into the thread; `git push` triggers an approval gate with buttons
4. Users reply in threads for follow-up tasks — the agent picks them up automatically

## Architecture

**Repository layout:**

```
agent.sh                  # Deployment script (Linux / macOS)
agent.ps1                 # Deployment script (Windows)
build.mjs                 # Generates standalone scripts → dist/
src/
├── package.json          # Dependencies & npm scripts
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

**Runtime layout** (created by deployment scripts):

```
~/.local/share/discord-agent/
├── app/                  # Bot runtime (copied from src/)
│   ├── src/
│   │   └── *.mjs
│   └── package.json
├── repos/<project>/      # Cloned repository
├── workspaces/<project>/ # Git worktrees (one per channel)
└── state.sqlite          # Sessions, grants, task history
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

- **Path security** — `fs.realpathSync()` prevents symlink traversal
- **Deny-by-default** — all file/shell ops outside workspace blocked without explicit grant
- **Compound command scanning** — detects `git push` in `&&`, `||`, `;`, pipes, `sh -c`, `eval`, backticks
- **`cd` target validation** — blocks shell `cd` into paths outside workspace
- **Push approval gate** — `git push`, `gh pr create/merge` require Discord button approval (10 min timeout)
- **Secret scanner** — redacts 9 token patterns (GitHub PAT, AWS, Slack, Discord, OpenAI, …) before posting
- **Grant TTL + auto-revoke** — temporary grants with automatic expiration
- **Workspace isolation** — each channel gets its own git worktree
- **RBAC** — admin roles for privileged commands; rate limiting per user (admins exempt)
- **Branch sanitization** — only `[\w./-]` allowed, max 100 chars
- **Session recovery** — grants & sessions restored from SQLite on restart
- **Graceful shutdown** — SIGINT/SIGTERM handlers, DB cleanup, shutdown notifications

## Standalone Build

Generate standalone deployment scripts with all source files embedded inline (no `src/` directory needed):

```bash
node build.mjs     # → dist/agent.sh, dist/agent.ps1
```

The generated scripts are fully self-contained — drop them on any machine and run.

## Discord Bot Setup

1. [Discord Developer Portal](https://discord.com/developers/applications) → New Application → Bot → copy token
2. Enable **Message Content Intent** under Bot settings
3. Bot Permissions: `Send Messages`, `Embed Links`, `Attach Files`, `Use Slash Commands`, `Create Public Threads`, `Send Messages in Threads`
4. OAuth2 → URL Generator → scopes: `bot`, `applications.commands` → invite
5. Set `DISCORD_TOKEN` and run `./agent.sh` or `.\agent.ps1`

## License

[MIT](LICENSE)
