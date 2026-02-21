import {
  ActivityType,
  ActionRowBuilder,
  ButtonBuilder,
  ButtonStyle,
  Client,
  Events,
  GatewayIntentBits,
  MessageFlags,
  Partials,
  PermissionFlagsBits,
  REST,
  Routes,
  SlashCommandBuilder,
  EmbedBuilder,
} from "discord.js";

import {
  DISCORD_TOKEN,
  GITHUB_TOKEN,
  ALLOWED_GUILDS,
  ALLOWED_CHANNELS,
  ADMIN_ROLE_IDS,
  ALLOWED_DM_USERS,
  PROJECT_NAME,
  DISCORD_EDIT_THROTTLE_MS,
  DEFAULT_GRANT_MODE,
  DEFAULT_GRANT_TTL_MIN,
  BASE_ROOT,
  WORKSPACES_ROOT,
  REPO_PATH,
  TASK_TIMEOUT_MS,
  RATE_LIMIT_WINDOW_MS,
  RATE_LIMIT_MAX,
  STARTUP_CHANNEL_ID,
  ADMIN_USER_ID,
  DEFAULT_MODEL,
  CURRENT_VERSION,
  UPDATE_CHECK_INTERVAL_MS,
  AUTO_RETRY_ON_CRASH,
} from "./config.mjs";

import {
  enqueueTask,
  getSessionStatus,
  resetSession,
  hardStop,
  pauseSession,
  resumeSession,
  isAwaitingQuestion,
  addChannelResponder,
  removeChannelResponder,
  getChannelResponders,
  changeModel,
  listAvailableModels,
} from "./session-manager.mjs";

import { addGrant, revokeGrant, startGrantCleanup, restoreGrants } from "./grants.mjs";
import {
  closeDb,
  getAllSessions,
  getStaleSessions,
  getStaleRunningTasks,
  markStaleTasksAborted,
  resetStaleSessions,
} from "./state.mjs";
import { stopCopilotClient } from "./copilot-client.mjs";
import { redactSecrets } from "./secret-scanner.mjs";
import { checkForUpdate, downloadAndApplyUpdate, restartBot } from "./updater.mjs";
import { createLogger } from "./logger.mjs";
import { execSync, execFile } from "node:child_process";
import { promisify } from "node:util";
import { existsSync } from "node:fs";

const execFileAsync = promisify(execFile);

const log = createLogger("bot");

// ── Slash Commands Definition ───────────────────────────────────────────────

const commands = [
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
    .setDescription("Pause queue processing (current task finishes, no new ones start)")
    .setDefaultMemberPermissions(PermissionFlagsBits.ManageGuild),

  new SlashCommandBuilder()
    .setName("resume")
    .setDescription("Resume queue processing after a pause")
    .setDefaultMemberPermissions(PermissionFlagsBits.ManageGuild),

  new SlashCommandBuilder()
    .setName("config")
    .setDescription("View current bot configuration")
    .setDefaultMemberPermissions(PermissionFlagsBits.ManageGuild),

  new SlashCommandBuilder()
    .setName("update")
    .setDescription("Check for and apply bot updates")
    .addStringOption((opt) =>
      opt
        .setName("action")
        .setDescription("What to do")
        .addChoices(
          { name: "Check for updates", value: "check" },
          { name: "Apply update now", value: "apply" }
        )
    )
    .setDefaultMemberPermissions(PermissionFlagsBits.ManageGuild),

  new SlashCommandBuilder()
    .setName("responders")
    .setDescription("Manage who can answer agent questions")
    .addStringOption((opt) =>
      opt
        .setName("action")
        .setDescription("What to do")
        .setRequired(true)
        .addChoices(
          { name: "Add user", value: "add" },
          { name: "Remove user", value: "remove" },
          { name: "List responders", value: "list" }
        )
    )
    .addUserOption((opt) =>
      opt.setName("user").setDescription("User to add/remove")
    )
    .setDefaultMemberPermissions(PermissionFlagsBits.ManageGuild),

  new SlashCommandBuilder()
    .setName("model")
    .setDescription("View or change the AI model for this channel")
    .addStringOption((opt) =>
      opt
        .setName("action")
        .setDescription("What to do")
        .addChoices(
          { name: "Show current model", value: "current" },
          { name: "List available models", value: "list" },
          { name: "Set model", value: "set" }
        )
    )
    .addStringOption((opt) =>
      opt.setName("name").setDescription("Model ID to switch to (for set)").setAutocomplete(true)
    )
    .setDefaultMemberPermissions(PermissionFlagsBits.ManageGuild),
];

// ── Access Control ──────────────────────────────────────────────────────────

function isAllowed(interaction) {
  const isDM = !interaction.guildId;

  // DMs: only allow if ADMIN_USER_ID is set and matches the sender
  if (isDM) {
    return ADMIN_USER_ID && interaction.user.id === ADMIN_USER_ID;
  }

  if (ALLOWED_GUILDS && !ALLOWED_GUILDS.has(interaction.guildId)) return false;
  if (ALLOWED_CHANNELS && !ALLOWED_CHANNELS.has(interaction.channelId)) return false;
  if (ADMIN_ROLE_IDS) {
    if (!hasAnyRole(interaction.member, ADMIN_ROLE_IDS)) return false;
  }
  return true;
}

function isAdmin(interaction) {
  // DM users must match ADMIN_USER_ID to be treated as admin
  if (!interaction.guildId) {
    return ADMIN_USER_ID && interaction.user.id === ADMIN_USER_ID;
  }
  if (!ADMIN_ROLE_IDS) return true;
  return hasAnyRole(interaction.member, ADMIN_ROLE_IDS);
}

/**
 * Safely check if a member has any of the given role IDs.
 * Handles both GuildMemberRoleManager (.cache Collection) and plain string[] (API interactions).
 */
function hasAnyRole(member, roleIds) {
  const roles = member?.roles;
  if (!roles) return false;
  // GuildMemberRoleManager with .cache (Collection with .has)
  if (roles.cache) return [...roleIds].some((id) => roles.cache.has(id));
  // Plain array of role ID strings (API interaction)
  if (Array.isArray(roles)) return [...roleIds].some((id) => roles.includes(id));
  return false;
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
  if (timestamps.length >= RATE_LIMIT_MAX) return true;
  timestamps.push(now);
  return false;
}

/**
 * Lightweight rate-limiter for messageCreate follow-ups (DMs + threads).
 * Reuses the same window/max as slash commands.
 */
function isDmRateLimited(userId) {
  if (ADMIN_USER_ID && userId === ADMIN_USER_ID) return false;
  const now = Date.now();
  let timestamps = rateLimitMap.get(userId);
  if (!timestamps) {
    timestamps = [];
    rateLimitMap.set(userId, timestamps);
  }
  const cutoff = now - RATE_LIMIT_WINDOW_MS;
  while (timestamps.length > 0 && timestamps[0] <= cutoff) timestamps.shift();
  if (timestamps.length >= RATE_LIMIT_MAX) return true;
  timestamps.push(now);
  return false;
}

// Periodic cleanup of stale rate-limit entries (cap map size to prevent memory growth)
const MAX_RATE_LIMIT_ENTRIES = 10_000;
const _rlCleanup = setInterval(() => {
  const cutoff = Date.now() - RATE_LIMIT_WINDOW_MS;
  for (const [userId, ts] of rateLimitMap) {
    while (ts.length > 0 && ts[0] <= cutoff) ts.shift();
    if (ts.length === 0) rateLimitMap.delete(userId);
  }
  // Hard cap: if someone floods the bot, evict oldest entries
  if (rateLimitMap.size > MAX_RATE_LIMIT_ENTRIES) {
    const excess = rateLimitMap.size - MAX_RATE_LIMIT_ENTRIES;
    const iter = rateLimitMap.keys();
    for (let i = 0; i < excess; i++) rateLimitMap.delete(iter.next().value);
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
    activities: [{ name: `v${CURRENT_VERSION} · @me`, type: ActivityType.Watching }],
    status: "online",
  });

  startUpdateChecker();
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
    .setDescription(`**${client.user.tag}** · ${PROJECT_NAME} · ${commands.length} cmds · v${CURRENT_VERSION}`);

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
  if (GITHUB_TOKEN) {
    try {
      const resp = await fetch("https://api.github.com/user", {
        headers: {
          Authorization: `token ${GITHUB_TOKEN}`,
          "User-Agent": `discord-copilot-agent/${CURRENT_VERSION}`,
        },
        signal: AbortSignal.timeout(10_000),
      });
      if (resp.status === 401) {
        errors.push("GITHUB_TOKEN is expired or invalid (401). Generate a new one at https://github.com/settings/tokens");
      } else if (resp.status === 403) {
        warnings.push("GITHUB_TOKEN returned 403 (rate-limited or forbidden). The token may still work.");
      } else if (!resp.ok) {
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

  // Check Copilot auth — the SDK uses `gh auth` credentials (not the GITHUB_TOKEN PAT)
  try {
    execSync("gh auth status", { encoding: "utf-8", timeout: 10_000, stdio: "pipe" });
  } catch (err) {
    const output = err.stdout || err.stderr || err.message || "";
    if (output.includes("not logged")) {
      errors.push("GitHub CLI is not authenticated. Run `gh auth login` so the Copilot SDK can use its credentials.");
    } else {
      warnings.push(`Could not verify gh auth status: ${output.slice(0, 120)}`);
    }
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
    prompt: t.prompt,
    prompt_snippet: t.prompt.slice(0, 120),
    task_id: t.id,
    user_id: t.user_id || null,
  }));

  const abortedCount = markStaleTasksAborted();
  const resetCount = resetStaleSessions();

  log.info("Recovery complete", { abortedTasks: abortedCount, resetSessions: resetCount });

  // Notify affected channels and offer retry (best-effort)
  const notifiedChannels = new Set();
  for (const task of abortedTasks) {
    if (notifiedChannels.has(task.channel_id)) continue;
    notifiedChannels.add(task.channel_id);
    try {
      const ch = await client.channels.fetch(task.channel_id);
      if (!ch?.isTextBased()) continue;

      const snippet = task.prompt_snippet.length > 100 ? task.prompt_snippet.slice(0, 100) + "\u2026" : task.prompt_snippet;

      // ── Auto-retry: re-enqueue the task automatically ──────────────
      if (AUTO_RETRY_ON_CRASH) {
        const embed = new EmbedBuilder()
          .setTitle("\u26A0\uFE0F Bot Restarted — Retrying Task")
          .setColor(0xffa500)
          .setDescription(
            `The bot was restarted and your running task was interrupted.\n\n` +
            `**Aborted task:** ${snippet}\n\n` +
            `\u{1F504} **Automatically re-submitting…**`
          )
          .setTimestamp();
        await ch.send({ embeds: [embed] });

        enqueueTask(task.channel_id, ch, task.prompt, ch, { id: task.user_id, tag: null }).catch((err) => {
          log.warn("Auto-retry failed", { channelId: task.channel_id, error: err.message });
          ch.send(`\u274C Auto-retry failed: ${redactSecrets(err.message).clean}`).catch(() => {});
        });
        log.info("Auto-retrying aborted task", { channelId: task.channel_id, taskId: task.task_id });
        continue;
      }

      // ── Manual retry: show button ──────────────────────────────────
      const retryId = `retry_task_${task.channel_id}_${Date.now()}`;
      const embed = new EmbedBuilder()
        .setTitle("\u26A0\uFE0F Bot Restarted — Task Aborted")
        .setColor(0xffa500)
        .setDescription(
          `The bot was restarted and your running task was interrupted.\n\n` +
          `**Aborted task:** ${snippet}\n\n` +
          `Click the button below to re-submit, or send a new message.`
        )
        .setTimestamp();

      const row = new ActionRowBuilder().addComponents(
        new ButtonBuilder()
          .setCustomId(retryId)
          .setLabel("\u{1F504} Retry Task")
          .setStyle(ButtonStyle.Primary),
      );

      const msg = await ch.send({ embeds: [embed], components: [row] });

      // Await button click with 10 min timeout (non-blocking — do not await the outer promise)
      msg.awaitMessageComponent({
        filter: (i) => {
          if (i.customId !== retryId) return false;
          if (ADMIN_USER_ID && i.user.id === ADMIN_USER_ID) return true;
          if (task.user_id && i.user.id === task.user_id) return true;
          if (ADMIN_ROLE_IDS && i.member?.roles?.cache) {
            if ([...ADMIN_ROLE_IDS].some((id) => i.member.roles.cache.has(id))) return true;
          }
          i.reply({ content: "\u26D4 Only the task author or an admin can retry.", flags: MessageFlags.Ephemeral }).catch(() => {});
          return false;
        },
        time: 600_000,
      }).then(async (btn) => {
        const retried = EmbedBuilder.from(embed)
          .setTitle("\u{1F504} Retrying Task…")
          .setColor(0x3498db)
          .setFooter({ text: `Retried by ${btn.user.tag}` });
        await btn.update({ embeds: [retried], components: [] }).catch(() => {});

        enqueueTask(task.channel_id, ch, task.prompt, ch, { id: btn.user.id, tag: btn.user.tag }).catch((err) => {
          ch.send(`\u274C Retry failed: ${redactSecrets(err.message).clean}`).catch(() => {});
        });
        log.info("Task retried via button", { channelId: task.channel_id, user: btn.user.tag });
      }).catch(() => {
        // Timeout or error — remove the button
        msg.edit({ components: [] }).catch(() => {});
      });
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

  // Admin DM notification (preferred)
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

  // Fallback: channel notification if admin DM was not sent
  if (!adminSent && STARTUP_CHANNEL_ID) {
    try {
      const ch = await client.channels.fetch(STARTUP_CHANNEL_ID);
      if (ch?.isTextBased()) {
        await ch.send({ embeds: [embed] });
        log.info("Startup notification sent to channel", { channelId: STARTUP_CHANNEL_ID });
        return;
      } else {
        log.warn("STARTUP_CHANNEL_ID is not a text channel", { channelId: STARTUP_CHANNEL_ID });
      }
    } catch (err) {
      log.warn("Failed to send startup notification to channel", { channelId: STARTUP_CHANNEL_ID, error: err.message });
    }
  }

  // Last resort: post to first available text channel
  if (!adminSent) {
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

// ── Periodic Update Checker ─────────────────────────────────────────────────

let _lastNotifiedVersion = null;

async function sendUpdateBanner(updateInfo) {
  if (_lastNotifiedVersion === updateInfo.latestVersion) return;
  _lastNotifiedVersion = updateInfo.latestVersion;

  const embed = new EmbedBuilder()
    .setTitle("🚀 Update Available!")
    .setColor(0xFFAA00)
    .setDescription(
      `A new version of **Discord Autopilot** is ready!\n\n` +
      `\`v${updateInfo.currentVersion}\` → \`v${updateInfo.latestVersion}\``
    )
    .setTimestamp();

  if (updateInfo.releaseNotes) {
    const notes = updateInfo.releaseNotes.length > 500
      ? updateInfo.releaseNotes.slice(0, 497) + "…"
      : updateInfo.releaseNotes;
    embed.addFields({ name: "📋 What's New", value: notes, inline: false });
  }

  embed.addFields({
    name: "💡 How to Update",
    value: "Use `/update apply` in Discord, or run `--update` / `-Update` from the command line.",
    inline: false,
  });

  const row = new ActionRowBuilder().addComponents(
    new ButtonBuilder()
      .setLabel("View Release")
      .setStyle(ButtonStyle.Link)
      .setURL(updateInfo.releaseUrl),
  );

  const payload = { embeds: [embed], components: [row] };

  if (ADMIN_USER_ID) {
    try {
      const user = await client.users.fetch(ADMIN_USER_ID);
      await user.send(payload);
      log.info("Update notification sent to admin", { version: updateInfo.latestVersion });
    } catch (err) {
      log.warn("Failed to send update notification DM", { error: err.message });
    }
  }

  if (STARTUP_CHANNEL_ID) {
    try {
      const ch = await client.channels.fetch(STARTUP_CHANNEL_ID);
      if (ch?.isTextBased()) await ch.send(payload);
    } catch (err) {
      log.warn("Failed to send update notification to channel", { error: err.message });
    }
  }
}

function startUpdateChecker() {
  const initialTimer = setTimeout(async () => {
    try {
      const result = await checkForUpdate();
      if (result.available) await sendUpdateBanner(result);
    } catch (err) {
      log.warn("Initial update check failed", { error: err.message });
    }
  }, 30_000);
  initialTimer.unref();

  const interval = setInterval(async () => {
    try {
      const result = await checkForUpdate();
      if (result.available) await sendUpdateBanner(result);
    } catch (err) {
      log.warn("Periodic update check failed", { error: err.message });
    }
  }, UPDATE_CHECK_INTERVAL_MS);
  interval.unref();
}

// ── Interaction Handler ─────────────────────────────────────────────────────

client.on("interactionCreate", async (interaction) => {
  // Model name autocomplete
  if (interaction.isAutocomplete()) {
    if (interaction.commandName === "model") {
      const focused = interaction.options.getFocused();
      try {
        const models = await listAvailableModels();
        const filtered = models
          .filter((m) => m.id.toLowerCase().includes(focused.toLowerCase()) || m.name.toLowerCase().includes(focused.toLowerCase()))
          .slice(0, 25);
        await interaction.respond(filtered.map((m) => ({ name: `${m.name} (${m.id})`, value: m.id })));
      } catch {
        await interaction.respond([]).catch(() => {});
      }
    }
    return;
  }

  if (!interaction.isChatInputCommand() && !interaction.isButton()) return;

  // Button interactions (push approve/reject) handled by collector in push-approval.mjs
  if (interaction.isButton()) return;

  if (!isAllowed(interaction)) {
    await interaction.reply({
      content: "⛔ You don't have permission to use this bot.",
      flags: MessageFlags.Ephemeral,
    });
    return;
  }

  if (isRateLimited(interaction)) {
    await interaction.reply({
      content: `⏳ Rate limited — max ${RATE_LIMIT_MAX} commands per ${Math.round(RATE_LIMIT_WINDOW_MS / 1000)}s. Please wait.`,
      flags: MessageFlags.Ephemeral,
    });
    return;
  }

  const { commandName, channelId } = interaction;
  const channel = interaction.channel;

  try {
    switch (commandName) {
      // ── /grant ────────────────────────────────────────────────────────
      case "grant": {
        const grantPath = interaction.options.getString("path");
        const mode = interaction.options.getString("mode") || "ro";
        const ttl = interaction.options.getInteger("ttl") || 30;

        // Basic sanity: must be absolute
        if (!grantPath.startsWith("/") && !grantPath.match(/^[A-Z]:\\/i)) {
          await interaction.reply({
            content: "⚠️ Path must be absolute (e.g. `/home/user/data` or `C:\\Users\\...`).",
            flags: MessageFlags.Ephemeral,
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
        await interaction.editReply("🔄 Session reset. @mention me or send a DM to start a new task.");
        break;
      }

      // ── /stop ─────────────────────────────────────────────────────────
      case "stop": {
        const clearQ = interaction.options.getBoolean("clear_queue") ?? true;
        const result = hardStop(channelId, clearQ);
        if (!result.found) {
          await interaction.reply({
            content: "No active session to stop.",
            flags: MessageFlags.Ephemeral,
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
            flags: MessageFlags.Ephemeral,
          });
          break;
        }
        if (result.wasAlreadyPaused) {
          await interaction.reply({
            content: "Session is already paused.",
            flags: MessageFlags.Ephemeral,
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
            flags: MessageFlags.Ephemeral,
          });
          break;
        }
        if (!result.wasPaused) {
          await interaction.reply({
            content: "Session was not paused.",
            flags: MessageFlags.Ephemeral,
          });
          break;
        }
        await interaction.reply("▶️ **Queue resumed.** Pending tasks will now be processed.");
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
            { name: "Default Model", value: DEFAULT_MODEL || "*(SDK default)*", inline: true },
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
            },
            { name: "Task Timeout", value: `${Math.round(TASK_TIMEOUT_MS / 60_000)} min`, inline: true },
            { name: "Rate Limit", value: `${RATE_LIMIT_MAX} / ${Math.round(RATE_LIMIT_WINDOW_MS / 1000)}s`, inline: true },
          )
          .setTimestamp();
        await interaction.reply({ embeds: [embed], flags: MessageFlags.Ephemeral });
        break;
      }

      // ── /responders ─────────────────────────────────────────────────
      case "responders": {
        const action = interaction.options.getString("action");
        const user = interaction.options.getUser("user");

        if (action === "list") {
          const responders = getChannelResponders(channelId);
          if (responders.size === 0) {
            await interaction.reply({
              content: "No responders configured — only admins can answer agent questions.",
              flags: MessageFlags.Ephemeral,
            });
          } else {
            const list = [...responders].map((id) => `<@${id}>`).join(", ");
            await interaction.reply({
              content: `**Responders:** ${list}`,
              flags: MessageFlags.Ephemeral,
            });
          }
          break;
        }

        if (!user) {
          await interaction.reply({
            content: "⚠️ Please provide a user (`user` option).",
            flags: MessageFlags.Ephemeral,
          });
          break;
        }

        if (action === "add") {
          addChannelResponder(channelId, user.id);
          await interaction.reply(`✅ <@${user.id}> can now answer agent questions in this channel.`);
        } else if (action === "remove") {
          removeChannelResponder(channelId, user.id);
          await interaction.reply(`🔒 <@${user.id}> removed as responder.`);
        }
        break;
      }

      // ── /model ─────────────────────────────────────────────────────────
      case "model": {
        const action = interaction.options.getString("action") || "current";
        const modelName = interaction.options.getString("name");

        if (action === "list") {
          await interaction.deferReply({ flags: MessageFlags.Ephemeral });
          try {
            const models = await listAvailableModels();
            if (!models || models.length === 0) {
              await interaction.editReply("No models available.");
              break;
            }
            const lines = models.map((m) => {
              const effort = m.supportedReasoningEfforts?.length
                ? ` · reasoning: ${m.supportedReasoningEfforts.join(", ")}`
                : "";
              const policy = m.policy?.state === "disabled" ? " ⛔" : "";
              return `**${m.name}** — \`${m.id}\`${effort}${policy}`;
            });
            let description = lines.join("\n");
            if (description.length > 4000) {
              description = description.slice(0, 4000) + "\n…(truncated)";
            }
            const embed = new EmbedBuilder()
              .setTitle("🤖 Available Models")
              .setColor(0x3498db)
              .setDescription(description)
              .setTimestamp();
            await interaction.editReply({ embeds: [embed] });
          } catch (err) {
            await interaction.editReply(`❌ Failed to list models: ${redactSecrets(err.message).clean}`);
          }
          break;
        }

        if (action === "current") {
          const status = getSessionStatus(channelId);
          const current = status?.model || DEFAULT_MODEL || "*(SDK default)*";
          await interaction.reply({
            content: `Current model: \`${current}\``,
            flags: MessageFlags.Ephemeral,
          });
          break;
        }

        if (action === "set") {
          if (!modelName) {
            await interaction.reply({
              content: "⚠️ Please provide a model ID (`name` option). Use `/model action:list` to see available models.",
              flags: MessageFlags.Ephemeral,
            });
            break;
          }

          await interaction.deferReply();
          const result = await changeModel(channelId, channel, modelName);
          if (result.ok) {
            await interaction.editReply(`✅ Model switched to \`${modelName}\`.`);
          } else {
            await interaction.editReply(`❌ ${result.error}`);
          }
          break;
        }
        break;
      }

      // ── /update ───────────────────────────────────────────────────────
      case "update": {
        const action = interaction.options.getString("action") || "check";

        if (action === "check") {
          await interaction.deferReply({ flags: MessageFlags.Ephemeral });
          const result = await checkForUpdate({ force: true });

          if (result.error) {
            const embed = new EmbedBuilder()
              .setTitle("❌ Update Check Failed")
              .setColor(0xe74c3c)
              .setDescription(`Could not check for updates: ${result.error}`)
              .setTimestamp();
            await interaction.editReply({ embeds: [embed] });
            break;
          }

          if (result.available) {
            const embed = new EmbedBuilder()
              .setTitle("🚀 Update Available!")
              .setColor(0xFFAA00)
              .setDescription(
                `A new version is ready!\n\n` +
                `\`v${result.currentVersion}\` → \`v${result.latestVersion}\``
              )
              .setTimestamp();

            if (result.releaseNotes) {
              const notes = result.releaseNotes.length > 800
                ? result.releaseNotes.slice(0, 797) + "…"
                : result.releaseNotes;
              embed.addFields({ name: "📋 What's New", value: notes, inline: false });
            }

            embed.addFields({
              name: "💡 How to Update",
              value: "Run `/update apply` to update and restart the bot.",
              inline: false,
            });

            const row = new ActionRowBuilder().addComponents(
              new ButtonBuilder()
                .setLabel("View Release")
                .setStyle(ButtonStyle.Link)
                .setURL(result.releaseUrl),
            );

            await interaction.editReply({ embeds: [embed], components: [row] });
          } else {
            const embed = new EmbedBuilder()
              .setTitle("✅ Up to Date")
              .setColor(0x2ecc71)
              .setDescription(`You're running the latest version: **v${result.currentVersion}**`)
              .setTimestamp();
            await interaction.editReply({ embeds: [embed] });
          }
          break;
        }

        if (action === "apply") {
          await interaction.deferReply();
          const check = await checkForUpdate({ force: true });

          if (!check.available) {
            const embed = new EmbedBuilder()
              .setTitle("✅ Already Up to Date")
              .setColor(0x2ecc71)
              .setDescription(`Running version **v${check.currentVersion || CURRENT_VERSION}** — no update needed.`)
              .setTimestamp();
            await interaction.editReply({ embeds: [embed] });
            break;
          }

          const confirmEmbed = new EmbedBuilder()
            .setTitle("🔄 Confirm Update")
            .setColor(0xFFAA00)
            .setDescription(
              `Update from **v${check.currentVersion}** to **v${check.latestVersion}**?\n\n` +
              `⚠️ The bot will restart after the update is applied.`
            )
            .setTimestamp();

          const row = new ActionRowBuilder().addComponents(
            new ButtonBuilder()
              .setCustomId("update_confirm")
              .setLabel("✅ Update Now")
              .setStyle(ButtonStyle.Success),
            new ButtonBuilder()
              .setCustomId("update_cancel")
              .setLabel("Cancel")
              .setStyle(ButtonStyle.Secondary),
          );

          const msg = await interaction.editReply({ embeds: [confirmEmbed], components: [row] });

          try {
            const btn = await msg.awaitMessageComponent({
              filter: (i) => i.user.id === interaction.user.id,
              time: 120_000,
            });

            if (btn.customId === "update_cancel") {
              await btn.update({
                embeds: [new EmbedBuilder().setTitle("❌ Update Cancelled").setColor(0x95a5a6).setTimestamp()],
                components: [],
              });
              break;
            }

            await btn.update({
              embeds: [new EmbedBuilder()
                .setTitle("⏳ Downloading Update...")
                .setColor(0x3498db)
                .setDescription(`Downloading v${check.latestVersion}…`)
                .setTimestamp()],
              components: [],
            });

            const result = await downloadAndApplyUpdate();

            if (result.success) {
              await interaction.editReply({
                embeds: [new EmbedBuilder()
                  .setTitle("✅ Update Applied!")
                  .setColor(0x2ecc71)
                  .setDescription(
                    `Updated to **v${result.version}**\n\n` +
                    `🔄 **The bot will restart now.** It should be back online in a few seconds.\n\n` +
                    `💾 Backup saved to \`${result.backupPath}\``
                  )
                  .setTimestamp()],
                components: [],
              });
              setTimeout(() => restartBot(), 2_000);
            } else {
              await interaction.editReply({
                embeds: [new EmbedBuilder()
                  .setTitle("❌ Update Failed")
                  .setColor(0xe74c3c)
                  .setDescription(`**Reason:** ${result.reason}\n\nThe bot continues running on the current version.`)
                  .setTimestamp()],
                components: [],
              });
            }
          } catch {
            await interaction.editReply({
              embeds: [new EmbedBuilder().setTitle("⏰ Update Timed Out").setColor(0x95a5a6).setDescription("No response received. Update cancelled.").setTimestamp()],
              components: [],
            }).catch(() => {});
          }
          break;
        }
        break;
      }

      default:
        await interaction.reply({ content: "Unknown command.", flags: MessageFlags.Ephemeral });
    }
  } catch (err) {
    log.error("Command error", { command: commandName, error: err.message });
    const reply = interaction.deferred || interaction.replied
      ? (msg) => interaction.editReply(msg)
      : (msg) => interaction.reply({ content: msg, flags: MessageFlags.Ephemeral });
    await reply(`❌ Error: ${redactSecrets(err.message).clean}`).catch(() => {});
  }
});

// ── Follow-up in Threads & DMs ──────────────────────────────────────────────

// Known command names for detecting slash-command-like messages typed as plain text
const KNOWN_COMMANDS = new Set(commands.map((c) => c.name));

client.on("messageCreate", async (message) => {
  if (message.author.bot) return;

  // Detect plain-text messages that look like slash commands (e.g. "/model", "/status")
  const slashMatch = message.content.trim().match(/^\/([\w-]+)/);
  if (slashMatch && KNOWN_COMMANDS.has(slashMatch[1])) {
    message.reply(`💡 **\`/${slashMatch[1]}\`** is a slash command — type it in the message bar and pick it from the popup, or use it in a server channel (not as plain text).`).catch(() => {});
    return;
  }

  const isDM = !message.guild;

  // ── DM messages: new tasks + follow-ups ────────────────────────────────
  if (isDM) {
    const userId = message.author.id;
    const dmAllowed = (ADMIN_USER_ID && userId === ADMIN_USER_ID)
      || (ALLOWED_DM_USERS && ALLOWED_DM_USERS.has(userId));
    if (!dmAllowed) return;

    const dmChannelId = message.channel.id;

    // If the agent is waiting for a question answer, don't enqueue as new task
    if (isAwaitingQuestion(dmChannelId)) return;

    const prompt = message.content.trim();
    if (!prompt) return;

    // Rate-limit DM messages
    if (isDmRateLimited(userId)) {
      message.react("⏳").catch(() => {});
      return;
    }

    const status = getSessionStatus(dmChannelId);
    log.info(status ? "Follow-up in DM" : "New task via DM", { channelId: dmChannelId, prompt: prompt.slice(0, 100) });
    message.react("✅").catch(() => {});

    enqueueTask(dmChannelId, message.channel, prompt, message.channel, { id: userId, tag: message.author.tag }).catch((err) => {
      if (err._reportedByOutput) return;
      message.channel
        .send(`❌ **Task failed:** ${redactSecrets(err.message).clean}`)
        .catch(() => {});
    });
    return;
  }

  // ── @mention in guild channels: start new task ──────────────────────────
  if (!message.channel.isThread() && message.mentions.has(client.user)) {
    if (ALLOWED_GUILDS && !ALLOWED_GUILDS.has(message.guildId)) return;
    if (ALLOWED_CHANNELS && !ALLOWED_CHANNELS.has(message.channel.id)) return;
    if (ADMIN_ROLE_IDS && !hasAnyRole(message.member, ADMIN_ROLE_IDS)) return;

    // Strip the bot mention from the prompt
    const prompt = message.content
      .replace(new RegExp(`<@!?${client.user.id}>`, "g"), "")
      .trim();
    if (!prompt) return;

    if (isDmRateLimited(message.author.id)) {
      message.react("⏳").catch(() => {});
      return;
    }

    const channelId = message.channel.id;
    log.info("New task via @mention", { channelId, prompt: prompt.slice(0, 100) });
    message.react("✅").catch(() => {});

    // Create a thread for this task
    let outputChannel = message.channel;
    try {
      const thread = await message.startThread({
        name: `Task: ${prompt.slice(0, 90)}`,
        autoArchiveDuration: 1440,
      });
      outputChannel = thread;
    } catch (err) {
      log.warn("Failed to create thread for @mention task, using channel", { error: err.message });
    }

    enqueueTask(channelId, message.channel, prompt, outputChannel, { id: message.author.id, tag: message.author.tag }).catch((err) => {
      if (err._reportedByOutput) return;
      outputChannel
        .send(`❌ **Task failed:** ${redactSecrets(err.message).clean}`)
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

  // If the agent is waiting for a question answer, don't enqueue as follow-up
  if (isAwaitingQuestion(parentId)) return;

  if (ADMIN_ROLE_IDS) {
    if (!hasAnyRole(message.member, ADMIN_ROLE_IDS)) return;
  }

  const prompt = message.content.trim();
  if (!prompt) return;

  // Rate-limit thread follow-ups
  if (isDmRateLimited(message.author.id)) {
    message.react("⏳").catch(() => {});
    return;
  }

  log.info("Follow-up in thread", { channelId: parentId, threadId: message.channel.id, prompt: prompt.slice(0, 100) });
  message.react("✅").catch(() => {});

  enqueueTask(parentId, parent, prompt, message.channel, { id: message.author.id, tag: message.author.tag }).catch((err) => {
    if (err._reportedByOutput) return;
    message.channel
      .send(`❌ **Follow-up failed:** ${redactSecrets(err.message).clean}`)
      .catch(() => {});
  });
});

// ── Graceful Shutdown ───────────────────────────────────────────────────────

async function shutdown(signal, exitCode = 0) {
  log.info("Shutting down", { signal });

  // Hard deadline: force exit if cleanup takes too long
  const forceTimer = setTimeout(() => {
    log.error("Shutdown timed out after 15s, forcing exit");
    process.exit(1);
  }, 15_000);
  forceTimer.unref();

  // Send shutdown notification before destroying the client
  const shutdownEmbed = new EmbedBuilder()
    .setColor(0xe74c3c)
    .setDescription(`\u{1F534} Offline — **${client.user?.tag ?? "Bot"}** (${signal})`);

  let adminNotified = false;
  if (ADMIN_USER_ID) {
    try {
      const user = await client.users.fetch(ADMIN_USER_ID);
      await user.send({ embeds: [shutdownEmbed] });
      adminNotified = true;
    } catch { /* best effort */ }
  }
  if (!adminNotified && STARTUP_CHANNEL_ID) {
    try {
      const ch = await client.channels.fetch(STARTUP_CHANNEL_ID);
      if (ch?.isTextBased()) await ch.send({ embeds: [shutdownEmbed] });
    } catch { /* best effort */ }
  }

  try { client.destroy(); } catch (err) { log.error("Client destroy failed", { error: err.message }); }
  try { await stopCopilotClient(); } catch (err) { log.error("Copilot stop failed", { error: err.message }); }
  try { closeDb(); } catch (err) { log.error("DB close failed", { error: err.message }); }
  process.exit(exitCode);
}

// Prevent double-shutdown on repeated signals
let _shuttingDown = false;
async function safeShutdown(signal, exitCode) {
  if (_shuttingDown) return;
  _shuttingDown = true;
  await shutdown(signal, exitCode);
}

process.on("SIGINT", () => safeShutdown("SIGINT"));
process.on("SIGTERM", () => safeShutdown("SIGTERM"));

process.on("uncaughtException", (err) => {
  log.error("Uncaught exception — shutting down", { error: err?.message || String(err), stack: err?.stack });
  safeShutdown("uncaughtException", 1);
});

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

client.on("shardError", (err, shardId) => {
  log.error("Shard error", { shardId, error: err?.message || String(err) });
});

client.on("shardReconnecting", (shardId) => {
  log.info("Shard reconnecting", { shardId });
});

client.on("shardResume", async (shardId) => {
  log.info("Shard resumed", { shardId });

  // Reconnect notification — prefer admin DM, fallback to channel
  const reconnectEmbed = new EmbedBuilder()
    .setTitle("\u{1F7E1} Bot Reconnected")
    .setColor(0xf1c40f)
    .setDescription(`**${client.user?.tag ?? "Bot"}** has reconnected after a brief disconnect.`)
    .addFields({ name: "Project", value: PROJECT_NAME, inline: true })
    .setTimestamp();

  let reconnectSent = false;
  if (ADMIN_USER_ID) {
    try {
      const user = await client.users.fetch(ADMIN_USER_ID);
      await user.send({ embeds: [reconnectEmbed] });
      reconnectSent = true;
    } catch { /* best effort */ }
  }
  if (!reconnectSent && STARTUP_CHANNEL_ID) {
    try {
      const ch = await client.channels.fetch(STARTUP_CHANNEL_ID);
      if (ch?.isTextBased()) await ch.send({ embeds: [reconnectEmbed] });
    } catch (err) {
      log.warn("Failed to send reconnect notification", { error: err.message });
    }
  }
});

// ── Start ───────────────────────────────────────────────────────────────────

log.info("Starting Discord bot");
client.login(DISCORD_TOKEN).catch((err) => {
  if (err.code === "DisallowedIntents" || err.code === 4014) {
    log.error("Discord rejected privileged intents (Message Content Intent not enabled)", { error: err.message });
    log.error("Enable it: Discord Developer Portal > Bot > Privileged Gateway Intents", {});
  } else {
    log.error("Failed to login to Discord", { error: err.message });
  }
  process.exit(1);
});
