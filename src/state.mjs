import Database from "better-sqlite3";
import { mkdirSync, existsSync, copyFileSync, unlinkSync } from "node:fs";
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
    // Remove WAL/SHM files to prevent old journal applying to the new DB
    for (const suffix of ["-wal", "-shm"]) {
      try { unlinkSync(STATE_DB_PATH + suffix); } catch { /* may not exist */ }
    }
  }
  try {
    db = new Database(STATE_DB_PATH);
    db.pragma("journal_mode = WAL");
    db.pragma("foreign_keys = ON");
  } catch (retryErr) {
    log.error("Database recovery also failed — cannot start", { error: retryErr.message });
    throw retryErr;
  }
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
  let v;
  try {
    v = getSchemaVersion();
  } catch (err) {
    log.error("Failed to read schema version, attempting fresh start", { error: err.message });
    return;
  }

  try {
  if (v < 1) {
    db.transaction(() => {
      const cols = db.pragma("table_info(sessions)").map((c) => c.name);
      if (!cols.includes("model")) {
        db.exec(`ALTER TABLE sessions ADD COLUMN model TEXT`);
      }
      setSchemaVersion(1);
    })();
    v = 1;
  }

  if (v < 2) {
    db.transaction(() => {
      const cols = db.pragma("table_info(task_history)").map((c) => c.name);
      if (!cols.includes("user_id")) {
        db.exec(`ALTER TABLE task_history ADD COLUMN user_id TEXT`);
      }
      setSchemaVersion(2);
    })();
    v = 2;
  }

  if (v < 3) {
    db.transaction(() => {
      db.exec(`
        CREATE TABLE IF NOT EXISTS usage_log (
          id                INTEGER PRIMARY KEY AUTOINCREMENT,
          channel_id        TEXT NOT NULL,
          task_id           INTEGER,
          prompt_tokens     INTEGER NOT NULL DEFAULT 0,
          completion_tokens INTEGER NOT NULL DEFAULT 0,
          requests          INTEGER NOT NULL DEFAULT 1,
          model             TEXT,
          cost_eur          REAL NOT NULL DEFAULT 0,
          created_at        TEXT NOT NULL DEFAULT (datetime('now'))
        )
      `);
      db.exec(`CREATE INDEX IF NOT EXISTS idx_usage_log_created ON usage_log(created_at)`);
      db.exec(`CREATE INDEX IF NOT EXISTS idx_usage_log_channel ON usage_log(channel_id)`);
      setSchemaVersion(3);
    })();
    v = 3;
  }

  if (v < 4) {
    db.transaction(() => {
      db.exec(`DROP TABLE IF EXISTS usage_log`);
      setSchemaVersion(4);
    })();
    v = 4;
  }

  if (v < 5) {
    db.transaction(() => {
      db.exec(`
        CREATE TABLE IF NOT EXISTS repo_overrides (
          channel_id   TEXT PRIMARY KEY,
          repo_url     TEXT NOT NULL,
          repo_path    TEXT NOT NULL,
          project_name TEXT NOT NULL,
          set_at       TEXT NOT NULL DEFAULT (datetime('now'))
        )
      `);
      setSchemaVersion(5);
    })();
    v = 5;
  }

  if (v < 6) {
    db.transaction(() => {
      db.exec(`
        CREATE TABLE IF NOT EXISTS branch_overrides (
          channel_id   TEXT PRIMARY KEY,
          base_branch  TEXT NOT NULL,
          set_at       TEXT NOT NULL DEFAULT (datetime('now'))
        )
      `);
      setSchemaVersion(6);
    })();
    v = 6;
  }

  // Future migrations go here as `if (v < 7) { ... setSchemaVersion(7); }`
  } catch (migrationErr) {
    log.error("Migration failed — backing up DB and continuing with current schema", { error: migrationErr.message });
    try {
      const backupPath = STATE_DB_PATH + ".pre-migration." + Date.now();
      copyFileSync(STATE_DB_PATH, backupPath);
      log.info("Pre-migration DB backed up", { path: backupPath });
    } catch { /* best effort */ }
  }
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

function deleteExpiredGrants() {
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
  INSERT INTO task_history (channel_id, prompt, status, user_id, timeout_ms)
  VALUES (?, ?, 'running', ?, ?)
`);

const stmtCompleteTask = db.prepare(`
  UPDATE task_history SET status = ?, completed_at = datetime('now')
  WHERE id = ?
`);

export function insertTask(channelId, prompt, userId = null, timeoutMs = null) {
  const info = stmtInsertTask.run(channelId, prompt, userId, timeoutMs);
  return info.lastInsertRowid;
}

export function completeTask(taskId, status) {
  stmtCompleteTask.run(status, taskId);
}

// ── Repo Overrides ──────────────────────────────────────────────────────────
const stmtUpsertRepoOverride = db.prepare(`
  INSERT INTO repo_overrides (channel_id, repo_url, repo_path, project_name)
  VALUES (@channelId, @repoUrl, @repoPath, @projectName)
  ON CONFLICT(channel_id) DO UPDATE SET
    repo_url     = excluded.repo_url,
    repo_path    = excluded.repo_path,
    project_name = excluded.project_name,
    set_at       = datetime('now')
`);

const stmtGetRepoOverride = db.prepare(
  `SELECT * FROM repo_overrides WHERE channel_id = ?`
);

const stmtDeleteRepoOverride = db.prepare(
  `DELETE FROM repo_overrides WHERE channel_id = ?`
);

const stmtAllRepoOverrides = db.prepare(`SELECT * FROM repo_overrides`);

export function upsertRepoOverride(channelId, repoUrl, repoPath, projectName) {
  stmtUpsertRepoOverride.run({ channelId, repoUrl, repoPath, projectName });
}

export function getRepoOverride(channelId) {
  return stmtGetRepoOverride.get(channelId) || null;
}

export function deleteRepoOverride(channelId) {
  stmtDeleteRepoOverride.run(channelId);
}

export function getAllRepoOverrides() {
  return stmtAllRepoOverrides.all();
}

// ── Branch Overrides ────────────────────────────────────────────────────────
const stmtUpsertBranchOverride = db.prepare(`
  INSERT INTO branch_overrides (channel_id, base_branch)
  VALUES (@channelId, @baseBranch)
  ON CONFLICT(channel_id) DO UPDATE SET
    base_branch = excluded.base_branch,
    set_at      = datetime('now')
`);

const stmtGetBranchOverride = db.prepare(
  `SELECT * FROM branch_overrides WHERE channel_id = ?`
);

const stmtDeleteBranchOverride = db.prepare(
  `DELETE FROM branch_overrides WHERE channel_id = ?`
);

const stmtAllBranchOverrides = db.prepare(`SELECT * FROM branch_overrides`);

export function upsertBranchOverride(channelId, baseBranch) {
  stmtUpsertBranchOverride.run({ channelId, baseBranch });
}

export function getBranchOverride(channelId) {
  return stmtGetBranchOverride.get(channelId) || null;
}

export function deleteBranchOverride(channelId) {
  stmtDeleteBranchOverride.run(channelId);
}

export function getAllBranchOverrides() {
  return stmtAllBranchOverrides.all();
}

// ── Stale state recovery ────────────────────────────────────────────────────
const stmtStaleSessions = db.prepare(
  `SELECT channel_id, project_name, branch FROM sessions WHERE status = 'working'`
);

const stmtStaleRunningTasks = db.prepare(
  `SELECT id, channel_id, prompt, started_at, user_id FROM task_history WHERE status = 'running'`
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

const stmtRecentTasks = db.prepare(
  `SELECT prompt, status, started_at FROM task_history
   WHERE channel_id = ? ORDER BY started_at DESC LIMIT ?`
);

/** Get recent tasks for a channel (most recent first). */
export function getRecentTasks(channelId, limit = 10) {
  return stmtRecentTasks.all(channelId, limit);
}

let dbClosed = false;

export function closeDb() {
  if (dbClosed) return;
  dbClosed = true;
  db.close();
}
