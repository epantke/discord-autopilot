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
