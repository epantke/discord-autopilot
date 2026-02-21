import { DISCORD_EDIT_THROTTLE_MS } from "./config.mjs";
import { AttachmentBuilder } from "discord.js";
import { redactSecrets } from "./secret-scanner.mjs";

const MESSAGE_SPLIT_THRESHOLD = 1800;

/**
 * Manages streaming output from Copilot to a Discord channel.
 * Accumulates full content per message and splits into multiple messages
 * when content exceeds Discord's limit, giving a readable streaming feel.
 */
export class DiscordOutput {
  /** @param {import("discord.js").TextBasedChannel} channel */
  constructor(channel) {
    this.channel = channel;
    this.content = "";
    this.dirty = false;
    this.message = null;
    this.lastEdit = 0;
    this.editTimer = null;
    this.finished = false;
    this._flushing = false;
    this._flushQueued = false;
    this._statusFooter = "";
  }

  /**
   * Append a chunk of text and schedule a throttled edit.
   */
  append(text) {
    if (this.finished) return;
    this.content += text;
    this.dirty = true;
    this._scheduleEdit();
  }

  /**
   * Set a transient status footer (replaces previous, not appended).
   * Shown below the content in Discord; cleared on finish().
   */
  status(text) {
    if (this.finished) return;
    this._statusFooter = text;
    this.dirty = true;
    this._scheduleEdit();
  }

  /**
   * Final flush — send remaining content, send as attachment if too large.
   */
  async finish(epilogue = "") {
    this.finished = true;
    this._statusFooter = "";
    if (this.editTimer) {
      clearTimeout(this.editTimer);
      this.editTimer = null;
    }
    if (epilogue) {
      this.content += `\n${epilogue}`;
      this.dirty = true;
    }
    try {
      await this.flush();
    } catch {
      // Best-effort final flush
    }
  }

  /**
   * Force-send current content to Discord (serialized — no concurrent edits).
   */
  async flush() {
    if (!this.dirty) return;
    if (this._flushing) {
      this._flushQueued = true;
      return;
    }
    this._flushing = true;
    this.dirty = false;

    try {
      const footer = this._statusFooter ? `\n${this._statusFooter}` : "";

      // If permanent content exceeds threshold, split (footer stays with remainder)
      if (this.content.length > MESSAGE_SPLIT_THRESHOLD && !this.finished) {
        const splitAt = this._findSplitPoint(this.content, MESSAGE_SPLIT_THRESHOLD);
        const head = redactSecrets(this.content.slice(0, splitAt)).clean;
        const tail = this.content.slice(splitAt);

        if (this.message) {
          await this.message.edit(head);
        } else {
          await this.channel.send(head);
        }
        // Start a new message for the remainder
        this.message = null;
        this.content = tail;
        this.dirty = tail.length > 0 || footer.length > 0;
        return;
      }

      const displayText = this.content + footer;
      const cleaned = redactSecrets(displayText).clean;
      if (!cleaned) return;

      if (cleaned.length <= 1990) {
        if (this.message) {
          await this.message.edit(cleaned);
        } else {
          this.message = await this.channel.send(cleaned);
        }
      } else {
        // Too large even for finish — send as attachment
        await this._sendAsAttachment(cleaned);
        this.message = null;
        this.content = "";
        this._statusFooter = "";
      }
    } catch (err) {
      // If edit fails (message deleted etc.), try a new message
      if (err.code === 10008 || err.code === 50005) {
        this.message = null;
        try {
          const footer = this._statusFooter ? `\n${this._statusFooter}` : "";
          const cleaned = redactSecrets(this.content + footer).clean;
          if (cleaned && cleaned.length <= 1990) {
            this.message = await this.channel.send(cleaned);
          } else if (cleaned) {
            await this._sendAsAttachment(cleaned);
            this.content = "";
            this._statusFooter = "";
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
   * Find a good split point near maxLen, preferring newline boundaries.
   */
  _findSplitPoint(text, maxLen) {
    const lastNewline = text.lastIndexOf("\n", maxLen);
    if (lastNewline > maxLen / 2) return lastNewline + 1;
    return maxLen;
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
    this.editTimer.unref();
  }
}
