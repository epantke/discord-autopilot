#!/usr/bin/env bash
set -euo pipefail

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  Discord Autopilot — Autonomous AI Coding Agent                            ║
# ║  Single-script deployment. Run: ./agent.sh                                 ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

# ── Cleanup trap ─────────────────────────────────────────────────────────────
_TMPFILES=()
_cleanup() {
  for f in "${_TMPFILES[@]}"; do
    rm -f "$f" 2>/dev/null
  done
  # Remove lockfile on exit
  [[ -n "${_LOCKFILE:-}" ]] && rm -f "$_LOCKFILE" 2>/dev/null
}
trap _cleanup EXIT
trap 'echo ""; echo -e "  \033[1;33m⚠ Interrupted — cleaning up…\033[0m"; _cleanup; exit 130' INT TERM

# Safe mktemp wrapper that registers files for cleanup
safe_mktemp() {
  local f; f=$(mktemp "$@")
  _TMPFILES+=("$f")
  echo "$f"
}

# ── Output helpers ───────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'; GRAY='\033[0;37m'; DGRAY='\033[1;30m'; NC='\033[0m'
BG_DCYAN='\033[46m'; BG_DGRAY='\033[100m'; BG_RED='\033[41m'; BG_GREEN='\033[42m'; BG_DYELLOW='\033[43m'
BLACK='\033[0;30m'

START_TIME=$(date +%s)

info()  { echo -e "  ${CYAN}▸${NC} $*"; }
ok()    { echo -e "  ${GREEN}✔${NC} $*"; }
warn()  { echo -e "  ${YELLOW}⚠${NC} ${YELLOW}$*${NC}"; }
die()   {
  echo ""
  echo -e "  ${RED}✘ FATAL:${NC} $1"
  [[ -n "${2:-}" ]] && echo -e "         ${DGRAY}→ $2${NC}"
  echo ""
  exit 1
}

# Extract the most relevant error line from captured output
_err_line() {
  echo "$1" | grep -iE 'fatal|error|fail|denied|not found|EACCES|ENOENT|ERESOLVE|unable|refused' | head -1 | sed 's/^[[:space:]]*//' | cut -c1-120
}

elapsed() {
  local now; now=$(date +%s)
  local diff=$(( now - START_TIME ))
  printf '%02d:%02d' $(( diff / 60 )) $(( diff % 60 ))
}

write_step() {
  local num=$1 total=$2 title=$3
  local el; el=$(elapsed)
  local pad_title; pad_title=$(printf '%-36s' "$title")
  echo ""
  echo -ne "  ${BLACK}${BG_DCYAN} ${num}/${total} ${NC} ${WHITE}${pad_title}${NC}"
  echo -e " ${DGRAY}⏱ ${el}${NC}"
  # progress dots
  echo -n "       "
  for (( i = 1; i <= total; i++ )); do
    if (( i < num )); then
      echo -ne "${GREEN}━${NC}"
    elif (( i == num )); then
      echo -ne "${CYAN}◉${NC}"
    else
      echo -ne "${DGRAY}━${NC}"
    fi
  done
  echo ""
}

write_file_progress() {
  local name=$1 current=$2 total=$3
  local pct=$(( (current * 100) / total ))
  local fill=$(( (current * 20) / total ))
  if (( fill > 20 )); then fill=20; fi
  local bar=""
  for (( i = 0; i < fill; i++ )); do bar+="█"; done
  for (( i = fill; i < 20; i++ )); do bar+="░"; done
  echo -e "       ${DGRAY}│${NC} ${CYAN}${bar}${NC} ${DGRAY}${pct}%${NC} ${WHITE}${name}${NC}"
}

write_check() {
  local label=$1 value=$2 is_ok=${3:-true}
  local pad_label; pad_label=$(printf '%-14s' "$label")
  if [[ "$is_ok" == "true" ]]; then
    echo -e "       ${DGRAY}│${NC} ${GREEN}✔${NC} ${GRAY}${pad_label}${NC} ${WHITE}${value}${NC}"
  else
    echo -e "       ${DGRAY}│${NC} ${RED}✘${NC} ${GRAY}${pad_label}${NC} ${WHITE}${value}${NC}"
  fi
}

box_top()    { echo -e "       ${DGRAY}┌$(printf '─%.0s' $(seq 1 "$1"))${NC}"; }
box_bottom() { echo -e "       ${DGRAY}└$(printf '─%.0s' $(seq 1 "$1"))${NC}"; }

# Version comparison — returns 0 if $1 >= $2 (semver-compatible, no sort -V needed)
_ver_ge() {
  local IFS='.'
  local -a a=($1) b=($2)
  local i
  for (( i=0; i<${#a[@]} || i<${#b[@]}; i++ )); do
    local ai=${a[i]:-0} bi=${b[i]:-0}
    (( ai > bi )) && return 0
    (( ai < bi )) && return 1
  done
  return 0
}

# ── Platform detection ───────────────────────────────────────────────────────
ARCH=$(uname -m 2>/dev/null || echo "unknown")
OS_KERNEL=$(uname -s 2>/dev/null || echo "unknown")
DISTRO_ID="unknown"; DISTRO_NAME="unknown"
if [[ -f /etc/os-release ]]; then
  # shellcheck source=/dev/null
  . /etc/os-release
  DISTRO_ID="${ID:-unknown}"
  DISTRO_NAME="${PRETTY_NAME:-$ID}"
fi

# Detect package manager
PKG_MGR=""
if command -v apt-get >/dev/null 2>&1; then   PKG_MGR="apt"
elif command -v dnf >/dev/null 2>&1; then     PKG_MGR="dnf"
elif command -v yum >/dev/null 2>&1; then     PKG_MGR="yum"
elif command -v pacman >/dev/null 2>&1; then  PKG_MGR="pacman"
elif command -v apk >/dev/null 2>&1; then     PKG_MGR="apk"
elif command -v zypper >/dev/null 2>&1; then  PKG_MGR="zypper"
elif command -v brew >/dev/null 2>&1; then    PKG_MGR="brew"
fi

# Elevate helper — uses sudo only when not root, checks availability
_sudo() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    echo >&2 "Need root privileges but sudo is not available. Run as root or install sudo."
    return 1
  fi
}

# Generic package install
pkg_install() {
  local pkg="$1"
  case "$PKG_MGR" in
    apt)    _sudo apt-get update -qq && _sudo apt-get install -y -qq "$pkg" ;;
    dnf)    _sudo dnf install -y -q "$pkg" ;;
    yum)    _sudo yum install -y -q "$pkg" ;;
    pacman) _sudo pacman -S --noconfirm --quiet "$pkg" ;;
    apk)    _sudo apk add --quiet "$pkg" ;;
    zypper) _sudo zypper install -y "$pkg" ;;
    brew)   brew install --quiet "$pkg" ;;
    *)      return 1 ;;
  esac
}

# Install Node.js (platform-aware)
install_node() {
  # ARMv6 (RPi Zero) — no official Node.js 18+ builds
  if [[ "$ARCH" == "armv6l" ]]; then
    warn "ARMv6 detected (Raspberry Pi Zero). No official Node.js 18+ for this arch."
    info "Trying unofficial-builds.nodejs.org …"
    local NODE_MAJOR=22
    local NODE_VER_FULL=""
    NODE_VER_FULL=$(fetch_url "https://unofficial-builds.nodejs.org/download/release/latest-v${NODE_MAJOR}.x/SHASUMS256.txt" 2>/dev/null \
      | grep -o "node-v[0-9.]*-linux-armv6l.tar.gz" | head -1 | sed 's/node-v//;s/-linux.*//' || true)
    if [[ -z "$NODE_VER_FULL" ]]; then
      warn "Could not determine latest Node.js v${NODE_MAJOR} for ARMv6."
      return 1
    fi
    local URL="https://unofficial-builds.nodejs.org/download/release/v${NODE_VER_FULL}/node-v${NODE_VER_FULL}-linux-armv6l.tar.gz"
    local TMPDIR; TMPDIR=$(mktemp -d)
    info "Downloading Node.js v${NODE_VER_FULL} (armv6l) …"
    if fetch_url "$URL" > "$TMPDIR/node.tar.gz" 2>/dev/null; then
      _sudo tar -xzf "$TMPDIR/node.tar.gz" -C /usr/local --strip-components=1
      rm -rf "$TMPDIR"
      ok "Node.js v${NODE_VER_FULL} installed (unofficial armv6l build)"
      return 0
    else
      rm -rf "$TMPDIR"
      warn "Download failed."
      return 1
    fi
  fi

  # Standard platforms — try nodesource first, then package manager
  case "$PKG_MGR" in
    apt)
      info "Installing Node.js via NodeSource (LTS) …"
      local _ns_setup; _ns_setup=$(safe_mktemp)
      if fetch_url "https://deb.nodesource.com/setup_22.x" > "$_ns_setup" 2>/dev/null; then
        _sudo bash "$_ns_setup" 2>/dev/null
        rm -f "$_ns_setup"
        _sudo apt-get install -y -qq nodejs
      else
        rm -f "$_ns_setup"
        warn "NodeSource setup failed. Trying system package …"
        _sudo apt-get update -qq && _sudo apt-get install -y -qq nodejs npm
      fi
      ;;
    dnf|yum)
      info "Installing Node.js via NodeSource (LTS) …"
      local _ns_setup; _ns_setup=$(safe_mktemp)
      if fetch_url "https://rpm.nodesource.com/setup_22.x" > "$_ns_setup" 2>/dev/null; then
        _sudo bash "$_ns_setup" 2>/dev/null
        rm -f "$_ns_setup"
        _sudo "$PKG_MGR" install -y -q nodejs
      else
        rm -f "$_ns_setup"
        _sudo "$PKG_MGR" install -y -q nodejs npm
      fi
      ;;
    pacman) _sudo pacman -S --noconfirm --quiet nodejs npm ;;
    apk)    _sudo apk add --quiet nodejs npm ;;
    zypper) _sudo zypper install -y nodejs22 npm22 2>/dev/null || _sudo zypper install -y nodejs npm ;;
    brew)   brew install --quiet node ;;
    *)
      warn "No supported package manager found. Install Node.js manually: https://nodejs.org/"
      return 1
      ;;
  esac
}

# Install GitHub CLI
install_gh() {
  case "$PKG_MGR" in
    apt)
      info "Installing GitHub CLI …"
      _sudo mkdir -p /etc/apt/keyrings
      fetch_url "https://cli.github.com/packages/githubcli-archive-keyring.gpg" | _sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | _sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
      _sudo apt-get update -qq && _sudo apt-get install -y -qq gh
      ;;
    dnf|yum)
      _sudo "$PKG_MGR" install -y -q 'dnf-command(config-manager)' 2>/dev/null || true
      _sudo "$PKG_MGR" config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo 2>/dev/null || true
      _sudo "$PKG_MGR" install -y -q gh
      ;;
    pacman) _sudo pacman -S --noconfirm --quiet github-cli ;;
    apk)    _sudo apk add --quiet github-cli ;;
    zypper)
      _sudo zypper addrepo https://cli.github.com/packages/rpm/gh-cli.repo 2>/dev/null || true
      _sudo zypper install -y gh
      ;;
    brew)   brew install --quiet gh ;;
    *)      warn "Install gh CLI manually: https://cli.github.com/"; return 1 ;;
  esac
}

# HTTP fetch helper — prefers curl, falls back to wget
fetch_url() {
  local url="$1"
  local _fu_ef; _fu_ef=$(safe_mktemp)
  if command -v curl >/dev/null 2>&1; then
    if curl -fsSL --max-time 30 "$url" 2>"$_fu_ef"; then
      rm -f "$_fu_ef"; return 0
    fi
    _LAST_ERR=$(_err_line "$(cat "$_fu_ef")")
    [[ -z "$_LAST_ERR" ]] && _LAST_ERR=$(head -1 "$_fu_ef" | cut -c1-120)
    rm -f "$_fu_ef"; return 1
  elif command -v wget >/dev/null 2>&1; then
    if wget -qO- --timeout=30 "$url" 2>"$_fu_ef"; then
      rm -f "$_fu_ef"; return 0
    fi
    _LAST_ERR=$(_err_line "$(cat "$_fu_ef")")
    [[ -z "$_LAST_ERR" ]] && _LAST_ERR=$(head -1 "$_fu_ef" | cut -c1-120)
    rm -f "$_fu_ef"; return 1
  else
    _LAST_ERR="Neither curl nor wget found"
    rm -f "$_fu_ef"; return 1
  fi
}

# HTTP fetch with status code — outputs body to file, returns HTTP code
# Usage: http_code=$(fetch_status "$url" "$outfile" "$headers_string")
fetch_status() {
  local url="$1" outfile="$2" extra_header="${3:-}"
  if command -v curl >/dev/null 2>&1; then
    if [[ -n "$extra_header" ]]; then
      curl -s -o "$outfile" -w "%{http_code}" -H "$extra_header" "$url" --max-time 10 2>/dev/null
    else
      curl -s -o "$outfile" -w "%{http_code}" "$url" --max-time 10 2>/dev/null
    fi
  elif command -v wget >/dev/null 2>&1; then
    local _hdr_file; _hdr_file=$(safe_mktemp)
    local _wget_args=(-q -O "$outfile" -S --timeout=10)
    [[ -n "$extra_header" ]] && _wget_args+=(--header="$extra_header")
    if wget "${_wget_args[@]}" "$url" 2>"$_hdr_file"; then
      grep -o 'HTTP/[0-9.]* [0-9]*' "$_hdr_file" | tail -1 | awk '{print $2}'
    else
      grep -o 'HTTP/[0-9.]* [0-9]*' "$_hdr_file" | tail -1 | awk '{print $2}'
    fi
    rm -f "$_hdr_file"
  else
    echo "000"
  fi
}

# HTTP fetch with headers (for GitHub API) — saves headers and body to separate files
# Usage: http_code=$(fetch_with_headers "$url" "$headers_file" "$body_file" "$auth_header")
fetch_with_headers() {
  local url="$1" headers_file="$2" body_file="$3" auth_header="${4:-}"
  if command -v curl >/dev/null 2>&1; then
    local _curl_args=(-s -D "$headers_file" -o "$body_file" -w "%{http_code}" --max-time 10)
    [[ -n "$auth_header" ]] && _curl_args+=(-H "$auth_header")
    curl "${_curl_args[@]}" "$url" 2>/dev/null
  elif command -v wget >/dev/null 2>&1; then
    local _wget_args=(-q -O "$body_file" -S --timeout=10)
    [[ -n "$auth_header" ]] && _wget_args+=(--header="$auth_header")
    local _tmp_headers; _tmp_headers=$(safe_mktemp)
    if wget "${_wget_args[@]}" "$url" 2>"$_tmp_headers"; then
      grep -v '^$' "$_tmp_headers" > "$headers_file"
      grep -o 'HTTP/[0-9.]* [0-9]*' "$_tmp_headers" | tail -1 | awk '{print $2}'
    else
      grep -v '^$' "$_tmp_headers" > "$headers_file" 2>/dev/null
      grep -o 'HTTP/[0-9.]* [0-9]*' "$_tmp_headers" | tail -1 | awk '{print $2}'
    fi
    rm -f "$_tmp_headers"
  else
    echo "000"
  fi
}

# ── Version & update config ──────────────────────────────────────────────────────
# Global last-error variable for error capture pattern
_LAST_ERR=""

SCRIPT_VERSION="0.0.0-dev"
UPDATE_REPO="epantke/discord-autopilot"
UPDATE_API_URL="https://api.github.com/repos/$UPDATE_REPO/releases/latest"
# ──────────────────────────────────────────────────────────────────────────────
# Load .env if present
# ──────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  # Validate .env is readable and not binary/corrupt
  _env_is_text=false
  if [[ -r "$SCRIPT_DIR/.env" ]]; then
    if command -v file >/dev/null 2>&1 && file "$SCRIPT_DIR/.env" 2>/dev/null | grep -qi 'text\|ascii\|utf'; then
      _env_is_text=true
    elif ! command -v file >/dev/null 2>&1; then
      # No 'file' command — check for NUL bytes as binary indicator
      if ! grep -qP '\x00' "$SCRIPT_DIR/.env" 2>/dev/null && ! tr -d '[:print:][:space:]' < "$SCRIPT_DIR/.env" | grep -q . 2>/dev/null; then
        _env_is_text=true
      fi
    fi
  fi
  if [[ "$_env_is_text" == "true" ]]; then
    set -a
    # shellcheck source=/dev/null
    # Strip \r from CRLF line endings, skip blank/comment-only, filter valid KEY=VALUE lines
    source <(sed 's/\r$//' "$SCRIPT_DIR/.env" | grep -E '^[A-Za-z_][A-Za-z0-9_]*=' || true)
    set +a
  else
    echo -e "  \033[1;33m⚠\033[0m \033[1;33m.env file exists but is not readable or appears corrupt — skipping\033[0m"
  fi
fi

# ── Lockfile — prevent concurrent runs ──────────────────────────────────────
_dir_hash=$(echo "$SCRIPT_DIR" | md5sum 2>/dev/null | cut -d' ' -f1 || md5 -q -s "$SCRIPT_DIR" 2>/dev/null || echo "$SCRIPT_DIR" | cksum | cut -d' ' -f1 || echo 'default')
_LOCKFILE="${TMPDIR:-/tmp}/discord-agent-${_dir_hash}.lock"
if [[ -f "$_LOCKFILE" ]]; then
  _LOCK_PID=$(cat "$_LOCKFILE" 2>/dev/null)
  if [[ -n "$_LOCK_PID" ]] && kill -0 "$_LOCK_PID" 2>/dev/null; then
    echo -e "  \033[0;31m✘ FATAL:\033[0m Another instance is already running (PID $_LOCK_PID)."
    echo -e "  If this is incorrect, delete: $_LOCKFILE"
    exit 1
  fi
fi
# Atomic lockfile creation — avoids TOCTOU race
if ! ( set -o noclobber; echo $$ > "$_LOCKFILE" ) 2>/dev/null; then
  # File appeared between check and create — re-check PID
  _LOCK_PID=$(cat "$_LOCKFILE" 2>/dev/null)
  if [[ -n "$_LOCK_PID" ]] && kill -0 "$_LOCK_PID" 2>/dev/null; then
    echo -e "  \033[0;31m✘ FATAL:\033[0m Another instance is already running (PID $_LOCK_PID)."
    echo -e "  If this is incorrect, delete: $_LOCKFILE"
    exit 1
  fi
  # Stale lock — overwrite
  echo $$ > "$_LOCKFILE"
fi

# ── Handle --update flag ────────────────────────────────────────────────────────
if [[ "${1:-}" == "--update" || "${1:-}" == "-u" ]]; then
  if [[ "$SCRIPT_VERSION" == "0.0.0-dev" ]]; then
    info "Running from source — use 'git pull' to update instead."
    exit 0
  fi

  info "Current version: v$SCRIPT_VERSION"
  info "Checking for updates…"

  RELEASE_DATA=$(fetch_url "$UPDATE_API_URL" 2>/dev/null) || die "Failed to fetch release info." "${_LAST_ERR:-network error or API unreachable}"

  LATEST_VER=$(echo "$RELEASE_DATA" | node -e "
    process.stdout.write((JSON.parse(require('fs').readFileSync(0,'utf8')).tag_name||'').replace(/^v/,''))
  " 2>/dev/null) || die "Failed to parse release data."

  [[ -z "$LATEST_VER" ]] && die "Could not determine latest version."

  if [[ "$LATEST_VER" == "$SCRIPT_VERSION" ]]; then
    ok "Already on latest version (v$SCRIPT_VERSION)"
    exit 0
  fi

  HIGHEST=$(printf '%s\n%s' "$LATEST_VER" "$SCRIPT_VERSION" | sort -V 2>/dev/null | tail -1)
  # Fallback for systems without sort -V (e.g. macOS)
  if [[ -z "$HIGHEST" ]]; then
    _ver_ge "$LATEST_VER" "$SCRIPT_VERSION" && HIGHEST="$LATEST_VER" || HIGHEST="$SCRIPT_VERSION"
  fi
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
  TMPFILE=$(safe_mktemp)

  fetch_url "$DOWNLOAD_URL" > "$TMPFILE" 2>/dev/null || die "Download failed." "${_LAST_ERR:-network error}"

  if ! head -1 "$TMPFILE" | grep -q "#!/usr/bin/env bash"; then
    _first=$(head -c 80 "$TMPFILE" | tr -d '\n')
    die "Downloaded file is not a valid bash script." "Got: ${_first:0:60}"
  fi

  SELF_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
  cp "$SELF_PATH" "${SELF_PATH}.bak"
  mv "$TMPFILE" "$SELF_PATH"
  chmod +x "$SELF_PATH"

  echo ""
  ok "Updated to v$LATEST_VER!"
  ok "Backup saved as $(basename "${SELF_PATH}.bak")"
  info "Restart the script to use the new version."
  echo ""
  exit 0
fi

# ── Banner ───────────────────────────────────────────────────────────────────
echo ""
echo -e "   ${MAGENTA}___  _                       _${NC}"
echo -e "  ${MAGENTA}|   \\(_)___ __ ___ _ _ __| |${NC}"
echo -e "  ${MAGENTA}| |) | (_-</ _/ _ \\ '_/ _\` |${NC}"
echo -e "  ${MAGENTA}|___/|_/__/\\__\\___/_| \\__,_|${NC}"
echo -e "         ${DGRAY}×${NC} ${CYAN}C o p i l o t${NC}"
echo ""
echo -e "    ${DGRAY}$(printf '═%.0s' $(seq 1 46))${NC}"
echo -e "    ${DGRAY}Discord Autopilot${NC}   ${CYAN}v${SCRIPT_VERSION}${NC}"
echo -e "    ${DGRAY}$(printf '═%.0s' $(seq 1 46))${NC}"

# Quick update check (non-blocking, 3s timeout)
if [[ "$SCRIPT_VERSION" != "0.0.0-dev" ]] && command -v node >/dev/null 2>&1; then
  _UPDATE_JSON=$(fetch_url "$UPDATE_API_URL" 2>/dev/null || true)
  if [[ -n "$_UPDATE_JSON" ]]; then
    _LATEST_VER=$(echo "$_UPDATE_JSON" | node -e "
      process.stdout.write((JSON.parse(require('fs').readFileSync(0,'utf8')).tag_name||'').replace(/^v/,''))
    " 2>/dev/null || true)
    if [[ -n "$_LATEST_VER" && "$_LATEST_VER" != "$SCRIPT_VERSION" ]]; then
      _HIGHEST=$(printf '%s\n%s' "$_LATEST_VER" "$SCRIPT_VERSION" | sort -V 2>/dev/null | tail -1)
      # Fallback for systems without sort -V (e.g. macOS)
      if [[ -z "$_HIGHEST" ]]; then
        _ver_ge "$_LATEST_VER" "$SCRIPT_VERSION" && _HIGHEST="$_LATEST_VER" || _HIGHEST="$SCRIPT_VERSION"
      fi
      if [[ "$_HIGHEST" == "$_LATEST_VER" ]]; then
        echo ""
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
# 1) Configuration — Setup Wizard
# ──────────────────────────────────────────────────────────────────────────────
ENV_CHANGED=false
ENV_FILE="$SCRIPT_DIR/.env"

NEED_SETUP=false
[[ -z "${DISCORD_TOKEN:-}" ]] && NEED_SETUP=true
[[ -z "${REPO_URL:-}" ]] && NEED_SETUP=true

if [[ "$NEED_SETUP" == "true" ]]; then
  write_step 1 8 "Configuration"
  echo -e "  ${DGRAY}Some required settings are missing. Let's configure them.${NC}"
  echo -e "  ${DGRAY}Values from ${CYAN}.env${DGRAY} and environment variables are used automatically.${NC}"
else
  write_step 1 8 "Configuration"
  ok "All values loaded (DISCORD_TOKEN, REPO_URL)"
fi

# ── DISCORD_TOKEN ──
if [[ -z "${DISCORD_TOKEN:-}" ]]; then
  if [[ ! -t 0 ]]; then
    die "DISCORD_TOKEN is not set and stdin is not a terminal (non-interactive)." "export DISCORD_TOKEN=\"your-token\" or create a .env file next to this script."
  fi
  echo ""
  echo -e "  ${BLACK}${BG_DCYAN} DISCORD_TOKEN ${NC} ${DGRAY}(required)${NC}"
  echo ""
  echo -e "  ${GRAY}How to get your token:${NC}"
  echo -e "    ${DGRAY}1. Go to ${CYAN}https://discord.com/developers/applications${NC}"
  echo -e "    ${DGRAY}2. Click ${WHITE}New Application${DGRAY} (or select existing)${NC}"
    echo -e "    ${DGRAY}3. Go to ${WHITE}Bot${DGRAY} tab → ${WHITE}Reset Token${DGRAY} → copy it${NC}"
  echo -e "    ${DGRAY}4. Under ${WHITE}Privileged Gateway Intents${DGRAY}: enable ${YELLOW}Message Content${NC}"
  echo -e "    ${DGRAY}5. Under ${WHITE}OAuth2 > URL Generator${DGRAY}:${NC}"
  echo -e "       ${DGRAY}Scopes: ${WHITE}bot, applications.commands${NC}"
  echo -e "       ${DGRAY}Permissions: ${WHITE}Send Messages, Embed Links, Attach Files, Use Slash Commands${NC}"
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
    die "REPO_URL is not set and stdin is not a terminal (non-interactive)." "export REPO_URL=\"https://github.com/owner/repo.git\" or add to .env"
  fi
  echo ""
  echo -e "  ${BLACK}${BG_DCYAN} REPO_URL ${NC} ${DGRAY}(required)${NC}"
  echo ""
  echo -e "  ${GRAY}The Git repository the agent will work on.${NC}"
  echo -e "  ${DGRAY}HTTPS example: ${CYAN}https://github.com/owner/repo.git${NC}"
  echo -e "  ${DGRAY}SSH example:   ${CYAN}git@github.com:owner/repo.git${NC}"
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
if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  if [[ -t 0 ]]; then
    echo ""
    echo -e "  ${BLACK}${BG_DGRAY} GITHUB_TOKEN ${NC} ${DGRAY}(optional)${NC}"
    echo ""
    echo -e "  ${GRAY}Needed for private repos, pushing, and creating PRs.${NC}"
    echo -e "  ${DGRAY}Create a fine-grained PAT: ${CYAN}https://github.com/settings/personal-access-tokens/new${NC}"
    echo -e "  ${DGRAY}Repository access: ${WHITE}Only select repositories${DGRAY} (pick your target repo)${NC}"
    echo -e "  ${DGRAY}Required permissions: ${WHITE}Contents (read/write)${DGRAY}, ${WHITE}Pull requests (read/write)${NC}"
    echo -e "  ${DGRAY}Press ${YELLOW}Enter${DGRAY} to skip.${NC}"
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
else
  ok "GITHUB_TOKEN found"
fi

# ── ADMIN_USER_ID (optional) ──
if [[ -z "${ADMIN_USER_ID:-}" ]]; then
  if [[ -t 0 ]]; then
    echo ""
    echo -e "  ${BLACK}${BG_DGRAY} ADMIN_USER_ID ${NC} ${DGRAY}(optional)${NC}"
    echo ""
    echo -e "  ${GRAY}Your Discord User ID — the bot will DM you on startup/shutdown.${NC}"
    echo -e "  ${GRAY}How to find it:${NC}"
    echo -e "    ${DGRAY}1. Open Discord → ${WHITE}User Settings (gear icon at bottom left)${NC}"
    echo -e "    ${DGRAY}2. Go to ${WHITE}App Settings > Advanced${DGRAY} → enable ${YELLOW}Developer Mode${NC}"
    echo -e "    ${DGRAY}3. Go to ${WHITE}My Account${DGRAY} → click the ${WHITE}...${DGRAY} (three dots) next to your username${NC}"
    echo -e "    ${DGRAY}4. Click ${WHITE}Copy User ID${NC}"
    echo -e "  ${DGRAY}Press ${YELLOW}Enter${DGRAY} to skip.${NC}"
    echo ""
    read -rp "  ▸ Admin User ID (or Enter to skip): " _admin_id
    if [[ -n "$_admin_id" ]]; then
      if [[ "$_admin_id" =~ ^[0-9]{17,20}$ ]]; then
        export ADMIN_USER_ID="$_admin_id"
        ENV_CHANGED=true
        ok "ADMIN_USER_ID set"
      else
        warn "'$_admin_id' is not a valid Discord User ID (must be 17-20 digits)."
        warn "  That looks like a username. Discord IDs are long numbers like 123456789012345678."
        warn "  To find yours: Settings (gear icon) > App Settings > Advanced > Developer Mode ON"
        warn "  Then: Settings > My Account > click ... next to your username > Copy User ID"
        echo ""
        read -rp "  ▸ Enter numeric User ID (or Enter to skip): " _retry_id
        if [[ -n "$_retry_id" ]] && [[ "$_retry_id" =~ ^[0-9]{17,20}$ ]]; then
          export ADMIN_USER_ID="$_retry_id"
          ENV_CHANGED=true
          ok "ADMIN_USER_ID set"
        elif [[ -n "$_retry_id" ]]; then
          warn "'$_retry_id' is still not a valid snowflake ID. Skipping ADMIN_USER_ID."
        else
          info "ADMIN_USER_ID skipped"
        fi
      fi
    else
      info "ADMIN_USER_ID skipped"
    fi
  fi
else
  # Validate existing value from .env
  if [[ ! "${ADMIN_USER_ID}" =~ ^[0-9]{17,20}$ ]]; then
    warn "ADMIN_USER_ID '${ADMIN_USER_ID}' is not a valid snowflake (must be 17-20 digits). Ignoring."
    export ADMIN_USER_ID=""
  else
    ok "ADMIN_USER_ID found (${ADMIN_USER_ID})"
  fi
fi

# ── STARTUP_CHANNEL_ID (optional) ──
if [[ -z "${STARTUP_CHANNEL_ID:-}" ]]; then
  if [[ -t 0 ]]; then
    echo ""
    echo -e "  ${BLACK}${BG_DGRAY} STARTUP_CHANNEL_ID ${NC} ${DGRAY}(optional)${NC}"
    echo ""
    echo -e "  ${GRAY}Channel for bot online/offline notifications.${NC}"
    echo -e "  ${DGRAY}Right-click any text channel → ${WHITE}Copy Channel ID${NC}"
    echo -e "  ${DGRAY}Press ${YELLOW}Enter${DGRAY} to skip (bot uses first available channel).${NC}"
    echo ""
    read -rp "  ▸ Startup Channel ID (or Enter to skip): " _startup_ch
    if [[ -n "$_startup_ch" ]]; then
      if [[ "$_startup_ch" =~ ^[0-9]{17,20}$ ]]; then
        export STARTUP_CHANNEL_ID="$_startup_ch"
        ENV_CHANGED=true
        ok "STARTUP_CHANNEL_ID set"
      else
        warn "'$_startup_ch' is not a valid Discord Channel ID (must be 17-20 digits)."
        warn "  Right-click a text channel in Discord > Copy Channel ID"
        echo ""
        read -rp "  ▸ Enter numeric Channel ID (or Enter to skip): " _retry_ch
        if [[ -n "$_retry_ch" ]] && [[ "$_retry_ch" =~ ^[0-9]{17,20}$ ]]; then
          export STARTUP_CHANNEL_ID="$_retry_ch"
          ENV_CHANGED=true
          ok "STARTUP_CHANNEL_ID set"
        elif [[ -n "$_retry_ch" ]]; then
          warn "'$_retry_ch' is still not a valid snowflake ID. Skipping."
        else
          info "STARTUP_CHANNEL_ID skipped"
        fi
      fi
    else
      info "STARTUP_CHANNEL_ID skipped"
    fi
  fi
else
  # Validate existing value from .env
  if [[ ! "${STARTUP_CHANNEL_ID}" =~ ^[0-9]{17,20}$ ]]; then
    warn "STARTUP_CHANNEL_ID '${STARTUP_CHANNEL_ID}' is not a valid snowflake (must be 17-20 digits). Ignoring."
    export STARTUP_CHANNEL_ID=""
  else
    ok "STARTUP_CHANNEL_ID found (${STARTUP_CHANNEL_ID})"
  fi
fi

# ── Offer to save .env ──
if [[ "$ENV_CHANGED" == "true" ]] && [[ -t 0 ]]; then
  echo ""
  echo -e "  ${BLACK}${BG_DYELLOW} SAVE ${NC}"
  echo -e "  ${DGRAY}Save these values to ${CYAN}$ENV_FILE${DGRAY}?${NC}"
  echo -e "  ${DGRAY}So you don't have to enter them again next time.${NC}"
  echo ""
  read -rp "  ▸ Save to .env? [Y/n] " _save_answer
  if [[ -z "$_save_answer" || "$_save_answer" =~ ^[yYjJ] ]]; then
    # Read existing .env BEFORE truncating so we can preserve extra keys
    _existing_env=""
    if [[ -f "$ENV_FILE" ]]; then
      _existing_env=$(cat "$ENV_FILE")
    fi
    {
      echo "# Discord x Copilot Agent - auto-generated $(date +%Y-%m-%d)"
      echo "DISCORD_TOKEN=$DISCORD_TOKEN"
      echo "REPO_URL=$REPO_URL"
      [[ -n "${GITHUB_TOKEN:-}" ]]      && echo "GITHUB_TOKEN=$GITHUB_TOKEN"
      [[ -n "${DEFAULT_BRANCH:-}" ]]     && echo "DEFAULT_BRANCH=$DEFAULT_BRANCH"
      [[ -n "${ADMIN_USER_ID:-}" ]]      && echo "ADMIN_USER_ID=$ADMIN_USER_ID"
      [[ -n "${STARTUP_CHANNEL_ID:-}" ]] && echo "STARTUP_CHANNEL_ID=$STARTUP_CHANNEL_ID"
      # preserve extra keys from existing .env
      if [[ -n "$_existing_env" ]]; then
        while IFS= read -r line; do
          key="${line%%=*}"
          key="${key// /}"
          case "$key" in
            DISCORD_TOKEN|REPO_URL|GITHUB_TOKEN|DEFAULT_BRANCH|ADMIN_USER_ID|STARTUP_CHANNEL_ID|""|"#"*) ;;
            *) echo "$line" ;;
          esac
        done <<< "$_existing_env"
      fi
    } > "$ENV_FILE"
    _val_count=$(grep -c '=' "$ENV_FILE")
    ok ".env saved ($_val_count values)"
  else
    info ".env not saved"
  fi
fi

echo ""

# ──────────────────────────────────────────────────────────────────────────────
# 2) Prerequisite checks
# ──────────────────────────────────────────────────────────────────────────────

write_step 2 8 "Prerequisites"

# Show platform info
box_top 50
write_check "Platform"  "$OS_KERNEL $ARCH" "true"
write_check "Distro"    "$DISTRO_NAME"     "true"
write_check "Pkg Mgr"   "${PKG_MGR:-none detected}" "$( [[ -n "$PKG_MGR" ]] && echo true || echo false )"
box_bottom 50

# ARMv6 early warning
if [[ "$ARCH" == "armv6l" ]]; then
  echo ""
  warn "ARMv6 detected (e.g. Raspberry Pi Zero)."
  warn "Official Node.js 18+ builds are NOT available for this architecture."
  warn "The installer will attempt to use unofficial builds if needed."
fi

# ── Check & auto-install prerequisites ──
_check_and_install() {
  local tool="$1"
  if command -v "$tool" >/dev/null 2>&1; then return 0; fi

  if [[ -z "$PKG_MGR" ]]; then return 1; fi
  if [[ ! -t 0 ]]; then return 1; fi  # non-interactive

  echo ""
  echo -e "  ${YELLOW}${tool}${NC} is not installed."
  read -rp "  ▸ Install ${tool} automatically? [Y/n] " _answer
  if [[ -z "$_answer" || "$_answer" =~ ^[yYjJ] ]]; then
    case "$tool" in
      git)     pkg_install git ;;
      node)    install_node ;;
      npm)     install_node ;;  # npm comes with node
      gh)      install_gh ;;
      curl)    pkg_install curl ;;
      *)       return 1 ;;
    esac
    # Rehash PATH so new binaries are found
    hash -r 2>/dev/null || true
    if command -v "$tool" >/dev/null 2>&1; then
      ok "${tool} installed successfully"
      return 0
    else
      warn "${tool} install failed — binary not found in PATH after install."
      [[ -n "${_LAST_ERR:-}" ]] && warn "  ${_LAST_ERR}"
      return 1
    fi
  else
    return 1
  fi
}

# Ensure curl or wget is available (needed for validation & update checks)
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  _check_and_install curl || true
fi

HAS_GIT=false;  command -v git  >/dev/null 2>&1 && HAS_GIT=true
HAS_NODE=false; command -v node >/dev/null 2>&1 && HAS_NODE=true
HAS_NPM=false;  command -v npm  >/dev/null 2>&1 && HAS_NPM=true

# Auto-install if missing and interactive
MISSING=()
if [[ "$HAS_GIT" == "false" ]]; then
  _check_and_install git && HAS_GIT=true || MISSING+=("git")
fi
if [[ "$HAS_NODE" == "false" ]]; then
  _check_and_install node && { HAS_NODE=true; HAS_NPM=true; } || MISSING+=("node")
fi
if [[ "$HAS_NODE" == "true" && "$HAS_NPM" == "false" ]]; then
  command -v npm >/dev/null 2>&1 && HAS_NPM=true || MISSING+=("npm")
fi

# Copilot CLI: accept 'copilot' binary OR 'gh copilot' extension
COPILOT_CMD=""
if command -v copilot >/dev/null 2>&1; then
  COPILOT_CMD="copilot"
elif command -v gh >/dev/null 2>&1 && gh copilot --help >/dev/null 2>&1; then
  COPILOT_CMD="gh copilot"
else
  # Try installing gh first, then the copilot extension
  if ! command -v gh >/dev/null 2>&1; then
    _check_and_install gh || true
  fi
  if command -v gh >/dev/null 2>&1; then
    if ! gh copilot --help >/dev/null 2>&1; then
      if [[ -t 0 ]]; then
        echo ""
        echo -e "  ${YELLOW}gh copilot${NC} extension is not installed."
        read -rp "  ▸ Install gh copilot extension? [Y/n] " _cop_answer
        if [[ -z "$_cop_answer" || "$_cop_answer" =~ ^[yYjJ] ]]; then
          gh extension install github/gh-copilot 2>/dev/null && COPILOT_CMD="gh copilot"
        fi
      fi
    else
      COPILOT_CMD="gh copilot"
    fi
  fi
  [[ -z "$COPILOT_CMD" ]] && MISSING+=("copilot")
fi

# Collect version strings
GIT_VER="not found";  [[ "$HAS_GIT" == "true" ]]  && GIT_VER=$(git --version | sed 's/git version //')
NODE_VER="not found";  [[ "$HAS_NODE" == "true" ]] && NODE_VER=$(node -v)
NPM_VER="not found";   [[ "$HAS_NPM" == "true" ]]  && NPM_VER=$(npm -v)
COP_VER="not found";   [[ -n "$COPILOT_CMD" ]]      && COP_VER="$COPILOT_CMD"

# Display version table
echo ""
box_top 40
write_check "git"     "$GIT_VER"  "$HAS_GIT"
write_check "node"    "$NODE_VER" "$HAS_NODE"
write_check "npm"     "$NPM_VER"  "$HAS_NPM"
write_check "copilot" "$COP_VER"  "$( [[ -n "$COPILOT_CMD" ]] && echo true || echo false )"
box_bottom 40

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo ""
  echo -e "  ${BLACK}${BG_RED} MISSING TOOLS ${NC}"
  echo ""

  for tool in "${MISSING[@]}"; do
    _tool_url=""; _tool_hint=""
    case "$tool" in
      git)     _tool_url="https://git-scm.com/downloads";
               _tool_hint="sudo apt install git  /  sudo dnf install git  /  brew install git" ;;
      node)    _tool_url="https://nodejs.org/";
               _tool_hint="Install LTS version (>= 18). npm is included." ;;
      npm)     _tool_url="https://nodejs.org/";
               _tool_hint="Comes bundled with Node.js." ;;
      copilot) _tool_url="https://github.com/github/gh-copilot";
               _tool_hint="Install gh CLI first, then: gh extension install github/gh-copilot" ;;
    esac
    echo -e "    ${RED}✘${NC} ${WHITE}${tool}${NC}"
    echo -e "      ${CYAN}${_tool_url}${NC}"
    echo -e "      ${DGRAY}${_tool_hint}${NC}"
    echo ""
  done
  echo -e "  ${YELLOW}Install the missing tools, then re-run this script.${NC}"
  echo ""
  exit 1
fi

# Node version check (>= 18)
NODE_MAJOR=$(node -e "process.stdout.write(String(process.versions.node.split('.')[0]))")
if [[ "$NODE_MAJOR" -lt 18 ]]; then
  warn "Node.js >= 18 required (found $(node -v))."
  if [[ -n "$PKG_MGR" && -t 0 ]]; then
    read -rp "  ▸ Upgrade Node.js automatically? [Y/n] " _upgrade_answer
    if [[ -z "$_upgrade_answer" || "$_upgrade_answer" =~ ^[yYjJ] ]]; then
      install_node
      hash -r 2>/dev/null || true
      if command -v node >/dev/null 2>&1; then
        NODE_MAJOR=$(node -e "process.stdout.write(String(process.versions.node.split('.')[0]))")
      fi
    fi
  fi
  if [[ "$NODE_MAJOR" -lt 18 ]]; then
    die "Node.js >= 18 required (found $(node -v)). Update: https://nodejs.org/"
  fi
  ok "Node.js upgraded to $(node -v)"
fi
ok "All prerequisites satisfied"

# Copilot auth check
if [[ -n "$COPILOT_CMD" ]]; then
  if ! $COPILOT_CMD auth status >/dev/null 2>&1; then
    warn "copilot auth not configured. Attempting to continue…"
    warn "If it fails, run:  $COPILOT_CMD auth login"
  fi
fi

# ──────────────────────────────────────────────────────────────────────────────
# 3) Credential & access validation
# ──────────────────────────────────────────────────────────────────────────────

write_step 3 8 "Validation"

VALIDATION_FAILED=false
HAS_HTTP=false
(command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1) && HAS_HTTP=true

box_top 44

# Discord token validation
if [[ "$HAS_HTTP" == "true" ]]; then
  DISCORD_CHECK=$(safe_mktemp)
  DISCORD_HTTP=$(fetch_status "https://discord.com/api/v10/users/@me" "$DISCORD_CHECK" "Authorization: Bot $DISCORD_TOKEN")
  if [[ "$DISCORD_HTTP" == "200" ]]; then
    DISCORD_USER=$(grep -o '"username":"[^"]*"' "$DISCORD_CHECK" | head -1 | cut -d'"' -f4)
    DISCORD_DISC=$(grep -o '"discriminator":"[^"]*"' "$DISCORD_CHECK" | head -1 | cut -d'"' -f4)
    if [[ -n "$DISCORD_DISC" && "$DISCORD_DISC" != "0" ]]; then
      DISCORD_USER="${DISCORD_USER}#${DISCORD_DISC}"
    fi
    write_check "Discord Bot" "$DISCORD_USER" "true"

    # Check if bot is in any guilds
    DISCORD_GUILDS=$(safe_mktemp)
    GUILDS_HTTP=$(fetch_status "https://discord.com/api/v10/users/@me/guilds?limit=1" "$DISCORD_GUILDS" "Authorization: Bot $DISCORD_TOKEN")
    if [[ "$GUILDS_HTTP" == "200" ]]; then
      GUILD_COUNT=$(grep -o '"id"' "$DISCORD_GUILDS" | wc -l)
      if [[ "$GUILD_COUNT" -gt 0 ]]; then
        write_check "Bot Guilds" "in at least 1 server" "true"
      else
        write_check "Bot Guilds" "not in any server yet" "false"
        warn "  Invite the bot first: Developer Portal > OAuth2 > URL Generator"
        warn "  Scopes: bot, applications.commands"
      fi
    else
      write_check "Bot Guilds" "could not check" "false"
    fi
    rm -f "$DISCORD_GUILDS"

  elif [[ "$DISCORD_HTTP" == "401" ]]; then
    VALIDATION_FAILED=true
    write_check "Discord Bot" "Invalid token (401 Unauthorized)" "false"
  else
    _disc_msg="API unreachable (HTTP $DISCORD_HTTP)"
    write_check "Discord Bot" "$_disc_msg" "false"
    warn "  Network issue? Bot may still work if the API is temporarily down."
  fi
  rm -f "$DISCORD_CHECK"
else
  write_check "Discord Bot" "no HTTP client — skipped" "false"
fi

# GitHub token validation (if set)
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  if [[ "$HAS_HTTP" == "true" ]]; then
    # Detect token type
    GH_TOKEN_TYPE="unknown"
    case "$GITHUB_TOKEN" in
      ghp_*)         GH_TOKEN_TYPE="PAT (classic)" ;;
      github_pat_*)  GH_TOKEN_TYPE="PAT (fine-grained)" ;;
      gho_*)         GH_TOKEN_TYPE="OAuth" ;;
      ghu_*)         GH_TOKEN_TYPE="User-to-server" ;;
      ghs_*)         GH_TOKEN_TYPE="Server-to-server" ;;
    esac

    GH_HEADERS_FILE=$(safe_mktemp)
    GH_BODY_FILE=$(safe_mktemp)
    GH_HTTP=$(fetch_with_headers "https://api.github.com/user" "$GH_HEADERS_FILE" "$GH_BODY_FILE" "Authorization: token $GITHUB_TOKEN")

    if [[ "$GH_HTTP" == "200" ]]; then
      GH_USER=$(grep -o '"login":"[^"]*"' "$GH_BODY_FILE" | head -1 | cut -d'"' -f4)
      write_check "GitHub User" "$GH_USER ($GH_TOKEN_TYPE)" "true"

      # Rate limit
      RATE_REMAIN=$(grep -i '^x-ratelimit-remaining:' "$GH_HEADERS_FILE" | tr -d '\r' | awk '{print $2}')
      RATE_LIMIT=$(grep -i '^x-ratelimit-limit:' "$GH_HEADERS_FILE" | tr -d '\r' | awk '{print $2}')
      if [[ -n "$RATE_REMAIN" && -n "$RATE_LIMIT" ]]; then
        if [[ "$RATE_REMAIN" -gt 100 ]]; then
          write_check "Rate Limit" "$RATE_REMAIN/$RATE_LIMIT remaining" "true"
        else
          write_check "Rate Limit" "$RATE_REMAIN/$RATE_LIMIT remaining" "false"
          warn "  Rate limit is low. Consider waiting or using a different token."
        fi
      fi

      # Scope checks
      GH_SCOPES=$(grep -i '^x-oauth-scopes:' "$GH_HEADERS_FILE" | cut -d: -f2- | tr -d '\r' | xargs)

      if [[ -n "$GH_SCOPES" ]]; then
        # Classic PAT
        if echo "$GH_SCOPES" | grep -qw "repo"; then
          write_check "Scope: repo" "granted (clone, push, PRs)" "true"
        else
          write_check "Scope: repo" "MISSING" "false"
          warn "  Required for private repos, pushing, and creating PRs."
        fi

        if echo "$GH_SCOPES" | grep -qw "workflow"; then
          write_check "Scope: workflow" "granted" "true"
        else
          write_check "Scope: workflow" "not set (optional)" "true"
          info "  Needed only if the agent modifies .github/workflows/ files."
        fi

        if echo "$GH_SCOPES" | grep -qw "copilot"; then
          write_check "Scope: copilot" "granted" "true"
        else
          write_check "Scope: copilot" "not set (optional)" "true"
          info "  The Copilot SDK uses \`gh auth\` credentials, not the PAT."
          info "  Ensure \`gh auth login\` has been run on this machine."
        fi

        if ! echo "$GH_SCOPES" | grep -qw "repo"; then
          warn "  Current scopes: $GH_SCOPES"
        fi
      else
        write_check "Scopes" "n/a (fine-grained PAT)" "true"
        info "  Ensure token has: Contents (read/write) + Pull requests (read/write)"
        info "  and access to the target repository."
      fi

      # Check access to the specific repo
      _REPO_PATH=$(echo "$REPO_URL" | sed 's/\.git$//' | sed 's|^https\?://github\.com/||' | sed 's|^git@github\.com:||')
      if [[ "$_REPO_PATH" =~ ^[^/]+/[^/]+$ ]]; then
        GH_REPO_FILE=$(safe_mktemp)
        REPO_HTTP=$(fetch_status "https://api.github.com/repos/$_REPO_PATH" "$GH_REPO_FILE" "Authorization: token $GITHUB_TOKEN")
        if [[ "$REPO_HTTP" == "200" ]]; then
          CAN_PUSH=$(grep -o '"push":[a-z]*' "$GH_REPO_FILE" | head -1 | grep -o 'true\|false')
          CAN_PULL=$(grep -o '"pull":[a-z]*' "$GH_REPO_FILE" | head -1 | grep -o 'true\|false')
          CAN_ADMIN=$(grep -o '"admin":[a-z]*' "$GH_REPO_FILE" | head -1 | grep -o 'true\|false')
          PERMS_LIST=()
          [[ "$CAN_PUSH" == "true" ]]  && PERMS_LIST+=("push")
          [[ "$CAN_PULL" == "true" ]]  && PERMS_LIST+=("pull")
          [[ "$CAN_ADMIN" == "true" ]] && PERMS_LIST+=("admin")
          PERMS=$(IFS=', '; echo "${PERMS_LIST[*]}")
          write_check "Repo Perms" "$_REPO_PATH ($PERMS)" "$CAN_PUSH"
          if [[ "$CAN_PUSH" != "true" ]]; then
            warn "  Token can read the repo but cannot push. Agent needs push access."
          fi
        elif [[ "$REPO_HTTP" == "404" ]]; then
          write_check "Token→Repo" "$_REPO_PATH (not found or no access)" "false"
          warn "  Token cannot see this repo. Check repo name and token permissions."
        elif [[ "$REPO_HTTP" == "403" ]]; then
          write_check "Token→Repo" "$_REPO_PATH (forbidden)" "false"
          warn "  Token is valid but not authorized for this repository."
        else
          write_check "Token→Repo" "$_REPO_PATH (could not check)" "false"
        fi
        rm -f "$GH_REPO_FILE"
      fi

    elif [[ "$GH_HTTP" == "401" ]]; then
      write_check "GitHub Token" "Invalid token (401 Unauthorized)" "false"
      warn "  Create a new token: https://github.com/settings/tokens"
      VALIDATION_FAILED=true
    else
      _gh_err="API error (HTTP $GH_HTTP)"
      write_check "GitHub Token" "$_gh_err" "false"
      warn "  Network issue? Continuing without validation."
    fi
    rm -f "$GH_HEADERS_FILE" "$GH_BODY_FILE"
  fi
else
  write_check "GitHub Token" "not set (optional)" "true"
fi

# Repo URL accessibility
if _ls_err=$(git ls-remote --exit-code "$REPO_URL" HEAD 2>&1); then
  write_check "Git Access" "reachable" "true"
else
  _ls_msg=$(echo "$_ls_err" | head -1 | cut -c1-60)
  [[ ${#_ls_msg} -ge 60 ]] && _ls_msg="${_ls_msg:0:57}..."
  write_check "Git Access" "unreachable (${_ls_msg})" "false"
  warn "  Check URL, SSH keys, or network. Clone step may fail."
fi

# GitHub CLI auth (required for Copilot SDK)
if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    write_check "gh auth" "authenticated" "true"
  else
    write_check "gh auth" "not authenticated" "false"
    warn "  The Copilot SDK requires \`gh auth login\`. Run it before starting the bot."
    VALIDATION_FAILED=true
  fi
else
  write_check "gh CLI" "not installed" "false"
  warn "  The Copilot SDK requires GitHub CLI (\`gh\`). Install it: https://cli.github.com/"
  VALIDATION_FAILED=true
fi

box_bottom 44

if [[ "$VALIDATION_FAILED" == "true" ]]; then
  echo ""
  echo -e "  ${BLACK}${BG_RED} VALIDATION FAILED ${NC}"
  echo ""
  echo -e "  ${YELLOW}Fix the issues above and re-run the script.${NC}"
  echo -e "  ${DGRAY}Discord token: ${CYAN}https://discord.com/developers/applications${NC}"
  echo -e "  ${DGRAY}GitHub token:  ${CYAN}https://github.com/settings/tokens${NC}"
  echo ""
  exit 1
else
  ok "All credentials validated"
fi

# ──────────────────────────────────────────────────────────────────────────────
# 4) Derive project name & paths
# ──────────────────────────────────────────────────────────────────────────────

write_step 4 8 "Paths"

PROJECT_NAME=$(basename "$REPO_URL" .git)
PROJECT_NAME=${PROJECT_NAME##*/}  # strip any remaining slashes

BASE="${BASE_ROOT:-$HOME/.local/share/discord-agent}"
REPOS="$BASE/repos"
APP="$BASE/app"
WORKSPACES="${WORKSPACES_ROOT:-$BASE/workspaces}"
REPO_DIR="$REPOS/$PROJECT_NAME"

box_top 50
echo -e "       ${DGRAY}│${NC} ${CYAN}$(printf '%-14s' "Project:")${NC}${WHITE}${PROJECT_NAME}${NC}"
echo -e "       ${DGRAY}│${NC} ${CYAN}$(printf '%-14s' "Base:")${NC}${WHITE}${BASE}${NC}"
echo -e "       ${DGRAY}│${NC} ${CYAN}$(printf '%-14s' "Repo:")${NC}${WHITE}${REPO_DIR}${NC}"
echo -e "       ${DGRAY}│${NC} ${CYAN}$(printf '%-14s' "App:")${NC}${WHITE}${APP}${NC}"
echo -e "       ${DGRAY}│${NC} ${CYAN}$(printf '%-14s' "Workspaces:")${NC}${WHITE}${WORKSPACES}${NC}"
box_bottom 50

mkdir -p "$REPOS" "$APP/src" "$WORKSPACES" || die "Cannot create directories." "Check permissions on $(dirname "$BASE")"

# Disk space check — warn if < 500 MB available
_avail_kb=$(df -Pk "$BASE" 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)
if [[ "$_avail_kb" -gt 0 && "$_avail_kb" -lt 512000 ]]; then
  _avail_mb=$(( _avail_kb / 1024 ))
  warn "Low disk space: ${_avail_mb} MB available on $(df -Pk "$BASE" | awk 'NR==2 {print $6}')"
  warn "  At least 500 MB recommended for npm install and worktrees."
  if [[ -t 0 ]]; then
    read -rp "  ▸ Continue anyway? [y/N] " _disk_answer
    [[ "$_disk_answer" =~ ^[yYjJ] ]] || die "Aborting due to low disk space."
  fi
fi

# ──────────────────────────────────────────────────────────────────────────────
# 5) Clone or update repo
# ──────────────────────────────────────────────────────────────────────────────

write_step 5 8 "Repository"

if [[ -d "$REPO_DIR/.git" ]]; then
  info "Updating existing repo…"
  _fetch_out=$(git -C "$REPO_DIR" fetch --all --prune 2>&1) || {
    _msg=$(_err_line "$_fetch_out")
    warn "fetch failed: ${_msg:-unknown}"
  }
  _pull_out=$(git -C "$REPO_DIR" pull --ff-only 2>&1) || {
    _msg=$(_err_line "$_pull_out")
    warn "pull failed: ${_msg:-diverged? — using existing state}"
  }
  ok "Repo updated"
else
  info "Cloning $REPO_URL …"
  _clone_err=""
  if ! _clone_err=$(git clone "$REPO_URL" "$REPO_DIR" 2>&1); then
    _msg=$(_err_line "$_clone_err")
    warn "Full clone failed — retrying with shallow clone …"
    [[ -n "$_msg" ]] && info "  $_msg"
    rm -rf "$REPO_DIR" 2>/dev/null || true
    if ! _clone_err=$(git clone --depth 1 "$REPO_URL" "$REPO_DIR" 2>&1); then
      _msg=$(_err_line "$_clone_err")
      die "Git clone failed." "${_msg:-Check REPO_URL, credentials, and network.}"
    fi
    # Unshallow in background so worktrees work properly
    info "Unshallowing repository …"
    _unshal=$(git -C "$REPO_DIR" fetch --unshallow 2>&1) || {
      _msg=$(_err_line "$_unshal")
      warn "Unshallow failed: ${_msg:-some features may be limited}"
    }
  fi
  ok "Repo cloned"
fi

# ── DEFAULT_BRANCH (interactive branch picker) ──
cfgBranch="${DEFAULT_BRANCH:-}"
if [[ -n "$cfgBranch" ]]; then
  ok "DEFAULT_BRANCH: $cfgBranch"
elif [[ -t 0 ]]; then
  # Collect remote branches (strip origin/ prefix, ignore HEAD)
  _branches=()
  while IFS= read -r _b; do
    [[ -n "$_b" ]] && _branches+=("$_b")
  done < <(
    git -C "$REPO_DIR" branch -r 2>/dev/null \
      | sed 's/^[* ]*//' \
      | grep -v '\->' \
      | sed 's|^origin/||' \
      | sort -u
  )
  if [[ ${#_branches[@]} -gt 1 ]]; then
    echo ""
    echo -e "  ${BLACK}${BG_DCYAN} DEFAULT_BRANCH ${NC} ${DGRAY}(optional)${NC}"
    echo ""
    echo -e "  ${GRAY}Pick the base branch for new worktrees.${NC}"
    echo -e "  ${GRAY}Can be changed later via ${CYAN}/branch set${GRAY}.${NC}"
    echo ""
    for i in "${!_branches[@]}"; do
      printf "    ${CYAN}%2d${NC})  %s\n" "$((i+1))" "${_branches[$i]}"
    done
    echo ""
    read -rp "  ▸ Number (or Enter for remote default): " _pick
    if [[ -n "$_pick" ]] && [[ "$_pick" =~ ^[0-9]+$ ]] && (( _pick >= 1 && _pick <= ${#_branches[@]} )); then
      export DEFAULT_BRANCH="${_branches[$((_pick-1))]}"
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
# 6) Copy application files from src/
# ──────────────────────────────────────────────────────────────────────────────

write_step 6 8 "Source files"

SRC_DIR="$SCRIPT_DIR/src"
if [[ ! -d "$SRC_DIR" ]]; then
  die "Source directory not found." "Expected: $SRC_DIR — are you running from the correct directory?"
fi

mkdir -p "$APP/src" "$APP/llm"
cp "$SCRIPT_DIR/src/package.json" "$APP/package.json" || die "Failed to copy package.json." "Check disk space and permissions on $APP"
[[ -f "$SCRIPT_DIR/src/package-lock.json" ]] && { cp "$SCRIPT_DIR/src/package-lock.json" "$APP/package-lock.json" || warn "Failed to copy package-lock.json"; }

# Count files for progress bar
_src_files=("$SRC_DIR"/*.mjs)
_llm_files=("$SCRIPT_DIR/llm"/*.md)
_total_files=$(( ${#_src_files[@]} + ${#_llm_files[@]} + 1 ))  # +1 for package.json
_file_idx=1

write_file_progress "package.json" $_file_idx $_total_files

for f in "${_src_files[@]}"; do
  (( _file_idx++ ))
  cp "$f" "$APP/src/$(basename "$f")" || die "Failed to copy $(basename "$f")." "Check disk space and permissions on $APP/src/"
  write_file_progress "$(basename "$f")" $_file_idx $_total_files
done
for f in "${_llm_files[@]}"; do
  [[ -f "$f" ]] || continue
  (( _file_idx++ ))
  cp "$f" "$APP/llm/$(basename "$f")" || die "Failed to copy $(basename "$f")." "Check disk space and permissions on $APP/llm/"
  write_file_progress "$(basename "$f")" $_file_idx $_total_files
done

ok "$_total_files files copied (${#_src_files[@]} source + ${#_llm_files[@]} llm)"

# ──────────────────────────────────────────────────────────────────────────────
# 7) Install dependencies
# ──────────────────────────────────────────────────────────────────────────────

write_step 7 8 "Dependencies"

info "Running npm install …"
cd "$APP" || die "Cannot cd to app directory." "$APP does not exist or is inaccessible"

# Use npm ci if lock file exists, otherwise npm install — with retry
_npm_attempt=0
_npm_max=3
_npm_err=""
while (( ++_npm_attempt <= _npm_max )); do
  if [[ -f "package-lock.json" ]]; then
    _npm_err=$(npm ci --loglevel=error 2>&1) && break
  else
    _npm_err=$(npm install --loglevel=error 2>&1) && break
  fi
  if (( _npm_attempt < _npm_max )); then
    _npm_line=$(_err_line "$_npm_err")
    warn "npm install failed (attempt $_npm_attempt/$_npm_max)${_npm_line:+: }${_npm_line}"
    warn "  Retrying in 5s …"
    sleep 5
    # Clean node_modules on retry to avoid corrupt state
    rm -rf "$APP/node_modules" 2>/dev/null || true
  else
    _npm_line=$(_err_line "$_npm_err")
    die "npm install failed after $_npm_max attempts." "${_npm_line:-see npm output above}"
  fi
done

PKG_COUNT=$(find "$APP/node_modules" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
ok "$PKG_COUNT packages installed"

# ──────────────────────────────────────────────────────────────────────────────
# 8) Launch
# ──────────────────────────────────────────────────────────────────────────────

write_step 8 8 "Launch"

ELAPSED=$(elapsed)

# ── Summary ──
echo ""
_HL=$(printf '═%.0s' $(seq 1 48))
echo -e "    ${CYAN}╔${_HL}╗${NC}"
echo -e "    ${CYAN}║${NC}  ${GREEN}Setup complete ✔${NC}                               ${CYAN}║${NC}"
echo -e "    ${CYAN}╠$(printf '─%.0s' $(seq 1 48))╣${NC}"
printf "    ${CYAN}║${NC}${GRAY}  %-11s${NC}${WHITE}%-35s${NC} ${CYAN}║${NC}\n" "Project:" "$PROJECT_NAME"
printf "    ${CYAN}║${NC}${GRAY}  %-11s${NC}${WHITE}%-35s${NC} ${CYAN}║${NC}\n" "Repo:" "$(basename "$REPO_DIR")"
printf "    ${CYAN}║${NC}${GRAY}  %-11s${NC}${WHITE}%-35s${NC} ${CYAN}║${NC}\n" "Runtime:" "Node.js $(node -v)"
printf "    ${CYAN}║${NC}${GRAY}  %-11s${NC}${WHITE}%-35s${NC} ${CYAN}║${NC}\n" "Elapsed:" "$ELAPSED"
echo -e "    ${CYAN}╚${_HL}╝${NC}"
echo ""

# ── Go ──
echo -e "    ${BLACK}${BG_GREEN} ► STARTING BOT ${NC}  ${DGRAY}press ${YELLOW}Ctrl+C${DGRAY} to stop${NC}"
echo ""

export PROJECT_NAME
export REPO_PATH="$REPO_DIR"
export DEFAULT_BRANCH="${DEFAULT_BRANCH:-}"
export ADMIN_USER_ID="${ADMIN_USER_ID:-}"
export STARTUP_CHANNEL_ID="${STARTUP_CHANNEL_ID:-}"
export AGENT_SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

# Clean up temp files before exec replaces this process (EXIT trap won't fire after exec)
for _f in "${_TMPFILES[@]}"; do
  rm -f "$_f" 2>/dev/null
done

exec node "$APP/src/bot.mjs"
