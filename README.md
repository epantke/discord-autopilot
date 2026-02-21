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

## Highlights

- 🤖 **Autonomous agent** — edits, tests, commits without hand-holding
- 💬 **Conversational** — @mention or DM the bot, reply in threads for follow-ups
- 📡 **Live streaming** — output streams into per-task Discord threads
- 🔒 **Push approval gate** — `git push` & PR actions require human approval via buttons
- 🔓 **Deny-by-default grants** — outside-workspace access is blocked and the user is prompted to use `/grant`
- 🧵 **Thread follow-ups** — reply in a thread to continue the conversation
- 👥 **Multi-channel** — each channel or DM gets its own isolated workspace and session
- ❓ **Ask-user** — agent can ask clarifying questions via Discord and wait for your answer
- 🛡️ **Deny-by-default** — all access outside workspace blocked unless explicitly granted
- 🔑 **Secret scanner** — auto-redacts tokens & keys before posting to Discord
- 💾 **Session recovery** — sessions, grants & history survive bot restarts (SQLite)
- 🏗️ **Workspace isolation** — every DM / channel gets its own git worktree
- 🧠 **Self-aware** — the bot knows its capabilities and can explain them when asked

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
3. Bot Permissions: `Send Messages`, `Embed Links`, `Attach Files`, `Read Message History`, `Use Slash Commands`, `Create Public Threads`, `Send Messages in Threads`
4. OAuth2 → URL Generator → scopes: `bot`, `applications.commands` → invite
5. Set `DISCORD_TOKEN` and run `./agent.sh` or `.\agent.ps1`

## How To Use

### @mention (primary interaction)

@mention the bot in any allowed channel to submit work:

```
@Autopilot Refactor the auth module to use JWT
Bot:   ✅ (creates a thread, streams output)
```

The bot auto-creates a session and workspace on the first task. Follow up by replying in the thread.

### DMs

If `ADMIN_USER_ID` or `ALLOWED_DM_USERS` is set, those users can DM the bot directly. Every DM becomes a task.

```
You:   Fix the failing test in auth.test.js
Bot:   ✅ (reacts, starts working, streams output)
```

Follow-up messages continue the conversation.

### Thread follow-ups

Reply in any bot-owned thread to continue the conversation with additional instructions.

### Slash commands (Manage Guild permission required)

| Command | Description |
|---------|-------------|
| `/stop` | Abort running task (optionally clear queue) |
| `/reset` | Reset the agent session and workspace |
| `/model [current\|list\|set]` | View or change the AI model |
| `/config` | View current bot configuration |
| `/grant path mode:[ro\|rw] ttl:<min>` | Grant access outside workspace |
| `/revoke path` | Revoke a path grant |
| `/update [check\|apply]` | Check for and apply bot updates |
| `/pause` | Pause queue processing |
| `/resume` | Resume queue processing |
| `/responders [add\|remove\|list]` | Manage who can answer agent questions |

## How It Works

1. **@mention or DM** → session manager provisions a git worktree
2. **Agent works** — Copilot agent works autonomously; every tool call passes through the policy engine
3. **Live stream** — output streams into a thread (channels) or directly (DMs); secrets are redacted
4. **Approval gates** — `git push` triggers a button prompt; outside-workspace access is denied with a notification to use `/grant`

## Architecture

```
agent.sh / agent.ps1      # Deployment scripts (standalone after build)
build.mjs                  # Generates standalone scripts → dist/
src/
├── bot.mjs               # Discord client, slash commands, RBAC, message handler
├── command-info.mjs      # Self-awareness prompt (bot identity & capabilities)
├── config.mjs            # ENV parsing, defaults
├── state.mjs             # SQLite (WAL), migrations
├── policy-engine.mjs     # Path security, push detection
├── grants.mjs            # Grant CRUD, TTL, auto-revoke
├── copilot-client.mjs    # Copilot SDK session factory
├── session-manager.mjs   # Session lifecycle, task queue, worktrees
├── discord-output.mjs    # Streaming, throttling, chunking
├── push-approval.mjs     # Push gate, diff summary, buttons
├── secret-scanner.mjs    # Token redaction (11 patterns)
├── updater.mjs           # Self-update checker & applier
└── logger.mjs            # Structured JSON logging
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `DISCORD_TOKEN` | **required** | Discord bot token |
| `REPO_URL` | _(prompted)_ | Repository to clone |
| `GITHUB_TOKEN` | _(none)_ | Fine-grained PAT — permissions: Contents (r/w), Pull requests (r/w) |
| `DEFAULT_MODEL` | `claude-opus-4.6` | AI model ID (e.g. `claude-sonnet-4.6`, `gpt-4o`) |
| `ADMIN_USER_ID` | _(none)_ | Your Discord user ID — always allowed in DMs |
| `ALLOWED_DM_USERS` | _(none)_ | Comma-separated user IDs allowed to DM the bot |
| `ALLOWED_GUILDS` | _(all)_ | Comma-separated guild IDs |
| `ALLOWED_CHANNELS` | _(all)_ | Comma-separated channel IDs |
| `ADMIN_ROLE_IDS` | _(all)_ | Comma-separated admin role IDs |

<details>
<summary><strong>More options</strong></summary>

| Variable | Default | Description |
|----------|---------|-------------|
| `STARTUP_CHANNEL_ID` | _(none)_ | Channel for online/offline/reconnect notifications |
| `MAX_QUEUE_SIZE` | `50` | Maximum number of queued tasks per session |
| `MAX_PROMPT_LENGTH` | `4000` | Maximum prompt length in characters |
| `TASK_TIMEOUT_MS` | `1800000` | Task timeout (default: 30 min) |
| `DISCORD_EDIT_THROTTLE_MS` | `1500` | Throttle interval for Discord message edits |
| `RATE_LIMIT_WINDOW_MS` | `60000` | Rate limit window per user |
| `RATE_LIMIT_MAX` | `10` | Max messages per window (admins exempt) |
| `AUTO_APPROVE_PUSH` | `false` | Auto-approve `git push` without Discord confirmation |
| `AUTO_RETRY_ON_CRASH` | `false` | Re-enqueue tasks aborted by a crash/restart |
| `BASE_ROOT` | `~/.local/share/discord-agent` | Base directory for all data |
| `WORKSPACES_ROOT` | `$BASE_ROOT/workspaces` | Worktree directory |
| `LOG_LEVEL` | `info` | `debug` / `info` / `warn` / `error` |

</details>

## Security

The agent enforces **deny-by-default** security:

- All file/shell access outside the workspace is blocked
- `git push` requires Discord button approval (RBAC-protected, 10 min timeout)
- Outside-workspace access shows approve/deny buttons with read-only or read/write options
- Secrets are auto-redacted before posting to Discord (11 token patterns + ENV values)
- Symlink-safe path resolution (`realpathSync`) before all boundary checks
- Compound command scanning: `&&`, `||`, `;`, pipes, `sh -c`, `eval`, backticks, `$()`
- Git push detection covers flags between `git` and `push`, env-variable prefixes
- DM access restricted to `ADMIN_USER_ID` and `ALLOWED_DM_USERS` only
- Tilde expansion (`cd ~`) blocked in shell commands
- Grant TTL with auto-revoke — no permanent grants
- All SQL uses prepared statements (no string interpolation)
- `DISCORD_TOKEN` and PATs removed from `process.env` before Copilot subprocess
- Branch name sanitization: `/^[\w.\/-]{1,100}$/`
- Snowflake validation: Discord IDs checked as 17-20 digit strings
- Per-user rate limiting on messages and follow-ups

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
