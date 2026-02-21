import { DISCORD_EDIT_THROTTLE_MS } from "./config.mjs";
import { AttachmentBuilder } from "discord.js";
import { redactSecrets } from "./secret-scanner.mjs";

/**
 * Manages streaming output from Copilot to a Discord channel.
 * Handles throttled message edits and chunking for large output.
 */
export class DiscordOutput {
  /** @param {import("discord.js").TextBasedChannel} channel */
  constructor(channel) {
    this.channel = channel;
    this.buffer = "";
    this.message = null;
    this.lastEdit = 0;
    this.editTimer = null;
    this.finished = false;
    this._flushing = false;
    this._flushQueued = false;
  }

  /**
   * Append a chunk of text and schedule a throttled edit.
   */
  append(text) {
    this.buffer += text;
    this._scheduleEdit();
  }

  /**
   * Post a standalone status line (e.g. tool execution info).
   */
  async status(text) {
    try {
      // If buffer is small enough, append inline
      if (this.buffer.length + text.length + 2 < 1900) {
        this.buffer += `\n${text}`;
        this._scheduleEdit();
        return;
      }
      // Otherwise flush buffer and post new message
      await this.flush();
      this.buffer = text;
      this._scheduleEdit();
    } catch {
      // Swallow Discord errors — don't crash the agent
    }
  }

  /**
   * Final flush — send remaining buffer, send as attachment if too large.
   */
  async finish(epilogue = "") {
    this.finished = true;
    if (this.editTimer) {
      clearTimeout(this.editTimer);
      this.editTimer = null;
    }
    if (epilogue) this.buffer += `\n${epilogue}`;
    await this.flush();
  }

  /**
   * Force-send current buffer to Discord (serialized — no concurrent edits).
   */
  async flush() {
    if (!this.buffer) return;
    if (this._flushing) {
      this._flushQueued = true;
      return;
    }
    this._flushing = true;

    const content = redactSecrets(this.buffer).clean;
    this.buffer = "";

    try {
      if (content.length <= 1990) {
        if (this.message) {
          await this.message.edit(content);
        } else {
          this.message = await this.channel.send(content);
        }
      } else {
        // Large content → send as attachment
        await this._sendAsAttachment(content);
        this.message = null; // next chunk starts a new message
      }
    } catch (err) {
      // If edit fails (message deleted etc.), try a new message
      if (err.code === 10008 || err.code === 50005) {
        this.message = null;
        try {
          if (content.length <= 1990) {
            this.message = await this.channel.send(content);
          } else {
            await this._sendAsAttachment(content);
          }
        } catch {
          // Give up silently
        }
      }
    } finally {
      this._flushing = false;
      if (this._flushQueued) {
        this._flushQueued = false;
        await this.flush();
      }
    }
  }

  /**
   * Upload content as a .txt file attachment.
   */
  async _sendAsAttachment(content) {
    const attachment = new AttachmentBuilder(Buffer.from(content, "utf-8"), {
      name: "output.txt",
      description: "Agent output (too large for a message)",
    });
    await this.channel.send({ files: [attachment] });
  }

  /**
   * Schedule a throttled edit (max 1 edit per DISCORD_EDIT_THROTTLE_MS).
   */
  _scheduleEdit() {
    if (this.finished) return;
    if (this.editTimer) return; // already scheduled

    const elapsed = Date.now() - this.lastEdit;
    const delay = Math.max(0, DISCORD_EDIT_THROTTLE_MS - elapsed);

    this.editTimer = setTimeout(async () => {
      this.editTimer = null;
      this.lastEdit = Date.now();
      await this.flush();
    }, delay);
  }
}
