#!/usr/bin/env bash
set -euo pipefail

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  Discord × Copilot — Autonomous Remote Coding Agent                        ║
# ║  Single-script deployment. Run: ./agent.sh                                 ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[FATAL]${NC} $*" >&2; exit 1; }

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
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  Discord × Copilot Remote Coding Agent          ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
echo ""

if [[ -n "${REPO_URL:-}" ]]; then
  info "Using REPO_URL from environment: $REPO_URL"
else
  read -rp "Repo URL? " REPO_URL
fi

[[ -z "$REPO_URL" ]] && die "No repo URL provided."

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

# ENV check
if [[ -z "${DISCORD_TOKEN:-}" ]]; then
  echo ""
  die "DISCORD_TOKEN is not set.\n\n  export DISCORD_TOKEN=\"your-bot-token-here\"\n\n  Create a bot at https://discord.com/developers/applications\n  → Bot → Reset Token → copy it.\n\n  Required bot permissions: Send Messages, Embed Links, Attach Files, Use Slash Commands\n  Required intents: Message Content"
fi
ok "DISCORD_TOKEN is set"

# ──────────────────────────────────────────────────────────────────────────────
# Credential & access validation
# ──────────────────────────────────────────────────────────────────────────────
VALIDATION_FAILED=false

# Discord token validation
if command -v curl >/dev/null 2>&1; then
  DISCORD_HTTP=$(curl -s -o /tmp/.discord_check -w "%{http_code}" \
    -H "Authorization: Bot $DISCORD_TOKEN" \
    "https://discord.com/api/v10/users/@me" --max-time 10 2>/dev/null)
  if [[ "$DISCORD_HTTP" == "200" ]]; then
    DISCORD_USER=$(grep -o '"username":"[^"]*"' /tmp/.discord_check | head -1 | cut -d'"' -f4)
    ok "Discord bot: $DISCORD_USER"

    # Check Message Content Intent via /applications/@me
    APP_HTTP=$(curl -s -o /tmp/.discord_app -w "%{http_code}" \
      -H "Authorization: Bot $DISCORD_TOKEN" \
      "https://discord.com/api/v10/applications/@me" --max-time 10 2>/dev/null)
    if [[ "$APP_HTTP" == "200" ]]; then
      APP_FLAGS=$(grep -o '"flags":[0-9]*' /tmp/.discord_app | head -1 | grep -o '[0-9]*$')
      if [[ -n "$APP_FLAGS" ]]; then
        # GatewayMessageContent = 1<<18 (262144), Limited = 1<<19 (524288)
        HAS_MSG_CONTENT=$(( (APP_FLAGS & 262144) | (APP_FLAGS & 524288) ))
        if [[ "$HAS_MSG_CONTENT" -ne 0 ]]; then
          ok "Message Content Intent: enabled"
        else
          warn "Message Content Intent: NOT enabled"
          warn "  Enable it: Discord Developer Portal > Bot > Privileged Gateway Intents"
        fi
      fi
    fi
    rm -f /tmp/.discord_app

    # Check if bot is in any guilds
    GUILDS_HTTP=$(curl -s -o /tmp/.discord_guilds -w "%{http_code}" \
      -H "Authorization: Bot $DISCORD_TOKEN" \
      "https://discord.com/api/v10/users/@me/guilds?limit=1" --max-time 10 2>/dev/null)
    if [[ "$GUILDS_HTTP" == "200" ]]; then
      GUILD_COUNT=$(grep -o '"id"' /tmp/.discord_guilds | wc -l)
      if [[ "$GUILD_COUNT" -gt 0 ]]; then
        ok "Bot guilds: in at least 1 server"
      else
        warn "Bot is not in any server yet"
        warn "  Invite the bot: Developer Portal > OAuth2 > URL Generator"
      fi
    fi
    rm -f /tmp/.discord_guilds

  elif [[ "$DISCORD_HTTP" == "401" ]]; then
    VALIDATION_FAILED=true
    echo -e "${RED}[FAIL]${NC} Discord token invalid (401 Unauthorized)"
    echo "       Regenerate at: https://discord.com/developers/applications"
  else
    warn "Discord API returned HTTP $DISCORD_HTTP (network issue?). Continuing..."
  fi
  rm -f /tmp/.discord_check
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
      -H "Authorization: token $GITHUB_TOKEN" \
      -H "User-Agent: discord-copilot-agent/1.0" \
      "https://api.github.com/user" --max-time 10 2>/dev/null)

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
      else
        info "Scopes: n/a (fine-grained PAT)"
        info "  Ensure token has: Contents (read/write) + Pull requests (read/write)"
        info "  and access to the target repository."
      fi

      # Check access to the specific repo
      REPO_PATH=$(echo "$REPO_URL" | sed 's/\.git$//' | sed 's|^https\?://github\.com/||' | sed 's|^git@github\.com:||')
      if [[ "$REPO_PATH" =~ ^[^/]+/[^/]+$ ]]; then
        REPO_HTTP=$(curl -s -o /tmp/.gh_repo -w "%{http_code}" \
          -H "Authorization: token $GITHUB_TOKEN" \
          -H "User-Agent: discord-copilot-agent/1.0" \
          "https://api.github.com/repos/$REPO_PATH" --max-time 10 2>/dev/null)
        if [[ "$REPO_HTTP" == "200" ]]; then
          CAN_PUSH=$(grep -o '"push":[a-z]*' /tmp/.gh_repo | head -1 | grep -o 'true\|false')
          CAN_PULL=$(grep -o '"pull":[a-z]*' /tmp/.gh_repo | head -1 | grep -o 'true\|false')
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
        rm -f /tmp/.gh_repo
      fi

    elif [[ "$GH_HTTP" == "401" ]]; then
      warn "GitHub token invalid (401). Create a new one: https://github.com/settings/tokens"
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

# ──────────────────────────────────────────────────────────────────────────────
# 5) Copy application files from src/
# ──────────────────────────────────────────────────────────────────────────────
info "Copying bot application files…"

SRC_DIR="$SCRIPT_DIR/src"
if [[ ! -d "$SRC_DIR" ]]; then
  fatal "Source directory not found: $SRC_DIR"
fi

mkdir -p "$APP/src"
cp "$SCRIPT_DIR/src/package.json" "$APP/package.json"
for f in "$SRC_DIR"/*.mjs; do
  cp "$f" "$APP/src/$(basename "$f")"
done

FILE_COUNT=$(find "$APP/src" -name "*.mjs" | wc -l)
ok "$FILE_COUNT source files copied"

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
