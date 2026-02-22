#!/usr/bin/env bash
set -euo pipefail

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  Discord Autopilot — Autonomous AI Coding Agent                            ║
# ║  Single-script deployment. Run: ./agent.sh                                 ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[FATAL]${NC} $*" >&2; exit 1; }
# ── Version & update config ──────────────────────────────────────────────────────
SCRIPT_VERSION="0.0.0-dev"
UPDATE_REPO="epantke/remote-coding-agent"
UPDATE_API_URL="https://api.github.com/repos/$UPDATE_REPO/releases/latest"
# ──────────────────────────────────────────────────────────────────────────────
# 1) Load .env if present, then single question: Repo URL
# ──────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/.env"
  set +a
fi

# ── Handle --update flag ────────────────────────────────────────────────────────
if [[ "${1:-}" == "--update" || "${1:-}" == "-u" ]]; then
  if [[ "$SCRIPT_VERSION" == "0.0.0-dev" ]]; then
    info "Running from source — use 'git pull' to update instead."
    exit 0
  fi

  info "Current version: v$SCRIPT_VERSION"
  info "Checking for updates…"

  RELEASE_DATA=$(curl -sL --max-time 15 \
    -H "User-Agent: discord-copilot-agent/$SCRIPT_VERSION" \
    ${GITHUB_TOKEN:+-H "Authorization: token $GITHUB_TOKEN"} \
    "$UPDATE_API_URL" 2>/dev/null) || die "Failed to fetch release info."

  LATEST_VER=$(echo "$RELEASE_DATA" | node -e "
    process.stdout.write((JSON.parse(require('fs').readFileSync(0,'utf8')).tag_name||'').replace(/^v/,''))
  " 2>/dev/null) || die "Failed to parse release data."

  [[ -z "$LATEST_VER" ]] && die "Could not determine latest version."

  if [[ "$LATEST_VER" == "$SCRIPT_VERSION" ]]; then
    ok "Already on latest version (v$SCRIPT_VERSION)"
    exit 0
  fi

  HIGHEST=$(printf '%s\n%s' "$LATEST_VER" "$SCRIPT_VERSION" | sort -V | tail -1)
  if [[ "$HIGHEST" != "$LATEST_VER" ]]; then
    ok "Already up to date (v$SCRIPT_VERSION, latest release: v$LATEST_VER)"
    exit 0
  fi

  DOWNLOAD_URL=$(echo "$RELEASE_DATA" | node -e "
    const r=JSON.parse(require('fs').readFileSync(0,'utf8'));
    const a=(r.assets||[]).find(a=>a.name==='agent.sh');
    process.stdout.write(a?.browser_download_url||'')
  " 2>/dev/null)
  [[ -z "$DOWNLOAD_URL" ]] && die "No agent.sh asset found in release v$LATEST_VER"

  info "Downloading v$LATEST_VER…"
  TMPFILE=$(mktemp)
  trap 'rm -f "$TMPFILE"' EXIT

  curl -sL --max-time 60 -o "$TMPFILE" "$DOWNLOAD_URL" 2>/dev/null || { rm -f "$TMPFILE"; die "Download failed."; }

  if ! head -1 "$TMPFILE" | grep -q "#!/usr/bin/env bash"; then
    rm -f "$TMPFILE"
    die "Downloaded file is not a valid bash script."
  fi

  SELF_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
  cp "$SELF_PATH" "${SELF_PATH}.bak"
  mv "$TMPFILE" "$SELF_PATH"
  chmod +x "$SELF_PATH"
  trap - EXIT

  echo ""
  ok "Updated to v$LATEST_VER!"
  ok "Backup saved as $(basename "${SELF_PATH}.bak")"
  info "Restart the script to use the new version."
  echo ""
  exit 0
fi

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}  Discord Autopilot  ${GREEN}v${SCRIPT_VERSION}${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
echo ""

# Quick update check (non-blocking, 3s timeout)
if [[ "$SCRIPT_VERSION" != "0.0.0-dev" ]] && command -v curl >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
  _UPDATE_JSON=$(curl -sL --max-time 3 -H "User-Agent: discord-copilot-agent/$SCRIPT_VERSION" "$UPDATE_API_URL" 2>/dev/null || true)
  if [[ -n "$_UPDATE_JSON" ]]; then
    _LATEST_VER=$(echo "$_UPDATE_JSON" | node -e "
      process.stdout.write((JSON.parse(require('fs').readFileSync(0,'utf8')).tag_name||'').replace(/^v/,''))
    " 2>/dev/null || true)
    if [[ -n "$_LATEST_VER" && "$_LATEST_VER" != "$SCRIPT_VERSION" ]]; then
      _HIGHEST=$(printf '%s\n%s' "$_LATEST_VER" "$SCRIPT_VERSION" | sort -V | tail -1)
      if [[ "$_HIGHEST" == "$_LATEST_VER" ]]; then
        echo -e "  ${YELLOW}⚡ UPDATE AVAILABLE: ${GREEN}v${_LATEST_VER}${NC}"
        echo -e "     ${YELLOW}Current: v${SCRIPT_VERSION}  →  Latest: v${_LATEST_VER}${NC}"
        _SCRIPT_NAME=$(basename "${BASH_SOURCE[0]}")
        echo -e "     ${YELLOW}Run ${CYAN}./${_SCRIPT_NAME} --update${YELLOW} to upgrade${NC}"
        echo ""
      fi
    fi
  fi
fi

# ──────────────────────────────────────────────────────────────────────────────
# 2) Prerequisite checks
# ──────────────────────────────────────────────────────────────────────────────
MISSING=()

command -v git   >/dev/null 2>&1 || MISSING+=("git   → https://git-scm.com/downloads")
command -v node  >/dev/null 2>&1 || MISSING+=("node  → https://nodejs.org/ (>= 18)")
command -v npm   >/dev/null 2>&1 || MISSING+=("npm   → ships with node")

# Copilot CLI: accept 'copilot' binary OR 'gh copilot' extension
COPILOT_CMD=""
if command -v copilot >/dev/null 2>&1; then
  COPILOT_CMD="copilot"
elif command -v gh >/dev/null 2>&1 && gh copilot --help >/dev/null 2>&1; then
  COPILOT_CMD="gh copilot"
else
  MISSING+=("copilot → npm install -g @githubnext/github-copilot-cli   OR   gh extension install github/gh-copilot")
fi

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo ""
  die "Missing prerequisites:\n$(printf '  • %s\n' "${MISSING[@]}")\n\nInstall them and re-run this script."
fi

# Node version check (>= 18)
NODE_MAJOR=$(node -e "process.stdout.write(String(process.versions.node.split('.')[0]))")
if [[ "$NODE_MAJOR" -lt 18 ]]; then
  die "Node.js >= 18 required (found v$(node -v)). Update: https://nodejs.org/"
fi
ok "node $(node -v)"

# Copilot auth check
if [[ -n "$COPILOT_CMD" ]]; then
  if ! $COPILOT_CMD auth status >/dev/null 2>&1; then
    warn "copilot auth not configured. Attempting to continue…"
    warn "If it fails, run:  $COPILOT_CMD auth login"
  fi
fi

# ──────────────────────────────────────────────────────────────────────────────
# Setup Wizard — interactive prompts for missing config
# ──────────────────────────────────────────────────────────────────────────────
ENV_CHANGED=false
ENV_FILE="$SCRIPT_DIR/.env"

# ── DISCORD_TOKEN ──
if [[ -z "${DISCORD_TOKEN:-}" ]]; then
  if [[ ! -t 0 ]]; then
    die "DISCORD_TOKEN is not set and stdin is not a terminal (non-interactive).\n\n  export DISCORD_TOKEN=\"your-bot-token-here\"\n  Or create a .env file next to this script."
  fi
  echo ""
  echo -e "  ${CYAN} DISCORD_TOKEN ${NC} (required)"
  echo ""
  echo -e "  How to get your token:"
  echo -e "    1. Go to ${CYAN}https://discord.com/developers/applications${NC}"
  echo -e "    2. Click ${NC}New Application${NC} (or select existing)"
  echo -e "    3. Go to Bot tab → Reset Token → copy it"
  echo -e "    4. Under ${NC}Privileged Gateway Intents${NC}: enable ${YELLOW}Message Content${NC}"
  echo -e "    5. Under ${NC}OAuth2 > URL Generator${NC}:"
  echo -e "       Scopes: bot, applications.commands"
  echo -e "       Permissions: Send Messages, Embed Links, Attach Files, Use Slash Commands"
  echo ""
  read -rp "  ▸ Paste your Discord bot token: " DISCORD_TOKEN
  [[ -z "$DISCORD_TOKEN" ]] && die "DISCORD_TOKEN is required."
  export DISCORD_TOKEN
  ENV_CHANGED=true
  ok "DISCORD_TOKEN set"
else
  ok "DISCORD_TOKEN found"
fi

# ── REPO_URL ──
if [[ -z "${REPO_URL:-}" ]]; then
  if [[ ! -t 0 ]]; then
    die "REPO_URL is not set and stdin is not a terminal (non-interactive)."
  fi
  echo ""
  echo -e "  ${CYAN} REPO_URL ${NC} (required)"
  echo ""
  echo -e "  The Git repository the agent will work on."
  echo -e "  HTTPS example: ${CYAN}https://github.com/owner/repo.git${NC}"
  echo -e "  SSH example:   ${CYAN}git@github.com:owner/repo.git${NC}"
  echo ""
  read -rp "  ▸ Repository URL: " REPO_URL
  [[ -z "$REPO_URL" ]] && die "REPO_URL is required."
  export REPO_URL
  ENV_CHANGED=true
  ok "REPO_URL set"
else
  ok "REPO_URL: $REPO_URL"
fi

# ── GITHUB_TOKEN (optional) ──
if [[ -z "${GITHUB_TOKEN:-}" ]] && [[ -t 0 ]]; then
  echo ""
  echo -e "  ${NC} GITHUB_TOKEN ${NC} (optional)"
  echo ""
  echo -e "  Needed for private repos, pushing, and creating PRs."
  echo -e "  Create a fine-grained PAT: ${CYAN}https://github.com/settings/personal-access-tokens/new${NC}"
  echo -e "  Required permissions: ${NC}Contents (read/write)${NC}, ${NC}Pull requests (read/write)${NC}"
  echo -e "  Press ${YELLOW}Enter${NC} to skip."
  echo ""
  read -rp "  ▸ GitHub token (or Enter to skip): " _gh_token
  if [[ -n "$_gh_token" ]]; then
    export GITHUB_TOKEN="$_gh_token"
    ENV_CHANGED=true
    ok "GITHUB_TOKEN set"
  else
    info "GITHUB_TOKEN skipped"
  fi
fi

# ── ADMIN_USER_ID (optional) ──
if [[ -z "${ADMIN_USER_ID:-}" ]] && [[ -t 0 ]]; then
  echo ""
  echo -e "  ${NC} ADMIN_USER_ID ${NC} (optional)"
  echo ""
  echo -e "  Your Discord User ID — allows DMs and admin access."
  echo -e "  How to find it:"
  echo -e "    1. Discord → User Settings (gear) → Advanced → enable ${YELLOW}Developer Mode${NC}"
  echo -e "    2. My Account → click ${NC}...${NC} next to your username → ${NC}Copy User ID${NC}"
  echo -e "  Press ${YELLOW}Enter${NC} to skip."
  echo ""
  read -rp "  ▸ Admin User ID (or Enter to skip): " _admin_id
  if [[ -n "$_admin_id" ]]; then
    if [[ "$_admin_id" =~ ^[0-9]{17,20}$ ]]; then
      export ADMIN_USER_ID="$_admin_id"
      ENV_CHANGED=true
      ok "ADMIN_USER_ID set"
    else
      warn "'$_admin_id' is not a valid Discord User ID (must be 17-20 digits). Skipping."
    fi
  else
    info "ADMIN_USER_ID skipped"
  fi
fi

# ── STARTUP_CHANNEL_ID (optional) ──
if [[ -z "${STARTUP_CHANNEL_ID:-}" ]] && [[ -t 0 ]]; then
  echo ""
  echo -e "  ${NC} STARTUP_CHANNEL_ID ${NC} (optional)"
  echo ""
  echo -e "  Channel for bot online/offline notifications."
  echo -e "  Right-click any text channel → ${NC}Copy Channel ID${NC}"
  echo -e "  Press ${YELLOW}Enter${NC} to skip."
  echo ""
  read -rp "  ▸ Startup Channel ID (or Enter to skip): " _startup_ch
  if [[ -n "$_startup_ch" ]]; then
    if [[ "$_startup_ch" =~ ^[0-9]{17,20}$ ]]; then
      export STARTUP_CHANNEL_ID="$_startup_ch"
      ENV_CHANGED=true
      ok "STARTUP_CHANNEL_ID set"
    else
      warn "'$_startup_ch' is not a valid Discord Channel ID (must be 17-20 digits). Skipping."
    fi
  else
    info "STARTUP_CHANNEL_ID skipped"
  fi
fi

# ── Offer to save .env ──
if [[ "$ENV_CHANGED" == "true" ]] && [[ -t 0 ]]; then
  echo ""
  echo -e "  ${YELLOW} SAVE ${NC}"
  echo -e "  Save these values to ${CYAN}$ENV_FILE${NC}?"
  echo -e "  So you don't have to enter them again next time."
  echo ""
  read -rp "  ▸ Save to .env? [Y/n] " _save_answer
  if [[ -z "$_save_answer" || "$_save_answer" =~ ^[yYjJ] ]]; then
    {
      echo "# Discord Autopilot — auto-generated $(date +%Y-%m-%d)"
      echo "DISCORD_TOKEN=$DISCORD_TOKEN"
      echo "REPO_URL=$REPO_URL"
      [[ -n "${GITHUB_TOKEN:-}" ]]      && echo "GITHUB_TOKEN=$GITHUB_TOKEN"
      [[ -n "${DEFAULT_BRANCH:-}" ]]     && echo "DEFAULT_BRANCH=$DEFAULT_BRANCH"
      [[ -n "${ADMIN_USER_ID:-}" ]]      && echo "ADMIN_USER_ID=$ADMIN_USER_ID"
      [[ -n "${STARTUP_CHANNEL_ID:-}" ]] && echo "STARTUP_CHANNEL_ID=$STARTUP_CHANNEL_ID"
      # preserve extra keys from existing .env
      if [[ -f "$ENV_FILE" ]]; then
        while IFS= read -r line; do
          key="${line%%=*}"
          key="${key// /}"
          case "$key" in
            DISCORD_TOKEN|REPO_URL|GITHUB_TOKEN|DEFAULT_BRANCH|ADMIN_USER_ID|STARTUP_CHANNEL_ID|""|"#"*) ;;
            *) echo "$line" ;;
          esac
        done < "$ENV_FILE"
      fi
    } > "$ENV_FILE"
    ok ".env saved"
  else
    info ".env not saved"
  fi
fi

echo ""

# ──────────────────────────────────────────────────────────────────────────────
# Credential & access validation
# ──────────────────────────────────────────────────────────────────────────────
VALIDATION_FAILED=false

# Discord token validation
if command -v curl >/dev/null 2>&1; then
  DISCORD_CHECK=$(mktemp)
  DISCORD_HTTP=$(curl -s -o "$DISCORD_CHECK" -w "%{http_code}" \
    -H @- "https://discord.com/api/v10/users/@me" --max-time 10 2>/dev/null <<< "Authorization: Bot $DISCORD_TOKEN")
  if [[ "$DISCORD_HTTP" == "200" ]]; then
    DISCORD_USER=$(grep -o '"username":"[^"]*"' "$DISCORD_CHECK" | head -1 | cut -d'"' -f4)
    ok "Discord bot: $DISCORD_USER"

    # Check if bot is in any guilds
    DISCORD_GUILDS=$(mktemp)
    GUILDS_HTTP=$(curl -s -o "$DISCORD_GUILDS" -w "%{http_code}" \
      -H @- "https://discord.com/api/v10/users/@me/guilds?limit=1" --max-time 10 2>/dev/null <<< "Authorization: Bot $DISCORD_TOKEN")
    if [[ "$GUILDS_HTTP" == "200" ]]; then
      GUILD_COUNT=$(grep -o '"id"' "$DISCORD_GUILDS" | wc -l)
      if [[ "$GUILD_COUNT" -gt 0 ]]; then
        ok "Bot guilds: in at least 1 server"
      else
        warn "Bot is not in any server yet"
        warn "  Invite the bot: Developer Portal > OAuth2 > URL Generator"
      fi
    fi
    rm -f "$DISCORD_GUILDS"

  elif [[ "$DISCORD_HTTP" == "401" ]]; then
    VALIDATION_FAILED=true
    echo -e "${RED}[FAIL]${NC} Discord token invalid (401 Unauthorized)"
    echo "       Regenerate at: https://discord.com/developers/applications"
  else
    warn "Discord API returned HTTP $DISCORD_HTTP (network issue?). Continuing..."
  fi
  rm -f "$DISCORD_CHECK"
else
  warn "curl not found — skipping Discord token validation"
fi

# GitHub token validation (if set)
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  if command -v curl >/dev/null 2>&1; then
    # Detect token type
    GH_TOKEN_TYPE="unknown"
    case "$GITHUB_TOKEN" in
      ghp_*)         GH_TOKEN_TYPE="PAT (classic)" ;;
      github_pat_*)  GH_TOKEN_TYPE="PAT (fine-grained)" ;;
      gho_*)         GH_TOKEN_TYPE="OAuth" ;;
      ghu_*)         GH_TOKEN_TYPE="User-to-server" ;;
      ghs_*)         GH_TOKEN_TYPE="Server-to-server" ;;
    esac

    GH_HEADERS_FILE=$(mktemp)
    GH_BODY_FILE=$(mktemp)
    GH_HTTP=$(curl -s -D "$GH_HEADERS_FILE" -o "$GH_BODY_FILE" -w "%{http_code}" \
      -H "User-Agent: discord-copilot-agent/$SCRIPT_VERSION" \
      -H @- "https://api.github.com/user" --max-time 10 2>/dev/null <<< "Authorization: token $GITHUB_TOKEN")

    if [[ "$GH_HTTP" == "200" ]]; then
      GH_USER=$(grep -o '"login":"[^"]*"' "$GH_BODY_FILE" | head -1 | cut -d'"' -f4)
      ok "GitHub user: $GH_USER ($GH_TOKEN_TYPE)"

      # Rate limit
      RATE_REMAIN=$(grep -i '^x-ratelimit-remaining:' "$GH_HEADERS_FILE" | tr -d '\r' | awk '{print $2}')
      RATE_LIMIT=$(grep -i '^x-ratelimit-limit:' "$GH_HEADERS_FILE" | tr -d '\r' | awk '{print $2}')
      if [[ -n "$RATE_REMAIN" && -n "$RATE_LIMIT" ]]; then
        if [[ "$RATE_REMAIN" -gt 100 ]]; then
          ok "Rate limit: $RATE_REMAIN/$RATE_LIMIT remaining"
        else
          warn "Rate limit low: $RATE_REMAIN/$RATE_LIMIT remaining"
        fi
      fi

      # Scope checks
      GH_SCOPES=$(grep -i '^x-oauth-scopes:' "$GH_HEADERS_FILE" | cut -d: -f2- | tr -d '\r' | xargs)

      if [[ -n "$GH_SCOPES" ]]; then
        # Classic PAT
        if echo "$GH_SCOPES" | grep -qw "repo"; then
          ok "Scope: repo (clone, push, PRs)"
        else
          warn "Scope: repo MISSING — needed for private repos, push, PRs"
          warn "  Current scopes: $GH_SCOPES"
        fi

        if echo "$GH_SCOPES" | grep -qw "workflow"; then
          ok "Scope: workflow (CI files)"
        else
          info "Scope: workflow not set (optional, for .github/workflows/)"
        fi

        if echo "$GH_SCOPES" | grep -qw "copilot"; then
          ok "Scope: copilot"
        else
          info "Scope: copilot not set (optional)"
          info "  The Copilot SDK uses \`gh auth\` credentials, not the PAT."
          info "  Ensure \`gh auth login\` has been run on this machine."
        fi
      else
        info "Scopes: n/a (fine-grained PAT)"
        info "  Ensure token has: Contents (read/write) + Pull requests (read/write)"
        info "  and access to the target repository."
      fi

      # Check access to the specific repo
      REPO_PATH=$(echo "$REPO_URL" | sed 's/\.git$//' | sed 's|^https\?://github\.com/||' | sed 's|^git@github\.com:||')
      if [[ "$REPO_PATH" =~ ^[^/]+/[^/]+$ ]]; then
        GH_REPO_FILE=$(mktemp)
        REPO_HTTP=$(curl -s -o "$GH_REPO_FILE" -w "%{http_code}" \
          -H "User-Agent: discord-copilot-agent/$SCRIPT_VERSION" \
          -H @- "https://api.github.com/repos/$REPO_PATH" --max-time 10 2>/dev/null <<< "Authorization: token $GITHUB_TOKEN")
        if [[ "$REPO_HTTP" == "200" ]]; then
          CAN_PUSH=$(grep -o '"push":[a-z]*' "$GH_REPO_FILE" | head -1 | grep -o 'true\|false')
          CAN_PULL=$(grep -o '"pull":[a-z]*' "$GH_REPO_FILE" | head -1 | grep -o 'true\|false')
          PERMS=""
          [[ "$CAN_PULL" == "true" ]] && PERMS="pull"
          [[ "$CAN_PUSH" == "true" ]] && PERMS="${PERMS:+$PERMS, }push"
          if [[ "$CAN_PUSH" == "true" ]]; then
            ok "Repo perms: $REPO_PATH ($PERMS)"
          else
            warn "Repo perms: $REPO_PATH ($PERMS) — no push access"
            warn "  Agent needs push access to create branches and PRs."
          fi
        elif [[ "$REPO_HTTP" == "404" ]]; then
          warn "Token→Repo: $REPO_PATH (not found or no access)"
        elif [[ "$REPO_HTTP" == "403" ]]; then
          warn "Token→Repo: $REPO_PATH (forbidden)"
        else
          warn "Token→Repo: $REPO_PATH (HTTP $REPO_HTTP)"
        fi
        rm -f "$GH_REPO_FILE"
      fi

    elif [[ "$GH_HTTP" == "401" ]]; then
      warn "GitHub token invalid (401). Create a new one: https://github.com/settings/tokens"
      VALIDATION_FAILED=true
    else
      warn "GitHub API returned HTTP $GH_HTTP. Continuing..."
    fi
    rm -f "$GH_HEADERS_FILE" "$GH_BODY_FILE"
  fi
else
  info "GITHUB_TOKEN not set (optional)"
fi

# Repo URL accessibility
if git ls-remote --exit-code "$REPO_URL" HEAD >/dev/null 2>&1; then
  ok "Git access: reachable"
else
  warn "Git access: unreachable via git ls-remote. Clone step may fail."
  warn "  Check URL, SSH keys, or network connectivity."
fi

# GitHub CLI auth (required for Copilot SDK)
if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    ok "gh auth: authenticated"
  else
    warn "gh auth: not authenticated"
    warn "  The Copilot SDK requires \`gh auth login\`. Run it before starting the bot."
    VALIDATION_FAILED=true
  fi
else
  warn "GitHub CLI (gh) not installed"
  warn "  The Copilot SDK requires \`gh\`. Install it: https://cli.github.com/"
  VALIDATION_FAILED=true
fi

if [[ "$VALIDATION_FAILED" == "true" ]]; then
  echo ""
  die "Credential validation failed. Fix the issues above and re-run."
fi

ok "All credentials validated"

# ──────────────────────────────────────────────────────────────────────────────
# 3) Derive project name & paths
# ──────────────────────────────────────────────────────────────────────────────
PROJECT_NAME=$(basename "$REPO_URL" .git)
PROJECT_NAME=${PROJECT_NAME##*/}  # strip any remaining slashes

BASE="${BASE_ROOT:-$HOME/.local/share/discord-agent}"
REPOS="$BASE/repos"
APP="$BASE/app"
WORKSPACES="${WORKSPACES_ROOT:-$BASE/workspaces}"
REPO_DIR="$REPOS/$PROJECT_NAME"

info "Project:    $PROJECT_NAME"
info "Base:       $BASE"
info "Repo:       $REPO_DIR"
info "App:        $APP"
info "Workspaces: $WORKSPACES"

mkdir -p "$REPOS" "$APP/src" "$WORKSPACES"

# ──────────────────────────────────────────────────────────────────────────────
# 4) Clone or update repo
# ──────────────────────────────────────────────────────────────────────────────
if [[ -d "$REPO_DIR/.git" ]]; then
  info "Updating existing repo…"
  git -C "$REPO_DIR" fetch --all --prune 2>/dev/null || true
  git -C "$REPO_DIR" pull --ff-only 2>/dev/null || warn "pull failed (diverged?) — using existing state"
  ok "Repo updated"
else
  info "Cloning $REPO_URL …"
  git clone "$REPO_URL" "$REPO_DIR"
  ok "Repo cloned"
fi

# ── DEFAULT_BRANCH (interactive branch picker) ──
if [[ -n "${DEFAULT_BRANCH:-}" ]]; then
  ok "DEFAULT_BRANCH: $DEFAULT_BRANCH"
elif [[ -t 0 ]]; then
  # Collect remote branches (strip origin/ prefix, ignore HEAD)
  mapfile -t _branches < <(
    git -C "$REPO_DIR" branch -r 2>/dev/null \
      | sed 's/^[* ]*//' \
      | grep -v '\->' \
      | sed 's|^origin/||' \
      | sort -u
  )
  if [[ ${#_branches[@]} -gt 1 ]]; then
    echo ""
    echo -e "  ${CYAN} DEFAULT_BRANCH ${NC} (optional)"
    echo ""
    echo -e "  Pick the base branch for new worktrees."
    echo -e "  Can be changed later via ${CYAN}/branch set${NC}."
    echo ""
    for i in "${!_branches[@]}"; do
      printf "    ${CYAN}%2d${NC})  %s\n" "$((i+1))" "${_branches[$i]}"
    done
    echo ""
    read -rp "  ▸ Number (or Enter for remote default): " _pick
    if [[ -n "$_pick" ]] && [[ "$_pick" =~ ^[0-9]+$ ]] && (( _pick >= 1 && _pick <= ${#_branches[@]} )); then
      export DEFAULT_BRANCH="${_branches[$((_pick-1))]}"
      ENV_CHANGED=true
      ok "DEFAULT_BRANCH set to '$DEFAULT_BRANCH'"
    else
      [[ -n "$_pick" ]] && warn "Invalid selection — using remote default."
      info "DEFAULT_BRANCH skipped (remote default)"
    fi
  else
    info "Only one branch found — using remote default."
  fi
fi

# ──────────────────────────────────────────────────────────────────────────────
# 5) Copy application files from src/
# ──────────────────────────────────────────────────────────────────────────────
info "Copying bot application files…"

SRC_DIR="$SCRIPT_DIR/src"
if [[ ! -d "$SRC_DIR" ]]; then
  fatal "Source directory not found: $SRC_DIR"
fi

mkdir -p "$APP/src" "$APP/llm"
cp "$SCRIPT_DIR/src/package.json" "$APP/package.json"
[[ -f "$SCRIPT_DIR/src/package-lock.json" ]] && cp "$SCRIPT_DIR/src/package-lock.json" "$APP/package-lock.json"
for f in "$SRC_DIR"/*.mjs; do
  cp "$f" "$APP/src/$(basename "$f")"
done
for f in "$SCRIPT_DIR/llm"/*.md; do
  [[ -f "$f" ]] && cp "$f" "$APP/llm/$(basename "$f")"
done

FILE_COUNT=$(find "$APP/src" -name "*.mjs" | wc -l)
LLM_COUNT=$(find "$APP/llm" -name "*.md" 2>/dev/null | wc -l)
ok "$FILE_COUNT source files + $LLM_COUNT llm files copied"

# ──────────────────────────────────────────────────────────────────────────────
# 6) Install dependencies
# ──────────────────────────────────────────────────────────────────────────────
info "Installing npm dependencies…"
cd "$APP"

# Use npm ci if lock file exists, otherwise npm install
if [[ -f "package-lock.json" ]]; then
  npm ci --loglevel=error
else
  npm install --loglevel=error
fi

ok "Dependencies installed"

# ──────────────────────────────────────────────────────────────────────────────
# 7) Launch
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Starting bot — Ctrl+C to stop                  ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""

export PROJECT_NAME
export REPO_PATH="$REPO_DIR"
export DEFAULT_BRANCH="${DEFAULT_BRANCH:-}"
export AGENT_SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

# Validate snowflake IDs (17-20 digits)
if [[ -n "${ADMIN_USER_ID:-}" && ! "${ADMIN_USER_ID}" =~ ^[0-9]{17,20}$ ]]; then
  warn "ADMIN_USER_ID '${ADMIN_USER_ID}' is not a valid Discord snowflake (must be 17-20 digits). Ignoring."
  warn "  To find your ID: Settings (gear) > Advanced > Developer Mode ON"
  warn "  Then: Settings > My Account > ... next to your username > Copy User ID"
  export ADMIN_USER_ID=""
else
  export ADMIN_USER_ID="${ADMIN_USER_ID:-}"
fi

if [[ -n "${STARTUP_CHANNEL_ID:-}" && ! "${STARTUP_CHANNEL_ID}" =~ ^[0-9]{17,20}$ ]]; then
  warn "STARTUP_CHANNEL_ID '${STARTUP_CHANNEL_ID}' is not a valid Discord snowflake (must be 17-20 digits). Ignoring."
  warn "  Copy the numeric ID: right-click a text channel in Discord → Copy Channel ID"
  export STARTUP_CHANNEL_ID=""
else
  export STARTUP_CHANNEL_ID="${STARTUP_CHANNEL_ID:-}"
fi

exec node "$APP/src/bot.mjs"
