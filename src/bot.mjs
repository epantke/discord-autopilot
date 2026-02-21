import {
  ActivityType,
  Client,
  Events,
  GatewayIntentBits,
  Partials,
  PermissionFlagsBits,
  REST,
  Routes,
  SlashCommandBuilder,
  EmbedBuilder,
  AttachmentBuilder,
} from "discord.js";

import {
  DISCORD_TOKEN,
  ALLOWED_GUILDS,
  ALLOWED_CHANNELS,
  ADMIN_ROLE_IDS,
  PROJECT_NAME,
  DISCORD_EDIT_THROTTLE_MS,
  DEFAULT_GRANT_MODE,
  DEFAULT_GRANT_TTL_MIN,
  BASE_ROOT,
  WORKSPACES_ROOT,
  REPO_PATH,
  RATE_LIMIT_WINDOW_MS,
  RATE_LIMIT_MAX,
  STARTUP_CHANNEL_ID,
  ADMIN_USER_ID,
} from "./config.mjs";

import {
  enqueueTask,
  getSessionStatus,
  approvePendingPush,
  resetSession,
  hardStop,
  pauseSession,
  resumeSession,
  clearQueue,
  getQueueInfo,
  getTaskHistory,
  getActiveSessionCount,
} from "./session-manager.mjs";

import { addGrant, revokeGrant, startGrantCleanup, restoreGrants } from "./grants.mjs";
import {
  closeDb,
  getAllSessions,
  getTaskStats,
  getStaleSessions,
  getStaleRunningTasks,
  markStaleTasksAborted,
  resetStaleSessions,
} from "./state.mjs";
import { stopCopilotClient, getCopilotClient } from "./copilot-client.mjs";
import { redactSecrets } from "./secret-scanner.mjs";
import { createLogger } from "./logger.mjs";
import { execSync } from "node:child_process";
import { existsSync } from "node:fs";

const log = createLogger("bot");

// ── Slash Commands Definition ───────────────────────────────────────────────

const commands = [
  new SlashCommandBuilder()
    .setName("task")
    .setDescription("Send a task to the coding agent")
    .addStringOption((opt) =>
      opt.setName("prompt").setDescription("Task description").setRequired(true)
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
    .addStringOption((opt) =>
      opt.setName("path").setDescription("Absolute path to grant").setRequired(true)
    )
    .addStringOption((opt) =>
      opt
        .setName("mode")
        .setDescription("Access mode")
        .addChoices(
          { name: "Read Only", value: "ro" },
          { name: "Read/Write", value: "rw" }
        )
    )
    .addIntegerOption((opt) =>
      opt
        .setName("ttl")
        .setDescription("Time-to-live in minutes (default: 30)")
        .setMinValue(1)
        .setMaxValue(1440)
    )
    .setDefaultMemberPermissions(PermissionFlagsBits.ManageGuild),

  new SlashCommandBuilder()
    .setName("revoke")
    .setDescription("Revoke agent access to a path")
    .addStringOption((opt) =>
      opt.setName("path").setDescription("Absolute path to revoke").setRequired(true)
    )
    .setDefaultMemberPermissions(PermissionFlagsBits.ManageGuild),

  new SlashCommandBuilder()
    .setName("reset")
    .setDescription("Reset the agent session for this channel")
    .setDefaultMemberPermissions(PermissionFlagsBits.ManageGuild),

  new SlashCommandBuilder()
    .setName("stop")
    .setDescription("Hard stop — abort the running task immediately")
    .addBooleanOption((opt) =>
      opt
        .setName("clear_queue")
        .setDescription("Also clear all pending tasks (default: true)")
    )
    .setDefaultMemberPermissions(PermissionFlagsBits.ManageGuild),

  new SlashCommandBuilder()
    .setName("pause")
    .setDescription("Pause queue processing (current task finishes, no new ones start)"),

  new SlashCommandBuilder()
    .setName("resume")
    .setDescription("Resume queue processing after a pause"),

  new SlashCommandBuilder()
    .setName("queue")
    .setDescription("View or manage the task queue")
    .addStringOption((opt) =>
      opt
        .setName("action")
        .setDescription("What to do")
        .addChoices(
          { name: "List pending tasks", value: "list" },
          { name: "Clear all pending tasks", value: "clear" }
        )
    ),

  new SlashCommandBuilder()
    .setName("history")
    .setDescription("Show recent task history")
    .addIntegerOption((opt) =>
      opt
        .setName("limit")
        .setDescription("Number of tasks to show (default: 10)")
        .setMinValue(1)
        .setMaxValue(50)
    ),

  new SlashCommandBuilder()
    .setName("config")
    .setDescription("View current bot configuration")
    .setDefaultMemberPermissions(PermissionFlagsBits.ManageGuild),

  new SlashCommandBuilder()
    .setName("diff")
    .setDescription("Show git diff for the agent workspace")
    .addStringOption((opt) =>
      opt
        .setName("mode")
        .setDescription("Diff mode")
        .addChoices(
          { name: "Summary (stat)", value: "stat" },
          { name: "Full diff", value: "full" },
          { name: "Staged only", value: "staged" }
        )
    ),

  new SlashCommandBuilder()
    .setName("branch")
    .setDescription("Manage agent branches")
    .addStringOption((opt) =>
      opt
        .setName("action")
        .setDescription("What to do")
        .addChoices(
          { name: "List branches", value: "list" },
          { name: "Show current branch", value: "current" },
          { name: "Create new branch", value: "create" },
          { name: "Switch branch", value: "switch" }
        )
    )
    .addStringOption((opt) =>
      opt.setName("name").setDescription("Branch name (for create/switch)")
    ),

  new SlashCommandBuilder()
    .setName("help")
    .setDescription("Show all available bot commands"),

  new SlashCommandBuilder()
    .setName("stats")
    .setDescription("Show bot statistics and uptime"),
];

// ── Access Control ──────────────────────────────────────────────────────────

function isAllowed(interaction) {
  const isDM = !interaction.guildId;

  // DMs bypass guild and role checks
  if (isDM) return true;

  if (ALLOWED_GUILDS && !ALLOWED_GUILDS.has(interaction.guildId)) return false;
  if (ALLOWED_CHANNELS && !ALLOWED_CHANNELS.has(interaction.channelId)) return false;
  if (ADMIN_ROLE_IDS) {
    const memberRoles = interaction.member?.roles?.cache;
    if (!memberRoles) return false;
    const hasRole = [...ADMIN_ROLE_IDS].some((id) => memberRoles.has(id));
    if (!hasRole) return false;
  }
  return true;
}

function isAdmin(interaction) {
  // DM users are treated as admins (they have direct bot access)
  if (!interaction.guildId) return true;
  if (!ADMIN_ROLE_IDS) return true;
  const memberRoles = interaction.member?.roles?.cache;
  return memberRoles ? [...ADMIN_ROLE_IDS].some((id) => memberRoles.has(id)) : false;
}

// ── Rate Limiting ───────────────────────────────────────────────────────────

/** Map<userId, number[]> — timestamps of recent commands */
const rateLimitMap = new Map();

/**
 * Returns true if the user is rate-limited. Admins bypass rate limits.
 */
function isRateLimited(interaction) {
  if (isAdmin(interaction)) return false;
  const userId = interaction.user.id;
  const now = Date.now();
  let timestamps = rateLimitMap.get(userId);
  if (!timestamps) {
    timestamps = [];
    rateLimitMap.set(userId, timestamps);
  }
  // Remove entries outside the window
  const cutoff = now - RATE_LIMIT_WINDOW_MS;
  while (timestamps.length > 0 && timestamps[0] <= cutoff) timestamps.shift();
  if (timestamps.length === 0) { rateLimitMap.delete(userId); }
  if (timestamps.length >= RATE_LIMIT_MAX) return true;
  timestamps.push(now);
  return false;
}

// Periodic cleanup of stale rate-limit entries
const _rlCleanup = setInterval(() => {
  const cutoff = Date.now() - RATE_LIMIT_WINDOW_MS;
  for (const [userId, ts] of rateLimitMap) {
    while (ts.length > 0 && ts[0] <= cutoff) ts.shift();
    if (ts.length === 0) rateLimitMap.delete(userId);
  }
}, 300_000);
_rlCleanup.unref();

// ── Register Slash Commands ─────────────────────────────────────────────────

async function registerCommands(clientId) {
  const rest = new REST({ version: "10" }).setToken(DISCORD_TOKEN);
  const body = commands.map((c) => c.toJSON());

  if (ALLOWED_GUILDS && ALLOWED_GUILDS.size > 0) {
    // Guild-scoped (instant update)
    for (const guildId of ALLOWED_GUILDS) {
      try {
        await rest.put(Routes.applicationGuildCommands(clientId, guildId), {
          body,
        });
        log.info("Registered slash commands", { guildId });
      } catch (err) {
        log.error("Failed to register commands for guild", { guildId, error: err.message });
      }
    }
  } else {
    // Global (may take up to 1h to propagate)
    await rest.put(Routes.applicationCommands(clientId), { body });
    log.info("Registered global slash commands");
  }
}

// ── Discord Client ──────────────────────────────────────────────────────────

const client = new Client({
  intents: [
    GatewayIntentBits.Guilds,
    GatewayIntentBits.GuildMessages,
    GatewayIntentBits.MessageContent,
    GatewayIntentBits.DirectMessages,
  ],
  partials: [Partials.Channel],
});

client.once(Events.ClientReady, async () => {
  log.info("Logged in", { tag: client.user.tag });
  try {
    await registerCommands(client.user.id);
  } catch (err) {
    log.error("Failed to register slash commands — bot continues but commands may not appear", { error: err.message });
  }
  startGrantCleanup();

  // Restore grants from DB for any persisted sessions
  for (const row of getAllSessions()) {
    restoreGrants(row.channel_id);
  }

  log.info("Bot ready", { project: PROJECT_NAME });

  // ── Environment Validation & Crash Recovery ─────────────────────────────
  const envIssues = await validateEnvironment();
  const recoveryInfo = await recoverFromPreviousErrors();

  // ── Startup Notification ────────────────────────────────────────────────
  await sendStartupNotification({ envIssues, recoveryInfo });

  // ── Bot Presence ────────────────────────────────────────────────────────
  client.user.setPresence({
    activities: [{ name: "/task", type: ActivityType.Listening }],
    status: "online",
  });
});

/** Build the startup embed once and reuse for channel + DM. */
function buildStartupEmbed({ envIssues, recoveryInfo } = {}) {
  let repoInfo = "unknown";
  try {
    repoInfo = execSync("git remote get-url origin", { cwd: REPO_PATH, encoding: "utf-8", timeout: 5_000 }).trim();
  } catch { /* ignore */ }

  const hasErrors = envIssues?.errors?.length > 0;
  const hasWarnings = envIssues?.warnings?.length > 0;
  const hasRecovery = recoveryInfo && (recoveryInfo.recoveredSessions > 0 || recoveryInfo.abortedTasks.length > 0);

  const color = hasErrors ? 0xff0000 : (hasWarnings || hasRecovery) ? 0xffa500 : 0x2ecc71;
  const title = hasErrors ? "\u26A0\uFE0F Bot Online — Configuration Errors" : hasRecovery ? "\u{1F7E1} Bot Online — Recovered" : "\u{1F7E2} Bot Online";

  const embed = new EmbedBuilder()
    .setTitle(title)
    .setColor(color)
    .setDescription(`**${client.user.tag}** is ready and listening.`)
    .addFields(
      { name: "Project", value: PROJECT_NAME, inline: true },
      { name: "Commands", value: `${commands.length} registered`, inline: true },
      { name: "Repository", value: repoInfo, inline: false },
    )
    .setTimestamp();

  if (hasErrors) {
    embed.addFields({
      name: "\u{1F534} Configuration Errors",
      value: envIssues.errors.map((e) => `\u2022 ${e}`).join("\n").slice(0, 1024),
      inline: false,
    });
  }

  if (hasWarnings) {
    embed.addFields({
      name: "\u{1F7E1} Warnings",
      value: envIssues.warnings.map((w) => `\u2022 ${w}`).join("\n").slice(0, 1024),
      inline: false,
    });
  }

  if (hasRecovery) {
    const lines = [];
    if (recoveryInfo.recoveredSessions > 0) {
      lines.push(`${recoveryInfo.recoveredSessions} interrupted session(s) reset to idle`);
    }
    for (const t of recoveryInfo.abortedTasks.slice(0, 10)) {
      const snippet = t.prompt_snippet.length > 80 ? t.prompt_snippet.slice(0, 80) + "\u2026" : t.prompt_snippet;
      lines.push(`\u{1F6D1} Aborted: ${snippet}`);
    }
    if (recoveryInfo.abortedTasks.length > 10) {
      lines.push(`\u2026 and ${recoveryInfo.abortedTasks.length - 10} more`);
    }
    embed.addFields({
      name: "\u{1F504} Recovered from Previous Crash",
      value: lines.join("\n").slice(0, 1024),
      inline: false,
    });
  }

  return embed;
}

// ── Environment Validation ──────────────────────────────────────────────────

async function validateEnvironment() {
  const errors = [];
  const warnings = [];

  // Check STARTUP_CHANNEL_ID — does the channel still exist?
  if (STARTUP_CHANNEL_ID) {
    try {
      const ch = await client.channels.fetch(STARTUP_CHANNEL_ID);
      if (!ch?.isTextBased()) {
        errors.push(`STARTUP_CHANNEL_ID (${STARTUP_CHANNEL_ID}) exists but is not a text channel.`);
      }
    } catch {
      errors.push(`STARTUP_CHANNEL_ID (${STARTUP_CHANNEL_ID}) points to a deleted or inaccessible channel. Update it in your .env file.`);
    }
  }

  // Check ADMIN_USER_ID — is the user reachable?
  if (ADMIN_USER_ID) {
    try {
      await client.users.fetch(ADMIN_USER_ID);
    } catch {
      errors.push(`ADMIN_USER_ID (${ADMIN_USER_ID}) is invalid or the user cannot be found. Update it in your .env file.`);
    }
  }

  // Check GITHUB_TOKEN — is it still valid?
  if (process.env.GITHUB_TOKEN) {
    try {
      const resp = await fetch("https://api.github.com/user", {
        headers: {
          Authorization: `token ${process.env.GITHUB_TOKEN}`,
          "User-Agent": "discord-copilot-agent/1.0",
        },
        signal: AbortSignal.timeout(10_000),
      });
      if (resp.status === 401) {
        errors.push("GITHUB_TOKEN is expired or invalid (401). Generate a new one at https://github.com/settings/tokens");
      } else if (resp.status === 403) {
        warnings.push("GITHUB_TOKEN returned 403 (rate-limited or forbidden). The token may still work.");
      } else if (resp.ok) {
        // Check for copilot scope (classic PATs expose X-OAuth-Scopes)
        const scopes = resp.headers.get("x-oauth-scopes") || "";
        if (scopes && !scopes.split(",").map((s) => s.trim()).includes("copilot")) {
          errors.push(
            "GITHUB_TOKEN is missing the `copilot` scope. " +
            "Edit your token at https://github.com/settings/tokens and enable the `copilot` scope, " +
            "or run `copilot auth login` on the host."
          );
        }
      } else {
        warnings.push(`GITHUB_TOKEN validation returned HTTP ${resp.status}. Might be a transient issue.`);
      }
    } catch (err) {
      warnings.push(`Could not validate GITHUB_TOKEN (network error: ${err.message}). Continuing...`);
    }
  }

  // Check REPO_PATH — does it exist and is it a git repo?
  if (!existsSync(REPO_PATH)) {
    warnings.push(`REPO_PATH (${REPO_PATH}) does not exist. Clone the repo or update the path.`);
  } else if (!existsSync(`${REPO_PATH}/.git`) && !existsSync(`${REPO_PATH}/HEAD`)) {
    warnings.push(`REPO_PATH (${REPO_PATH}) exists but does not appear to be a git repository.`);
  }

  // Check ALLOWED_GUILDS — are we actually in those guilds?
  if (ALLOWED_GUILDS) {
    for (const guildId of ALLOWED_GUILDS) {
      if (!client.guilds.cache.has(guildId)) {
        warnings.push(`ALLOWED_GUILDS contains ${guildId} but bot is not in that server.`);
      }
    }
  }

  // Check Copilot CLI auth — try to get the client (auth check happens on session creation,
  // but we can at least verify the CLI binary is available)
  try {
    getCopilotClient();
  } catch (err) {
    errors.push(`Copilot CLI is not available: ${err.message}. Run \`copilot auth login\` on the host.`);
  }

  if (errors.length > 0 || warnings.length > 0) {
    log.warn("Environment validation issues", { errors, warnings });
  } else {
    log.info("Environment validation passed");
  }

  return { errors, warnings };
}

// ── Previous Crash Recovery ─────────────────────────────────────────────────

async function recoverFromPreviousErrors() {
  const staleSessions = getStaleSessions();
  const staleTasks = getStaleRunningTasks();

  if (staleSessions.length === 0 && staleTasks.length === 0) {
    return null;
  }

  log.warn("Recovering from previous crash", {
    staleSessions: staleSessions.length,
    staleTasks: staleTasks.length,
  });

  const abortedTasks = staleTasks.map((t) => ({
    channel_id: t.channel_id,
    prompt_snippet: t.prompt.slice(0, 120),
    task_id: t.id,
  }));

  const abortedCount = markStaleTasksAborted();
  const resetCount = resetStaleSessions();

  log.info("Recovery complete", { abortedTasks: abortedCount, resetSessions: resetCount });

  // Notify affected channels (best-effort)
  const notifiedChannels = new Set();
  for (const task of abortedTasks) {
    if (notifiedChannels.has(task.channel_id)) continue;
    notifiedChannels.add(task.channel_id);
    try {
      const ch = await client.channels.fetch(task.channel_id);
      if (ch?.isTextBased()) {
        const snippet = task.prompt_snippet.length > 100 ? task.prompt_snippet.slice(0, 100) + "\u2026" : task.prompt_snippet;
        const embed = new EmbedBuilder()
          .setTitle("\u26A0\uFE0F Bot Restarted — Task Aborted")
          .setColor(0xffa500)
          .setDescription(`The bot was restarted and your running task was interrupted.\n\n**Aborted task:** ${snippet}\n\nYou can re-submit the task with \`/task\`.`)
          .setTimestamp();
        await ch.send({ embeds: [embed] });
      }
    } catch (err) {
      log.warn("Failed to notify channel about aborted task", { channelId: task.channel_id, error: err.message });
    }
  }

  return {
    recoveredSessions: resetCount,
    abortedTasks,
  };
}

async function sendStartupNotification({ envIssues, recoveryInfo } = {}) {
  const embed = buildStartupEmbed({ envIssues, recoveryInfo });

  // Channel notification
  let channelSent = false;
  if (STARTUP_CHANNEL_ID) {
    try {
      const ch = await client.channels.fetch(STARTUP_CHANNEL_ID);
      if (ch?.isTextBased()) {
        await ch.send({ embeds: [embed] });
        log.info("Startup notification sent to channel", { channelId: STARTUP_CHANNEL_ID });
        channelSent = true;
      } else {
        log.warn("STARTUP_CHANNEL_ID is not a text channel", { channelId: STARTUP_CHANNEL_ID });
      }
    } catch (err) {
      log.warn("Failed to send startup notification to channel", { channelId: STARTUP_CHANNEL_ID, error: err.message });
    }
  }

  // Admin DM notification
  let adminSent = false;
  if (ADMIN_USER_ID) {
    try {
      const user = await client.users.fetch(ADMIN_USER_ID);
      await user.send({ embeds: [embed] });
      log.info("Startup DM sent to admin", { userId: ADMIN_USER_ID });
      adminSent = true;
    } catch (err) {
      log.warn("Failed to send startup DM to admin", { userId: ADMIN_USER_ID, error: err.message });
    }
  }

  // Fallback: if no notification was delivered, post to first available text channel
  if (!channelSent && !adminSent) {
    try {
      const guild = client.guilds.cache.first();
      if (guild) {
        const fallback = guild.systemChannel
          ?? guild.channels.cache.find((c) => c.isTextBased() && c.permissionsFor(guild.members.me)?.has("SendMessages"));
        if (fallback) {
          await fallback.send({ embeds: [embed] });
          log.info("Startup notification sent to fallback channel", { channelId: fallback.id, guildId: guild.id });
        }
      }
    } catch (err) {
      log.warn("Failed to send fallback startup notification", { error: err.message });
    }
  }
}

// ── Interaction Handler ─────────────────────────────────────────────────────

client.on("interactionCreate", async (interaction) => {
  if (!interaction.isChatInputCommand() && !interaction.isButton()) return;

  // Button interactions (push approve/reject) handled by collector in push-approval.mjs
  if (interaction.isButton()) return;

  if (!isAllowed(interaction)) {
    await interaction.reply({
      content: "⛔ You don't have permission to use this bot.",
      ephemeral: true,
    });
    return;
  }

  if (isRateLimited(interaction)) {
    await interaction.reply({
      content: `⏳ Rate limited — max ${RATE_LIMIT_MAX} commands per ${Math.round(RATE_LIMIT_WINDOW_MS / 1000)}s. Please wait.`,
      ephemeral: true,
    });
    return;
  }

  const { commandName, channelId } = interaction;
  const channel = interaction.channel;

  try {
    switch (commandName) {
      // ── /task ─────────────────────────────────────────────────────────
      case "task": {
        const prompt = interaction.options.getString("prompt");
        await interaction.reply(`📋 **Task queued:** ${prompt}`);

        // Create a thread for this task's output — fall back to channel on failure
        let outputChannel = channel;
        try {
          const reply = await interaction.fetchReply();
          const thread = await reply.startThread({
            name: `Task: ${prompt.slice(0, 90)}`,
            autoArchiveDuration: 1440,
          });
          outputChannel = thread;
        } catch (err) {
          log.warn("Failed to create thread, using channel", { error: err.message });
        }

        // Fire and forget — streaming output handled by session manager
        enqueueTask(channelId, channel, prompt, outputChannel, { id: interaction.user.id, tag: interaction.user.tag }).catch((err) => {
          outputChannel
            .send(`❌ **Task failed:** ${err.message}`)
            .catch(() => {});
        });
        break;
      }

      // ── /status ───────────────────────────────────────────────────────
      case "status": {
        const status = getSessionStatus(channelId);
        if (!status) {
          await interaction.reply({
            content: "No active session for this channel. Use `/task` to start one.",
            ephemeral: true,
          });
          break;
        }

        const grantLines = status.grants.length
          ? status.grants
              .map((g) => `\`${g.path}\` (${g.mode}, ${g.expiresIn}min left)`)
              .join("\n")
          : "None";

        const embed = new EmbedBuilder()
          .setTitle("📊 Agent Status")
          .setColor(
            status.paused
              ? 0xff6600
              : status.status === "working"
                ? 0x3498db
                : status.status === "idle"
                  ? 0x2ecc71
                  : 0xff9900
          )
          .addFields(
            { name: "Status", value: status.paused ? `${status.status} (⏸ paused)` : status.status, inline: true },
            { name: "Branch", value: status.branch, inline: true },
            { name: "Queue", value: `${status.queueLength} pending`, inline: true },
            { name: "Workspace", value: `\`${status.workspace}\``, inline: false },
            { name: "Active Grants", value: grantLines, inline: false }
          )
          .setTimestamp();

        await interaction.reply({ embeds: [embed] });
        break;
      }

      // ── /approve_push ─────────────────────────────────────────────────
      case "approve_push": {
        await interaction.deferReply();
        const result = await approvePendingPush(channelId, channel);
        if (!result.found) {
          await interaction.editReply("No active session found. Use `/task` first.");
        } else {
          await interaction.editReply("✅ Push approval noted.");
        }
        break;
      }

      // ── /grant ────────────────────────────────────────────────────────
      case "grant": {
        const grantPath = interaction.options.getString("path");
        const mode = interaction.options.getString("mode") || "ro";
        const ttl = interaction.options.getInteger("ttl") || 30;

        // Basic sanity: must be absolute
        if (!grantPath.startsWith("/") && !grantPath.match(/^[A-Z]:\\/i)) {
          await interaction.reply({
            content: "⚠️ Path must be absolute (e.g. `/home/user/data` or `C:\\Users\\...`).",
            ephemeral: true,
          });
          break;
        }

        const result = addGrant(channelId, grantPath, mode, ttl);
        await interaction.reply(
          `✅ **Granted** \`${mode}\` access to \`${grantPath}\` for **${ttl} min** (expires <t:${Math.floor(new Date(result.expiresAt).getTime() / 1000)}:R>).`
        );
        break;
      }

      // ── /revoke ───────────────────────────────────────────────────────
      case "revoke": {
        const revokePath = interaction.options.getString("path");
        revokeGrant(channelId, revokePath);
        await interaction.reply(`🔒 **Revoked** access to \`${revokePath}\`.`);
        break;
      }

      // ── /reset ────────────────────────────────────────────────────────
      case "reset": {
        await interaction.deferReply();
        await resetSession(channelId);
        await interaction.editReply("🔄 Session reset. Use `/task` to start a new one.");
        break;
      }

      // ── /stop ─────────────────────────────────────────────────────────
      case "stop": {
        const clearQ = interaction.options.getBoolean("clear_queue") ?? true;
        const result = hardStop(channelId, clearQ);
        if (!result.found) {
          await interaction.reply({
            content: "No active session to stop.",
            ephemeral: true,
          });
          break;
        }
        const parts = [];
        if (result.wasWorking) parts.push("Aborted running task");
        else parts.push("No task was running");
        if (result.queueCleared > 0) parts.push(`cleared ${result.queueCleared} queued task(s)`);
        await interaction.reply(`🛑 **Stopped.** ${parts.join(", ")}.`);
        break;
      }

      // ── /pause ────────────────────────────────────────────────────────
      case "pause": {
        const result = pauseSession(channelId);
        if (!result.found) {
          await interaction.reply({
            content: "No active session to pause.",
            ephemeral: true,
          });
          break;
        }
        await interaction.reply(
          "⏸ **Queue paused.** Current task (if any) will finish, but no new tasks will start.\n" +
            "Use `/resume` to continue or `/stop` to abort the running task."
        );
        break;
      }

      // ── /resume ───────────────────────────────────────────────────────
      case "resume": {
        const result = resumeSession(channelId, channel);
        if (!result.found) {
          await interaction.reply({
            content: "No active session to resume.",
            ephemeral: true,
          });
          break;
        }
        if (!result.wasPaused) {
          await interaction.reply({
            content: "Session was not paused.",
            ephemeral: true,
          });
          break;
        }
        await interaction.reply("▶️ **Queue resumed.** Pending tasks will now be processed.");
        break;
      }

      // ── /queue ────────────────────────────────────────────────────────
      case "queue": {
        const action = interaction.options.getString("action") || "list";

        if (action === "clear") {
          const result = clearQueue(channelId);
          if (!result.found) {
            await interaction.reply({
              content: "No active session.",
              ephemeral: true,
            });
            break;
          }
          await interaction.reply(
            result.cleared > 0
              ? `🗑 Cleared **${result.cleared}** pending task(s).`
              : "Queue was already empty."
          );
          break;
        }

        // action === "list"
        const info = getQueueInfo(channelId);
        if (!info) {
          await interaction.reply({
            content: "No active session. Use `/task` to start one.",
            ephemeral: true,
          });
          break;
        }

        if (info.length === 0) {
          await interaction.reply({
            content: `Queue is empty.${info.paused ? " *(paused)*" : ""}`,
            ephemeral: true,
          });
          break;
        }

        const lines = info.items.map(
          (item) => `**${item.index}.** ${item.prompt}${item.prompt.length >= 100 ? "…" : ""}${item.userTag ? ` *(${item.userTag})*` : ""}`
        );
        const embed = new EmbedBuilder()
          .setTitle(`📋 Task Queue (${info.length} pending)`)
          .setColor(info.paused ? 0xff6600 : 0x3498db)
          .setDescription(lines.join("\n"))
          .setFooter({ text: info.paused ? "⏸ Queue is paused" : "Queue is active" });
        await interaction.reply({ embeds: [embed] });
        break;
      }

      // ── /history ──────────────────────────────────────────────────────
      case "history": {
        const limit = interaction.options.getInteger("limit") || 10;
        const tasks = getTaskHistory(channelId, limit);

        if (tasks.length === 0) {
          await interaction.reply({
            content: "No task history for this channel.",
            ephemeral: true,
          });
          break;
        }

        const statusIcon = { completed: "✅", failed: "❌", running: "⏳", aborted: "🛑" };
        const lines = tasks.map((t) => {
          const icon = statusIcon[t.status] || "❔";
          const prompt = t.prompt.length > 60 ? t.prompt.slice(0, 60) + "…" : t.prompt;
          const time = t.started_at ? `<t:${Math.floor(new Date(t.started_at + "Z").getTime() / 1000)}:R>` : "";
          return `${icon} ${prompt} ${time}`;
        });

        const embed = new EmbedBuilder()
          .setTitle(`📜 Task History (last ${tasks.length})`)
          .setColor(0x9b59b6)
          .setDescription(lines.join("\n"))
          .setTimestamp();
        await interaction.reply({ embeds: [embed] });
        break;
      }

      // ── /config ───────────────────────────────────────────────────────
      case "config": {
        const embed = new EmbedBuilder()
          .setTitle("⚙️ Bot Configuration")
          .setColor(0x95a5a6)
          .addFields(
            { name: "Project", value: PROJECT_NAME, inline: true },
            { name: "Repo Path", value: `\`${REPO_PATH}\``, inline: true },
            { name: "Base Root", value: `\`${BASE_ROOT}\``, inline: false },
            { name: "Workspaces Root", value: `\`${WORKSPACES_ROOT}\``, inline: false },
            { name: "Edit Throttle", value: `${DISCORD_EDIT_THROTTLE_MS} ms`, inline: true },
            { name: "Default Grant Mode", value: DEFAULT_GRANT_MODE, inline: true },
            { name: "Default Grant TTL", value: `${DEFAULT_GRANT_TTL_MIN} min`, inline: true },
            {
              name: "Guild Filter",
              value: ALLOWED_GUILDS ? [...ALLOWED_GUILDS].join(", ") : "*(all)*",
              inline: false,
            },
            {
              name: "Channel Filter",
              value: ALLOWED_CHANNELS ? [...ALLOWED_CHANNELS].join(", ") : "*(all)*",
              inline: false,
            },
            {
              name: "Admin Roles",
              value: ADMIN_ROLE_IDS ? [...ADMIN_ROLE_IDS].join(", ") : "*(none — all users allowed)*",
              inline: false,
            }
          )
          .setTimestamp();
        await interaction.reply({ embeds: [embed], ephemeral: true });
        break;
      }

      // ── /diff ─────────────────────────────────────────────────────────
      case "diff": {
        const status = getSessionStatus(channelId);
        if (!status) {
          await interaction.reply({
            content: "No active session. Use `/task` first.",
            ephemeral: true,
          });
          break;
        }

        const mode = interaction.options.getString("mode") || "stat";
        const gitCmd =
          mode === "stat"
            ? "git diff --stat"
            : mode === "staged"
              ? "git diff --cached"
              : "git diff";

        await interaction.deferReply();

        try {
          const output = execSync(gitCmd, {
            cwd: status.workspace,
            encoding: "utf-8",
            timeout: 15_000,
          });

          if (!output.trim()) {
            await interaction.editReply("No changes.");
            break;
          }

          const clean = redactSecrets(output).clean;

          if (clean.length <= 1900) {
            await interaction.editReply(`\`\`\`diff\n${clean}\n\`\`\``);
          } else {
            const attachment = new AttachmentBuilder(Buffer.from(clean, "utf-8"), {
              name: "diff.txt",
              description: `git diff (${mode})`,
            });
            await interaction.editReply({ files: [attachment] });
          }
        } catch (err) {
          await interaction.editReply(`❌ \`${gitCmd}\` failed: ${err.message}`);
        }
        break;
      }

      // ── /branch ───────────────────────────────────────────────────────
      case "branch": {
        const status = getSessionStatus(channelId);
        if (!status) {
          await interaction.reply({
            content: "No active session. Use `/task` first.",
            ephemeral: true,
          });
          break;
        }

        const action = interaction.options.getString("action") || "current";
        const branchName = interaction.options.getString("name");

        if (action === "current") {
          await interaction.reply(`Current branch: \`${status.branch}\``);
          break;
        }

        if (action === "list") {
          try {
            const branches = execSync("git branch --list", {
              cwd: status.workspace,
              encoding: "utf-8",
              timeout: 5_000,
            }).trim();
            await interaction.reply(`\`\`\`\n${branches}\n\`\`\``);
          } catch (err) {
            await interaction.reply(`❌ Failed: ${err.message}`);
          }
          break;
        }

        if (!branchName) {
          await interaction.reply({
            content: `Please provide a branch name for \`${action}\`.`,
            ephemeral: true,
          });
          break;
        }

        // Sanitize branch name: only allow safe characters
        if (!/^[\w.\/-]{1,100}$/.test(branchName)) {
          await interaction.reply({
            content: "\u26A0\uFE0F Invalid branch name. Only letters, digits, `.`, `/`, `-`, `_` are allowed (max 100 chars).",
            ephemeral: true,
          });
          break;
        }

        // Guard: no branch operations while working
        if (status.status === "working") {
          await interaction.reply({
            content: "⚠️ Cannot switch/create branches while a task is running. Use `/stop` first.",
            ephemeral: true,
          });
          break;
        }

        await interaction.deferReply();

        if (action === "create") {
          try {
            execSync(`git checkout -b "${branchName}"`, {
              cwd: status.workspace,
              encoding: "utf-8",
              timeout: 10_000,
            });
            await interaction.editReply(`✅ Created and switched to branch \`${branchName}\`.`);
          } catch (err) {
            await interaction.editReply(`❌ Failed: ${err.message}`);
          }
          break;
        }

        if (action === "switch") {
          try {
            execSync(`git checkout "${branchName}"`, {
              cwd: status.workspace,
              encoding: "utf-8",
              timeout: 10_000,
            });
            await interaction.editReply(`✅ Switched to branch \`${branchName}\`.`);
          } catch (err) {
            await interaction.editReply(`❌ Failed: ${err.message}`);
          }
          break;
        }
        break;
      }

      // ── /help ─────────────────────────────────────────────────────────
      case "help": {
        const embed = new EmbedBuilder()
          .setTitle("📖 Bot Commands")
          .setColor(0x3498db)
          .setDescription(
            commands
              .filter((c) => c.name !== "help")
              .map((c) => `**/${c.name}** — ${c.description}`)
              .join("\n")
          )
          .setFooter({ text: `${commands.length} commands available` })
          .setTimestamp();
        await interaction.reply({ embeds: [embed], ephemeral: true });
        break;
      }

      // ── /stats ────────────────────────────────────────────────────────
      case "stats": {
        const stats = getTaskStats();
        const uptime = process.uptime();
        const days = Math.floor(uptime / 86400);
        const hours = Math.floor((uptime % 86400) / 3600);
        const mins = Math.floor((uptime % 3600) / 60);
        const uptimeStr = days > 0
          ? `${days}d ${hours}h ${mins}m`
          : hours > 0
            ? `${hours}h ${mins}m`
            : `${mins}m`;

        const embed = new EmbedBuilder()
          .setTitle("📈 Bot Statistics")
          .setColor(0x2ecc71)
          .addFields(
            { name: "Uptime", value: uptimeStr, inline: true },
            { name: "Active Sessions", value: String(getActiveSessionCount()), inline: true },
            { name: "Tasks Total", value: String(stats.total), inline: true },
            { name: "✅ Completed", value: String(stats.completed), inline: true },
            { name: "❌ Failed", value: String(stats.failed), inline: true },
            { name: "🛑 Aborted", value: String(stats.aborted), inline: true },
          )
          .setTimestamp();
        await interaction.reply({ embeds: [embed] });
        break;
      }

      default:
        await interaction.reply({ content: "Unknown command.", ephemeral: true });
    }
  } catch (err) {
    log.error("Command error", { command: commandName, error: err.message });
    const reply = interaction.deferred || interaction.replied
      ? (msg) => interaction.editReply(msg)
      : (msg) => interaction.reply({ content: msg, ephemeral: true });
    await reply(`❌ Error: ${err.message}`).catch(() => {});
  }
});

// ── Follow-up in Threads & DMs ──────────────────────────────────────────────

client.on("messageCreate", async (message) => {
  if (message.author.bot) return;

  const isDM = !message.guild;

  // ── DM follow-ups: if a session exists for this DM channel, treat as follow-up
  if (isDM) {
    const dmChannelId = message.channel.id;
    const status = getSessionStatus(dmChannelId);
    if (!status) return; // No active session in this DM — ignore

    const prompt = message.content.trim();
    if (!prompt) return;

    log.info("Follow-up in DM", { channelId: dmChannelId, prompt: prompt.slice(0, 100) });

    enqueueTask(dmChannelId, message.channel, prompt, message.channel, { id: message.author.id, tag: message.author.tag }).catch((err) => {
      message.channel
        .send(`❌ **Follow-up failed:** ${err.message}`)
        .catch(() => {});
    });
    return;
  }

  // ── Thread follow-ups (guild channels)
  if (!message.channel.isThread()) return;

  const parent = message.channel.parent;
  if (!parent) return;
  const parentId = parent.id;

  if (ALLOWED_GUILDS && !ALLOWED_GUILDS.has(parent.guildId)) return;
  if (ALLOWED_CHANNELS && !ALLOWED_CHANNELS.has(parentId)) return;
  if (message.channel.ownerId !== client.user.id) return;

  if (ADMIN_ROLE_IDS) {
    const memberRoles = message.member?.roles?.cache;
    if (!memberRoles || ![...ADMIN_ROLE_IDS].some((id) => memberRoles.has(id))) {
      return;
    }
  }

  const prompt = message.content.trim();
  if (!prompt) return;

  log.info("Follow-up in thread", { channelId: parentId, threadId: message.channel.id, prompt: prompt.slice(0, 100) });

  enqueueTask(parentId, parent, prompt, message.channel, { id: message.author.id, tag: message.author.tag }).catch((err) => {
    message.channel
      .send(`❌ **Follow-up failed:** ${err.message}`)
      .catch(() => {});
  });
});

// ── Graceful Shutdown ───────────────────────────────────────────────────────

async function shutdown(signal) {
  log.info("Shutting down", { signal });

  // Send shutdown notification before destroying the client
  const shutdownEmbed = new EmbedBuilder()
    .setTitle("\u{1F534} Bot Going Offline")
    .setColor(0xe74c3c)
    .setDescription(`**${client.user?.tag ?? "Bot"}** is shutting down (${signal}).`)
    .addFields({ name: "Project", value: PROJECT_NAME, inline: true })
    .setTimestamp();

  if (STARTUP_CHANNEL_ID) {
    try {
      const ch = await client.channels.fetch(STARTUP_CHANNEL_ID);
      if (ch?.isTextBased()) await ch.send({ embeds: [shutdownEmbed] });
    } catch { /* best effort */ }
  }
  if (ADMIN_USER_ID) {
    try {
      const user = await client.users.fetch(ADMIN_USER_ID);
      await user.send({ embeds: [shutdownEmbed] });
    } catch { /* best effort */ }
  }

  try { client.destroy(); } catch (err) { log.error("Client destroy failed", { error: err.message }); }
  try { await stopCopilotClient(); } catch (err) { log.error("Copilot stop failed", { error: err.message }); }
  try { closeDb(); } catch (err) { log.error("DB close failed", { error: err.message }); }
  process.exit(0);
}

process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("unhandledRejection", (err) => {
  log.error("Unhandled rejection", { error: err?.message || String(err) });
});

client.on("error", (err) => {
  log.error("Discord client error", { error: err.message });
});

client.on("warn", (msg) => {
  log.warn("Discord client warning", { message: msg });
});

client.on("shardDisconnect", (event, shardId) => {
  log.warn("Shard disconnected", { shardId, code: event?.code });
});

client.on("shardReconnecting", (shardId) => {
  log.info("Shard reconnecting", { shardId });
});

client.on("shardResume", async (shardId) => {
  log.info("Shard resumed", { shardId });

  // Reconnect notification
  if (STARTUP_CHANNEL_ID) {
    try {
      const ch = await client.channels.fetch(STARTUP_CHANNEL_ID);
      if (ch?.isTextBased()) {
        const embed = new EmbedBuilder()
          .setTitle("\u{1F7E1} Bot Reconnected")
          .setColor(0xf1c40f)
          .setDescription(`**${client.user?.tag ?? "Bot"}** has reconnected after a brief disconnect.`)
          .addFields({ name: "Project", value: PROJECT_NAME, inline: true })
          .setTimestamp();
        await ch.send({ embeds: [embed] });
      }
    } catch (err) {
      log.warn("Failed to send reconnect notification", { error: err.message });
    }
  }
});

// ── Start ───────────────────────────────────────────────────────────────────

log.info("Starting Discord bot");
client.login(DISCORD_TOKEN).catch((err) => {
  log.error("Failed to login to Discord", { error: err.message });
  process.exit(1);
});
