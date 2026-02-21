# Project Guidelines — Discord Autopilot

An autonomous AI coding agent controlled via Discord slash commands, powered by the GitHub Copilot SDK. Users submit `/task` commands; the agent edits files, runs tests, creates commits, and streams progress to Discord threads. `git push` always requires human approval via Discord buttons.

## Tech Stack

- **Runtime**: Node.js ≥ 18, ES Modules (`.mjs`, `"type": "module"`)
- **Discord**: discord.js v14 — `SlashCommandBuilder`, `EmbedBuilder`, `InteractionReply`
- **AI Backend**: `@github/copilot-sdk` — ACP/stdio protocol, `onPreToolUse` policy hook
- **Database**: better-sqlite3 — WAL mode, prepared statements, schema migrations in `state.mjs`
- **Build**: `build.mjs` embeds `src/` into standalone `agent.sh` / `agent.ps1` → `dist/`

## Code Style

- **ES Modules only** — all files use `.mjs` extension with `import`/`export`
- **Named exports** — no default exports anywhere
- **No TypeScript** — plain JavaScript; use JSDoc type hints where helpful
- **Destructuring imports** — `import { X, Y } from "discord.js"` and `import { Z } from "node:fs"`
- **Node built-in prefix** — always use `node:` prefix for built-in modules (`node:fs`, `node:path`, etc.)

## Architecture

| Module | Responsibility |
|---|---|
| `bot.mjs` | Discord client, slash commands, RBAC, rate limiting, interaction handler |
| `config.mjs` | ENV parsing, Snowflake validation, constants |
| `copilot-client.mjs` | Copilot SDK singleton, session factory, `onPreToolUse` policy hooks |
| `session-manager.mjs` | Session lifecycle, git worktrees per channel, task queue (FIFO), pause/resume |
| `policy-engine.mjs` | Path validation (`realpathSync`), workspace boundary checks, git-push detection, grant checking |
| `grants.mjs` | Grant CRUD, TTL with auto-revoke, in-memory + SQLite dual-store |
| `state.mjs` | SQLite persistence, schema migrations (v0→v2), prepared statements |
| `discord-output.mjs` | Streaming output, throttled message edits, chunking, attachment fallback |
| `push-approval.mjs` | Push gate with embed + buttons, approve/reject, 10 min timeout, RBAC |
| `secret-scanner.mjs` | Token redaction (9 regex patterns + ENV value detection) |
| `logger.mjs` | Structured JSON logging to stdout/stderr |

## Logging

Always use the structured logger — never use `console.log`/`console.error`:

```js
import { createLogger } from "./logger.mjs";
const log = createLogger("my-module");

log.info("Something happened", { key: "value" });
log.error("Something failed", { error: err.message });
```

The second argument is a plain data object (not the error itself).

## Database Conventions

- All DB operations use **prepared statements** (never string-interpolated SQL)
- SQLite runs in **WAL mode** — do not change the journal mode
- Schema changes go through the migration chain in `state.mjs` (`runMigrations()`)
- In-memory state (`Map`) is the primary store; SQLite is the crash-recovery backup

## Error Handling

- Wrap Discord API calls in try/catch — **swallow errors** to avoid crashing the agent
- Log errors via `log.error()` with `{ error: err.message }` context
- For interaction replies: check `interaction.deferred || interaction.replied` before choosing `editReply` vs `reply`
- Use `catch(() => {})` for fire-and-forget Discord sends

## Timers

- Always call `.unref()` on `setInterval` / `setTimeout` handles to avoid blocking process exit

## Security Posture

This project enforces strict security boundaries — do not relax them:

- **Deny-by-default**: all file/shell operations outside the workspace are blocked
- **Symlink-safe path resolution**: always use `realpathSync()` before path comparisons
- **Compound command scanning**: `git push` detection covers `&&`, `||`, `;`, pipes, `sh -c`, `eval`, backticks, `$()`
- **Push approval gate**: `git push` is never auto-approved; requires Discord button confirmation
- **Secret scanner**: all output to Discord passes through `redactSecrets()` before sending
- **Grant TTL**: temporary path grants auto-expire; never create permanent grants
- **Branch name sanitization**: only `/^[\w.\/-]{1,100}$/` allowed
- **Snowflake validation**: Discord IDs validated as 17-20 digit strings

## Build & Deploy

```bash
node build.mjs          # Produces dist/agent.sh and dist/agent.ps1
npm start               # Runs bot.mjs directly (for development)
```

The standalone scripts (`agent.sh` / `agent.ps1`) embed all source files inline and handle `.env` loading, prerequisite checks, credential validation, repo cloning, and `npm install`.

## Testing

There is no unit test framework. CI (`.github/workflows/ci.yml`) validates:
- Build artifact existence
- Embedded file completeness
- Shell syntax (`bash -n`)
- Script headers
