import { join } from "node:path";
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
const TASK_TIMEOUT_MS = parseInt(
  process.env.TASK_TIMEOUT_MS || String(30 * 60_000),
  10
);
const RATE_LIMIT_WINDOW_MS = parseInt(
  process.env.RATE_LIMIT_WINDOW_MS || "60000",
  10
);
const RATE_LIMIT_MAX = parseInt(
  process.env.RATE_LIMIT_MAX || "10",
  10
);

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
  TASK_TIMEOUT_MS,
  RATE_LIMIT_WINDOW_MS,
  RATE_LIMIT_MAX,
};
