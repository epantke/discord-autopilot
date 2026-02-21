import {
  Client,
  GatewayIntentBits,
  REST,
  Routes,
  SlashCommandBuilder,
  EmbedBuilder,
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
];

// ── Access Control ──────────────────────────────────────────────────────────

function isAllowed(interaction) {
  if (ALLOWED_GUILDS && !ALLOWED_GUILDS.has(interaction.guildId)) return false;
  if (ALLOWED_CHANNELS && !ALLOWED_CHANNELS.has(interaction.channelId)) return false;
  if (ADMIN_ROLE_IDS) {
    const memberRoles = interaction.member?.roles?.cache;
    if (memberRoles) {
      const hasRole = [...ADMIN_ROLE_IDS].some((id) => memberRoles.has(id));
      if (!hasRole) return false;
    }
  }
  return true;
}

// ── Register Slash Commands ─────────────────────────────────────────────────

async function registerCommands(clientId) {
  const rest = new REST({ version: "10" }).setToken(DISCORD_TOKEN);
  const body = commands.map((c) => c.toJSON());

  if (ALLOWED_GUILDS && ALLOWED_GUILDS.size > 0) {
    // Guild-scoped (instant update)
    for (const guildId of ALLOWED_GUILDS) {
      await rest.put(Routes.applicationGuildCommands(clientId, guildId), {
        body,
      });
      console.log(`[discord] Registered slash commands in guild ${guildId}`);
    }
  } else {
    // Global (may take up to 1h to propagate)
    await rest.put(Routes.applicationCommands(clientId), { body });
    console.log("[discord] Registered global slash commands");
  }
}

// ── Discord Client ──────────────────────────────────────────────────────────

const client = new Client({
  intents: [
    GatewayIntentBits.Guilds,
    GatewayIntentBits.GuildMessages,
    GatewayIntentBits.MessageContent,
  ],
});

client.once("ready", async () => {
  console.log(`[discord] Logged in as ${client.user.tag}`);
  try {
    await registerCommands(client.user.id);
  } catch (err) {
    console.error("[discord] Failed to register slash commands:", err.message);
    console.error("[discord] Bot will continue, but commands may not appear. Retry by restarting.");
  }
  startGrantCleanup();

  // Restore grants from DB for any persisted sessions
  for (const row of getAllSessions()) {
    restoreGrants(row.channel_id);
  }

  console.log(`[discord] Bot ready — project: ${PROJECT_NAME}`);
});

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

  const { commandName, channelId } = interaction;
  const channel = interaction.channel;

  try {
    switch (commandName) {
      // ── /task ─────────────────────────────────────────────────────────
      case "task": {
        const prompt = interaction.options.getString("prompt");
        await interaction.reply(`📋 **Task queued:** ${prompt}`);

        // Fire and forget — streaming output handled by session manager
        enqueueTask(channelId, channel, prompt).catch((err) => {
          channel
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

      default:
        await interaction.reply({ content: "Unknown command.", ephemeral: true });
    }
  } catch (err) {
    console.error(`[discord] Command error (${commandName}):`, err);
    const reply = interaction.deferred || interaction.replied
      ? (msg) => interaction.editReply(msg)
      : (msg) => interaction.reply({ content: msg, ephemeral: true });
    await reply(`❌ Error: ${err.message}`).catch(() => {});
  }
});

// ── Graceful Shutdown ───────────────────────────────────────────────────────

async function shutdown(signal) {
  console.log(`\n[bot] Received ${signal}, shutting down…`);
  client.destroy();
  await stopCopilotClient();
  closeDb();
  process.exit(0);
}

process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("unhandledRejection", (err) => {
  console.error("[bot] Unhandled rejection:", err);
});

// ── Start ───────────────────────────────────────────────────────────────────

console.log("[bot] Starting Discord bot…");
client.login(DISCORD_TOKEN);
