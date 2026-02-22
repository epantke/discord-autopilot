import {
  EmbedBuilder,
  ActionRowBuilder,
  ButtonBuilder,
  ButtonStyle,
  MessageFlags,
} from "discord.js";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { redactSecrets } from "./secret-scanner.mjs";
import { ADMIN_ROLE_IDS, ADMIN_USER_ID } from "./config.mjs";

const execFileAsync = promisify(execFile);

/** Active collectors per channel, so they can be cancelled on /reset. */
const _activeCollectors = new Map();

/** Cancel any active push-approval collector for a channel. */
export function cancelPushApproval(channelId) {
  const collector = _activeCollectors.get(channelId);
  if (collector) {
    collector.stop("reset");
    _activeCollectors.delete(channelId);
  }
}

async function getBranch(cwd) {
  try {
    const { stdout } = await execFileAsync("git", ["branch", "--show-current"], { cwd, encoding: "utf-8", timeout: 5_000 });
    return stdout.trim() || "(detached)";
  } catch {
    return "(unknown)";
  }
}

/**
 * Collects git info and posts a push-approval embed with buttons.
 * Returns a Promise that resolves to { approved: boolean }.
 * @param {string} [channelId] - Channel ID for collector tracking
 */
export async function createPushApprovalRequest(channel, workspacePath, command, channelId) {
  let diffSummary = "";
  let logSummary = "";

  try {
    const { stdout } = await execFileAsync("git", ["diff", "--stat", "HEAD~1"], {
      cwd: workspacePath,
      encoding: "utf-8",
      timeout: 10_000,
    });
    diffSummary = redactSecrets(stdout.slice(0, 900)).clean;
  } catch {
    try {
      const { stdout } = await execFileAsync("git", ["diff", "--stat"], {
        cwd: workspacePath,
        encoding: "utf-8",
        timeout: 10_000,
      });
      diffSummary = redactSecrets(stdout.slice(0, 900)).clean;
    } catch {
      diffSummary = "(diff unavailable)";
    }
  }

  try {
    const { stdout } = await execFileAsync("git", ["log", "--oneline", "-5"], {
      cwd: workspacePath,
      encoding: "utf-8",
      timeout: 5_000,
    });
    logSummary = redactSecrets(stdout.slice(0, 500)).clean;
  } catch {
    logSummary = "(log unavailable)";
  }

  const cleanCmd = redactSecrets(command.slice(0, 200)).clean;

  const embed = new EmbedBuilder()
    .setTitle("🗡️ Push Approval")
    .setColor(0x71797e)
    .setDescription(
      `Nyx will ausführen:\n\`\`\`\n${cleanCmd}\n\`\`\``
    )
    .addFields(
      { name: "Letzte Commits", value: `\`\`\`\n${logSummary}\n\`\`\``, inline: false },
      { name: "Diff", value: `\`\`\`\n${diffSummary}\n\`\`\``, inline: false },
      { name: "Branch", value: await getBranch(workspacePath), inline: true },
      { name: "Workspace", value: workspacePath, inline: true }
    )
    .setTimestamp();

  const row = new ActionRowBuilder().addComponents(
    new ButtonBuilder()
      .setCustomId("push_approve")
      .setLabel("💜 Approve")
      .setStyle(ButtonStyle.Success),
    new ButtonBuilder()
      .setCustomId("push_reject")
      .setLabel("🩸 Reject")
      .setStyle(ButtonStyle.Danger)
  );

  let msg;
  try {
    msg = await channel.send({ embeds: [embed], components: [row] });
  } catch (err) {
    return { approved: false, user: `(send failed: ${err.message})` };
  }

  return new Promise((resolve) => {
    const collector = msg.createMessageComponentCollector({
      filter: (i) => {
        if (i.customId !== "push_approve" && i.customId !== "push_reject") return false;
        // RBAC: admins can approve/reject pushes
        // Deny-by-default: if neither ADMIN_USER_ID nor ADMIN_ROLE_IDS are configured,
        // nobody is allowed to approve pushes.
        if (!ADMIN_USER_ID && !ADMIN_ROLE_IDS) {
          i.reply({ content: "\u26d3\ufe0f Kein Admin konfiguriert — Push-Approval deaktiviert. Setze ADMIN_USER_ID oder ADMIN_ROLE_IDS.", flags: MessageFlags.Ephemeral }).catch(() => {});
          return false;
        }
        // In DMs (no member/roles), fall back to ADMIN_USER_ID check
        const isAdminUser = ADMIN_USER_ID && i.user.id === ADMIN_USER_ID;
        if (!isAdminUser && ADMIN_ROLE_IDS) {
          const roles = i.member?.roles?.cache;
          if (!roles || ![...ADMIN_ROLE_IDS].some((id) => roles.has(id))) {
            i.reply({ content: "\u26d3\ufe0f Keine Berechtigung für Push-Approval.", flags: MessageFlags.Ephemeral }).catch(() => {});
            return false;
          }
        }
        if (!isAdminUser && !ADMIN_ROLE_IDS) {
          i.reply({ content: "\u26d3\ufe0f Keine Berechtigung für Push-Approval.", flags: MessageFlags.Ephemeral }).catch(() => {});
          return false;
        }
        return true;
      },
      max: 1,
      time: 600_000, // 10 min timeout
    });

    collector.on("collect", async (interaction) => {
      const approved = interaction.customId === "push_approve";
      const label = approved ? "💜 Push approved" : "🩸 Push rejected";
      const color = approved ? 0x2d1b4e : 0x8b0000;

      const updatedEmbed = EmbedBuilder.from(embed)
        .setColor(color)
        .setFooter({ text: `${label} by ${interaction.user.tag}` });

      try {
        await interaction.update({
          embeds: [updatedEmbed],
          components: [], // remove buttons
        });
      } catch {}

      resolve({ approved, user: interaction.user.tag });
    });

    collector.on("end", (collected) => {
      if (channelId) _activeCollectors.delete(channelId);
      if (collected.size === 0) {
        msg.edit({ components: [] }).catch(() => {});
        resolve({ approved: false, user: "(timeout)" });
      }
    });
  });
}
