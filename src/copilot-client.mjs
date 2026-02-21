import { CopilotClient } from "@github/copilot-sdk";
import { evaluateToolUse } from "./policy-engine.mjs";
import { getActiveGrants } from "./grants.mjs";
import { createLogger } from "./logger.mjs";

const log = createLogger("copilot");

const approveAll = () => ({ kind: "approved" });

let client = null;

/**
 * Get or create the singleton CopilotClient.
 */
export function getCopilotClient() {
  if (!client) {
    const opts = {
      useStdio: true,
      autoRestart: true,
    };
    // The Copilot CLI subprocess inherits process.env. PATs (ghp_, github_pat_)
    // are rejected by the Copilot API — if GITHUB_TOKEN is set to a PAT, the
    // CLI will try to use it and fail silently, causing sendAndWait to hang.
    // We must remove it from env so the CLI falls back to `gh auth` credentials.
    const token = process.env.GITHUB_TOKEN;
    if (token && token.startsWith("gho_")) {
      opts.githubToken = token;
    } else if (token && (token.startsWith("ghp_") || token.startsWith("github_pat_"))) {
      delete process.env.GITHUB_TOKEN;
      log.info("Cleared PAT from GITHUB_TOKEN env — Copilot CLI will use gh auth credentials");
    } else if (token) {
      // Unknown token format — pass it through and let the SDK decide
      opts.githubToken = token;
    }
    // DISCORD_TOKEN is never needed by the Copilot CLI subprocess — remove it
    // to prevent leaking the bot token if the CLI or a tool dumps its env.
    if (process.env.DISCORD_TOKEN) {
      delete process.env.DISCORD_TOKEN;
      log.info("Cleared DISCORD_TOKEN from env — not needed by Copilot CLI");
    }
    client = new CopilotClient(opts);
  }
  return client;
}

/**
 * Create a new Copilot session for a given channel.
 *
 * @param {object} opts
 * @param {string} opts.channelId - Discord channel ID (for grant lookups)
 * @param {string} opts.workspacePath - Absolute path to the git worktree
 * @param {function} opts.onPushRequest - Called when agent tries to git push
 * @param {function} opts.onOutsideRequest - Called when agent accesses outside workspace
 * @param {function} opts.onDelta - Called with streaming text chunks
 * @param {function} opts.onToolStart - Called when a tool starts executing
 * @param {function} opts.onToolComplete - Called when a tool finishes
 * @param {function} opts.onIdle - Called when agent finishes
 * @param {function} opts.onUserQuestion - Called when agent asks a question
 * @param {string|null} [opts.model] - Model ID to use (null = SDK default)
 */
export async function createAgentSession(opts) {
  const {
    channelId,
    workspacePath,
    onPushRequest,
    onOutsideRequest,
    onDelta,
    onToolStart,
    onToolComplete,
    onIdle,
    onUserQuestion,
    model,
  } = opts;

  const copilot = getCopilotClient();

  const sessionConfig = {
    workingDirectory: workspacePath,
    streaming: true,
    ...(model ? { model } : {}),
  };

  const session = await copilot.createSession({
    ...sessionConfig,

    // Approve all native permission requests (our policy is in onPreToolUse)
    onPermissionRequest: approveAll,

    // Enable ask_user tool → forward questions to Discord
    onUserInputRequest: async (request) => {
      if (onUserQuestion) {
        const answer = await onUserQuestion(request.question, request.choices);
        return { answer, wasFreeform: !request.choices };
      }
      return { answer: "No user available to answer. Proceed with your best judgment.", wasFreeform: true };
    },

    hooks: {
      onPreToolUse: async (input) => {
        const grants = getActiveGrants(channelId);
        const result = evaluateToolUse(
          input.toolName,
          input.toolArgs,
          workspacePath,
          grants
        );

        if (result.decision === "allow") {
          return { permissionDecision: "allow" };
        }

        // Hard Gate A: Push
        if (result.gate === "push") {
          if (onPushRequest) {
            const command =
              input.toolArgs?.command || input.toolArgs?.cmd || "";
            const { approved } = await onPushRequest(command);
            if (approved) {
              return { permissionDecision: "allow" };
            }
          }
          return {
            permissionDecision: "deny",
            additionalContext:
              "Push was denied by the user. Do NOT retry pushing. " +
              "Inform the user that the push was rejected and ask what to do instead.",
          };
        }

        // Hard Gate B: Outside workspace
        if (result.gate === "outside") {
          if (onOutsideRequest) {
            onOutsideRequest(result.reason);
          }
          return {
            permissionDecision: "deny",
            additionalContext:
              `Access denied: ${result.reason}. ` +
              "The user must grant access via /grant command first. " +
              "Do NOT retry this operation. Inform the user what path you need access to.",
          };
        }

        // Generic deny
        return {
          permissionDecision: "deny",
          additionalContext: result.reason || "Action denied by policy.",
        };
      },

      onErrorOccurred: async (input) => {
        log.error("Agent error", { error: input.error, context: input.errorContext });
        return { errorHandling: "skip" };
      },
    },

    systemMessage: {
      content: [
        `You are an autonomous coding agent working in: ${workspacePath}`,
        "You may freely edit files, run tests, lint, build, and create git branches/commits within the workspace.",
        "IMPORTANT RULES:",
        "1. You CANNOT git push or publish PRs without explicit user approval — the system will block it.",
        "2. You CANNOT access files outside the workspace directory without explicit grants.",
        "3. If a push is denied, inform the user and stop retrying.",
        "4. If file access outside the workspace is denied, tell the user which path you need and ask them to use /grant.",
        "5. Always run tests before suggesting a push.",
        "6. Provide clear summaries of what you changed and why.",
      ].join("\n"),
    },
  });

  // Wire up streaming events
  let _lastToolName = "tool";

  if (onDelta) {
    session.on("assistant.message_delta", (event) => {
      onDelta(event.data?.deltaContent || "");
    });
  }

  if (onToolStart) {
    session.on("tool.execution_start", (event) => {
      _lastToolName = event.data?.toolName || "unknown";
      onToolStart(_lastToolName);
    });
  }

  if (onToolComplete) {
    session.on("tool.execution_complete", (event) => {
      const toolName = event.data?.toolName || _lastToolName;
      onToolComplete(
        toolName,
        event.data?.success ?? true,
        event.data?.error
      );
    });
  }

  if (onIdle) {
    session.on("session.idle", () => {
      onIdle();
    });
  }

  return session;
}

/**
 * List available models from the Copilot API.
 * @returns {Promise<Array<{id: string, name: string}>>}
 */
export async function listAvailableModels() {
  const copilot = getCopilotClient();
  return copilot.listModels();
}

/**
 * Gracefully stop the copilot client.
 */
export async function stopCopilotClient() {
  if (client) {
    const c = client;
    client = null;
    try { await c.stop(); } catch {}
  }
}
