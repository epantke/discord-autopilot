import { resolve } from "node:path";
import { realpathSync } from "node:fs";
import { DEFAULT_GRANT_MODE, DEFAULT_GRANT_TTL_MIN } from "./config.mjs";
import {
  upsertGrant,
  deleteGrant,
  getGrants as dbGetGrants,
  deleteGrantsByChannel,
  purgeExpiredGrants,
} from "./state.mjs";
import { createLogger } from "./logger.mjs";

const log = createLogger("grants");

/**
 * In-memory grant store per channel.
 * Map< channelId, Map< path, { mode, expiry, timer } > >
 */
const grantStore = new Map();

// ── Helpers ─────────────────────────────────────────────────────────────────

function channelGrants(channelId) {
  if (!grantStore.has(channelId)) {
    grantStore.set(channelId, new Map());
  }
  return grantStore.get(channelId);
}

export function getActiveGrants(channelId) {
  const grants = channelGrants(channelId);
  // Prune expired while reading
  const now = Date.now();
  for (const [p, g] of grants) {
    if (now > g.expiry) {
      clearTimeout(g.timer);
      grants.delete(p);
    }
  }
  return grants;
}

// ── Add Grant ───────────────────────────────────────────────────────────────

export function addGrant(channelId, grantPath, mode, ttlMinutes) {
  mode = mode || DEFAULT_GRANT_MODE;
  ttlMinutes = ttlMinutes ?? DEFAULT_GRANT_TTL_MIN;
  // Resolve symlinks so grant paths match policy-engine's realpathSync checks
  try {
    grantPath = realpathSync(resolve(grantPath));
  } catch {
    grantPath = resolve(grantPath);
  }

  const expiry = Date.now() + ttlMinutes * 60_000;
  // Use SQLite-compatible datetime format (space separator, no trailing Z)
  // so that deleteExpiredGrants WHERE expires_at <= datetime('now') works correctly
  const expiresAt = new Date(expiry).toISOString().replace("T", " ").replace(/\.\d+Z$/, "");

  // Persist to DB
  upsertGrant(channelId, grantPath, mode, expiresAt);

  // Set up in-memory + auto-revoke timer
  const grants = channelGrants(channelId);
  const existing = grants.get(grantPath);
  if (existing?.timer) clearTimeout(existing.timer);

  const timer = setTimeout(() => {
    revokeGrant(channelId, grantPath);
  }, ttlMinutes * 60_000);
  timer.unref(); // don't keep process alive

  grants.set(grantPath, { mode, expiry, timer });
  log.info("Grant added", { channelId, path: grantPath, mode, ttlMinutes });

  return { path: grantPath, mode, ttlMinutes, expiresAt };
}

// ── Revoke Grant ────────────────────────────────────────────────────────────

export function revokeGrant(channelId, grantPath) {
  // Normalize path the same way addGrant does so lookups match
  try {
    grantPath = realpathSync(resolve(grantPath));
  } catch {
    grantPath = resolve(grantPath);
  }
  const grants = channelGrants(channelId);
  const existing = grants.get(grantPath);
  if (existing?.timer) clearTimeout(existing.timer);
  grants.delete(grantPath);
  deleteGrant(channelId, grantPath);
  log.info("Grant revoked", { channelId, path: grantPath });
  return true;
}

// ── Revoke All (for /reset) ─────────────────────────────────────────────────

export function revokeAllGrants(channelId) {
  const grants = channelGrants(channelId);
  for (const [, g] of grants) {
    if (g.timer) clearTimeout(g.timer);
  }
  grants.clear();
  deleteGrantsByChannel(channelId);
}

// ── Restore grants from DB on startup ───────────────────────────────────────

export function restoreGrants(channelId) {
  const rows = dbGetGrants(channelId);
  const now = Date.now();
  for (const row of rows) {
    const expiry = new Date(row.expires_at.replace(" ", "T") + "Z").getTime();
    if (expiry <= now) continue; // skip expired
    const remaining = expiry - now;
    const grants = channelGrants(channelId);
    // Clear any existing timer to prevent leaks on double-restore
    const existing = grants.get(row.path);
    if (existing?.timer) clearTimeout(existing.timer);
    const timer = setTimeout(() => {
      revokeGrant(channelId, row.path);
    }, remaining);
    timer.unref();
    grants.set(row.path, { mode: row.mode, expiry, timer });
  }
}

// ── Periodic cleanup ────────────────────────────────────────────────────────

export function startGrantCleanup(intervalMs = 60_000) {
  const timer = setInterval(() => {
    try { purgeExpiredGrants(); } catch { /* DB may be closed during shutdown */ }
  }, intervalMs);
  timer.unref();
  return timer;
}

/**
 * Cancel all grant timers across all channels.
 * Call before closeDb() during shutdown to prevent DB-closed errors.
 */
export function cancelAllGrantTimers() {
  for (const [, grants] of grantStore) {
    for (const [, g] of grants) {
      if (g.timer) clearTimeout(g.timer);
    }
  }
}
