import Database from "better-sqlite3";
import { mkdirSync, existsSync, copyFileSync } from "node:fs";
import { dirname } from "node:path";
import { STATE_DB_PATH } from "./config.mjs";
import { createLogger } from "./logger.mjs";

const log = createLogger("state");

// Ensure parent directory exists
mkdirSync(dirname(STATE_DB_PATH), { recursive: true });

let db;
try {
  db = new Database(STATE_DB_PATH);
  db.pragma("journal_mode = WAL");
  db.pragma("foreign_keys = ON");
} catch (err) {
  // Database may be corrupt — back up and recreate
  log.error("Database open failed, attempting recovery", { error: err.message });
  if (existsSync(STATE_DB_PATH)) {
    const backupPath = STATE_DB_PATH + ".corrupt." + Date.now();
    try {
      copyFileSync(STATE_DB_PATH, backupPath);
      log.info("Corrupt DB backed up", { path: backupPath });
    } catch { /* best effort */ }
  }
  db = new Database(STATE_DB_PATH);
  db.pragma("journal_mode = WAL");
  db.pragma("foreign_keys = ON");
}

// ── Schema ──────────────────────────────────────────────────────────────────

db.exec(`
  CREATE TABLE IF NOT EXISTS sessions (
    channel_id     TEXT PRIMARY KEY,
    project_name   TEXT NOT NULL,
    workspace_path TEXT NOT NULL,
    branch         TEXT NOT NULL,
    status         TEXT NOT NULL DEFAULT 'idle',
    model          TEXT,
    created_at     TEXT NOT NULL DEFAULT (datetime('now'))
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
    completed_at TEXT,
    timeout_ms   INTEGER
  );

  CREATE TABLE IF NOT EXISTS responders (
    channel_id TEXT NOT NULL,
    user_id    TEXT NOT NULL,
    added_at   TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE(channel_id, user_id)
  );

  CREATE INDEX IF NOT EXISTS idx_task_history_channel
    ON task_history(channel_id, started_at DESC);
  CREATE INDEX IF NOT EXISTS idx_grants_channel
    ON grants(channel_id);
  CREATE INDEX IF NOT EXISTS idx_responders_channel
    ON responders(channel_id);
`);

// ── Migrations ──────────────────────────────────────────────────────────────

db.exec(`CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)`);

function getSchemaVersion() {
  const row = db.prepare("SELECT MAX(version) as v FROM schema_version").get();
  return row?.v ?? 0;
}

function setSchemaVersion(v) {
  db.prepare("INSERT INTO schema_version (version) VALUES (?)").run(v);
}

function runMigrations() {
  let v = getSchemaVersion();

  if (v < 1) {
    // v1: Add model column if missing
    const cols = db.pragma("table_info(sessions)").map((c) => c.name);
    if (!cols.includes("model")) {
      db.exec(`ALTER TABLE sessions ADD COLUMN model TEXT`);
    }
    setSchemaVersion(1);
    v = 1;
  }

  // Future migrations go here as `if (v < 2) { ... setSchemaVersion(2); }`
}

runMigrations();

// ── Sessions ────────────────────────────────────────────────────────────────
const stmtUpsertSession = db.prepare(`
  INSERT INTO sessions (channel_id, project_name, workspace_path, branch, status, model)
  VALUES (@channelId, @projectName, @workspacePath, @branch, @status, @model)
  ON CONFLICT(channel_id) DO UPDATE SET
    project_name   = excluded.project_name,
    workspace_path = excluded.workspace_path,
    branch         = excluded.branch,
    status         = excluded.status,
    model          = excluded.model
`);

const stmtGetSession = db.prepare(
  `SELECT * FROM sessions WHERE channel_id = ?`
);

const stmtAllSessions = db.prepare(`SELECT * FROM sessions`);

const stmtUpdateSessionStatus = db.prepare(
  `UPDATE sessions SET status = ? WHERE channel_id = ?`
);

const stmtUpdateSessionModel = db.prepare(
  `UPDATE sessions SET model = ? WHERE channel_id = ?`
);

const stmtDeleteSession = db.prepare(
  `DELETE FROM sessions WHERE channel_id = ?`
);

export function upsertSession(channelId, projectName, workspacePath, branch, status = "idle", model = null) {
  stmtUpsertSession.run({ channelId, projectName, workspacePath, branch, status, model });
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

export function updateSessionModel(channelId, model) {
  stmtUpdateSessionModel.run(model, channelId);
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

// ── Responders ──────────────────────────────────────────────────────────────
const stmtAddResponder = db.prepare(
  `INSERT OR IGNORE INTO responders (channel_id, user_id) VALUES (?, ?)`
);

const stmtRemoveResponder = db.prepare(
  `DELETE FROM responders WHERE channel_id = ? AND user_id = ?`
);

const stmtGetResponders = db.prepare(
  `SELECT user_id FROM responders WHERE channel_id = ?`
);

const stmtDeleteRespondersByChannel = db.prepare(
  `DELETE FROM responders WHERE channel_id = ?`
);

export function addResponder(channelId, userId) {
  stmtAddResponder.run(channelId, userId);
}

export function removeResponder(channelId, userId) {
  return stmtRemoveResponder.run(channelId, userId).changes;
}

export function getResponders(channelId) {
  return stmtGetResponders.all(channelId);
}

export function deleteRespondersByChannel(channelId) {
  stmtDeleteRespondersByChannel.run(channelId);
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

export function getTaskHistory(channelId, limit = 10) {
  return stmtTaskHistory.all(channelId, limit);
}

// ── Stale state recovery ────────────────────────────────────────────────────
const stmtStaleSessions = db.prepare(
  `SELECT channel_id, project_name, branch FROM sessions WHERE status = 'working'`
);

const stmtStaleRunningTasks = db.prepare(
  `SELECT id, channel_id, prompt, started_at FROM task_history WHERE status = 'running'`
);

const stmtMarkStaleTasksAborted = db.prepare(
  `UPDATE task_history SET status = 'aborted', completed_at = datetime('now') WHERE status = 'running'`
);

const stmtResetStaleSessions = db.prepare(
  `UPDATE sessions SET status = 'idle' WHERE status = 'working'`
);

export function getStaleSessions() {
  return stmtStaleSessions.all();
}

export function getStaleRunningTasks() {
  return stmtStaleRunningTasks.all();
}

export function markStaleTasksAborted() {
  return stmtMarkStaleTasksAborted.run().changes;
}

export function resetStaleSessions() {
  return stmtResetStaleSessions.run().changes;
}

// ── Stats ───────────────────────────────────────────────────────────────────

const stmtTaskStats = db.prepare(`
  SELECT status, COUNT(*) as count FROM task_history GROUP BY status
`);

export function getTaskStats() {
  const rows = stmtTaskStats.all();
  const stats = { total: 0, completed: 0, failed: 0, aborted: 0, running: 0 };
  for (const row of rows) {
    stats[row.status] = row.count;
    stats.total += row.count;
  }
  return stats;
}

// ── Cleanup ─────────────────────────────────────────────────────────────────
export function purgeExpiredGrants() {
  return deleteExpiredGrants().changes;
}

const stmtPruneOldTasks = db.prepare(
  `DELETE FROM task_history WHERE started_at < datetime('now', '-90 days')`
);

/** Remove task_history entries older than 90 days. */
export function pruneOldTasks() {
  return stmtPruneOldTasks.run().changes;
}

let dbClosed = false;

export function closeDb() {
  if (dbClosed) return;
  dbClosed = true;
  db.close();
}
