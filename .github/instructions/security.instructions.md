---
description: "Use when editing security-critical files: policy engine, secret scanner, grants, or push approval gate. Covers path validation, workspace boundary enforcement, compound command detection, token redaction, and grant TTL."
applyTo: ["src/policy-engine.mjs", "src/secret-scanner.mjs", "src/grants.mjs", "src/push-approval.mjs"]
---
# Security Conventions

## Path Validation
- Always resolve paths through `realpathSync()` (via `safePath()`) before comparing against workspace root
- Use `isInsideWorkspace()` for all boundary checks — never compare raw strings
- File operations outside the workspace are denied unless an active, unexpired grant covers the path
- Grants require explicit `"rw"` mode for write access; `"ro"` is the default

## Git Push Detection
- `isGitPushCommand()` must catch pushes in compound commands: `&&`, `||`, `;`, `|`, newlines
- Also detect `sh -c` / `bash -c` wrappers, `$()` substitutions, backtick substitutions, and `eval`/`source`
- Cover `git push`, `git remote ... push`, `gh pr create`, `gh pr merge`, `gh pr push`
- Env-variable prefix pattern (`VAR=val git push`) must also be caught

## Secret Scanner
- All text sent to Discord must pass through `redactSecrets()` — no exceptions
- Token patterns use anchored prefixes (e.g. `ghp_`, `AKIA`, `xox[bprsao]-`) — keep these precise, not overly broad
- ENV value detection scans `process.env` keys matching `TOKEN|SECRET|KEY|PASSWORD|CREDENTIAL`
- New secret patterns need a `label` and a `re` regex in the `TOKEN_PATTERNS` array

## Grant System
- Grants are always temporary — TTL is mandatory, never create permanent grants
- In-memory `Map` is the primary store; SQLite is the crash-recovery backup
- `startGrantCleanup()` runs a periodic sweep; its timer must call `.unref()`
- Grant expiry is checked at evaluation time in `isGranted()` — expired grants are skipped, not removed inline

## Push Approval Gate
- `git push` is never auto-approved — it always triggers Discord button confirmation
- Embed shows diff summary + commit log so the reviewer has context
- 10-minute timeout via `awaitMessageComponent` — if no response, push is rejected
- Button clicks are RBAC-protected — only users with admin roles can approve
