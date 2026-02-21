import { readFileSync, writeFileSync, chmodSync } from "node:fs";
import { createLogger } from "./logger.mjs";
import { CURRENT_VERSION, AGENT_SCRIPT_PATH, GITHUB_TOKEN } from "./config.mjs";

const log = createLogger("updater");

const REPO_OWNER = process.env.UPDATE_REPO_OWNER || "epantke";
const REPO_NAME = process.env.UPDATE_REPO_NAME || "remote-coding-agent";

let _cachedResult = null;
let _cachedAt = 0;
const CACHE_TTL_MS = 5 * 60_000;

// ── Version comparison ──────────────────────────────────────────────────────

function parseVer(v) {
  return (v || "").replace(/^v/, "").split(".").map(Number);
}

function isNewer(latest, current) {
  const a = parseVer(latest);
  const b = parseVer(current);
  for (let i = 0; i < 3; i++) {
    if ((a[i] || 0) > (b[i] || 0)) return true;
    if ((a[i] || 0) < (b[i] || 0)) return false;
  }
  return false;
}

// ── Check for update ────────────────────────────────────────────────────────

export function getCurrentVersion() {
  return CURRENT_VERSION;
}

export async function checkForUpdate({ force = false } = {}) {
  if (!force && _cachedResult && Date.now() - _cachedAt < CACHE_TTL_MS) {
    return _cachedResult;
  }

  const url = `https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest`;
  const headers = {
    "User-Agent": `discord-copilot-agent/${CURRENT_VERSION}`,
    Accept: "application/vnd.github+json",
  };
  if (GITHUB_TOKEN) headers.Authorization = `token ${GITHUB_TOKEN}`;

  try {
    const resp = await fetch(url, { headers, signal: AbortSignal.timeout(15_000) });

    if (resp.status === 404) {
      return { available: false, currentVersion: CURRENT_VERSION, error: "No releases found" };
    }
    if (!resp.ok) {
      return { available: false, currentVersion: CURRENT_VERSION, error: `GitHub API returned ${resp.status}` };
    }

    const release = await resp.json();
    const latestVersion = (release.tag_name || "").replace(/^v/, "");
    const available = isNewer(latestVersion, CURRENT_VERSION);

    const shAsset = release.assets?.find((a) => a.name === "agent.sh");
    const ps1Asset = release.assets?.find((a) => a.name === "agent.ps1");

    const result = {
      available,
      currentVersion: CURRENT_VERSION,
      latestVersion,
      tagName: release.tag_name,
      releaseUrl: release.html_url,
      releaseNotes: (release.body || "").slice(0, 1500),
      publishedAt: release.published_at,
      downloadUrls: {
        sh: shAsset?.browser_download_url || null,
        ps1: ps1Asset?.browser_download_url || null,
      },
    };

    _cachedResult = result;
    _cachedAt = Date.now();

    if (available) {
      log.info("New version available", { current: CURRENT_VERSION, latest: latestVersion });
    }

    return result;
  } catch (err) {
    log.error("Update check failed", { error: err.message });
    return { available: false, currentVersion: CURRENT_VERSION, error: err.message };
  }
}

// ── Download & apply ────────────────────────────────────────────────────────

export async function downloadAndApplyUpdate() {
  const check = await checkForUpdate({ force: true });
  if (!check.available) {
    return { success: false, reason: "Already on the latest version" };
  }

  const isWindows = process.platform === "win32";
  const assetUrl = isWindows ? check.downloadUrls.ps1 : check.downloadUrls.sh;
  const assetName = isWindows ? "agent.ps1" : "agent.sh";

  if (!assetUrl) {
    return { success: false, reason: `No ${assetName} found in release ${check.tagName}` };
  }

  if (!AGENT_SCRIPT_PATH) {
    return {
      success: false,
      reason: "Cannot determine script location (AGENT_SCRIPT_PATH not set). Download the update manually from " + check.releaseUrl,
    };
  }

  const headers = { "User-Agent": `discord-copilot-agent/${CURRENT_VERSION}` };
  if (GITHUB_TOKEN) headers.Authorization = `token ${GITHUB_TOKEN}`;

  try {
    log.info("Downloading update", { version: check.latestVersion, asset: assetName });

    const resp = await fetch(assetUrl, {
      headers,
      signal: AbortSignal.timeout(120_000),
      redirect: "follow",
    });

    if (!resp.ok) {
      return { success: false, reason: `Download failed (HTTP ${resp.status})` };
    }

    const content = await resp.text();

    if (isWindows && !content.includes("#Requires")) {
      return { success: false, reason: "Downloaded file is not a valid PowerShell script" };
    }
    if (!isWindows && !content.startsWith("#!/")) {
      return { success: false, reason: "Downloaded file is not a valid shell script" };
    }

    const backupPath = AGENT_SCRIPT_PATH + ".bak";
    try {
      writeFileSync(backupPath, readFileSync(AGENT_SCRIPT_PATH, "utf-8"), "utf-8");
      log.info("Backup created", { path: backupPath });
    } catch {
      log.warn("Could not create backup — continuing anyway");
    }

    writeFileSync(AGENT_SCRIPT_PATH, content, "utf-8");

    if (!isWindows) {
      try { chmodSync(AGENT_SCRIPT_PATH, 0o755); } catch { /* ignore */ }
    }

    log.info("Update applied successfully", { version: check.latestVersion });

    return { success: true, version: check.latestVersion, scriptPath: AGENT_SCRIPT_PATH, backupPath };
  } catch (err) {
    log.error("Update download failed", { error: err.message });
    return { success: false, reason: err.message };
  }
}

// ── Restart ─────────────────────────────────────────────────────────────────

export function restartBot() {
  log.info("Restarting bot for update");
  // Trigger the graceful shutdown handler instead of raw exit
  process.kill(process.pid, "SIGTERM");
}
