import { execFile } from "node:child_process";
import { mkdirSync, existsSync } from "node:fs";
import { join } from "node:path";
import { promisify } from "node:util";
import { WORKSPACES_ROOT, PROJECT_NAME, REPO_PATH, TASK_TIMEOUT_MS, MAX_QUEUE_SIZE, MAX_PROMPT_LENGTH, ADMIN_USER_ID, ADMIN_ROLE_IDS, DEFAULT_MODEL } from "./config.mjs";
import {
  upsertSession,
  getSession,
  updateSessionStatus,
  updateSessionModel,
  deleteSession as dbDeleteSession,
  insertTask,
  completeTask,
  getTaskHistory as dbGetTaskHistory,
  addResponder as dbAddResponder,
  removeResponder as dbRemoveResponder,
  getResponders as dbGetResponders,
  deleteRespondersByChannel,
  pruneOldTasks,
} from "./state.mjs";
import { createAgentSession, listAvailableModels } from "./copilot-client.mjs";
import {
  getActiveGrants,
  restoreGrants,
  revokeAllGrants,
} from "./grants.mjs";
import { DiscordOutput } from "./discord-output.mjs";
import { createPushApprovalRequest } from "./push-approval.mjs";
import { redactSecrets } from "./secret-scanner.mjs";
import { createLogger } from "./logger.mjs";

const execFileAsync = promisify(execFile);
const log = createLogger("session");

/**
 * In-memory session context per channel.
 * @type {Map<string, SessionContext>}
 */
const sessions = new Map();

/**
 * In-memory responder store per channel.
 * Map< channelId, Set< userId > >
 */
const responderStore = new Map();

/**
 * @typedef {object} SessionContext
 * @property {import("@github/copilot-sdk").CopilotSession} copilotSession
 * @property {string} workspacePath
 * @property {string} branch
 * @property {"idle"|"working"|"awaiting_push"|"awaiting_grant"} status
 * @property {Promise<void>|null} currentTask
 * @property {Array<{prompt:string, resolve:Function, reject:Function}>} queue
 * @property {DiscordOutput|null} output
 * @property {number|null} taskId
 * @property {string|null} model
 * @property {boolean} paused
 * @property {boolean} _aborted
 */

// ── Workspace Setup ─────────────────────────────────────────────────────────

async function createWorktree(channelId) {
  const wsRoot = join(WORKSPACES_ROOT, PROJECT_NAME);
  mkdirSync(wsRoot, { recursive: true });

  const worktreePath = join(wsRoot, channelId);

  if (existsSync(worktreePath)) {
    // Reuse existing worktree — read its actual branch
    let branch;
    try {
      const { stdout } = await execFileAsync("git", ["branch", "--show-current"], {
        cwd: worktreePath, encoding: "utf-8", timeout: 5_000,
      });
      branch = stdout.trim();
    } catch {
      branch = `agent/${channelId.slice(-8)}-recovered`;
    }
    return { workspacePath: worktreePath, branch };
  }

  const branchName = `agent/${channelId.slice(-8)}-${Date.now().toString(36)}`;

  try {
    // Create branch from HEAD
    await execFileAsync("git", ["branch", branchName, "HEAD"], {
      cwd: REPO_PATH,
      timeout: 10_000,
    });
  } catch {
    // Branch may already exist
  }

  try {
    await execFileAsync("git", ["worktree", "add", worktreePath, branchName], {
      cwd: REPO_PATH,
      timeout: 30_000,
    });
  } catch (err) {
    // If worktree add fails, try with existing directory
    if (!existsSync(worktreePath)) {
      throw err;
    }
  }

  return { workspacePath: worktreePath, branch: branchName };
}

// ── Session CRUD ────────────────────────────────────────────────────────────

/**
 * Pending session creation promises to prevent duplicate sessions
 * when concurrent getOrCreateSession calls arrive for the same channel.
 */
const _pendingCreation = new Map();

/**
 * Get or create a session for a Discord channel.
 * @param {string} channelId
 * @param {import("discord.js").TextBasedChannel} channel
 */
export async function getOrCreateSession(channelId, channel) {
  if (sessions.has(channelId)) {
    return sessions.get(channelId);
  }

  // Guard against concurrent first-task race: reuse the in-flight promise
  if (_pendingCreation.has(channelId)) {
    return _pendingCreation.get(channelId);
  }

  const promise = _createSession(channelId, channel);
  _pendingCreation.set(channelId, promise);
  try {
    return await promise;
  } finally {
    _pendingCreation.delete(channelId);
  }
}

/**
 * Build the shared callback configuration for a Copilot session.
 */
function buildSessionCallbacks(channelId, channel, workspacePath) {
  return {
    onPushRequest: async (command) => {
      return createPushApprovalRequest(channel, workspacePath, command);
    },

    onOutsideRequest: (reason) => {
      const ctx = sessions.get(channelId);
      const target = ctx?.output?.channel || channel;
      target
        .send(
          `⛔ **Access Denied**\n${reason}\n\n` +
            `Use \`/grant path:<absolute-path> mode:ro ttl:30\` to allow access.`
        )
        .catch(() => {});
    },

    onDelta: (text) => {
      const ctx = sessions.get(channelId);
      ctx?.output?.append(text);
    },

    onToolStart: (toolName) => {
      const ctx = sessions.get(channelId);
      if (!ctx) return;
      const count = ctx._toolsCompleted || 0;
      const suffix = count > 0 ? `  · ${count} done` : "";
      ctx.output?.status(`🔧 \`${toolName}\`…${suffix}`);
    },

    onToolComplete: (toolName, success, error) => {
      const ctx = sessions.get(channelId);
      if (!ctx) return;
      ctx._toolsCompleted = (ctx._toolsCompleted || 0) + 1;
      if (!success && error) {
        ctx.output?.append(`\n❌ \`${toolName}\`: ${error}\n`);
      }
      const count = ctx._toolsCompleted;
      const icon = success ? "✅" : "❌";
      ctx.output?.status(`${icon} \`${toolName}\`  · ${count} tool${count !== 1 ? "s" : ""} done`);
    },

    onIdle: () => {
      // Status update only — finish() is handled by processQueue to avoid double-finish
      const ctx = sessions.get(channelId);
      if (ctx) {
        ctx.status = "idle";
        updateSessionStatus(channelId, "idle");
      }
    },

    onUserQuestion: async (question, choices) => {
      const ctx = sessions.get(channelId);
      if (ctx) ctx.awaitingQuestion = true;

      const target = ctx?.output?.channel || channel;
      await target.send(
        `❓ **Agent asks:**\n${question}` +
          (choices ? `\nOptions: ${choices.join(", ")}` : "")
      );

      try {
        const collected = await target.awaitMessages({
          max: 1,
          time: 300_000, // 5 min
          filter: (m) => {
            if (m.author.bot) return false;
            if (ADMIN_USER_ID && m.author.id === ADMIN_USER_ID) return true;
            if (ADMIN_ROLE_IDS && m.member?.roles?.cache) {
              if ([...ADMIN_ROLE_IDS].some((id) => m.member.roles.cache.has(id))) return true;
            }
            const responders = getChannelResponders(channelId);
            if (responders.size > 0) return responders.has(m.author.id);
            if (!ADMIN_ROLE_IDS) return true;
            return false;
          },
        });
        return collected.first()?.content || "No answer provided.";
      } catch {
        return "No answer provided within timeout.";
      } finally {
        if (ctx) ctx.awaitingQuestion = false;
      }
    },
  };
}

async function _createSession(channelId, channel) {

  // Check DB for existing session
  const dbRow = getSession(channelId);
  let workspacePath, branch, model;

  if (dbRow && existsSync(dbRow.workspace_path)) {
    workspacePath = dbRow.workspace_path;
    branch = dbRow.branch;
    model = dbRow.model || DEFAULT_MODEL;
  } else {
    const wt = await createWorktree(channelId);
    workspacePath = wt.workspacePath;
    branch = wt.branch;
    model = DEFAULT_MODEL;
  }

  // Create Copilot session with policy hooks — retry once on transient failure
  let copilotSession;
  for (let attempt = 1; attempt <= 2; attempt++) {
    try {
      copilotSession = await createAgentSession({
        channelId,
        workspacePath,
        model,
        ...buildSessionCallbacks(channelId, channel, workspacePath),
      });
      break; // success
    } catch (err) {
      if (attempt >= 2) {
        // Provide a clearer message for Copilot auth errors
        if (err.message?.includes("Authorization") || err.message?.includes("login")) {
          throw new Error(
            "Copilot authorization failed. Run `copilot auth login` on the host, " +
            "or check that GITHUB_TOKEN has Copilot access. Original error: " + err.message
          );
        }
        throw err;
      }
      log.warn("Session creation failed, retrying", { channelId, error: err.message });
      await new Promise((r) => setTimeout(r, 2_000));
    }
  }

  const ctx = {
    copilotSession,
    workspacePath,
    branch,
    model,
    status: "idle",
    currentTask: null,
    queue: [],
    output: null,
    taskId: null,
    paused: false,
    _aborted: false,
    currentPrompt: null,
    awaitingQuestion: false,
    _toolsCompleted: 0,
    _lastActivity: Date.now(),
  };

  sessions.set(channelId, ctx);

  // Persist to DB
  upsertSession(channelId, PROJECT_NAME, workspacePath, branch, "idle", model);
  log.info("Session created", { channelId, branch, model, workspace: workspacePath });

  // Restore grants from DB
  restoreGrants(channelId);
  restoreResponders(channelId);

  return ctx;
}

// ── Responders (answer agent questions) ───────────────────────────────────

function restoreResponders(channelId) {
  const rows = dbGetResponders(channelId);
  if (rows.length > 0) {
    responderStore.set(channelId, new Set(rows.map((r) => r.user_id)));
  }
}

export function addChannelResponder(channelId, userId) {
  if (!responderStore.has(channelId)) responderStore.set(channelId, new Set());
  responderStore.get(channelId).add(userId);
  dbAddResponder(channelId, userId);
}

export function removeChannelResponder(channelId, userId) {
  responderStore.get(channelId)?.delete(userId);
  return dbRemoveResponder(channelId, userId);
}

export function getChannelResponders(channelId) {
  return responderStore.get(channelId) || new Set();
}

// ── Task Execution ──────────────────────────────────────────────────────────

/**
 * Enqueue a task for execution. Tasks are serialized per channel.
 * @param {string} channelId
 * @param {import("discord.js").TextBasedChannel} channel - Parent channel (for session lookup)
 * @param {string} prompt
 * @param {import("discord.js").TextBasedChannel} [outputChannel] - Thread or channel for output
 */
export async function enqueueTask(channelId, channel, prompt, outputChannel, user) {
  if (prompt.length > MAX_PROMPT_LENGTH) {
    throw new Error(`Prompt too long (${prompt.length}/${MAX_PROMPT_LENGTH} chars).`);
  }

  const ctx = await getOrCreateSession(channelId, channel);

  if (ctx.queue.length >= MAX_QUEUE_SIZE) {
    throw new Error(`Queue full (${MAX_QUEUE_SIZE} tasks max). Use \`/queue clear\` or wait.`);
  }

  return new Promise((resolve, reject) => {
    ctx.queue.push({
      prompt,
      resolve,
      reject,
      outputChannel: outputChannel || channel,
      userId: user?.id || null,
      userTag: user?.tag || null,
    });
    processQueue(channelId);
  });
}

async function processQueue(channelId) {
  const ctx = sessions.get(channelId);
  if (!ctx || ctx.status === "working" || ctx.paused) return;
  if (ctx.queue.length === 0) return;

  const { prompt, resolve, reject, outputChannel } = ctx.queue.shift();

  ctx.status = "working";
  ctx.currentPrompt = prompt;
  ctx._toolsCompleted = 0;
  updateSessionStatus(channelId, "working");
  ctx.output = new DiscordOutput(outputChannel);
  ctx.taskId = insertTask(channelId, prompt);
  log.info("Task started", { channelId, taskId: ctx.taskId, prompt: prompt.slice(0, 100) });

  // Typing indicator while agent is working
  outputChannel.sendTyping().catch(() => {});
  const typingInterval = setInterval(() => outputChannel.sendTyping().catch(() => {}), 8_000);
  typingInterval.unref();

  try {
    const response = await ctx.copilotSession.sendAndWait({ prompt }, TASK_TIMEOUT_MS);
    completeTask(ctx.taskId, "completed");
    log.info("Task completed", { channelId, taskId: ctx.taskId });
    ctx.status = "idle";
    updateSessionStatus(channelId, "idle");
    await ctx.output?.finish("✨ **Task complete.**");
    resolve(response);
  } catch (err) {
    // If aborted via /stop, cleanup was already handled
    if (ctx._aborted) {
      ctx._aborted = false;
    } else if (err.message?.includes("Timeout") && err.message?.includes("session.idle")) {
      log.warn("Task timed out", { channelId, taskId: ctx.taskId, timeoutMs: TASK_TIMEOUT_MS });
      try { ctx.copilotSession.abort(); } catch {}
      completeTask(ctx.taskId, "aborted");
      await ctx.output?.finish(`⏱ **Task timed out** after ${Math.round(TASK_TIMEOUT_MS / 60_000)} min.`);
      ctx.status = "idle";
      updateSessionStatus(channelId, "idle");
    } else {
      completeTask(ctx.taskId, "failed");
      ctx.status = "idle";
      updateSessionStatus(channelId, "idle");
      await ctx.output?.finish(`❌ **Error:** ${redactSecrets(err.message).clean}`);
    }
    err._reportedByOutput = true;
    reject(err);
  } finally {
    clearInterval(typingInterval);
    ctx.output = null;
    ctx.currentPrompt = null;
    ctx._lastActivity = Date.now();
    // Continue queue unless paused (use setImmediate to avoid stack overflow)
    if (!ctx.paused) {
      setImmediate(() => processQueue(channelId));
    }
  }
}

// ── Status ──────────────────────────────────────────────────────────────────

export function getSessionStatus(channelId) {
  const ctx = sessions.get(channelId);
  if (!ctx) return null;

  const grants = getActiveGrants(channelId);
  const grantList = [];
  for (const [p, g] of grants) {
    grantList.push({
      path: p,
      mode: g.mode,
      expiresIn: Math.max(0, Math.round((g.expiry - Date.now()) / 60_000)),
    });
  }

  return {
    status: ctx.status,
    paused: ctx.paused,
    workspace: ctx.workspacePath,
    branch: ctx.branch,
    model: ctx.model || null,
    queueLength: ctx.queue.length,
    grants: grantList,
    currentPrompt: ctx.currentPrompt,
  };
}

// ── Reset ───────────────────────────────────────────────────────────────────

export async function resetSession(channelId) {
  const ctx = sessions.get(channelId);
  if (ctx) {
    try { ctx.copilotSession.abort(); } catch {}
    try { ctx.copilotSession.destroy(); } catch {}
    for (const item of ctx.queue) {
      try {
        const err = new Error("Session reset");
        err._reportedByOutput = true;
        item.reject(err);
      } catch {}
    }
    // Clean up the git worktree
    try {
      await execFileAsync("git", ["worktree", "remove", "--force", ctx.workspacePath], {
        cwd: REPO_PATH, timeout: 15_000,
      });
      log.info("Worktree removed", { channelId, path: ctx.workspacePath });
    } catch (err) {
      log.warn("Failed to remove worktree", { channelId, path: ctx.workspacePath, error: err.message });
    }
  }
  sessions.delete(channelId);
  responderStore.delete(channelId);
  try { revokeAllGrants(channelId); } catch (err) { log.error("Failed to revoke grants on reset", { channelId, error: err.message }); }
  try { dbDeleteSession(channelId); } catch (err) { log.error("Failed to delete session from DB", { channelId, error: err.message }); }
  try { deleteRespondersByChannel(channelId); } catch (err) { log.error("Failed to delete responders on reset", { channelId, error: err.message }); }
}

// ── Hard Stop ───────────────────────────────────────────────────────────────

/**
 * Immediately abort the running task and optionally clear the queue.
 */
export async function hardStop(channelId, clearQueue = true) {
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
    // await finish() so the Discord message is sent before we continue
    await ctx.output?.finish("🛑 **Task aborted by user.");
    // Don't null output synchronously — it will be nulled by processQueue's finally block
    ctx.status = "idle";
    updateSessionStatus(channelId, "idle");
  }

  if (clearQueue && ctx.queue.length > 0) {
    queueCleared = ctx.queue.length;
    for (const item of ctx.queue) {
      const err = new Error("Cleared by /stop");
      err._reportedByOutput = true;
      item.reject(err);
    }
    ctx.queue = [];
  }

  return { found: true, wasWorking, queueCleared };
}

// ── Pause / Resume ──────────────────────────────────────────────────────────

export function pauseSession(channelId) {
  const ctx = sessions.get(channelId);
  if (!ctx) return { found: false };
  const wasAlreadyPaused = ctx.paused;
  ctx.paused = true;
  return { found: true, wasAlreadyPaused };
}

export function resumeSession(channelId, channel) {
  const ctx = sessions.get(channelId);
  if (!ctx) return { found: false };
  const wasPaused = ctx.paused;
  ctx.paused = false;
  // Kick the queue in case items are waiting
  if (wasPaused && ctx.queue.length > 0) {
    processQueue(channelId);
  }
  return { found: true, wasPaused };
}

// ── Queue Management ────────────────────────────────────────────────────────

export function clearQueue(channelId) {
  const ctx = sessions.get(channelId);
  if (!ctx) return { found: false, cleared: 0 };
  const cleared = ctx.queue.length;
  for (const item of ctx.queue) {
    const err = new Error("Queue cleared");
    err._reportedByOutput = true;
    item.reject(err);
  }
  ctx.queue = [];
  return { found: true, cleared };
}

export function getQueueInfo(channelId) {
  const ctx = sessions.get(channelId);
  if (!ctx) return null;
  return {
    paused: ctx.paused,
    length: ctx.queue.length,
    items: ctx.queue.map((q, i) => ({ index: i + 1, prompt: q.prompt.slice(0, 100), userTag: q.userTag })),
  };
}

// ── Task History ────────────────────────────────────────────────────────────

export function getTaskHistory(channelId, limit = 10) {
  return dbGetTaskHistory(channelId, limit);
}

export function getActiveSessionCount() {
  return sessions.size;
}

/**
 * Update the branch for an active session (after /branch create or switch).
 */
export function updateBranch(channelId, newBranch) {
  const ctx = sessions.get(channelId);
  if (!ctx) return false;
  ctx.branch = newBranch;
  upsertSession(channelId, PROJECT_NAME, ctx.workspacePath, newBranch, ctx.status, ctx.model);
  return true;
}

/**
 * Change the model for an active session.
 * Destroys and recreates the Copilot session with the new model.
 * @param {string} channelId
 * @param {import("discord.js").TextBasedChannel} channel
 * @param {string} newModel - Model ID to switch to
 * @returns {Promise<{ok: boolean, error?: string}>}
 */
export async function changeModel(channelId, channel, newModel) {
  const ctx = sessions.get(channelId);
  if (!ctx) return { ok: false, error: "No active session." };
  if (ctx.status === "working") {
    return { ok: false, error: "Cannot switch models while a task is running. Use `/stop` first." };
  }

  const oldModel = ctx.model;
  ctx.model = newModel;

  // Create the new session FIRST — only destroy the old one on success
  // to avoid bricking ctx.copilotSession if the new one fails
  let newSession;
  try {
    newSession = await createAgentSession({
      channelId,
      workspacePath: ctx.workspacePath,
      model: newModel,
      ...buildSessionCallbacks(channelId, channel, ctx.workspacePath),
    });
  } catch (err) {
    // Rollback model on failure — old session is still alive
    ctx.model = oldModel;
    log.error("Failed to recreate session with new model", { channelId, model: newModel, error: err.message });
    return { ok: false, error: `Failed to create session with model \`${newModel}\`: ${err.message}` };
  }

  // Success — destroy old session and swap in the new one
  try { ctx.copilotSession.destroy(); } catch {}
  ctx.copilotSession = newSession;

  // Persist to DB
  updateSessionModel(channelId, newModel);
  log.info("Model changed", { channelId, from: oldModel, to: newModel });
  return { ok: true };
}

/**
 * List available models from the Copilot API.
 */
export { listAvailableModels } from "./copilot-client.mjs";

/**
 * Check if a session's onUserQuestion callback is currently awaiting input.
 * When true, messageCreate should NOT enqueue a follow-up — the message will
 * be consumed by the awaitMessages collector instead.
 */
export function isAwaitingQuestion(channelId) {
  const ctx = sessions.get(channelId);
  return ctx?.awaitingQuestion === true;
}

// ── Idle Session Sweep & Task Pruning ───────────────────────────────────────

const IDLE_SWEEP_MS = 24 * 60 * 60_000; // 24 hours
const _idleSweep = setInterval(() => {
  const now = Date.now();
  for (const [channelId, ctx] of sessions) {
    if (ctx.status !== "idle") continue;
    if (ctx.queue.length > 0) continue;
    // Track last activity — fall back to creation time
    const idle = now - (ctx._lastActivity || 0);
    if (idle >= IDLE_SWEEP_MS) {
      try { ctx.copilotSession.destroy(); } catch {}
      // Clean up the git worktree
      execFileAsync("git", ["worktree", "remove", "--force", ctx.workspacePath], {
        cwd: REPO_PATH, timeout: 15_000,
      }).catch((err) => log.warn("Failed to remove idle worktree", { channelId, error: err.message }));
      revokeAllGrants(channelId);
      responderStore.delete(channelId);
      sessions.delete(channelId);
      try { dbDeleteSession(channelId); } catch {}
      try { deleteRespondersByChannel(channelId); } catch {}
      log.info("Idle session swept", { channelId });
    }
  }
  // Prune old task history
  const pruned = pruneOldTasks();
  if (pruned > 0) log.info("Pruned old tasks", { count: pruned });
}, IDLE_SWEEP_MS);
_idleSweep.unref();
