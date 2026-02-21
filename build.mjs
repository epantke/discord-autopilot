#!/usr/bin/env node
/**
 * build.mjs — Generate standalone single-file deployment scripts.
 *
 * Reads agent.sh and agent.ps1 as templates, embeds all src/*.mjs files
 * and package.json inline, and writes the result to dist/.
 *
 * Usage: node build.mjs
 */

import { readFileSync, writeFileSync, readdirSync, mkdirSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const DIST = join(__dirname, "dist");
mkdirSync(DIST, { recursive: true });

// ── Collect source files ────────────────────────────────────────────────────

function readNormalized(filePath) {
  return readFileSync(filePath, "utf-8").replace(/\r\n/g, "\n");
}

const srcDir = join(__dirname, "src");
const pkgJsonContent = readNormalized(join(srcDir, "package.json"));
const PKG_VERSION = JSON.parse(pkgJsonContent).version || "0.0.0";
console.log(`Version: ${PKG_VERSION}`);
const srcFiles = readdirSync(srcDir).filter((f) => f.endsWith(".mjs")).sort();

const sources = [
  { name: "package.json", subdir: false, content: pkgJsonContent },
];

// Include package-lock.json if it exists
const lockPath = join(srcDir, "package-lock.json");
if (existsSync(lockPath)) {
  sources.push({ name: "package-lock.json", subdir: false, content: readNormalized(lockPath) });
}

sources.push(
  ...srcFiles.map((f) => ({
    name: f,
    subdir: true,
    content: readNormalized(join(srcDir, f)),
  })),
);

const total = sources.length;
console.log(`Collected ${total} files (package.json + ${srcFiles.length} source files)`);

// ── Helpers ─────────────────────────────────────────────────────────────────

function findLine(lines, predicate, label) {
  const idx = lines.findIndex(predicate);
  if (idx === -1) throw new Error(`Marker not found: ${label}`);
  return idx;
}

function findSeparatorBefore(lines, idx) {
  for (let i = idx - 1; i >= 0; i--) {
    if (/^#\s*─{20,}/.test(lines[i])) return i;
  }
  throw new Error(`Separator not found before line ${idx}`);
}

// ── Build agent.sh ──────────────────────────────────────────────────────────

function buildBash() {
  const template = readNormalized(join(__dirname, "agent.sh"));
  const lines = template.split("\n");

  const step5Idx = findLine(lines, (l) => /5\)\s*Copy application files/.test(l), "sh: step 5");
  const step6Idx = findLine(lines, (l) => /6\)\s*Install dependencies/.test(l), "sh: step 6");

  const step5Start = findSeparatorBefore(lines, step5Idx);
  const step6Start = findSeparatorBefore(lines, step6Idx);

  const sep = "# " + "─".repeat(78);
  const section = [
    sep,
    "# 5) Write embedded application files",
    sep,
    'info "Writing embedded application files…"',
    "",
    'mkdir -p "$APP/src"',
    "",
  ];

  for (const src of sources) {
    const dest = src.subdir ? `"$APP/src/${src.name}"` : `"$APP/${src.name}"`;
    const tag = `__EOF_${src.name.replace(/[.\-]/g, "_").toUpperCase()}__`;

    // Safety: ensure no line in the content matches the heredoc tag
    if (src.content.split("\n").some((l) => l === tag)) {
      throw new Error(`${src.name} contains a line matching heredoc tag "${tag}"`);
    }

    section.push(`cat <<'${tag}' > ${dest}`);
    // Heredoc always appends a trailing newline, so strip it from content to avoid duplication
    const contentLines = src.content.split("\n");
    if (contentLines.at(-1) === "") contentLines.pop();
    for (const line of contentLines) section.push(line);
    section.push(tag);
    section.push("");
  }

  section.push(`ok "${total} embedded files written"`);
  section.push("");

  return [...lines.slice(0, step5Start), ...section, ...lines.slice(step6Start)].join("\n")
    .replace('SCRIPT_VERSION="0.0.0-dev"', `SCRIPT_VERSION="${PKG_VERSION}"`);
}

// ── Build agent.ps1 ─────────────────────────────────────────────────────────

function buildPs1() {
  const template = readNormalized(join(__dirname, "agent.ps1"));
  const lines = template.split("\n");

  const step6Idx = findLine(
    lines,
    (l) => /Write-Step\s+6\s+8\s+'Source files'/.test(l),
    "ps1: step 6 (Write-Step)"
  );
  const step7Idx = findLine(lines, (l) => /7\)\s*Install dependencies/.test(l), "ps1: step 7");
  const step7Start = findSeparatorBefore(lines, step7Idx);

  const section = [
    "Write-Step 6 8 'Source files'",
    "",
    "$AppSrc = Join-Path $App 'src'",
    "if (-not (Test-Path $AppSrc)) { New-Item -ItemType Directory -Path $AppSrc -Force | Out-Null }",
    "$__utf8 = New-Object System.Text.UTF8Encoding $false",
    "",
  ];

  let counter = 0;
  for (const src of sources) {
    counter++;
    const dest = src.subdir
      ? `(Join-Path $AppSrc '${src.name}')`
      : `(Join-Path $App '${src.name}')`;

    // Check for PowerShell here-string terminator conflict ( '@ at start of line )
    const hasConflict = src.content.split("\n").some((l) => /^'@/.test(l));

    if (hasConflict) {
      // Base64 fallback
      const b64 = Buffer.from(src.content, "utf-8").toString("base64");
      section.push(
        `$__c = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${b64}'))`
      );
      console.warn(`  ⚠ ${src.name}: using Base64 fallback (contains "'@" pattern)`);
    } else {
      section.push("$__c = @'");
      // Push content lines — trailing newlines are preserved naturally
      const contentLines = src.content.split("\n");
      for (const line of contentLines) section.push(line);
      section.push("'@");
    }

    section.push(`[System.IO.File]::WriteAllText(${dest}, $__c, $__utf8)`);
    section.push(`Write-FileProgress '${src.name}' ${counter} ${total}`);
    section.push("");
  }

  section.push(`Write-Ok "${total} embedded files written"`);
  section.push("");

  return [...lines.slice(0, step6Idx), ...section, ...lines.slice(step7Start)].join("\n")
    .replace("$ScriptVersion = '0.0.0-dev'", () => `$ScriptVersion = '${PKG_VERSION}'`);
}

// ── Main ────────────────────────────────────────────────────────────────────

let exitCode = 0;

try {
  const sh = buildBash();
  writeFileSync(join(DIST, "agent.sh"), sh, "utf-8");
  console.log(`✅ dist/agent.sh (${(sh.length / 1024).toFixed(1)} KB)`);
} catch (err) {
  console.error(`❌ agent.sh: ${err.message}`);
  exitCode = 1;
}

try {
  const ps1 = buildPs1();
  writeFileSync(join(DIST, "agent.ps1"), ps1, "utf-8");
  console.log(`✅ dist/agent.ps1 (${(ps1.length / 1024).toFixed(1)} KB)`);
} catch (err) {
  console.error(`❌ agent.ps1: ${err.message}`);
  exitCode = 1;
}

if (exitCode === 0) {
  console.log("\n📦 Build complete.");
}

process.exit(exitCode);
