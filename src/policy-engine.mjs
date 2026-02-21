import { realpathSync } from "node:fs";
import { resolve, sep } from "node:path";
import { createLogger } from "./logger.mjs";

const log = createLogger("policy");

// ── Path Security ───────────────────────────────────────────────────────────

/**
 * Resolves a path to its real absolute form (following symlinks).
 * Returns null if the path doesn't exist.
 */
function safePath(p) {
  try {
    return realpathSync(resolve(p));
  } catch {
    // Path doesn't exist yet — resolve without symlink traversal
    return resolve(p);
  }
}

/**
 * Check if targetPath is inside workspaceRoot (symlink-safe).
 */
export function isInsideWorkspace(targetPath, workspaceRoot) {
  const resolvedTarget = safePath(targetPath);
  const resolvedRoot = safePath(workspaceRoot);
  // Must start with root + separator, or be exactly root
  return (
    resolvedTarget === resolvedRoot ||
    resolvedTarget.startsWith(resolvedRoot + sep)
  );
}

// ── Git Push Detection ──────────────────────────────────────────────────────

const GIT_PUSH_PATTERNS = [
  /\bgit\s+push\b/i,
  /\bgit\s+remote\s+.*push\b/i,
  /\bgh\s+pr\s+create\b/i,
  /\bgh\s+pr\s+merge\b/i,
  /\bgh\s+pr\s+push\b/i,
];

// Split compound commands (&&, ||, ;, |, newline) and also unwrap
// sh -c / bash -c wrappers to detect push in any sub-part.
const COMPOUND_SPLIT = /\s*(?:&&|\|\||[;|\n])\s*/;
const SUBSHELL_WRAPPER = /^\s*(?:sh|bash|zsh|dash)\s+-c\s+['"](.+)['"]\s*$/i;

function extractSubCommands(command) {
  const parts = command.split(COMPOUND_SPLIT).filter(Boolean);
  const result = [];
  for (const part of parts) {
    result.push(part);
    const m = SUBSHELL_WRAPPER.exec(part);
    if (m) result.push(...m[1].split(COMPOUND_SPLIT).filter(Boolean));
  }
  return result;
}

export function isGitPushCommand(command) {
  const parts = extractSubCommands(command);
  return parts.some((part) =>
    GIT_PUSH_PATTERNS.some((re) => re.test(part))
  );
}

// ── Grant Checking ──────────────────────────────────────────────────────────

/**
 * Check if a path is covered by an active grant.
 * @param {string} targetPath - Absolute path to check
 * @param {Map<string, {mode: string, expiry: number}>} grants - Active grants
 * @param {"ro"|"rw"} requiredMode - Minimum access mode needed
 * @returns {boolean}
 */
export function isGranted(targetPath, grants, requiredMode = "ro") {
  const resolvedTarget = safePath(targetPath);
  for (const [grantPath, grant] of grants) {
    if (Date.now() > grant.expiry) continue; // expired
    const resolvedGrant = safePath(grantPath);
    const isUnder =
      resolvedTarget === resolvedGrant ||
      resolvedTarget.startsWith(resolvedGrant + sep);
    if (!isUnder) continue;
    if (requiredMode === "ro") return true;
    if (requiredMode === "rw" && grant.mode === "rw") return true;
  }
  return false;
}

// ── Tool Name Classification ────────────────────────────────────────────────

const SHELL_TOOLS = new Set(["shell", "bash", "run_in_terminal", "terminal"]);
const READ_TOOLS = new Set([
  "read_file",
  "list_directory",
  "search_files",
  "grep_search",
  "file_search",
  "semantic_search",
]);
const WRITE_TOOLS = new Set([
  "write_file",
  "create_file",
  "delete_file",
  "replace_string_in_file",
  "edit_file",
  "rename_file",
]);

/**
 * Extract file path from tool arguments (handles different arg shapes).
 */
function extractPath(toolArgs) {
  return (
    toolArgs?.path ||
    toolArgs?.filePath ||
    toolArgs?.file ||
    toolArgs?.directory ||
    toolArgs?.target ||
    null
  );
}

/**
 * Extract command string from shell tool arguments.
 */
function extractCommand(toolArgs) {
  return toolArgs?.command || toolArgs?.cmd || toolArgs?.input || "";
}

/**
 * Extract working directory from tool arguments.
 */
function extractCwd(toolArgs) {
  return toolArgs?.cwd || toolArgs?.workingDirectory || null;
}

// ── Main Policy Decision ────────────────────────────────────────────────────

/**
 * Evaluate a tool use against the policy rules.
 *
 * Returns: { decision: "allow"|"deny", reason?: string, gate?: "push"|"outside" }
 */
export function evaluateToolUse(toolName, toolArgs, workspaceRoot, grants) {
  // ── Shell commands ──────────────────────────────────────────────────────
  if (SHELL_TOOLS.has(toolName)) {
    const cmd = extractCommand(toolArgs);

    // Hard Gate A: git push (checks compound commands & subshells)
    if (isGitPushCommand(cmd)) {
      log.warn("Push blocked — requires approval", { command: cmd });
      return {
        decision: "deny",
        reason: `git push requires Discord approval. Command: ${cmd}`,
        gate: "push",
      };
    }

    // Check CWD if explicitly provided
    const cwd = extractCwd(toolArgs);
    if (cwd && !isInsideWorkspace(cwd, workspaceRoot) && !isGranted(cwd, grants, "ro")) {
      return {
        decision: "deny",
        reason: `Shell working directory is outside workspace: ${cwd}`,
        gate: "outside",
      };
    }

    // Scan for cd into paths outside workspace
    const cdMatch = cmd.match(/\bcd\s+["']?([^\s"';&|]+)/);
    if (cdMatch) {
      const cdTarget = resolve(workspaceRoot, cdMatch[1]);
      if (!isInsideWorkspace(cdTarget, workspaceRoot) && !isGranted(cdTarget, grants, "ro")) {
        return {
          decision: "deny",
          reason: `Shell cd target is outside workspace: ${cdTarget}`,
          gate: "outside",
        };
      }
    }

    return { decision: "allow" };
  }

  // ── File read operations ────────────────────────────────────────────────
  if (READ_TOOLS.has(toolName)) {
    const filePath = extractPath(toolArgs);
    if (!filePath) return { decision: "allow" }; // no path → allow (e.g. search by content)

    if (isInsideWorkspace(filePath, workspaceRoot)) {
      return { decision: "allow" };
    }
    if (isGranted(filePath, grants, "ro")) {
      return { decision: "allow" };
    }
    log.warn("Read access denied", { path: filePath });
    return {
      decision: "deny",
      reason: `Read access outside workspace denied: ${filePath}`,
      gate: "outside",
    };
  }

  // ── File write operations ───────────────────────────────────────────────
  if (WRITE_TOOLS.has(toolName)) {
    const filePath = extractPath(toolArgs);
    if (!filePath) return { decision: "allow" };

    if (isInsideWorkspace(filePath, workspaceRoot)) {
      return { decision: "allow" };
    }
    if (isGranted(filePath, grants, "rw")) {
      return { decision: "allow" };
    }
    log.warn("Write access denied", { path: filePath });
    return {
      decision: "deny",
      reason: `Write access outside workspace denied: ${filePath}`,
      gate: "outside",
    };
  }

  // ── Everything else: auto-approve ───────────────────────────────────────
  return { decision: "allow" };
}
