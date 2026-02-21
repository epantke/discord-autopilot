import {
  Client,
  Events,
  GatewayIntentBits,
  Partials,
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
} from "./session-manager.mjs";

import { addGrant, revokeGrant, startGrantCleanup, restoreGrants } from "./grants.mjs";
import { closeDb, getAllSessions } from "./state.mjs";
import { stopCopilotClient } from "./copilot-client.mjs";
import { redactSecrets } from "./secret-scanner.mjs";
import { createLogger } from "./logger.mjs";
import { execSync } from "node:child_process";

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
    ),

  new SlashCommandBuilder()
    .setName("revoke")
    .setDescription("Revoke agent access to a path")
    .addStringOption((opt) =>
      opt.setName("path").setDescription("Absolute path to revoke").setRequired(true)
    ),

  new SlashCommandBuilder()
    .setName("reset")
    .setDescription("Reset the agent session for this channel"),

  new SlashCommandBuilder()
    .setName("stop")
    .setDescription("Hard stop — abort the running task immediately")
    .addBooleanOption((opt) =>
      opt
        .setName("clear_queue")
        .setDescription("Also clear all pending tasks (default: true)")
    ),

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
    .setDescription("View current bot configuration"),

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
];

// ── Access Control ──────────────────────────────────────────────────────────

function isAllowed(interaction) {
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

  // ── Startup Notification ────────────────────────────────────────────────
  await sendStartupNotification();
});

/** Build the startup embed once and reuse for channel + DM. */
function buildStartupEmbed() {
  let repoInfo = "unknown";
  try {
    repoInfo = execSync("git remote get-url origin", { cwd: REPO_PATH, encoding: "utf-8", timeout: 5_000 }).trim();
  } catch { /* ignore */ }

  return new EmbedBuilder()
    .setTitle("\u{1F7E2} Bot Online")
    .setColor(0x2ecc71)
    .setDescription(`**${client.user.tag}** is ready and listening.`)
    .addFields(
      { name: "Project", value: PROJECT_NAME, inline: true },
      { name: "Commands", value: `${commands.length} registered`, inline: true },
      { name: "Repository", value: repoInfo, inline: false },
    )
    .setTimestamp();
}

async function sendStartupNotification() {
  const embed = buildStartupEmbed();

  // Channel notification
  if (STARTUP_CHANNEL_ID) {
    try {
      const ch = await client.channels.fetch(STARTUP_CHANNEL_ID);
      if (ch?.isTextBased()) {
        await ch.send({ embeds: [embed] });
        log.info("Startup notification sent to channel", { channelId: STARTUP_CHANNEL_ID });
      } else {
        log.warn("STARTUP_CHANNEL_ID is not a text channel", { channelId: STARTUP_CHANNEL_ID });
      }
    } catch (err) {
      log.warn("Failed to send startup notification to channel", { channelId: STARTUP_CHANNEL_ID, error: err.message });
    }
  }

  // Admin DM notification
  if (ADMIN_USER_ID) {
    try {
      const user = await client.users.fetch(ADMIN_USER_ID);
      await user.send({ embeds: [embed] });
      log.info("Startup DM sent to admin", { userId: ADMIN_USER_ID });
    } catch (err) {
      log.warn("Failed to send startup DM to admin", { userId: ADMIN_USER_ID, error: err.message });
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
        enqueueTask(channelId, channel, prompt, outputChannel).catch((err) => {
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
          (item) => `**${item.index}.** ${item.prompt}${item.prompt.length >= 100 ? "…" : ""}`
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

// ── Follow-up in Threads ────────────────────────────────────────────────────

client.on("messageCreate", async (message) => {
  // Ignore bots and non-thread messages
  if (message.author.bot) return;
  if (!message.channel.isThread()) return;

  // Check if the thread was created by our bot (starter message author)
  const parent = message.channel.parent;
  if (!parent) return;
  const parentId = parent.id;

  // Only handle threads in allowed channels
  if (ALLOWED_CHANNELS && !ALLOWED_CHANNELS.has(parentId)) return;

  // Check that we own this thread (the thread's ownerId matches the bot)
  if (message.channel.ownerId !== client.user.id) return;

  // RBAC: check admin roles for follow-up messages
  if (ADMIN_ROLE_IDS) {
    const memberRoles = message.member?.roles?.cache;
    if (!memberRoles || ![...ADMIN_ROLE_IDS].some((id) => memberRoles.has(id))) {
      return;
    }
  }

  const prompt = message.content.trim();
  if (!prompt) return;

  log.info("Follow-up in thread", { channelId: parentId, threadId: message.channel.id, prompt: prompt.slice(0, 100) });

  enqueueTask(parentId, parent, prompt, message.channel).catch((err) => {
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
