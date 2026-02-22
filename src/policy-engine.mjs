import { realpathSync } from "node:fs";
import { resolve, sep, dirname, basename } from "node:path";
import { createLogger } from "./logger.mjs";

const log = createLogger("policy");

// ── Path Security ───────────────────────────────────────────────────────────

/**
 * Resolves a path to its real absolute form (following symlinks).
 * For non-existent paths, resolves the nearest existing parent to catch symlink escapes.
 */
function safePath(p) {
  try {
    return realpathSync(resolve(p));
  } catch {
    // Path doesn't exist yet — resolve parent to follow symlinks in the directory chain
    const resolved = resolve(p);
    try {
      return realpathSync(dirname(resolved)) + sep + basename(resolved);
    } catch {
      return resolved;
    }
  }
}

/**
 * Check if targetPath is inside workspaceRoot (symlink-safe).
 */
function isInsideWorkspace(targetPath, workspaceRoot) {
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
  /\bgit\s+(?:(?:-[\w-]+(?:=\S+|\s+\S+)?)\s+)*push\b/i,
  /\bgit\s+(?:(?:-[\w-]+(?:=\S+|\s+\S+)?)\s+)*remote\s+.*push\b/i,
  /\bgh\s+pr\s+create\b/i,
  /\bgh\s+pr\s+merge\b/i,
  /\bgh\s+pr\s+push\b/i,
];

// Dangerous shell wrappers that can hide commands from pattern matching
const DANGEROUS_WRAPPERS = /\b(?:eval|source)\s/i;

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
    // Recursively extract from $(...) command substitutions (handles nesting)
    let remaining = part;
    let depth = 0;
    let start = -1;
    for (let i = 0; i < remaining.length - 1; i++) {
      if (remaining[i] === "$" && remaining[i + 1] === "(") {
        if (depth === 0) start = i + 2;
        depth++;
        i++; // skip '('
      } else if (remaining[i] === ")" && depth > 0) {
        depth--;
        if (depth === 0 && start >= 0) {
          const inner = remaining.slice(start, i);
          result.push(...inner.split(COMPOUND_SPLIT).filter(Boolean));
          start = -1;
        }
      }
    }
    // Also extract from backtick substitutions
    const backtick = part.matchAll(/`([^`]+)`/g);
    for (const b of backtick) result.push(...b[1].split(COMPOUND_SPLIT).filter(Boolean));
  }
  return result;
}

function isGitPushCommand(command) {
  const parts = extractSubCommands(command);
  // Detect dangerous wrappers (eval/source) only when the command also references git push
  if (DANGEROUS_WRAPPERS.test(command) && /\bgit\b/i.test(command) && /\bpush\b/i.test(command)) return true;
  // Detect env-variable prefix pattern: VAR=val git push
  if (/\b\w+=\S+\s+git\s+push\b/i.test(command)) return true;
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
function isGranted(targetPath, grants, requiredMode = "ro") {
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

    // Scan for ALL cd's into paths outside workspace
    for (const cdMatch of cmd.matchAll(/\b(?:cd|pushd)\s+(?:--\s+)?(?:"([^"]+)"|'([^']+)'|([^\s;&|]+))/g)) {
      const rawTarget = cdMatch[1] || cdMatch[2] || cdMatch[3];
      // Block cd - / pushd - — shell navigates to previous directory which may be outside workspace
      if (rawTarget === "-") {
        return {
          decision: "deny",
          reason: `Shell cd to previous directory (\`-\`) is not allowed — target cannot be statically verified`,
          gate: "outside",
        };
      }
      // Block tilde expansion — shell expands ~ to home dir, bypassing resolve()
      if (rawTarget === "~" || rawTarget.startsWith("~/")) {
        return {
          decision: "deny",
          reason: `Shell cd with tilde expansion is not allowed: ${rawTarget}`,
          gate: "outside",
        };
      }
      // Block cd with shell variables or command substitution — cannot statically resolve
      if (rawTarget.startsWith("$") || rawTarget.includes("${") || rawTarget.includes("$(") || rawTarget.includes("`")) {
        return {
          decision: "deny",
          reason: `Shell cd with variable/command expansion is not allowed: ${rawTarget}`,
          gate: "outside",
        };
      }
      const cdTarget = resolve(workspaceRoot, rawTarget);
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
