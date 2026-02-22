import { join, dirname } from "node:path";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { homedir } from "node:os";
import { createLogger } from "./logger.mjs";

const log = createLogger("config");

/** Read an environment variable with automatic whitespace/CRLF trimming. */
function env(name) {
  const v = process.env[name];
  return v != null ? v.trim() : undefined;
}

// ── Required ────────────────────────────────────────────────────────────────
const DISCORD_TOKEN = env("DISCORD_TOKEN");
if (!DISCORD_TOKEN) {
  log.error("DISCORD_TOKEN is not set. Export it and restart.");
  process.exit(1);
}

// ── Paths ───────────────────────────────────────────────────────────────────
const BASE_ROOT =
  env("BASE_ROOT") || join(homedir(), ".local", "share", "discord-agent");
const WORKSPACES_ROOT =
  env("WORKSPACES_ROOT") || join(BASE_ROOT, "workspaces");
const REPOS_ROOT = join(BASE_ROOT, "repos");
const STATE_DB_PATH = join(BASE_ROOT, "state.sqlite");

// ── Project (set at runtime by agent.sh via env) ────────────────────────────
const PROJECT_NAME = env("PROJECT_NAME") || "default";
const REPO_PATH = env("REPO_PATH") || join(REPOS_ROOT, PROJECT_NAME);

// ── Optional filters ────────────────────────────────────────────────────────
const ALLOWED_GUILDS = csvToValidatedSet(env("ALLOWED_GUILDS"), "ALLOWED_GUILDS");
const ALLOWED_CHANNELS = csvToValidatedSet(env("ALLOWED_CHANNELS"), "ALLOWED_CHANNELS");
const ADMIN_ROLE_IDS = csvToValidatedSet(env("ADMIN_ROLE_IDS"), "ADMIN_ROLE_IDS");

// ── Tunables ────────────────────────────────────────────────────────────────
function safeInt(envVal, fallback, min = 0) {
  const n = parseInt(envVal, 10);
  return Number.isFinite(n) && n >= min ? n : fallback;
}

const DISCORD_EDIT_THROTTLE_MS = safeInt(
  env("DISCORD_EDIT_THROTTLE_MS"), 1500
);
const DEFAULT_GRANT_MODE = "ro";
const DEFAULT_GRANT_TTL_MIN = 30;
const TASK_TIMEOUT_MS = safeInt(
  env("TASK_TIMEOUT_MS"), 30 * 60_000, 1000
);
const RATE_LIMIT_WINDOW_MS = safeInt(
  env("RATE_LIMIT_WINDOW_MS"), 60_000
);
const RATE_LIMIT_MAX = safeInt(
  env("RATE_LIMIT_MAX"), 10, 1
);
const PAUSE_GRACE_MS = safeInt(
  env("PAUSE_GRACE_MS"), 60 * 60_000, 60_000
);

// Keepalive interval for Copilot SDK sessions to prevent silent expiry.
// Set to 0 to disable. Default: 15 minutes.
const SESSION_KEEPALIVE_MS = safeInt(
  env("SESSION_KEEPALIVE_MS"), 15 * 60_000, 0
);

// ── Snowflake ID validation ──────────────────────────────────────────────────
function validateSnowflake(val, name) {
  if (!val) return null;
  const trimmed = val.trim();
  if (/^\d{17,20}$/.test(trimmed)) return trimmed;
  log.warn(`Invalid Snowflake ID for ${name}, ignoring`, { value: trimmed });
  return null;
}

function csvToValidatedSet(envVal, name) {
  if (!envVal) return null;
  const ids = envVal.split(",").map((s) => s.trim()).filter(Boolean);
  const valid = ids.filter((id) => {
    if (/^\d{17,20}$/.test(id)) return true;
    log.warn(`Invalid Snowflake ID in ${name}, skipping`, { value: id });
    return false;
  });
  return valid.length > 0 ? new Set(valid) : null;
}

// ── GitHub Token (cached before copilot-client.mjs may delete it from env) ──
const GITHUB_TOKEN = env("GITHUB_TOKEN") || null;

// ── Startup Notifications ───────────────────────────────────────────────────
const STARTUP_CHANNEL_ID = validateSnowflake(env("STARTUP_CHANNEL_ID"), "STARTUP_CHANNEL_ID");
const ADMIN_USER_ID = validateSnowflake(env("ADMIN_USER_ID"), "ADMIN_USER_ID");

// ── DM Access Control ───────────────────────────────────────────────────────
// CSV of user Snowflake IDs allowed to interact via DMs (in addition to ADMIN_USER_ID).
// null = only ADMIN_USER_ID may use DMs (backwards-compatible).
const ALLOWED_DM_USERS = csvToValidatedSet(env("ALLOWED_DM_USERS"), "ALLOWED_DM_USERS");

// ── Model ───────────────────────────────────────────────────────────────────
const DEFAULT_MODEL = env("DEFAULT_MODEL") || "claude-opus-4.6";

// ── Default Branch ──────────────────────────────────────────────────────────
// Optional: base branch for new worktrees. null = use the remote default (HEAD).
const DEFAULT_BRANCH = env("DEFAULT_BRANCH") || null;

// ── Limits ──────────────────────────────────────────────────────────────────
const MAX_QUEUE_SIZE = safeInt(env("MAX_QUEUE_SIZE"), 50);
const MAX_PROMPT_LENGTH = safeInt(env("MAX_PROMPT_LENGTH"), 4000);

// ── Crash Recovery ───────────────────────────────────────────────────────
// When true, tasks aborted by a crash/restart are automatically re-enqueued.
const AUTO_RETRY_ON_CRASH = (env("AUTO_RETRY_ON_CRASH") || "false").toLowerCase() === "true";

// ── Auto-Approve Push ───────────────────────────────────────────────────
// When true, git push commands are auto-approved without Discord button confirmation.
const AUTO_APPROVE_PUSH = (env("AUTO_APPROVE_PUSH") || "false").toLowerCase() === "true";

// ── Version ─────────────────────────────────────────────────────────────────
const __dirname = dirname(fileURLToPath(import.meta.url));
const CURRENT_VERSION = (() => {
  for (const rel of [join(__dirname, "..", "package.json"), join(__dirname, "package.json")]) {
    try { return JSON.parse(readFileSync(rel, "utf-8")).version; } catch { /* next */ }
  }
  return "0.0.0";
})();

// ── Update Configuration ────────────────────────────────────────────────────
const UPDATE_CHECK_INTERVAL_MS = safeInt(
  env("UPDATE_CHECK_INTERVAL_MS"), 3_600_000
);
const AGENT_SCRIPT_PATH = env("AGENT_SCRIPT_PATH") || null;

export {
  DISCORD_TOKEN,
  GITHUB_TOKEN,
  BASE_ROOT,
  WORKSPACES_ROOT,
  REPOS_ROOT,
  STATE_DB_PATH,
  PROJECT_NAME,
  REPO_PATH,
  ALLOWED_GUILDS,
  ALLOWED_CHANNELS,
  ADMIN_ROLE_IDS,
  ALLOWED_DM_USERS,
  DISCORD_EDIT_THROTTLE_MS,
  DEFAULT_GRANT_MODE,
  DEFAULT_GRANT_TTL_MIN,
  TASK_TIMEOUT_MS,
  RATE_LIMIT_WINDOW_MS,
  RATE_LIMIT_MAX,
  STARTUP_CHANNEL_ID,
  ADMIN_USER_ID,
  DEFAULT_MODEL,
  MAX_QUEUE_SIZE,
  MAX_PROMPT_LENGTH,
  CURRENT_VERSION,
  UPDATE_CHECK_INTERVAL_MS,
  AGENT_SCRIPT_PATH,
  AUTO_RETRY_ON_CRASH,
  AUTO_APPROVE_PUSH,
  DEFAULT_BRANCH,
  PAUSE_GRACE_MS,
  SESSION_KEEPALIVE_MS,
};
