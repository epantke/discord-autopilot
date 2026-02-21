---
description: "Use when editing Discord bot interaction handling, slash commands, output streaming, thread management, embeds, or message chunking in the discord.js v14 bot."
applyTo: ["src/bot.mjs", "src/discord-output.mjs", "src/push-approval.mjs"]
---
# Discord Bot Conventions

## Slash Commands
- Define new commands as `SlashCommandBuilder` instances, added to the `commands` array in `bot.mjs`
- Admin-only commands set `.setDefaultMemberPermissions(PermissionFlagsBits.ManageGuild)`
- Command handler follows the `switch (commandName)` pattern in the `interactionCreate` listener
- Use `interaction.deferReply()` for operations that may take >3 seconds, then `interaction.editReply()`

## Interaction Lifecycle
- Check `interaction.deferred || interaction.replied` before choosing `editReply` vs `reply` in error handlers
- Use ephemeral replies (`{ ephemeral: true }`) for permission denials, errors, and config display
- Fire-and-forget sends use `.catch(() => {})` to swallow Discord API failures

## Thread & DM Follow-ups
- `/task` creates a thread via `reply.startThread()` for streaming output — fall back to channel on failure
- Thread follow-ups: `messageCreate` listener checks `message.channel.isThread()`, verifies parent channel, and routes to `enqueueTask()`
- DM follow-ups: if a session exists for the DM channel, messages route to `enqueueTask()`
- Both paths verify RBAC before processing

## Output Streaming (`DiscordOutput`)
- Throttled edits: one edit per `DISCORD_EDIT_THROTTLE_MS` (default 1500ms)
- Buffer >1990 chars triggers attachment fallback (`.txt` file via `AttachmentBuilder`)
- `flush()` is serialized — `_flushing` flag prevents concurrent Discord API calls
- On edit failure (error code 10008/50005 = deleted message), retry with a new message

## Secret Redaction
- Every text path to Discord must call `redactSecrets()` before `.send()` or `.edit()`
- This includes: `DiscordOutput.flush()`, `/diff` output, error messages, and push-approval embeds

## Embeds
- Use `EmbedBuilder` for structured responses (`/status`, `/history`, `/stats`, `/config`, `/help`)
- Color coding: green (0x2ecc71) = success/idle, blue (0x3498db) = active, orange (0xff6600) = paused/warning, red (0xe74c3c) = error/shutdown
