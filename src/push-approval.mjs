import {
  EmbedBuilder,
  ActionRowBuilder,
  ButtonBuilder,
  ButtonStyle,
} from "discord.js";
import { execSync } from "node:child_process";
import { redactSecrets } from "./secret-scanner.mjs";
import { ADMIN_ROLE_IDS } from "./config.mjs";

/**
 * Collects git info and posts a push-approval embed with buttons.
 * Returns a Promise that resolves to { approved: boolean }.
 */
export async function createPushApprovalRequest(channel, workspacePath, command) {
  let diffSummary = "";
  let logSummary = "";

  try {
    diffSummary = redactSecrets(
      execSync("git diff --stat HEAD~1 || git diff --stat", {
        cwd: workspacePath,
        encoding: "utf-8",
        timeout: 10_000,
        stdio: ["pipe", "pipe", "pipe"],
      }).slice(0, 900)
    ).clean;
  } catch {
    diffSummary = "(diff unavailable)";
  }

  try {
    logSummary = redactSecrets(
      execSync("git log --oneline -5", {
        cwd: workspacePath,
        encoding: "utf-8",
        timeout: 5_000,
      }).slice(0, 500)
    ).clean;
  } catch {
    logSummary = "(log unavailable)";
  }

  const embed = new EmbedBuilder()
    .setTitle("🚀 Push Approval Required")
    .setColor(0xff9900)
    .setDescription(
      `The agent wants to execute:\n\`\`\`\n${command.slice(0, 200)}\n\`\`\``
    )
    .addFields(
      { name: "Recent Commits", value: `\`\`\`\n${logSummary}\n\`\`\``, inline: false },
      { name: "Diff Summary", value: `\`\`\`\n${diffSummary}\n\`\`\``, inline: false },
      { name: "Workspace", value: workspacePath, inline: true }
    )
    .setTimestamp();

  const row = new ActionRowBuilder().addComponents(
    new ButtonBuilder()
      .setCustomId("push_approve")
      .setLabel("✅ Approve Push")
      .setStyle(ButtonStyle.Success),
    new ButtonBuilder()
      .setCustomId("push_reject")
      .setLabel("❌ Reject Push")
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
        // RBAC: only admins can approve/reject pushes
        if (ADMIN_ROLE_IDS) {
          const roles = i.member?.roles?.cache;
          if (!roles || ![...ADMIN_ROLE_IDS].some((id) => roles.has(id))) {
            i.reply({ content: "\u26d4 You don't have permission to approve/reject pushes.", ephemeral: true }).catch(() => {});
            return false;
          }
        }
        return true;
      },
      max: 1,
      time: 600_000, // 10 min timeout
    });

    collector.on("collect", async (interaction) => {
      const approved = interaction.customId === "push_approve";
      const label = approved ? "✅ Push approved" : "❌ Push rejected";
      const color = approved ? 0x00cc00 : 0xcc0000;

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
      if (collected.size === 0) {
        msg.edit({ components: [] }).catch(() => {});
        resolve({ approved: false, user: "(timeout)" });
      }
    });
  });
}
