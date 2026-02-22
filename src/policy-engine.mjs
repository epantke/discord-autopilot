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
  /\bgit\s+(?:(?:-[\w-]+(?:(?:\s*=\s*|\s+)\S+)?)\s+)*push\b/i,
  /\bgit\s+(?:(?:-[\w-]+(?:(?:\s*=\s*|\s+)\S+)?)\s+)*remote\s+.*push\b/i,
  /\bgh\s+pr\s+create\b/i,
  /\bgh\s+pr\s+merge\b/i,
  /\bgh\s+pr\s+push\b/i,
];

// Dangerous shell wrappers that can hide commands from pattern matching
const DANGEROUS_WRAPPERS = /\b(?:eval|source)\s/i;

// Split compound commands (&&, ||, ;, |, newline) and also unwrap
// sh -c / bash -c wrappers to detect push in any sub-part.
const SUBSHELL_WRAPPER = /^\s*(?:sh|bash|zsh|dash)\s+-c\s+['"](.+)['"]\s*$/i;

/**
 * Split a command on compound operators (&&, ||, ;, |, newline)
 * while respecting single- and double-quoted strings.
 */
function splitCompound(command) {
  const results = [];
  let current = "";
  let inSingle = false;
  let inDouble = false;

  for (let i = 0; i < command.length; i++) {
    const ch = command[i];

    if (ch === "\\" && !inSingle && i + 1 < command.length) {
      current += ch + command[i + 1];
      i++;
      continue;
    }

    if (ch === "'" && !inDouble) { inSingle = !inSingle; current += ch; continue; }
    if (ch === '"' && !inSingle) { inDouble = !inDouble; current += ch; continue; }

    if (inSingle || inDouble) { current += ch; continue; }

    if (ch === "&" && command[i + 1] === "&") {
      if (current.trim()) results.push(current.trim());
      current = "";
      i++;
      continue;
    }
    if (ch === "|" && command[i + 1] === "|") {
      if (current.trim()) results.push(current.trim());
      current = "";
      i++;
      continue;
    }
    if (ch === ";" || ch === "|" || ch === "\n") {
      if (current.trim()) results.push(current.trim());
      current = "";
      continue;
    }

    current += ch;
  }

  if (current.trim()) results.push(current.trim());
  return results;
}

function extractSubCommands(command) {
  const parts = splitCompound(command);
  const result = [];
  for (const part of parts) {
    result.push(part);
    const m = SUBSHELL_WRAPPER.exec(part);
    if (m) result.push(...splitCompound(m[1]));
    // Recursively extract from $(...) command substitutions (handles nesting)
    let remaining = part;
    let depth = 0;
    let start = -1;
    for (let i = 0; i < remaining.length; i++) {
      if (i + 1 < remaining.length && remaining[i] === "$" && remaining[i + 1] === "(") {
        if (depth === 0) start = i + 2;
        depth++;
        i++; // skip '('
      } else if (remaining[i] === ")" && depth > 0) {
        depth--;
        if (depth === 0 && start >= 0) {
          const inner = remaining.slice(start, i);
          result.push(...splitCompound(inner));
          start = -1;
        }
      }
    }
    // Also extract from backtick substitutions
    const backtick = part.matchAll(/`([^`]+)`/g);
    for (const b of backtick) result.push(...splitCompound(b[1]));
  }
  return result;
}

function isGitPushCommand(command) {
  const parts = extractSubCommands(command);
  // Detect dangerous wrappers (eval/source) only when the command also references git push
  if (DANGEROUS_WRAPPERS.test(command) && /\bgit\b/i.test(command) && /\bpush\b/i.test(command)) return true;
  // Detect env-variable prefix pattern: VAR=val git push
  if (/\b\w+=\S+\s+git\s+push\b/i.test(command)) return true;
  // Detect git config alias that references push-related commands (bypass via alias)
  if (/\bgit\s+config\b[^;&|\n]*\balias\.\w+\s.*?\b(?:push|pr\s+create|pr\s+merge)\b/i.test(command)) return true;
  // Detect git with dynamic subcommand via variable/command expansion (can't verify statically)
  if (/\bgit\b[^;&|\n]*\$[\w{(]/i.test(command)) return true;
  if (/\bgit\b[^;&|\n]*`/i.test(command)) return true;
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

// ── Shell File Access Scanning ──────────────────────────────────────────────

const SAFE_PATHS_RE = /^\/dev\/(null|stdin|stdout|stderr|urandom|random|zero|tty|fd\/\d+)$/;

/**
 * Scan a shell command for file operations targeting paths outside the workspace.
 * Returns { path, reason } if a violation is found, or null if clean.
 */
function checkShellFileAccess(command, workspaceRoot, grants) {
  // 1. File-reading commands with absolute path arguments
  const readRe = /\b(?:cat|tac|less|more|head|tail|sort|uniq|wc|nl|od|xxd|strings|base64|file|stat|type)\s+(?:(?:-[\w=]+)\s+)*(?:"(\/[^"]+)"|\'(\/[^\']+)\'|(\/[^\s;&|><"'`]+))/gi;
  for (const m of command.matchAll(readRe)) {
    const p = m[1] || m[2] || m[3];
    if (!p || SAFE_PATHS_RE.test(p)) continue;
    if (!isInsideWorkspace(p, workspaceRoot) && !isGranted(p, grants, "ro")) {
      return { path: p, reason: `Shell file read outside workspace denied: ${p}` };
    }
  }

  // 2. Output redirection to absolute paths outside workspace
  const redirectRe = />{1,2}\s*(?:"(\/[^"]+)"|\'(\/[^\']+)\'|(\/[^\s;&|><"'`]+))/g;
  for (const m of command.matchAll(redirectRe)) {
    const p = m[1] || m[2] || m[3];
    if (!p || SAFE_PATHS_RE.test(p)) continue;
    if (!isInsideWorkspace(p, workspaceRoot) && !isGranted(p, grants, "rw")) {
      return { path: p, reason: `Shell file write (redirect) outside workspace denied: ${p}` };
    }
  }

  // 3. curl/wget data exfiltration with file reference (@file)
  const exfilRe = /\b(?:curl|wget)\b[^;&|]*?(?:-[dF]\s*@|--data[-\w]*[\s=]+@|--upload-file\s+)(?:"(\/[^"]+)"|\'(\/[^\']+)\'|(\/[^\s;&|><"'`]+))/gi;
  for (const m of command.matchAll(exfilRe)) {
    const p = m[1] || m[2] || m[3];
    if (!p || SAFE_PATHS_RE.test(p)) continue;
    if (!isInsideWorkspace(p, workspaceRoot) && !isGranted(p, grants, "ro")) {
      return { path: p, reason: `Data exfiltration via file upload denied: ${p}` };
    }
  }

  return null;
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
    for (const cdMatch of cmd.matchAll(/\b(?:cd|pushd)\s+(?:-[A-Za-z]+\s+)*(?:--\s+)?(?:"([^"]+)"|'([^']+)'|([^\s;&|]+))/g)) {
      const rawTarget = cdMatch[1] || cdMatch[2] || cdMatch[3];
      // Block cd - / pushd - — shell navigates to previous directory which may be outside workspace
      if (rawTarget === "-") {
        return {
          decision: "deny",
          reason: `Shell cd to previous directory (\`-\`) is not allowed — target cannot be statically verified`,
          gate: "outside",
        };
      }
      // Block tilde expansion — shell expands ~ / ~/ / ~user to home dirs, bypassing resolve()
      if (rawTarget.startsWith("~")) {
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

    // Check for file operations on paths outside workspace
    const fileAccess = checkShellFileAccess(cmd, workspaceRoot, grants);
    if (fileAccess) {
      log.warn("Shell file access denied", { command: cmd, path: fileAccess.path });
      return {
        decision: "deny",
        reason: fileAccess.reason,
        gate: "outside",
      };
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
