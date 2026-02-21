import { join, dirname } from "node:path";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { homedir } from "node:os";
import { createLogger } from "./logger.mjs";

const log = createLogger("config");

// ── Required ────────────────────────────────────────────────────────────────
const DISCORD_TOKEN = process.env.DISCORD_TOKEN;
if (!DISCORD_TOKEN) {
  log.error("DISCORD_TOKEN is not set. Export it and restart.");
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
const ALLOWED_GUILDS = csvToValidatedSet(process.env.ALLOWED_GUILDS, "ALLOWED_GUILDS");
const ALLOWED_CHANNELS = csvToValidatedSet(process.env.ALLOWED_CHANNELS, "ALLOWED_CHANNELS");
const ADMIN_ROLE_IDS = csvToValidatedSet(process.env.ADMIN_ROLE_IDS, "ADMIN_ROLE_IDS");

// ── Tunables ────────────────────────────────────────────────────────────────
function safeInt(envVal, fallback) {
  const n = parseInt(envVal, 10);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

const DISCORD_EDIT_THROTTLE_MS = safeInt(
  process.env.DISCORD_EDIT_THROTTLE_MS, 1500
);
const DEFAULT_GRANT_MODE = "ro";
const DEFAULT_GRANT_TTL_MIN = 30;
const TASK_TIMEOUT_MS = safeInt(
  process.env.TASK_TIMEOUT_MS, 30 * 60_000
);
const RATE_LIMIT_WINDOW_MS = safeInt(
  process.env.RATE_LIMIT_WINDOW_MS, 60_000
);
const RATE_LIMIT_MAX = safeInt(
  process.env.RATE_LIMIT_MAX, 10
);

// ── Snowflake ID validation ──────────────────────────────────────────────────
function validateSnowflake(val, name) {
  if (!val) return null;
  if (/^\d{17,20}$/.test(val)) return val;
  log.warn(`Invalid Snowflake ID for ${name}, ignoring`, { value: val });
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
const GITHUB_TOKEN = process.env.GITHUB_TOKEN || null;

// ── Startup Notifications ───────────────────────────────────────────────────
const STARTUP_CHANNEL_ID = validateSnowflake(process.env.STARTUP_CHANNEL_ID, "STARTUP_CHANNEL_ID");
const ADMIN_USER_ID = validateSnowflake(process.env.ADMIN_USER_ID, "ADMIN_USER_ID");

// ── DM Access Control ───────────────────────────────────────────────────────
// CSV of user Snowflake IDs allowed to interact via DMs (in addition to ADMIN_USER_ID).
// null = only ADMIN_USER_ID may use DMs (backwards-compatible).
const ALLOWED_DM_USERS = csvToValidatedSet(process.env.ALLOWED_DM_USERS, "ALLOWED_DM_USERS");

// ── Model ───────────────────────────────────────────────────────────────────
const DEFAULT_MODEL = process.env.DEFAULT_MODEL || "claude-opus-4.6";

// ── Limits ──────────────────────────────────────────────────────────────────
const MAX_QUEUE_SIZE = safeInt(process.env.MAX_QUEUE_SIZE, 50);
const MAX_PROMPT_LENGTH = safeInt(process.env.MAX_PROMPT_LENGTH, 4000);

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
  process.env.UPDATE_CHECK_INTERVAL_MS, 3_600_000
);
const AGENT_SCRIPT_PATH = process.env.AGENT_SCRIPT_PATH || null;

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
};
