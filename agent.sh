#!/usr/bin/env bash
set -euo pipefail

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  Discord × Copilot — Autonomous Remote Coding Agent                        ║
# ║  Single-script deployment. Run: ./agent.sh                                 ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[FATAL]${NC} $*" >&2; exit 1; }

# ──────────────────────────────────────────────────────────────────────────────
# 1) Load .env if present, then single question: Repo URL
# ──────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/.env"
  set +a
fi
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  Discord × Copilot Remote Coding Agent          ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
echo ""

if [[ -n "${REPO_URL:-}" ]]; then
  info "Using REPO_URL from environment: $REPO_URL"
else
  read -rp "Repo URL? " REPO_URL
fi

[[ -z "$REPO_URL" ]] && die "No repo URL provided."

# ──────────────────────────────────────────────────────────────────────────────
# 2) Prerequisite checks
# ──────────────────────────────────────────────────────────────────────────────
MISSING=()

command -v git   >/dev/null 2>&1 || MISSING+=("git   → https://git-scm.com/downloads")
command -v node  >/dev/null 2>&1 || MISSING+=("node  → https://nodejs.org/ (>= 18)")
command -v npm   >/dev/null 2>&1 || MISSING+=("npm   → ships with node")

# Copilot CLI: accept 'copilot' binary OR 'gh copilot' extension
COPILOT_CMD=""
if command -v copilot >/dev/null 2>&1; then
  COPILOT_CMD="copilot"
elif command -v gh >/dev/null 2>&1 && gh copilot --help >/dev/null 2>&1; then
  COPILOT_CMD="gh copilot"
else
  MISSING+=("copilot → npm install -g @githubnext/github-copilot-cli   OR   gh extension install github/gh-copilot")
fi

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo ""
  die "Missing prerequisites:\n$(printf '  • %s\n' "${MISSING[@]}")\n\nInstall them and re-run this script."
fi

# Node version check (>= 18)
NODE_MAJOR=$(node -e "process.stdout.write(String(process.versions.node.split('.')[0]))")
if [[ "$NODE_MAJOR" -lt 18 ]]; then
  die "Node.js >= 18 required (found v$(node -v)). Update: https://nodejs.org/"
fi
ok "node $(node -v)"

# Copilot auth check
if [[ -n "$COPILOT_CMD" ]]; then
  if ! $COPILOT_CMD auth status >/dev/null 2>&1; then
    warn "copilot auth not configured. Attempting to continue…"
    warn "If it fails, run:  $COPILOT_CMD auth login"
  fi
fi

# ENV check
if [[ -z "${DISCORD_TOKEN:-}" ]]; then
  echo ""
  die "DISCORD_TOKEN is not set.\n\n  export DISCORD_TOKEN=\"your-bot-token-here\"\n\n  Create a bot at https://discord.com/developers/applications\n  → Bot → Reset Token → copy it.\n\n  Required bot permissions: Send Messages, Embed Links, Attach Files, Use Slash Commands\n  Required intents: Message Content"
fi
ok "DISCORD_TOKEN is set"

# ──────────────────────────────────────────────────────────────────────────────
# 3) Derive project name & paths
# ──────────────────────────────────────────────────────────────────────────────
PROJECT_NAME=$(basename "$REPO_URL" .git)
PROJECT_NAME=${PROJECT_NAME##*/}  # strip any remaining slashes

BASE="${BASE_ROOT:-$HOME/.local/share/discord-agent}"
REPOS="$BASE/repos"
APP="$BASE/app"
WORKSPACES="${WORKSPACES_ROOT:-$BASE/workspaces}"
REPO_DIR="$REPOS/$PROJECT_NAME"

info "Project:    $PROJECT_NAME"
info "Base:       $BASE"
info "Repo:       $REPO_DIR"
info "App:        $APP"
info "Workspaces: $WORKSPACES"

mkdir -p "$REPOS" "$APP/src" "$WORKSPACES"

# ──────────────────────────────────────────────────────────────────────────────
# 4) Clone or update repo
# ──────────────────────────────────────────────────────────────────────────────
if [[ -d "$REPO_DIR/.git" ]]; then
  info "Updating existing repo…"
  git -C "$REPO_DIR" fetch --all --prune 2>/dev/null || true
  git -C "$REPO_DIR" pull --ff-only 2>/dev/null || warn "pull failed (diverged?) — using existing state"
  ok "Repo updated"
else
  info "Cloning $REPO_URL …"
  git clone "$REPO_URL" "$REPO_DIR"
  ok "Repo cloned"
fi

# ──────────────────────────────────────────────────────────────────────────────
# 5) Write application files (heredocs)
# ──────────────────────────────────────────────────────────────────────────────
info "Writing bot application…"

# ── package.json ─────────────────────────────────────────────────────────────
cat > "$APP/package.json" << 'HEREDOC_PACKAGE'
{
  "name": "discord-copilot-agent",
  "version": "1.0.0",
  "type": "module",
  "private": true,
  "scripts": {
    "start": "node src/bot.mjs"
  },
  "dependencies": {
    "discord.js": "^14.16.0",
    "@github/copilot-sdk": "^0.1.25",
    "better-sqlite3": "^11.0.0"
  }
}
HEREDOC_PACKAGE

# ── src/config.mjs ──────────────────────────────────────────────────────────
cat > "$APP/src/config.mjs" << 'HEREDOC_CONFIG'
import { join } from "node:path";
import { homedir } from "node:os";

// ── Required ────────────────────────────────────────────────────────────────
const DISCORD_TOKEN = process.env.DISCORD_TOKEN;
if (!DISCORD_TOKEN) {
  console.error(
    `\n[FATAL] DISCORD_TOKEN is not set.\n\n` +
      `  export DISCORD_TOKEN="your-bot-token-here"\n\n` +
      `Create a bot at https://discord.com/developers/applications\n` +
      `then copy the token and set it as an environment variable.\n`
  );
  process.exit(1);
}

// ── Paths ───────────────────────────────────────────────────────────────────
const BASE_ROOT =
  process.env.BASE_ROOT || join(homedir(), ".local", "share", "discord-agent");
const WORKSPACES_ROOT =
  process.env.WORKSPACES_ROOT || join(BASE_ROOT, "workspaces");
const REPOS_ROOT = join(BASE_ROOT, "repos");
const STATE_DB_PATH = join(BASE_ROOT, "state.sqlite");

// ── Project (set at runtime by agent.sh via env) ────────────────────────────
const PROJECT_NAME = process.env.PROJECT_NAME || "default";
const REPO_PATH = process.env.REPO_PATH || join(REPOS_ROOT, PROJECT_NAME);

// ── Optional filters ────────────────────────────────────────────────────────
function csvToSet(envVal) {
  if (!envVal) return null;
  return new Set(envVal.split(",").map((s) => s.trim()).filter(Boolean));
}

const ALLOWED_GUILDS = csvToSet(process.env.ALLOWED_GUILDS);
const ALLOWED_CHANNELS = csvToSet(process.env.ALLOWED_CHANNELS);
const ADMIN_ROLE_IDS = csvToSet(process.env.ADMIN_ROLE_IDS);

// ── Tunables ────────────────────────────────────────────────────────────────
const DISCORD_EDIT_THROTTLE_MS = parseInt(
  process.env.DISCORD_EDIT_THROTTLE_MS || "1500",
  10
);
const DEFAULT_GRANT_MODE = "ro";
const DEFAULT_GRANT_TTL_MIN = 30;

export {
  DISCORD_TOKEN,
  BASE_ROOT,
  WORKSPACES_ROOT,
  REPOS_ROOT,
  STATE_DB_PATH,
  PROJECT_NAME,
  REPO_PATH,
  ALLOWED_GUILDS,
  ALLOWED_CHANNELS,
  ADMIN_ROLE_IDS,
  DISCORD_EDIT_THROTTLE_MS,
  DEFAULT_GRANT_MODE,
  DEFAULT_GRANT_TTL_MIN,
};
HEREDOC_CONFIG

# ── src/state.mjs ───────────────────────────────────────────────────────────
cat > "$APP/src/state.mjs" << 'HEREDOC_STATE'
import Database from "better-sqlite3";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { STATE_DB_PATH } from "./config.mjs";

// Ensure parent directory exists
mkdirSync(dirname(STATE_DB_PATH), { recursive: true });

const db = new Database(STATE_DB_PATH);
db.pragma("journal_mode = WAL");
db.pragma("foreign_keys = ON");

// ── Schema ──────────────────────────────────────────────────────────────────
db.exec(`
  CREATE TABLE IF NOT EXISTS sessions (
    channel_id    TEXT PRIMARY KEY,
    project_name  TEXT NOT NULL,
    workspace_path TEXT NOT NULL,
    branch        TEXT NOT NULL,
    status        TEXT NOT NULL DEFAULT 'idle',
    created_at    TEXT NOT NULL DEFAULT (datetime('now'))
  );

  CREATE TABLE IF NOT EXISTS grants (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    channel_id  TEXT NOT NULL,
    path        TEXT NOT NULL,
    mode        TEXT NOT NULL DEFAULT 'ro',
    expires_at  TEXT NOT NULL,
    UNIQUE(channel_id, path)
  );

  CREATE TABLE IF NOT EXISTS task_history (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    channel_id   TEXT NOT NULL,
    prompt       TEXT NOT NULL,
    status       TEXT NOT NULL DEFAULT 'running',
    started_at   TEXT NOT NULL DEFAULT (datetime('now')),
    completed_at TEXT
  );

  CREATE INDEX IF NOT EXISTS idx_task_history_channel
    ON task_history(channel_id, started_at DESC);

  CREATE INDEX IF NOT EXISTS idx_grants_channel
    ON grants(channel_id);
`);

// ── Sessions ────────────────────────────────────────────────────────────────
const stmtUpsertSession = db.prepare(`
  INSERT INTO sessions (channel_id, project_name, workspace_path, branch, status)
  VALUES (@channelId, @projectName, @workspacePath, @branch, @status)
  ON CONFLICT(channel_id) DO UPDATE SET
    project_name   = excluded.project_name,
    workspace_path = excluded.workspace_path,
    branch         = excluded.branch,
    status         = excluded.status
`);

const stmtGetSession = db.prepare(
  `SELECT * FROM sessions WHERE channel_id = ?`
);

const stmtAllSessions = db.prepare(`SELECT * FROM sessions`);

const stmtUpdateSessionStatus = db.prepare(
  `UPDATE sessions SET status = ? WHERE channel_id = ?`
);

const stmtDeleteSession = db.prepare(
  `DELETE FROM sessions WHERE channel_id = ?`
);

export function upsertSession(channelId, projectName, workspacePath, branch, status = "idle") {
  stmtUpsertSession.run({ channelId, projectName, workspacePath, branch, status });
}

export function getSession(channelId) {
  return stmtGetSession.get(channelId) || null;
}

export function getAllSessions() {
  return stmtAllSessions.all();
}

export function updateSessionStatus(channelId, status) {
  stmtUpdateSessionStatus.run(status, channelId);
}

export function deleteSession(channelId) {
  stmtDeleteSession.run(channelId);
}

// ── Grants ──────────────────────────────────────────────────────────────────
const stmtUpsertGrant = db.prepare(`
  INSERT INTO grants (channel_id, path, mode, expires_at)
  VALUES (@channelId, @path, @mode, @expiresAt)
  ON CONFLICT(channel_id, path) DO UPDATE SET
    mode       = excluded.mode,
    expires_at = excluded.expires_at
`);

const stmtGetGrants = db.prepare(
  `SELECT * FROM grants WHERE channel_id = ?`
);

const stmtDeleteGrant = db.prepare(
  `DELETE FROM grants WHERE channel_id = ? AND path = ?`
);

const stmtDeleteExpiredGrants = db.prepare(
  `DELETE FROM grants WHERE expires_at <= datetime('now')`
);

const stmtDeleteGrantsByChannel = db.prepare(
  `DELETE FROM grants WHERE channel_id = ?`
);

export function upsertGrant(channelId, grantPath, mode, expiresAt) {
  stmtUpsertGrant.run({ channelId, path: grantPath, mode, expiresAt });
}

export function getGrants(channelId) {
  return stmtGetGrants.all(channelId);
}

export function deleteGrant(channelId, grantPath) {
  stmtDeleteGrant.run(channelId, grantPath);
}

export function deleteExpiredGrants() {
  return stmtDeleteExpiredGrants.run();
}

export function deleteGrantsByChannel(channelId) {
  stmtDeleteGrantsByChannel.run(channelId);
}

// ── Task History ────────────────────────────────────────────────────────────
const stmtInsertTask = db.prepare(`
  INSERT INTO task_history (channel_id, prompt, status)
  VALUES (?, ?, 'running')
`);

const stmtCompleteTask = db.prepare(`
  UPDATE task_history SET status = ?, completed_at = datetime('now')
  WHERE id = ?
`);

const stmtLatestTask = db.prepare(`
  SELECT * FROM task_history WHERE channel_id = ?
  ORDER BY started_at DESC LIMIT 1
`);

const stmtTaskHistory = db.prepare(`
  SELECT * FROM task_history WHERE channel_id = ?
  ORDER BY started_at DESC LIMIT ?
`);

export function insertTask(channelId, prompt) {
  const info = stmtInsertTask.run(channelId, prompt);
  return info.lastInsertRowid;
}

export function completeTask(taskId, status) {
  stmtCompleteTask.run(status, taskId);
}

export function getLatestTask(channelId) {
  return stmtLatestTask.get(channelId) || null;
}

export function getTaskHistory(channelId, limit = 10) {
  return stmtTaskHistory.all(channelId, limit);
}

// ── Cleanup ─────────────────────────────────────────────────────────────────
export function purgeExpiredGrants() {
  return deleteExpiredGrants().changes;
}

export function closeDb() {
  db.close();
}
HEREDOC_STATE

# ── src/policy-engine.mjs ───────────────────────────────────────────────────
cat > "$APP/src/policy-engine.mjs" << 'HEREDOC_POLICY'
import { realpathSync } from "node:fs";
import { resolve, sep } from "node:path";

// ── Path Security ───────────────────────────────────────────────────────────

function safePath(p) {
  try {
    return realpathSync(resolve(p));
  } catch {
    return resolve(p);
  }
}

export function isInsideWorkspace(targetPath, workspaceRoot) {
  const resolvedTarget = safePath(targetPath);
  const resolvedRoot = safePath(workspaceRoot);
  return (
    resolvedTarget === resolvedRoot ||
    resolvedTarget.startsWith(resolvedRoot + sep)
  );
}

// ── Git Push Detection ──────────────────────────────────────────────────────

const GIT_PUSH_PATTERNS = [
  /\bgit\s+push\b/i,
  /\bgit\s+remote\s+.*push\b/i,
  /\bgh\s+pr\s+create\b/i,
  /\bgh\s+pr\s+merge\b/i,
  /\bgh\s+pr\s+push\b/i,
];

const COMPOUND_SPLIT = /\s*(?:&&|\|\||[;|\n])\s*/;
const SUBSHELL_WRAPPER = /^\s*(?:sh|bash|zsh|dash)\s+-c\s+['"](.+)['"]\s*$/i;

function extractSubCommands(command) {
  const parts = command.split(COMPOUND_SPLIT).filter(Boolean);
  const result = [];
  for (const part of parts) {
    result.push(part);
    const m = SUBSHELL_WRAPPER.exec(part);
    if (m) result.push(...m[1].split(COMPOUND_SPLIT).filter(Boolean));
  }
  return result;
}

export function isGitPushCommand(command) {
  const parts = extractSubCommands(command);
  return parts.some((part) =>
    GIT_PUSH_PATTERNS.some((re) => re.test(part))
  );
}

// ── Grant Checking ──────────────────────────────────────────────────────────

export function isGranted(targetPath, grants, requiredMode = "ro") {
  const resolvedTarget = safePath(targetPath);
  for (const [grantPath, grant] of grants) {
    if (Date.now() > grant.expiry) continue;
    const resolvedGrant = safePath(grantPath);
    const isUnder =
      resolvedTarget === resolvedGrant ||
      resolvedTarget.startsWith(resolvedGrant + sep);
    if (!isUnder) continue;
    if (requiredMode === "ro") return true;
    if (requiredMode === "rw" && grant.mode === "rw") return true;
  }
  return false;
}

// ── Tool Name Classification ────────────────────────────────────────────────

const SHELL_TOOLS = new Set(["shell", "bash", "run_in_terminal", "terminal"]);
const READ_TOOLS = new Set([
  "read_file", "list_directory", "search_files",
  "grep_search", "file_search", "semantic_search",
]);
const WRITE_TOOLS = new Set([
  "write_file", "create_file", "delete_file",
  "replace_string_in_file", "edit_file", "rename_file",
]);

function extractPath(toolArgs) {
  return toolArgs?.path || toolArgs?.filePath || toolArgs?.file ||
    toolArgs?.directory || toolArgs?.target || null;
}

function extractCommand(toolArgs) {
  return toolArgs?.command || toolArgs?.cmd || toolArgs?.input || "";
}

function extractCwd(toolArgs) {
  return toolArgs?.cwd || toolArgs?.workingDirectory || null;
}

// ── Main Policy Decision ────────────────────────────────────────────────────

export function evaluateToolUse(toolName, toolArgs, workspaceRoot, grants) {
  if (SHELL_TOOLS.has(toolName)) {
    const cmd = extractCommand(toolArgs);
    if (isGitPushCommand(cmd)) {
      return {
        decision: "deny",
        reason: `git push requires Discord approval. Command: ${cmd}`,
        gate: "push",
      };
    }
    const cwd = extractCwd(toolArgs);
    if (cwd && !isInsideWorkspace(cwd, workspaceRoot) && !isGranted(cwd, grants, "ro")) {
      return {
        decision: "deny",
        reason: `Shell working directory is outside workspace: ${cwd}`,
        gate: "outside",
      };
    }
    const cdMatch = cmd.match(/\bcd\s+["']?([^\s"';&|]+)/);
    if (cdMatch) {
      const cdTarget = resolve(workspaceRoot, cdMatch[1]);
      if (!isInsideWorkspace(cdTarget, workspaceRoot) && !isGranted(cdTarget, grants, "ro")) {
        return {
          decision: "deny",
          reason: `Shell cd target is outside workspace: ${cdTarget}`,
          gate: "outside",
        };
      }
    }
    return { decision: "allow" };
  }

  if (READ_TOOLS.has(toolName)) {
    const filePath = extractPath(toolArgs);
    if (!filePath) return { decision: "allow" };
    if (isInsideWorkspace(filePath, workspaceRoot)) return { decision: "allow" };
    if (isGranted(filePath, grants, "ro")) return { decision: "allow" };
    return {
      decision: "deny",
      reason: `Read access outside workspace denied: ${filePath}`,
      gate: "outside",
    };
  }

  if (WRITE_TOOLS.has(toolName)) {
    const filePath = extractPath(toolArgs);
    if (!filePath) return { decision: "allow" };
    if (isInsideWorkspace(filePath, workspaceRoot)) return { decision: "allow" };
    if (isGranted(filePath, grants, "rw")) return { decision: "allow" };
    return {
      decision: "deny",
      reason: `Write access outside workspace denied: ${filePath}`,
      gate: "outside",
    };
  }

  return { decision: "allow" };
}
HEREDOC_POLICY

# ── src/grants.mjs ──────────────────────────────────────────────────────────
cat > "$APP/src/grants.mjs" << 'HEREDOC_GRANTS'
import { DEFAULT_GRANT_MODE, DEFAULT_GRANT_TTL_MIN } from "./config.mjs";
import {
  upsertGrant,
  deleteGrant,
  getGrants as dbGetGrants,
  deleteGrantsByChannel,
  purgeExpiredGrants,
} from "./state.mjs";

const grantStore = new Map();

function channelGrants(channelId) {
  if (!grantStore.has(channelId)) {
    grantStore.set(channelId, new Map());
  }
  return grantStore.get(channelId);
}

export function getActiveGrants(channelId) {
  const grants = channelGrants(channelId);
  const now = Date.now();
  for (const [p, g] of grants) {
    if (now > g.expiry) {
      clearTimeout(g.timer);
      grants.delete(p);
    }
  }
  return grants;
}

export function addGrant(channelId, grantPath, mode, ttlMinutes) {
  mode = mode || DEFAULT_GRANT_MODE;
  ttlMinutes = ttlMinutes ?? DEFAULT_GRANT_TTL_MIN;

  const expiry = Date.now() + ttlMinutes * 60_000;
  const expiresAt = new Date(expiry).toISOString();

  upsertGrant(channelId, grantPath, mode, expiresAt);

  const grants = channelGrants(channelId);
  const existing = grants.get(grantPath);
  if (existing?.timer) clearTimeout(existing.timer);

  const timer = setTimeout(() => {
    revokeGrant(channelId, grantPath);
  }, ttlMinutes * 60_000);
  timer.unref();

  grants.set(grantPath, { mode, expiry, timer });

  return { path: grantPath, mode, ttlMinutes, expiresAt };
}

export function revokeGrant(channelId, grantPath) {
  const grants = channelGrants(channelId);
  const existing = grants.get(grantPath);
  if (existing?.timer) clearTimeout(existing.timer);
  grants.delete(grantPath);
  deleteGrant(channelId, grantPath);
  return true;
}

export function revokeAllGrants(channelId) {
  const grants = channelGrants(channelId);
  for (const [, g] of grants) {
    if (g.timer) clearTimeout(g.timer);
  }
  grants.clear();
  deleteGrantsByChannel(channelId);
}

export function restoreGrants(channelId) {
  const rows = dbGetGrants(channelId);
  const now = Date.now();
  for (const row of rows) {
    const expiry = new Date(row.expires_at).getTime();
    if (expiry <= now) continue;
    const remaining = expiry - now;
    const grants = channelGrants(channelId);
    const timer = setTimeout(() => {
      revokeGrant(channelId, row.path);
    }, remaining);
    timer.unref();
    grants.set(row.path, { mode: row.mode, expiry, timer });
  }
}

export function startGrantCleanup(intervalMs = 60_000) {
  const timer = setInterval(() => {
    purgeExpiredGrants();
  }, intervalMs);
  timer.unref();
  return timer;
}
HEREDOC_GRANTS

# ── src/discord-output.mjs ──────────────────────────────────────────────────
cat > "$APP/src/discord-output.mjs" << 'HEREDOC_DISCORDOUT'
import { DISCORD_EDIT_THROTTLE_MS } from "./config.mjs";
import { AttachmentBuilder } from "discord.js";

export class DiscordOutput {
  constructor(channel) {
    this.channel = channel;
    this.buffer = "";
    this.message = null;
    this.lastEdit = 0;
    this.editTimer = null;
    this.finished = false;
    this._flushing = false;
    this._flushQueued = false;
  }

  append(text) {
    this.buffer += text;
    this._scheduleEdit();
  }

  async status(text) {
    try {
      if (this.buffer.length + text.length + 2 < 1900) {
        this.buffer += `\n${text}`;
        this._scheduleEdit();
        return;
      }
      await this.flush();
      this.buffer = text;
      this._scheduleEdit();
    } catch { /* swallow */ }
  }

  async finish(epilogue = "") {
    this.finished = true;
    if (this.editTimer) {
      clearTimeout(this.editTimer);
      this.editTimer = null;
    }
    if (epilogue) this.buffer += `\n${epilogue}`;
    await this.flush();
  }

  async flush() {
    if (!this.buffer) return;
    if (this._flushing) {
      this._flushQueued = true;
      return;
    }
    this._flushing = true;
    const content = this.buffer;
    this.buffer = "";

    try {
      if (content.length <= 1990) {
        if (this.message) {
          await this.message.edit(content);
        } else {
          this.message = await this.channel.send(content);
        }
      } else {
        await this._sendAsAttachment(content);
        this.message = null;
      }
    } catch (err) {
      if (err.code === 10008 || err.code === 50005) {
        this.message = null;
        try {
          if (content.length <= 1990) {
            this.message = await this.channel.send(content);
          } else {
            await this._sendAsAttachment(content);
          }
        } catch { /* give up */ }
      }
    } finally {
      this._flushing = false;
      if (this._flushQueued) {
        this._flushQueued = false;
        await this.flush();
      }
    }
  }

  async _sendAsAttachment(content) {
    const attachment = new AttachmentBuilder(Buffer.from(content, "utf-8"), {
      name: "output.txt",
      description: "Agent output (too large for a message)",
    });
    await this.channel.send({ files: [attachment] });
  }

  _scheduleEdit() {
    if (this.finished || this.editTimer) return;
    const elapsed = Date.now() - this.lastEdit;
    const delay = Math.max(0, DISCORD_EDIT_THROTTLE_MS - elapsed);
    this.editTimer = setTimeout(async () => {
      this.editTimer = null;
      this.lastEdit = Date.now();
      await this.flush();
    }, delay);
  }
}
HEREDOC_DISCORDOUT

# ── src/push-approval.mjs ───────────────────────────────────────────────────
cat > "$APP/src/push-approval.mjs" << 'HEREDOC_PUSH'
import {
  EmbedBuilder,
  ActionRowBuilder,
  ButtonBuilder,
  ButtonStyle,
} from "discord.js";
import { execSync } from "node:child_process";

export async function createPushApprovalRequest(channel, workspacePath, command) {
  let diffSummary = "";
  let logSummary = "";

  try {
    diffSummary = execSync("git diff --stat HEAD~1 2>/dev/null || git diff --stat", {
      cwd: workspacePath, encoding: "utf-8", timeout: 10_000, shell: true,
    }).slice(0, 900);
  } catch { diffSummary = "(diff unavailable)"; }

  try {
    logSummary = execSync("git log --oneline -5", {
      cwd: workspacePath, encoding: "utf-8", timeout: 5_000,
    }).slice(0, 500);
  } catch { logSummary = "(log unavailable)"; }

  const embed = new EmbedBuilder()
    .setTitle("\u{1F680} Push Approval Required")
    .setColor(0xff9900)
    .setDescription(
      `The agent wants to execute:\n\`\`\`\n${command.slice(0, 200)}\n\`\`\``
    )
    .addFields(
      { name: "Recent Commits", value: `\`\`\`\n${logSummary}\n\`\`\``, inline: false },
      { name: "Diff Summary", value: `\`\`\`\n${diffSummary}\n\`\`\``, inline: false },
      { name: "Workspace", value: workspacePath, inline: true }
    )
    .setTimestamp();

  const row = new ActionRowBuilder().addComponents(
    new ButtonBuilder()
      .setCustomId("push_approve")
      .setLabel("\u2705 Approve Push")
      .setStyle(ButtonStyle.Success),
    new ButtonBuilder()
      .setCustomId("push_reject")
      .setLabel("\u274C Reject Push")
      .setStyle(ButtonStyle.Danger)
  );

  const msg = await channel.send({ embeds: [embed], components: [row] });

  return new Promise((resolve) => {
    const collector = msg.createMessageComponentCollector({
      filter: (i) => i.customId === "push_approve" || i.customId === "push_reject",
      max: 1,
      time: 600_000,
    });

    collector.on("collect", async (interaction) => {
      const approved = interaction.customId === "push_approve";
      const label = approved ? "\u2705 Push approved" : "\u274C Push rejected";
      const color = approved ? 0x00cc00 : 0xcc0000;

      const updatedEmbed = EmbedBuilder.from(embed)
        .setColor(color)
        .setFooter({ text: `${label} by ${interaction.user.tag}` });

      await interaction.update({
        embeds: [updatedEmbed],
        components: [],
      });

      resolve({ approved, user: interaction.user.tag });
    });

    collector.on("end", (collected) => {
      if (collected.size === 0) {
        msg.edit({ components: [] }).catch(() => {});
        resolve({ approved: false, user: "(timeout)" });
      }
    });
  });
}

export async function executePush(channel, workspacePath, command) {
  try {
    const output = execSync(command, {
      cwd: workspacePath, encoding: "utf-8", timeout: 60_000,
    });

    const embed = new EmbedBuilder()
      .setTitle("\u2705 Push Successful")
      .setColor(0x00cc00)
      .setDescription(`\`\`\`\n${(output || "(no output)").slice(0, 1800)}\n\`\`\``)
      .setTimestamp();

    await channel.send({ embeds: [embed] });
    return { success: true, output };
  } catch (err) {
    const embed = new EmbedBuilder()
      .setTitle("\u274C Push Failed")
      .setColor(0xcc0000)
      .setDescription(`\`\`\`\n${(err.stderr || err.message || "").slice(0, 1800)}\n\`\`\``)
      .setTimestamp();

    await channel.send({ embeds: [embed] });
    return { success: false, error: err.message };
  }
}
HEREDOC_PUSH

# ── src/copilot-client.mjs ──────────────────────────────────────────────────
cat > "$APP/src/copilot-client.mjs" << 'HEREDOC_COPILOT'
import { CopilotClient, approveAll } from "@github/copilot-sdk";
import { evaluateToolUse } from "./policy-engine.mjs";
import { getActiveGrants } from "./grants.mjs";

let client = null;

export function getCopilotClient() {
  if (!client) {
    client = new CopilotClient({
      useStdio: true,
      autoRestart: true,
    });
  }
  return client;
}

export async function createAgentSession(opts) {
  const {
    channelId, workspacePath,
    onPushRequest, onOutsideRequest,
    onDelta, onToolStart, onToolComplete, onIdle, onUserQuestion,
  } = opts;

  const copilot = getCopilotClient();

  const session = await copilot.createSession({
    workingDirectory: workspacePath,
    streaming: true,
    onPermissionRequest: approveAll,

    onUserInputRequest: async (request) => {
      if (onUserQuestion) {
        const answer = await onUserQuestion(request.question, request.choices);
        return { answer, wasFreeform: !request.choices };
      }
      return { answer: "No user available. Proceed with your best judgment.", wasFreeform: true };
    },

    hooks: {
      onPreToolUse: async (input) => {
        const grants = getActiveGrants(channelId);
        const result = evaluateToolUse(
          input.toolName, input.toolArgs, workspacePath, grants
        );

        if (result.decision === "allow") {
          return { permissionDecision: "allow" };
        }

        if (result.gate === "push") {
          if (onPushRequest) {
            const command = input.toolArgs?.command || input.toolArgs?.cmd || "";
            const { approved } = await onPushRequest(command);
            if (approved) return { permissionDecision: "allow" };
          }
          return {
            permissionDecision: "deny",
            additionalContext:
              "Push was denied by the user. Do NOT retry pushing. " +
              "Inform the user that the push was rejected and ask what to do instead.",
          };
        }

        if (result.gate === "outside") {
          if (onOutsideRequest) onOutsideRequest(result.reason);
          return {
            permissionDecision: "deny",
            additionalContext:
              `Access denied: ${result.reason}. ` +
              "The user must grant access via /grant command first. " +
              "Do NOT retry this operation.",
          };
        }

        return {
          permissionDecision: "deny",
          additionalContext: result.reason || "Action denied by policy.",
        };
      },

      onErrorOccurred: async (input) => {
        console.error("[copilot] Error:", input.error, input.errorContext);
        return { errorHandling: "skip" };
      },
    },

    systemMessage: {
      content: [
        `You are an autonomous coding agent working in: ${workspacePath}`,
        "You may freely edit files, run tests, lint, build, and create git branches/commits within the workspace.",
        "IMPORTANT RULES:",
        "1. You CANNOT git push or publish PRs without explicit user approval — the system will block it.",
        "2. You CANNOT access files outside the workspace directory without explicit grants.",
        "3. If a push is denied, inform the user and stop retrying.",
        "4. If file access outside the workspace is denied, tell the user which path you need and ask them to use /grant.",
        "5. Always run tests before suggesting a push.",
        "6. Provide clear summaries of what you changed and why.",
      ].join("\n"),
    },
  });

  if (onDelta) {
    session.on("assistant.message_delta", (event) => {
      onDelta(event.data?.deltaContent || "");
    });
  }
  if (onToolStart) {
    session.on("tool.execution_start", (event) => {
      onToolStart(event.data?.toolName || "unknown");
    });
  }
  if (onToolComplete) {
    session.on("tool.execution_complete", (event) => {
      onToolComplete(
        event.data?.toolName || "unknown",
        event.data?.success ?? true,
        event.data?.error
      );
    });
  }
  if (onIdle) {
    session.on("session.idle", () => { onIdle(); });
  }

  return session;
}

export async function stopCopilotClient() {
  if (client) {
    await client.stop();
    client = null;
  }
}
HEREDOC_COPILOT

# ── src/session-manager.mjs ─────────────────────────────────────────────────
cat > "$APP/src/session-manager.mjs" << 'HEREDOC_SESSION'
import { execSync } from "node:child_process";
import { mkdirSync, existsSync } from "node:fs";
import { join } from "node:path";
import { WORKSPACES_ROOT, PROJECT_NAME, REPO_PATH } from "./config.mjs";
import {
  upsertSession, getSession, getAllSessions,
  updateSessionStatus, deleteSession as dbDeleteSession,
  insertTask, completeTask,
  getTaskHistory as dbGetTaskHistory,
} from "./state.mjs";
import { createAgentSession } from "./copilot-client.mjs";
import { getActiveGrants, restoreGrants, revokeAllGrants } from "./grants.mjs";
import { DiscordOutput } from "./discord-output.mjs";
import { createPushApprovalRequest } from "./push-approval.mjs";

const sessions = new Map();

// ── Workspace Setup ─────────────────────────────────────────────────────────

function createWorktree(channelId) {
  const wsRoot = join(WORKSPACES_ROOT, PROJECT_NAME);
  mkdirSync(wsRoot, { recursive: true });

  const worktreePath = join(wsRoot, channelId);

  if (existsSync(worktreePath)) {
    let branch;
    try {
      branch = execSync("git branch --show-current", {
        cwd: worktreePath, encoding: "utf-8", stdio: ["pipe", "pipe", "pipe"],
      }).trim();
    } catch {
      branch = `agent/${channelId.slice(-8)}-recovered`;
    }
    return { workspacePath: worktreePath, branch };
  }

  const branchName = `agent/${channelId.slice(-8)}-${Date.now().toString(36)}`;

  try {
    execSync(`git branch "${branchName}" HEAD`, { cwd: REPO_PATH, stdio: "pipe" });
  } catch { /* branch may exist */ }

  try {
    execSync(`git worktree add "${worktreePath}" "${branchName}"`, { cwd: REPO_PATH, stdio: "pipe" });
  } catch (err) {
    if (!existsSync(worktreePath)) throw err;
  }

  return { workspacePath: worktreePath, branch: branchName };
}

// ── Session CRUD ────────────────────────────────────────────────────────────

export async function getOrCreateSession(channelId, channel) {
  if (sessions.has(channelId)) return sessions.get(channelId);

  const dbRow = getSession(channelId);
  let workspacePath, branch;

  if (dbRow && existsSync(dbRow.workspace_path)) {
    workspacePath = dbRow.workspace_path;
    branch = dbRow.branch;
  } else {
    const wt = createWorktree(channelId);
    workspacePath = wt.workspacePath;
    branch = wt.branch;
  }

  const copilotSession = await createAgentSession({
    channelId, workspacePath,

    onPushRequest: async (command) => {
      return createPushApprovalRequest(channel, workspacePath, command);
    },

    onOutsideRequest: (reason) => {
      channel.send(
        `\u26D4 **Access Denied**\n${reason}\n\n` +
        "Use `/grant path:<absolute-path> mode:ro ttl:30` to allow access."
      ).catch(() => {});
    },

    onDelta: (text) => {
      sessions.get(channelId)?.output?.append(text);
    },

    onToolStart: (toolName) => {
      sessions.get(channelId)?.output?.status(`\u{1F527} \`${toolName}\`\u2026`);
    },

    onToolComplete: (toolName, success, error) => {
      const ctx = sessions.get(channelId);
      const icon = success ? "\u2705" : "\u274C";
      ctx?.output?.status(`${icon} \`${toolName}\`${error ? `: ${error}` : ""}`);
    },

    onIdle: () => {
      const ctx = sessions.get(channelId);
      if (ctx) {
        ctx.output?.finish("\u2728 **Task complete.**");
        ctx.status = "idle";
        updateSessionStatus(channelId, "idle");
      }
    },

    onUserQuestion: async (question, choices) => {
      await channel.send(
        `\u2753 **Agent asks:**\n${question}` +
        (choices ? `\nOptions: ${choices.join(", ")}` : "")
      );
      try {
        const collected = await channel.awaitMessages({
          max: 1, time: 300_000,
          filter: (m) => !m.author.bot,
        });
        return collected.first()?.content || "No answer provided.";
      } catch {
        return "No answer provided within timeout.";
      }
    },
  });

  const ctx = {
    copilotSession, workspacePath, branch,
    status: "idle", currentTask: null,
    queue: [], output: null, taskId: null,
    paused: false, _aborted: false,
  };

  sessions.set(channelId, ctx);
  upsertSession(channelId, PROJECT_NAME, workspacePath, branch, "idle");
  restoreGrants(channelId);

  return ctx;
}

// ── Task Execution ──────────────────────────────────────────────────────────

export async function enqueueTask(channelId, channel, prompt) {
  const ctx = await getOrCreateSession(channelId, channel);

  return new Promise((resolve, reject) => {
    ctx.queue.push({ prompt, resolve, reject });
    processQueue(channelId, channel);
  });
}

async function processQueue(channelId, channel) {
  const ctx = sessions.get(channelId);
  if (!ctx || ctx.status === "working" || ctx.paused) return;
  if (ctx.queue.length === 0) return;

  const { prompt, resolve, reject } = ctx.queue.shift();

  ctx.status = "working";
  updateSessionStatus(channelId, "working");
  ctx.output = new DiscordOutput(channel);
  ctx.taskId = insertTask(channelId, prompt);

  try {
    const response = await ctx.copilotSession.sendAndWait({ prompt });
    completeTask(ctx.taskId, "completed");
    ctx.status = "idle";
    updateSessionStatus(channelId, "idle");
    resolve(response);
  } catch (err) {
    if (ctx._aborted) {
      ctx._aborted = false;
    } else {
      completeTask(ctx.taskId, "failed");
      ctx.status = "idle";
      updateSessionStatus(channelId, "idle");
      ctx.output?.finish(`\u274C **Error:** ${err.message}`);
    }
    reject(err);
  } finally {
    ctx.output = null;
    if (!ctx.paused) {
      processQueue(channelId, channel);
    }
  }
}

// ── Approve Push ────────────────────────────────────────────────────────────

export async function approvePendingPush(channelId, channel) {
  const ctx = sessions.get(channelId);
  if (!ctx) return { found: false };
  await channel.send(
    "\u2139\uFE0F Use the **Approve Push** button on the push request message, " +
    "or wait for the next push attempt."
  );
  return { found: true };
}

// ── Status ──────────────────────────────────────────────────────────────────

export function getSessionStatus(channelId) {
  const ctx = sessions.get(channelId);
  if (!ctx) return null;

  const grants = getActiveGrants(channelId);
  const grantList = [];
  for (const [p, g] of grants) {
    grantList.push({
      path: p, mode: g.mode,
      expiresIn: Math.max(0, Math.round((g.expiry - Date.now()) / 60_000)),
    });
  }

  return {
    status: ctx.status, paused: ctx.paused,
    workspace: ctx.workspacePath, branch: ctx.branch,
    queueLength: ctx.queue.length, grants: grantList,
  };
}

// ── Reset ───────────────────────────────────────────────────────────────────

export async function resetSession(channelId) {
  const ctx = sessions.get(channelId);
  if (ctx) {
    try { ctx.copilotSession.abort(); ctx.copilotSession.destroy(); } catch {}
    for (const item of ctx.queue) item.reject(new Error("Session reset"));
  }
  sessions.delete(channelId);
  revokeAllGrants(channelId);
  dbDeleteSession(channelId);
}

// ── Hard Stop ───────────────────────────────────────────────────────────────

export function hardStop(channelId, clearQueue = true) {
  const ctx = sessions.get(channelId);
  if (!ctx) return { found: false };

  const wasWorking = ctx.status === "working";
  let queueCleared = 0;

  if (wasWorking) {
    ctx._aborted = true;
    try { ctx.copilotSession.abort(); } catch {}
    if (ctx.taskId) {
      completeTask(ctx.taskId, "aborted");
      ctx.taskId = null;
    }
    ctx.output?.finish("\u{1F6D1} **Task aborted by user.**");
    ctx.output = null;
    ctx.status = "idle";
    updateSessionStatus(channelId, "idle");
  }

  if (clearQueue && ctx.queue.length > 0) {
    queueCleared = ctx.queue.length;
    for (const item of ctx.queue) item.reject(new Error("Cleared by /stop"));
    ctx.queue = [];
  }

  return { found: true, wasWorking, queueCleared };
}

// ── Pause / Resume ──────────────────────────────────────────────────────────

export function pauseSession(channelId) {
  const ctx = sessions.get(channelId);
  if (!ctx) return { found: false };
  ctx.paused = true;
  return { found: true, wasAlreadyPaused: false };
}

export function resumeSession(channelId, channel) {
  const ctx = sessions.get(channelId);
  if (!ctx) return { found: false };
  const wasPaused = ctx.paused;
  ctx.paused = false;
  if (wasPaused && ctx.queue.length > 0) processQueue(channelId, channel);
  return { found: true, wasPaused };
}

// ── Queue Management ────────────────────────────────────────────────────────

export function clearQueue(channelId) {
  const ctx = sessions.get(channelId);
  if (!ctx) return { found: false, cleared: 0 };
  const cleared = ctx.queue.length;
  for (const item of ctx.queue) item.reject(new Error("Queue cleared"));
  ctx.queue = [];
  return { found: true, cleared };
}

export function getQueueInfo(channelId) {
  const ctx = sessions.get(channelId);
  if (!ctx) return null;
  return {
    paused: ctx.paused,
    length: ctx.queue.length,
    items: ctx.queue.map((q, i) => ({ index: i + 1, prompt: q.prompt.slice(0, 100) })),
  };
}

// ── Task History ────────────────────────────────────────────────────────────

export function getTaskHistory(channelId, limit = 10) {
  return dbGetTaskHistory(channelId, limit);
}

// ── Restore ─────────────────────────────────────────────────────────────────

export function getStoredSessions() {
  return getAllSessions();
}
HEREDOC_SESSION

# ── src/bot.mjs ──────────────────────────────────────────────────────────────
cat > "$APP/src/bot.mjs" << 'HEREDOC_BOT'
import {
  Client, GatewayIntentBits, REST, Routes,
  SlashCommandBuilder, EmbedBuilder,
} from "discord.js";

import {
  DISCORD_TOKEN, ALLOWED_GUILDS, ALLOWED_CHANNELS,
  ADMIN_ROLE_IDS, PROJECT_NAME,
  DISCORD_EDIT_THROTTLE_MS, DEFAULT_GRANT_MODE, DEFAULT_GRANT_TTL_MIN,
  BASE_ROOT, WORKSPACES_ROOT, REPO_PATH,
} from "./config.mjs";

import {
  enqueueTask, getSessionStatus,
  approvePendingPush, resetSession,
  hardStop, pauseSession, resumeSession,
  clearQueue, getQueueInfo, getTaskHistory,
} from "./session-manager.mjs";

import { addGrant, revokeGrant, startGrantCleanup, restoreGrants } from "./grants.mjs";
import { closeDb, getAllSessions } from "./state.mjs";
import { stopCopilotClient } from "./copilot-client.mjs";

// ── Slash Commands ──────────────────────────────────────────────────────────

const commands = [
  new SlashCommandBuilder()
    .setName("task")
    .setDescription("Send a task to the coding agent")
    .addStringOption((o) =>
      o.setName("prompt").setDescription("Task description").setRequired(true)
    ),
  new SlashCommandBuilder()
    .setName("status")
    .setDescription("Show current agent session status"),
  new SlashCommandBuilder()
    .setName("approve_push")
    .setDescription("Approve a pending git push"),
  new SlashCommandBuilder()
    .setName("grant")
    .setDescription("Grant agent access to a path outside workspace")
    .addStringOption((o) =>
      o.setName("path").setDescription("Absolute path to grant").setRequired(true)
    )
    .addStringOption((o) =>
      o.setName("mode").setDescription("Access mode")
        .addChoices({ name: "Read Only", value: "ro" }, { name: "Read/Write", value: "rw" })
    )
    .addIntegerOption((o) =>
      o.setName("ttl").setDescription("Time-to-live in minutes (default: 30)")
        .setMinValue(1).setMaxValue(1440)
    ),
  new SlashCommandBuilder()
    .setName("revoke")
    .setDescription("Revoke agent access to a path")
    .addStringOption((o) =>
      o.setName("path").setDescription("Absolute path to revoke").setRequired(true)
    ),
  new SlashCommandBuilder()
    .setName("reset")
    .setDescription("Reset the agent session for this channel"),
  new SlashCommandBuilder()
    .setName("stop")
    .setDescription("Hard stop \u2014 abort the running task immediately")
    .addBooleanOption((o) =>
      o.setName("clear_queue").setDescription("Also clear all pending tasks (default: true)")
    ),
  new SlashCommandBuilder()
    .setName("pause")
    .setDescription("Pause queue processing (current task finishes, no new ones start)"),
  new SlashCommandBuilder()
    .setName("resume")
    .setDescription("Resume queue processing after a pause"),
  new SlashCommandBuilder()
    .setName("queue")
    .setDescription("View or manage the task queue")
    .addStringOption((o) =>
      o.setName("action").setDescription("What to do")
        .addChoices({ name: "List pending tasks", value: "list" }, { name: "Clear all pending tasks", value: "clear" })
    ),
  new SlashCommandBuilder()
    .setName("history")
    .setDescription("Show recent task history")
    .addIntegerOption((o) =>
      o.setName("limit").setDescription("Number of tasks to show (default: 10)")
        .setMinValue(1).setMaxValue(50)
    ),
  new SlashCommandBuilder()
    .setName("config")
    .setDescription("View current bot configuration"),
];

// ── Access Control ──────────────────────────────────────────────────────────

function isAllowed(interaction) {
  if (ALLOWED_GUILDS && !ALLOWED_GUILDS.has(interaction.guildId)) return false;
  if (ALLOWED_CHANNELS && !ALLOWED_CHANNELS.has(interaction.channelId)) return false;
  if (ADMIN_ROLE_IDS) {
    const memberRoles = interaction.member?.roles?.cache;
    if (memberRoles) {
      const hasRole = [...ADMIN_ROLE_IDS].some((id) => memberRoles.has(id));
      if (!hasRole) return false;
    }
  }
  return true;
}

// ── Register Commands ───────────────────────────────────────────────────────

async function registerCommands(clientId) {
  const rest = new REST({ version: "10" }).setToken(DISCORD_TOKEN);
  const body = commands.map((c) => c.toJSON());

  if (ALLOWED_GUILDS && ALLOWED_GUILDS.size > 0) {
    for (const guildId of ALLOWED_GUILDS) {
      await rest.put(Routes.applicationGuildCommands(clientId, guildId), { body });
      console.log(`[discord] Registered commands in guild ${guildId}`);
    }
  } else {
    await rest.put(Routes.applicationCommands(clientId), { body });
    console.log("[discord] Registered global slash commands");
  }
}

// ── Client ──────────────────────────────────────────────────────────────────

const client = new Client({
  intents: [
    GatewayIntentBits.Guilds,
    GatewayIntentBits.GuildMessages,
    GatewayIntentBits.MessageContent,
  ],
});

client.once("ready", async () => {
  console.log(`[discord] Logged in as ${client.user.tag}`);
  try {
    await registerCommands(client.user.id);
  } catch (err) {
    console.error("[discord] Failed to register slash commands:", err.message);
    console.error("[discord] Bot will continue, but commands may not appear.");
  }
  startGrantCleanup();
  for (const row of getAllSessions()) restoreGrants(row.channel_id);
  console.log(`[discord] Bot ready \u2014 project: ${PROJECT_NAME}`);
});

// ── Interaction Handler ─────────────────────────────────────────────────────

client.on("interactionCreate", async (interaction) => {
  if (!interaction.isChatInputCommand() && !interaction.isButton()) return;
  if (interaction.isButton()) return;

  if (!isAllowed(interaction)) {
    await interaction.reply({ content: "\u26D4 No permission.", ephemeral: true });
    return;
  }

  const { commandName, channelId } = interaction;
  const channel = interaction.channel;

  try {
    switch (commandName) {
      case "task": {
        const prompt = interaction.options.getString("prompt");
        await interaction.reply(`\u{1F4CB} **Task queued:** ${prompt}`);
        enqueueTask(channelId, channel, prompt).catch((err) => {
          channel.send(`\u274C **Task failed:** ${err.message}`).catch(() => {});
        });
        break;
      }

      case "status": {
        const st = getSessionStatus(channelId);
        if (!st) {
          await interaction.reply({ content: "No active session. Use `/task` first.", ephemeral: true });
          break;
        }
        const grantLines = st.grants.length
          ? st.grants.map((g) => `\`${g.path}\` (${g.mode}, ${g.expiresIn}min left)`).join("\n")
          : "None";
        const embed = new EmbedBuilder()
          .setTitle("\u{1F4CA} Agent Status")
          .setColor(st.paused ? 0xff6600 : st.status === "working" ? 0x3498db : st.status === "idle" ? 0x2ecc71 : 0xff9900)
          .addFields(
            { name: "Status", value: st.paused ? `${st.status} (\u23F8 paused)` : st.status, inline: true },
            { name: "Branch", value: st.branch, inline: true },
            { name: "Queue", value: `${st.queueLength} pending`, inline: true },
            { name: "Workspace", value: `\`${st.workspace}\``, inline: false },
            { name: "Active Grants", value: grantLines, inline: false },
          )
          .setTimestamp();
        await interaction.reply({ embeds: [embed] });
        break;
      }

      case "approve_push": {
        await interaction.deferReply();
        const res = await approvePendingPush(channelId, channel);
        await interaction.editReply(res.found ? "\u2705 Push approval noted." : "No active session.");
        break;
      }

      case "grant": {
        const grantPath = interaction.options.getString("path");
        const mode = interaction.options.getString("mode") || "ro";
        const ttl = interaction.options.getInteger("ttl") || 30;
        if (!grantPath.startsWith("/") && !/^[A-Z]:\\/i.test(grantPath)) {
          await interaction.reply({ content: "\u26A0\uFE0F Path must be absolute.", ephemeral: true });
          break;
        }
        const result = addGrant(channelId, grantPath, mode, ttl);
        const ts = Math.floor(new Date(result.expiresAt).getTime() / 1000);
        await interaction.reply(
          `\u2705 **Granted** \`${mode}\` access to \`${grantPath}\` for **${ttl} min** (expires <t:${ts}:R>).`
        );
        break;
      }

      case "revoke": {
        const path = interaction.options.getString("path");
        revokeGrant(channelId, path);
        await interaction.reply(`\u{1F512} **Revoked** access to \`${path}\`.`);
        break;
      }

      case "reset": {
        await interaction.deferReply();
        await resetSession(channelId);
        await interaction.editReply("\u{1F504} Session reset. Use `/task` to start a new one.");
        break;
      }

      case "stop": {
        const clearQ = interaction.options.getBoolean("clear_queue") ?? true;
        const result = hardStop(channelId, clearQ);
        if (!result.found) {
          await interaction.reply({ content: "No active session to stop.", ephemeral: true });
          break;
        }
        const parts = [];
        if (result.wasWorking) parts.push("Aborted running task");
        else parts.push("No task was running");
        if (result.queueCleared > 0) parts.push(`cleared ${result.queueCleared} queued task(s)`);
        await interaction.reply(`\u{1F6D1} **Stopped.** ${parts.join(", ")}.`);
        break;
      }

      case "pause": {
        const result = pauseSession(channelId);
        if (!result.found) {
          await interaction.reply({ content: "No active session to pause.", ephemeral: true });
          break;
        }
        await interaction.reply(
          "\u23F8 **Queue paused.** Current task (if any) will finish, but no new tasks will start.\n" +
          "Use `/resume` to continue or `/stop` to abort the running task."
        );
        break;
      }

      case "resume": {
        const result = resumeSession(channelId, channel);
        if (!result.found) {
          await interaction.reply({ content: "No active session to resume.", ephemeral: true });
          break;
        }
        if (!result.wasPaused) {
          await interaction.reply({ content: "Session was not paused.", ephemeral: true });
          break;
        }
        await interaction.reply("\u25B6\uFE0F **Queue resumed.** Pending tasks will now be processed.");
        break;
      }

      case "queue": {
        const action = interaction.options.getString("action") || "list";
        if (action === "clear") {
          const result = clearQueue(channelId);
          if (!result.found) {
            await interaction.reply({ content: "No active session.", ephemeral: true });
            break;
          }
          await interaction.reply(
            result.cleared > 0 ? `\u{1F5D1} Cleared **${result.cleared}** pending task(s).` : "Queue was already empty."
          );
          break;
        }
        const info = getQueueInfo(channelId);
        if (!info) {
          await interaction.reply({ content: "No active session. Use `/task` first.", ephemeral: true });
          break;
        }
        if (info.length === 0) {
          await interaction.reply({ content: `Queue is empty.${info.paused ? " *(paused)*" : ""}`, ephemeral: true });
          break;
        }
        const lines = info.items.map(
          (item) => `**${item.index}.** ${item.prompt}${item.prompt.length >= 100 ? "\u2026" : ""}`
        );
        const embed = new EmbedBuilder()
          .setTitle(`\u{1F4CB} Task Queue (${info.length} pending)`)
          .setColor(info.paused ? 0xff6600 : 0x3498db)
          .setDescription(lines.join("\n"))
          .setFooter({ text: info.paused ? "\u23F8 Queue is paused" : "Queue is active" });
        await interaction.reply({ embeds: [embed] });
        break;
      }

      case "history": {
        const limit = interaction.options.getInteger("limit") || 10;
        const tasks = getTaskHistory(channelId, limit);
        if (tasks.length === 0) {
          await interaction.reply({ content: "No task history for this channel.", ephemeral: true });
          break;
        }
        const statusIcon = { completed: "\u2705", failed: "\u274C", running: "\u23F3", aborted: "\u{1F6D1}" };
        const lns = tasks.map((t) => {
          const icon = statusIcon[t.status] || "\u2754";
          const pr = t.prompt.length > 60 ? t.prompt.slice(0, 60) + "\u2026" : t.prompt;
          const time = t.started_at ? `<t:${Math.floor(new Date(t.started_at + "Z").getTime() / 1000)}:R>` : "";
          return `${icon} ${pr} ${time}`;
        });
        const embed = new EmbedBuilder()
          .setTitle(`\u{1F4DC} Task History (last ${tasks.length})`)
          .setColor(0x9b59b6)
          .setDescription(lns.join("\n"))
          .setTimestamp();
        await interaction.reply({ embeds: [embed] });
        break;
      }

      case "config": {
        const embed = new EmbedBuilder()
          .setTitle("\u2699\uFE0F Bot Configuration")
          .setColor(0x95a5a6)
          .addFields(
            { name: "Project", value: PROJECT_NAME, inline: true },
            { name: "Repo Path", value: `\`${REPO_PATH}\``, inline: true },
            { name: "Base Root", value: `\`${BASE_ROOT}\``, inline: false },
            { name: "Workspaces Root", value: `\`${WORKSPACES_ROOT}\``, inline: false },
            { name: "Edit Throttle", value: `${DISCORD_EDIT_THROTTLE_MS} ms`, inline: true },
            { name: "Default Grant Mode", value: DEFAULT_GRANT_MODE, inline: true },
            { name: "Default Grant TTL", value: `${DEFAULT_GRANT_TTL_MIN} min`, inline: true },
            { name: "Guild Filter", value: ALLOWED_GUILDS ? [...ALLOWED_GUILDS].join(", ") : "*(all)*", inline: false },
            { name: "Channel Filter", value: ALLOWED_CHANNELS ? [...ALLOWED_CHANNELS].join(", ") : "*(all)*", inline: false },
            { name: "Admin Roles", value: ADMIN_ROLE_IDS ? [...ADMIN_ROLE_IDS].join(", ") : "*(none \u2014 all allowed)*", inline: false },
          )
          .setTimestamp();
        await interaction.reply({ embeds: [embed], ephemeral: true });
        break;
      }

      default:
        await interaction.reply({ content: "Unknown command.", ephemeral: true });
    }
  } catch (err) {
    console.error(`[discord] Command error (${commandName}):`, err);
    const reply = interaction.deferred || interaction.replied
      ? (msg) => interaction.editReply(msg)
      : (msg) => interaction.reply({ content: msg, ephemeral: true });
    await reply(`\u274C Error: ${err.message}`).catch(() => {});
  }
});

// ── Shutdown ────────────────────────────────────────────────────────────────

async function shutdown(signal) {
  console.log(`\n[bot] Received ${signal}, shutting down\u2026`);
  client.destroy();
  await stopCopilotClient();
  closeDb();
  process.exit(0);
}

process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("unhandledRejection", (err) => {
  console.error("[bot] Unhandled rejection:", err);
});

console.log("[bot] Starting Discord bot\u2026");
client.login(DISCORD_TOKEN);
HEREDOC_BOT

ok "All source files written"

# ──────────────────────────────────────────────────────────────────────────────
# 6) Install dependencies
# ──────────────────────────────────────────────────────────────────────────────
info "Installing npm dependencies…"
cd "$APP"

# Use npm ci if lock file exists, otherwise npm install
if [[ -f "package-lock.json" ]]; then
  npm ci --loglevel=warn
else
  npm install --loglevel=warn
fi

ok "Dependencies installed"

# ──────────────────────────────────────────────────────────────────────────────
# 7) Launch
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Starting bot — Ctrl+C to stop                  ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""

export PROJECT_NAME
export REPO_PATH="$REPO_DIR"

exec node "$APP/src/bot.mjs"
