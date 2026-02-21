import {
  EmbedBuilder,
  ActionRowBuilder,
  ButtonBuilder,
  ButtonStyle,
} from "discord.js";
import { execSync } from "node:child_process";

/**
 * Collects git info and posts a push-approval embed with buttons.
 * Returns a Promise that resolves to { approved: boolean }.
 */
export async function createPushApprovalRequest(channel, workspacePath, command) {
  let diffSummary = "";
  let logSummary = "";

  try {
    diffSummary = execSync("git diff --stat HEAD~1 2>/dev/null || git diff --stat", {
      cwd: workspacePath,
      encoding: "utf-8",
      timeout: 10_000,
      shell: true,
    }).slice(0, 900);
  } catch {
    diffSummary = "(diff unavailable)";
  }

  try {
    logSummary = execSync("git log --oneline -5", {
      cwd: workspacePath,
      encoding: "utf-8",
      timeout: 5_000,
    }).slice(0, 500);
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

  const msg = await channel.send({ embeds: [embed], components: [row] });

  return new Promise((resolve) => {
    const collector = msg.createMessageComponentCollector({
      filter: (i) => i.customId === "push_approve" || i.customId === "push_reject",
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

      await interaction.update({
        embeds: [updatedEmbed],
        components: [], // remove buttons
      });

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

/**
 * Execute the push and report result back to Discord.
 */
export async function executePush(channel, workspacePath, command) {
  try {
    const output = execSync(command, {
      cwd: workspacePath,
      encoding: "utf-8",
      timeout: 60_000,
    });

    const embed = new EmbedBuilder()
      .setTitle("✅ Push Successful")
      .setColor(0x00cc00)
      .setDescription(`\`\`\`\n${(output || "(no output)").slice(0, 1800)}\n\`\`\``)
      .setTimestamp();

    await channel.send({ embeds: [embed] });
    return { success: true, output };
  } catch (err) {
    const embed = new EmbedBuilder()
      .setTitle("❌ Push Failed")
      .setColor(0xcc0000)
      .setDescription(`\`\`\`\n${(err.stderr || err.message || "").slice(0, 1800)}\n\`\`\``)
      .setTimestamp();

    await channel.send({ embeds: [embed] });
    return { success: false, error: err.message };
  }
}
