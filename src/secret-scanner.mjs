import { createLogger } from "./logger.mjs";

const log = createLogger("secrets");

/**
 * Known secret token patterns — each entry has a label and regex.
 */
const TOKEN_PATTERNS = [
  { label: "GitHub PAT (classic)", re: /ghp_[A-Za-z0-9]{36,}/ },
  { label: "GitHub PAT (fine-grained)", re: /github_pat_[A-Za-z0-9_]{22,}/ },
  { label: "GitHub OAuth", re: /gho_[A-Za-z0-9]{36,}/ },
  { label: "GitHub App token", re: /(?:ghu|ghs|ghr)_[A-Za-z0-9]{36,}/ },
  { label: "OpenAI API key", re: /sk-[A-Za-z0-9]{20,}/ },
  { label: "AWS Access Key", re: /AKIA[0-9A-Z]{16}/ },
  { label: "Slack token", re: /xox[bprsao]-[0-9A-Za-z-]{10,}/ },
  { label: "Discord bot token", re: /[MN][A-Za-z\d]{23,}\.[A-Za-z\d_-]{6}\.[A-Za-z\d_-]{27,}/ },
  { label: "Generic secret", re: /(?:secret|token|password|api_key|apikey)\s*[:=]\s*["'][^"']{8,}["']/i },
];

/**
 * Collect runtime ENV values longer than 8 chars to detect leaked env vars.
 */
const envValues = new Set();
for (const [key, val] of Object.entries(process.env)) {
  if (val && val.length >= 8 && /TOKEN|SECRET|KEY|PASSWORD|CREDENTIAL/i.test(key)) {
    envValues.add(val);
  }
}

const REDACTED = "[REDACTED]";

/**
 * Scan text for secrets and return a redacted version.
 * Returns { clean, found } where found is an array of labels.
 */
export function redactSecrets(text) {
  if (!text) return { clean: text, found: [] };
  let clean = text;
  const found = [];

  for (const { label, re } of TOKEN_PATTERNS) {
    const global = new RegExp(re.source, re.flags.includes("g") ? re.flags : re.flags + "g");
    if (global.test(clean)) {
      found.push(label);
      clean = clean.replace(global, REDACTED);
    }
  }

  for (const val of envValues) {
    if (clean.includes(val)) {
      found.push("ENV value");
      // Use split/join for literal string replacement
      clean = clean.split(val).join(REDACTED);
    }
  }

  if (found.length > 0) {
    log.warn("Secrets redacted", { labels: found });
  }

  return { clean, found };
}
