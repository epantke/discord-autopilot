import { DISCORD_EDIT_THROTTLE_MS } from "./config.mjs";
import { AttachmentBuilder } from "discord.js";
import { redactSecrets } from "./secret-scanner.mjs";
import { createLogger } from "./logger.mjs";

const log = createLogger("output");

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
    /** Content already scanned and cleaned by redactSecrets */
    this._cleanedContent = "";
    /** Raw content not yet scanned */
    this._pendingContent = "";
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
    if (this.finished || !text) return;
    this.content += text;
    this._pendingContent += text;
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
      this._pendingContent += `\n${epilogue}`;
      this.content += `\n${epilogue}`;
      this.dirty = true;
    }
    try {
      await this.flush();
    } catch (err) {
      log.error("Finish flush failed", { error: err.message, code: err.code });
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

      // Incrementally scan only newly appended content
      if (this._pendingContent) {
        this._cleanedContent += redactSecrets(this._pendingContent).clean;
        this._pendingContent = "";
      }

      // If permanent content exceeds threshold, split (footer stays with remainder)
      while (this._cleanedContent.length > MESSAGE_SPLIT_THRESHOLD) {
        const splitAt = this._findSplitPoint(this._cleanedContent, MESSAGE_SPLIT_THRESHOLD);
        const head = this._cleanedContent.slice(0, splitAt);
        this._cleanedContent = this._cleanedContent.slice(splitAt);
        this.content = this._cleanedContent;

        if (!head) break;
        if (this.message) {
          await this.message.edit(head);
        } else {
          this.message = await this.channel.send(head);
        }
        this.message = null;
      }

      const displayText = this._cleanedContent + (footer ? redactSecrets(footer).clean : "");
      if (!displayText.trim()) return;

      if (displayText.length <= 1990) {
        if (this.message) {
          await this.message.edit(displayText);
        } else {
          this.message = await this.channel.send(displayText);
        }
      } else {
        // Too large even for finish — send as attachment
        await this._sendAsAttachment(displayText);
        this.message = null;
        this.content = "";
        this._cleanedContent = "";
        this._statusFooter = "";
      }
    } catch (err) {
      log.error("Flush failed", { error: err.message, code: err.code });
      // If message was deleted, channel is gone, or permissions changed — start fresh
      if (err.code === 10003 || err.code === 10008 || err.code === 50005 || err.code === 50001 || err.code === 50013) {
        this.message = null;
        try {
          const footer = this._statusFooter ? `\n${this._statusFooter}` : "";
          const fallback = this._cleanedContent + (footer ? redactSecrets(footer).clean : "");
          if (fallback && fallback.length <= 1990) {
            this.message = await this.channel.send(fallback);
          } else if (fallback) {
            await this._sendAsAttachment(fallback);
            this.content = "";
            this._cleanedContent = "";
            this._statusFooter = "";
          }
        } catch (retryErr) {
          log.error("Flush retry also failed — giving up on this message", { error: retryErr.message, code: retryErr.code });
          // Don't retry further — prevent infinite retry loops
          this.message = null;
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
      description: "Output (zu groß für eine Nachricht)",
    });
    await this.channel.send({ files: [attachment] });
  }

  /**
   * Find a good split point near maxLen, preferring newline then word boundaries.
   */
  _findSplitPoint(text, maxLen) {
    const lastNewline = text.lastIndexOf("\n", maxLen);
    if (lastNewline > maxLen / 2) return lastNewline + 1;
    // Fall back to word boundary (space)
    const lastSpace = text.lastIndexOf(" ", maxLen);
    if (lastSpace > maxLen * 0.7) return lastSpace + 1;
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

    this.editTimer = setTimeout(() => {
      this.editTimer = null;
      this.lastEdit = Date.now();
      this.flush().catch((err) => {
        log.error("Scheduled flush failed", { error: err.message });
      });
    }, delay);
    this.editTimer.unref();
  }
}
