#Requires -Version 5.1
<#
.SYNOPSIS
  Discord × Copilot — Autonomous Remote Coding Agent (Windows PowerShell)
.DESCRIPTION
  Single-script deployment. Run: .\agent.ps1
  Equivalent to agent.sh for Windows environments.
#>

$ErrorActionPreference = 'Stop'

# ── Output helpers ───────────────────────────────────────────────────────────

$script:StartTime = Get-Date

function Write-Info  { param([string]$Msg) Write-Host "  $([char]0x25B8) " -ForegroundColor DarkCyan -NoNewline; Write-Host $Msg -ForegroundColor Cyan }
function Write-Ok    { param([string]$Msg) Write-Host "  $([char]0x2714) " -ForegroundColor Green -NoNewline; Write-Host $Msg -ForegroundColor White }
function Write-Warn  { param([string]$Msg) Write-Host "  $([char]0x26A0) " -ForegroundColor Yellow -NoNewline; Write-Host $Msg -ForegroundColor Yellow }
function Write-Fatal {
    param([string]$Msg)
    Write-Host ''
    Write-Host "  $([char]0x2718) FATAL: " -ForegroundColor Red -NoNewline
    Write-Host $Msg -ForegroundColor White
    Write-Host ''
    exit 1
}
function Write-Step {
    param([int]$Num, [int]$Total, [string]$Title)
    $elapsed = '{0:mm\:ss}' -f ((Get-Date) - $script:StartTime)
    Write-Host ''
    $padTitle = $Title.PadRight(36)
    $numTag   = "$Num/$Total"
    Write-Host '  ' -NoNewline
    Write-Host " $numTag " -ForegroundColor Black -BackgroundColor DarkCyan -NoNewline
    Write-Host " $padTitle" -ForegroundColor White -NoNewline
    Write-Host " $([char]0x23F1) $elapsed" -ForegroundColor DarkGray
    # progress dots
    Write-Host '       ' -NoNewline
    for ($i = 1; $i -le $Total; $i++) {
        if ($i -lt $Num)  { Write-Host "$([char]0x2501)" -ForegroundColor Green -NoNewline }
        elseif ($i -eq $Num) { Write-Host "$([char]0x25C9)" -ForegroundColor Cyan -NoNewline }
        else              { Write-Host "$([char]0x2501)" -ForegroundColor DarkGray -NoNewline }
    }
    Write-Host ''
}
function Write-FileProgress {
    param([string]$Name, [int]$Current, [int]$Total)
    $pct  = [math]::Round(($Current / $Total) * 100)
    $fill = [math]::Round(($Current / $Total) * 20)
    $bar  = ([string][char]0x2588) * $fill + ([string][char]0x2591) * (20 - $fill)
    Write-Host "       $([char]0x2502) " -ForegroundColor DarkGray -NoNewline
    Write-Host "$bar" -ForegroundColor Cyan -NoNewline
    Write-Host " $pct% " -ForegroundColor DarkGray -NoNewline
    Write-Host $Name -ForegroundColor White
}
function Write-Check {
    param([string]$Label, [string]$Value, [bool]$Ok = $true)
    if ($Ok) {
        Write-Host "       $([char]0x2502) $([char]0x2714) " -ForegroundColor Green -NoNewline
    } else {
        Write-Host "       $([char]0x2502) $([char]0x2718) " -ForegroundColor Red -NoNewline
    }
    Write-Host ($Label.PadRight(14)) -ForegroundColor Gray -NoNewline
    Write-Host $Value -ForegroundColor White
}

# ──────────────────────────────────────────────────────────────────────────────
# 1) Load .env, show banner, interactive setup wizard
# ──────────────────────────────────────────────────────────────────────────────

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$EnvFile   = Join-Path $ScriptDir '.env'

if (Test-Path $EnvFile) {
    Get-Content $EnvFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith('#')) {
            if ($line -match '^([^=]+)=(.*)$') {
                $key = $Matches[1].Trim()
                $val = $Matches[2].Trim().Trim('"').Trim("'")
                [Environment]::SetEnvironmentVariable($key, $val, 'Process')
            }
        }
    }
}

Write-Host ''
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host '   ___  _                       _' -ForegroundColor Magenta
Write-Host '  |   \(_)___ __ ___ _ _ __| |' -ForegroundColor Magenta
Write-Host '  | |) | (_-</ _/ _ \ ''_/ _` |' -ForegroundColor Magenta
Write-Host '  |___/|_/__/\__\___/_| \__,_|' -ForegroundColor Magenta
Write-Host '         ' -NoNewline
Write-Host ([char]0x00D7) -ForegroundColor DarkGray -NoNewline
Write-Host ' C o p i l o t' -ForegroundColor Cyan
Write-Host ''
Write-Host ('    ' + ([string][char]0x2550) * 46) -ForegroundColor DarkGray
Write-Host '    Autonomous Remote Coding Agent' -ForegroundColor DarkGray -NoNewline
Write-Host '   v1.0' -ForegroundColor DarkCyan
Write-Host ('    ' + ([string][char]0x2550) * 46) -ForegroundColor DarkGray

# ── Setup Wizard ─────────────────────────────────────────────────────────────

$script:EnvChanged = $false   # track whether we need to offer .env save

# Clipboard helper — reads from Windows clipboard if available
function Get-ClipboardText {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $text = [System.Windows.Forms.Clipboard]::GetText()
        if ($text) { return $text.Trim() }
    } catch {}
    return $null
}

function Read-SecureInput {
    param([string]$Prompt, [switch]$OfferClipboard)
    if ($OfferClipboard) {
        $clip = Get-ClipboardText
        if ($clip -and $clip.Length -ge 8) {
            $preview = "[" + $clip.Length + " chars]"
            Write-Host "  $([char]0x25B8) " -ForegroundColor DarkCyan -NoNewline
            Write-Host "Clipboard detected: " -ForegroundColor DarkGray -NoNewline
            Write-Host $preview -ForegroundColor Yellow
            Write-Host "  $([char]0x25B8) " -ForegroundColor DarkCyan -NoNewline
            $useClip = Read-Host 'Use clipboard value? [Y/n]'
            if ($useClip -eq '' -or $useClip -match '^[yYjJ]') {
                return $clip
            }
        }
    }
    Write-Host ''
    Write-Host '  Tip: ' -ForegroundColor DarkGray -NoNewline
    Write-Host 'Right-click' -ForegroundColor Yellow -NoNewline
    Write-Host ' to paste in legacy terminals (Ctrl+V may not work)' -ForegroundColor DarkGray
    Write-Host "  $([char]0x25B8) " -ForegroundColor DarkCyan -NoNewline
    return (Read-Host $Prompt)
}

# Detect what is already configured
$cfgToken = $env:DISCORD_TOKEN
$cfgRepo  = $env:REPO_URL
$cfgGH    = $env:GITHUB_TOKEN

$needSetup = (-not $cfgToken) -or (-not $cfgRepo)

if ($needSetup) {
    Write-Step 1 8 'Configuration'
    Write-Host '  Some required settings are missing. Let''s configure them.' -ForegroundColor DarkGray
    Write-Host '  Values from ' -ForegroundColor DarkGray -NoNewline
    Write-Host '.env' -ForegroundColor Cyan -NoNewline
    Write-Host ' and environment variables are used automatically.' -ForegroundColor DarkGray
} else {
    Write-Step 1 8 'Configuration'
    Write-Ok 'All values loaded (DISCORD_TOKEN, REPO_URL)'
}

# ── 1. DISCORD_TOKEN ──
if (-not $cfgToken) {
    Write-Host ''
    Write-Host '  ' -NoNewline
    Write-Host ' DISCORD_TOKEN ' -ForegroundColor Black -BackgroundColor DarkCyan -NoNewline
    Write-Host ' (required)' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  How to get your token:' -ForegroundColor Gray
    Write-Host '    1. Go to ' -ForegroundColor DarkGray -NoNewline
    Write-Host 'https://discord.com/developers/applications' -ForegroundColor Cyan
    Write-Host '    2. Click ' -ForegroundColor DarkGray -NoNewline
    Write-Host 'New Application' -ForegroundColor White -NoNewline
    Write-Host ' (or select existing)' -ForegroundColor DarkGray
    Write-Host '    3. Go to ' -ForegroundColor DarkGray -NoNewline
    Write-Host 'Bot' -ForegroundColor White -NoNewline
    Write-Host ' tab ' -ForegroundColor DarkGray -NoNewline
    Write-Host ([char]0x2192) -ForegroundColor DarkGray -NoNewline
    Write-Host ' Reset Token ' -ForegroundColor White -NoNewline
    Write-Host ([char]0x2192) -ForegroundColor DarkGray -NoNewline
    Write-Host ' copy it' -ForegroundColor DarkGray
    Write-Host '    4. Under ' -ForegroundColor DarkGray -NoNewline
    Write-Host 'Privileged Gateway Intents' -ForegroundColor White -NoNewline
    Write-Host ': enable ' -ForegroundColor DarkGray -NoNewline
    Write-Host 'Message Content' -ForegroundColor Yellow
    Write-Host '    5. Under ' -ForegroundColor DarkGray -NoNewline
    Write-Host 'OAuth2 > URL Generator' -ForegroundColor White -NoNewline
    Write-Host ':' -ForegroundColor DarkGray
    Write-Host '       Scopes: ' -ForegroundColor DarkGray -NoNewline
    Write-Host 'bot, applications.commands' -ForegroundColor White
    Write-Host '       Permissions: ' -ForegroundColor DarkGray -NoNewline
    Write-Host 'Send Messages, Embed Links, Attach Files, Use Slash Commands' -ForegroundColor White
    Write-Host ''
    $cfgToken = Read-SecureInput 'Paste your Discord bot token' -OfferClipboard
    if (-not $cfgToken) { Write-Fatal 'DISCORD_TOKEN is required.' }
    [Environment]::SetEnvironmentVariable('DISCORD_TOKEN', $cfgToken, 'Process')
    $script:EnvChanged = $true
    Write-Ok 'DISCORD_TOKEN set'
} else {
    Write-Ok 'DISCORD_TOKEN found'
}

# ── 2. REPO_URL ──
if (-not $cfgRepo) {
    Write-Host ''
    Write-Host '  ' -NoNewline
    Write-Host ' REPO_URL ' -ForegroundColor Black -BackgroundColor DarkCyan -NoNewline
    Write-Host ' (required)' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  The Git repository the agent will work on.' -ForegroundColor Gray
    Write-Host '  HTTPS example: ' -ForegroundColor DarkGray -NoNewline
    Write-Host 'https://github.com/owner/repo.git' -ForegroundColor Cyan
    Write-Host '  SSH example:   ' -ForegroundColor DarkGray -NoNewline
    Write-Host 'git@github.com:owner/repo.git' -ForegroundColor Cyan
    Write-Host ''
    $cfgRepo = Read-SecureInput 'Repository URL'
    if (-not $cfgRepo) { Write-Fatal 'REPO_URL is required.' }
    [Environment]::SetEnvironmentVariable('REPO_URL', $cfgRepo, 'Process')
    $script:EnvChanged = $true
    Write-Ok 'REPO_URL set'
} else {
    Write-Ok "REPO_URL: $cfgRepo"
}
$RepoUrl = $cfgRepo

# ── 3. GITHUB_TOKEN (optional) ──
if (-not $cfgGH) {
    Write-Host ''
    Write-Host '  ' -NoNewline
    Write-Host ' GITHUB_TOKEN ' -ForegroundColor Black -BackgroundColor DarkGray -NoNewline
    Write-Host ' (optional)' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Needed for private repos, pushing, and creating PRs.' -ForegroundColor Gray
    Write-Host '  Create a fine-grained PAT: ' -ForegroundColor DarkGray -NoNewline
    Write-Host 'https://github.com/settings/personal-access-tokens/new' -ForegroundColor Cyan
    Write-Host '  Repository access: ' -ForegroundColor DarkGray -NoNewline
    Write-Host 'Only select repositories' -ForegroundColor White -NoNewline
    Write-Host ' (pick your target repo)' -ForegroundColor DarkGray
    Write-Host '  Required permissions: ' -ForegroundColor DarkGray -NoNewline
    Write-Host 'Contents (read/write)' -ForegroundColor White -NoNewline
    Write-Host ', ' -ForegroundColor DarkGray -NoNewline
    Write-Host 'Pull requests (read/write)' -ForegroundColor White
    Write-Host '  Press ' -ForegroundColor DarkGray -NoNewline
    Write-Host 'Enter' -ForegroundColor Yellow -NoNewline
    Write-Host ' to skip.' -ForegroundColor DarkGray
    Write-Host ''
    $cfgGH = Read-SecureInput 'GitHub token (or Enter to skip)' -OfferClipboard
    if ($cfgGH) {
        [Environment]::SetEnvironmentVariable('GITHUB_TOKEN', $cfgGH, 'Process')
        $script:EnvChanged = $true
        Write-Ok 'GITHUB_TOKEN set'
    } else {
        Write-Info 'GITHUB_TOKEN skipped'
    }
} else {
    Write-Ok 'GITHUB_TOKEN found'
}

# ── 4. ADMIN_USER_ID (optional) ──
$cfgAdmin = $env:ADMIN_USER_ID
if (-not $cfgAdmin) {
    Write-Host ''
    Write-Host '  ' -NoNewline
    Write-Host ' ADMIN_USER_ID ' -ForegroundColor Black -BackgroundColor DarkGray -NoNewline
    Write-Host ' (optional)' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Your Discord User ID — the bot will DM you on startup/shutdown.' -ForegroundColor Gray
    Write-Host '  How to find it:' -ForegroundColor Gray
    Write-Host '    1. Open Discord ' -ForegroundColor DarkGray -NoNewline
    Write-Host ([char]0x2192) -ForegroundColor DarkGray -NoNewline
    Write-Host ' User Settings (gear icon at bottom left)' -ForegroundColor White
    Write-Host '    2. Go to ' -ForegroundColor DarkGray -NoNewline
    Write-Host 'App Settings > Advanced' -ForegroundColor White -NoNewline
    Write-Host ' ' -NoNewline
    Write-Host ([char]0x2192) -ForegroundColor DarkGray -NoNewline
    Write-Host ' enable ' -ForegroundColor DarkGray -NoNewline
    Write-Host 'Developer Mode' -ForegroundColor Yellow
    Write-Host '    3. Go to ' -ForegroundColor DarkGray -NoNewline
    Write-Host 'My Account' -ForegroundColor White -NoNewline
    Write-Host ' ' -NoNewline
    Write-Host ([char]0x2192) -ForegroundColor DarkGray -NoNewline
    Write-Host ' click the ' -ForegroundColor DarkGray -NoNewline
    Write-Host '...' -ForegroundColor White -NoNewline
    Write-Host ' (three dots) next to your username' -ForegroundColor DarkGray
    Write-Host '    4. Click ' -ForegroundColor DarkGray -NoNewline
    Write-Host 'Copy User ID' -ForegroundColor White
    Write-Host '  Press ' -ForegroundColor DarkGray -NoNewline
    Write-Host 'Enter' -ForegroundColor Yellow -NoNewline
    Write-Host ' to skip.' -ForegroundColor DarkGray
    Write-Host ''
    $cfgAdmin = Read-SecureInput 'Admin User ID (or Enter to skip)'
    if ($cfgAdmin) {
        if ($cfgAdmin -notmatch '^\d{17,20}$') {
            Write-Warn "'$cfgAdmin' is not a valid Discord User ID (must be 17-20 digits)."
            Write-Warn '  That looks like a username. Discord IDs are long numbers like 123456789012345678.'
            Write-Warn '  To find yours: Settings (gear icon) > App Settings > Advanced > Developer Mode ON'
            Write-Warn '  Then: Settings > My Account > click ... next to your username > Copy User ID'
            Write-Host ''
            $retry = Read-Host "  $([char]0x25B8) Enter numeric User ID (or Enter to skip)"
            if ($retry -and $retry -match '^\d{17,20}$') {
                $cfgAdmin = $retry
            } elseif ($retry) {
                Write-Warn "'$retry' is still not a valid snowflake ID. Skipping ADMIN_USER_ID."
                $cfgAdmin = $null
            } else {
                $cfgAdmin = $null
            }
        }
        if ($cfgAdmin) {
            [Environment]::SetEnvironmentVariable('ADMIN_USER_ID', $cfgAdmin, 'Process')
            $script:EnvChanged = $true
            Write-Ok 'ADMIN_USER_ID set'
        } else {
            Write-Info 'ADMIN_USER_ID skipped'
        }
    } else {
        Write-Info 'ADMIN_USER_ID skipped'
    }
} else {
    if ($cfgAdmin -notmatch '^\d{17,20}$') {
        Write-Warn "ADMIN_USER_ID '$cfgAdmin' is not a valid snowflake (must be 17-20 digits). Ignoring."
        [Environment]::SetEnvironmentVariable('ADMIN_USER_ID', $null, 'Process')
        $cfgAdmin = $null
    } else {
        Write-Ok "ADMIN_USER_ID found ($cfgAdmin)"
    }
}

# ── 5. STARTUP_CHANNEL_ID (optional) ──
$cfgStartup = $env:STARTUP_CHANNEL_ID
if (-not $cfgStartup) {
    Write-Host ''
    Write-Host '  ' -NoNewline
    Write-Host ' STARTUP_CHANNEL_ID ' -ForegroundColor Black -BackgroundColor DarkGray -NoNewline
    Write-Host ' (optional)' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Channel for bot online/offline notifications.' -ForegroundColor Gray
    Write-Host '  Right-click any text channel ' -ForegroundColor DarkGray -NoNewline
    Write-Host ([char]0x2192) -ForegroundColor DarkGray -NoNewline
    Write-Host ' Copy Channel ID' -ForegroundColor White
    Write-Host '  Press ' -ForegroundColor DarkGray -NoNewline
    Write-Host 'Enter' -ForegroundColor Yellow -NoNewline
    Write-Host ' to skip (bot uses first available channel).' -ForegroundColor DarkGray
    Write-Host ''
    $cfgStartup = Read-SecureInput 'Startup Channel ID (or Enter to skip)'
    if ($cfgStartup) {
        if ($cfgStartup -notmatch '^\d{17,20}$') {
            Write-Warn "'$cfgStartup' is not a valid Discord Channel ID (must be 17-20 digits)."
            Write-Warn '  Right-click a text channel in Discord > Copy Channel ID'
            Write-Host ''
            $retry = Read-Host "  $([char]0x25B8) Enter numeric Channel ID (or Enter to skip)"
            if ($retry -and $retry -match '^\d{17,20}$') {
                $cfgStartup = $retry
            } elseif ($retry) {
                Write-Warn "'$retry' is still not a valid snowflake ID. Skipping."
                $cfgStartup = $null
            } else {
                $cfgStartup = $null
            }
        }
        if ($cfgStartup) {
            [Environment]::SetEnvironmentVariable('STARTUP_CHANNEL_ID', $cfgStartup, 'Process')
            $script:EnvChanged = $true
            Write-Ok 'STARTUP_CHANNEL_ID set'
        } else {
            Write-Info 'STARTUP_CHANNEL_ID skipped'
        }
    } else {
        Write-Info 'STARTUP_CHANNEL_ID skipped'
    }
} else {
    if ($cfgStartup -notmatch '^\d{17,20}$') {
        Write-Warn "STARTUP_CHANNEL_ID '$cfgStartup' is not a valid snowflake (must be 17-20 digits). Ignoring."
        [Environment]::SetEnvironmentVariable('STARTUP_CHANNEL_ID', $null, 'Process')
        $cfgStartup = $null
    } else {
        Write-Ok "STARTUP_CHANNEL_ID found ($cfgStartup)"
    }
}

# ── Offer to save .env ──
if ($script:EnvChanged) {
    Write-Host ''
    Write-Host '  ' -NoNewline
    Write-Host ' SAVE ' -ForegroundColor Black -BackgroundColor DarkYellow
    Write-Host "  Save these values to " -ForegroundColor DarkGray -NoNewline
    Write-Host $EnvFile -ForegroundColor Cyan -NoNewline
    Write-Host '?' -ForegroundColor DarkGray
    Write-Host '  So you don''t have to enter them again next time.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  ' -NoNewline
    $saveAnswer = Read-Host "$([char]0x25B8) Save to .env? [Y/n]"
    if ($saveAnswer -eq '' -or $saveAnswer -match '^[yYjJ]') {
        $dateFmt = Get-Date -Format 'yyyy-MM-dd'
        $lines = @("# Discord x Copilot Agent - auto-generated $dateFmt")
        $lines += "DISCORD_TOKEN=$([Environment]::GetEnvironmentVariable('DISCORD_TOKEN','Process'))"
        $lines += "REPO_URL=$([Environment]::GetEnvironmentVariable('REPO_URL','Process'))"
        $gh = [Environment]::GetEnvironmentVariable('GITHUB_TOKEN','Process')
        if ($gh) { $lines += "GITHUB_TOKEN=$gh" }
        $adminId = [Environment]::GetEnvironmentVariable('ADMIN_USER_ID','Process')
        if ($adminId) { $lines += "ADMIN_USER_ID=$adminId" }
        $startupCh = [Environment]::GetEnvironmentVariable('STARTUP_CHANNEL_ID','Process')
        if ($startupCh) { $lines += "STARTUP_CHANNEL_ID=$startupCh" }
        # preserve any extra keys from existing .env
        if (Test-Path $EnvFile) {
            $known = @('DISCORD_TOKEN','REPO_URL','GITHUB_TOKEN','ADMIN_USER_ID','STARTUP_CHANNEL_ID')
            Get-Content $EnvFile | ForEach-Object {
                $l = $_.Trim()
                if ($l -and -not $l.StartsWith('#') -and $l -match '^([^=]+)=') {
                    if ($known -notcontains $Matches[1].Trim()) { $lines += $l }
                }
            }
        }
        [System.IO.File]::WriteAllLines($EnvFile, $lines, (New-Object System.Text.UTF8Encoding $false))
        $valCount = $lines.Count - 1
        Write-Ok ".env saved ($valCount values)"
    } else {
        Write-Info '.env not saved'
    }
}

Write-Host ''

# ──────────────────────────────────────────────────────────────────────────────
# 2) Prerequisite checks
# ──────────────────────────────────────────────────────────────────────────────

Write-Step 2 8 'Prerequisites'

$Missing = @()

$hasGit  = [bool](Get-Command git -ErrorAction SilentlyContinue)
$hasNode = [bool](Get-Command node -ErrorAction SilentlyContinue)
$hasNpm  = [bool](Get-Command npm -ErrorAction SilentlyContinue)

if (-not $hasGit)  { $Missing += 'git' }
if (-not $hasNode) { $Missing += 'node' }
if (-not $hasNpm)  { $Missing += 'npm' }

# Copilot CLI: accept 'copilot' binary OR 'gh copilot' extension
$CopilotCmd = ''
if (Get-Command copilot -ErrorAction SilentlyContinue) {
    $CopilotCmd = 'copilot'
} elseif (Get-Command gh -ErrorAction SilentlyContinue) {
    try { gh copilot --help 2>&1 | Out-Null; $CopilotCmd = 'gh copilot' } catch {}
}
if (-not $CopilotCmd) { $Missing += 'copilot' }

$gitVer  = if ($hasGit)  { (git --version) -replace 'git version ','' } else { 'not found' }
$nodeVer = if ($hasNode) { (node -v) } else { 'not found' }
$npmVer  = if ($hasNpm)  { (npm -v) } else { 'not found' }
$copVer  = if ($CopilotCmd) { $CopilotCmd } else { 'not found' }

Write-Host "       $([char]0x250C)$(([string][char]0x2500) * 40)" -ForegroundColor DarkGray
Write-Check 'git'     $gitVer   $hasGit
Write-Check 'node'    $nodeVer  $hasNode
Write-Check 'npm'     $npmVer   $hasNpm
Write-Check 'copilot' $copVer   ([bool]$CopilotCmd)
Write-Host "       $([char]0x2514)$(([string][char]0x2500) * 40)" -ForegroundColor DarkGray

if ($Missing.Count -gt 0) {
    Write-Host ''
    Write-Host '  ' -NoNewline
    Write-Host ' MISSING TOOLS ' -ForegroundColor Black -BackgroundColor Red
    Write-Host ''
    $installGuide = @{
        'git'     = @('https://git-scm.com/downloads', 'Download and run the installer.')
        'node'    = @('https://nodejs.org/', 'Install LTS version (>= 18). npm is included.')
        'npm'     = @('https://nodejs.org/', 'Comes bundled with Node.js.')
        'copilot' = @('https://github.com/github/gh-copilot', 'Run: gh extension install github/gh-copilot')
    }
    foreach ($tool in $Missing) {
        $guide = $installGuide[$tool]
        Write-Host "    $([char]0x2718) " -ForegroundColor Red -NoNewline
        Write-Host $tool -ForegroundColor White
        Write-Host '      ' -NoNewline
        Write-Host $guide[0] -ForegroundColor Cyan
        Write-Host '      ' -NoNewline
        Write-Host $guide[1] -ForegroundColor DarkGray
        Write-Host ''
    }
    Write-Host '  Install the missing tools, then re-run this script.' -ForegroundColor Yellow
    Write-Host ''
    exit 1
}

# Node version check (>= 18)
$NodeMajor = [int](node -e "process.stdout.write(String(process.versions.node.split('.')[0]))")
if ($NodeMajor -lt 18) {
    Write-Fatal "Node.js >= 18 required (found v$(node -v)). Update: https://nodejs.org/"
}
Write-Ok 'All prerequisites satisfied'

# Copilot auth check
if ($CopilotCmd) {
    try {
        $null = & ($CopilotCmd.Split(' ')[0]) ($CopilotCmd.Split(' ') | Select-Object -Skip 1) auth status 2>&1
    } catch {
        Write-Warn 'copilot auth not configured. Attempting to continue...'
        Write-Warn "If it fails, run:  $CopilotCmd auth login"
    }
}

# ──────────────────────────────────────────────────────────────────────────────
# 3) Credential & access validation
# ──────────────────────────────────────────────────────────────────────────────

Write-Step 3 8 'Validation'

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$script:validationOk = $true

Write-Host "       $([char]0x250C)$(([string][char]0x2500) * 44)" -ForegroundColor DarkGray

# ── Discord Token ──
$discordBotToken = [Environment]::GetEnvironmentVariable('DISCORD_TOKEN','Process')
try {
    $discordHeaders = @{ Authorization = "Bot $discordBotToken" }
    $discordUser = Invoke-RestMethod -Uri 'https://discord.com/api/v10/users/@me' -Headers $discordHeaders -TimeoutSec 10 -ErrorAction Stop
    $botName = $discordUser.username
    if ($discordUser.discriminator -and $discordUser.discriminator -ne '0') {
        $botName = "$botName#$($discordUser.discriminator)"
    }
    Write-Check 'Discord Bot' $botName $true

    # Check privileged intents via /applications/@me
    try {
        $appInfo = Invoke-RestMethod -Uri 'https://discord.com/api/v10/applications/@me' -Headers $discordHeaders -TimeoutSec 10 -ErrorAction Stop
        $flags = [long]($appInfo.flags)
        # GatewayMessageContent = 1 << 18 (262144), GatewayMessageContentLimited = 1 << 19 (524288)
        $hasMessageContent = ($flags -band 262144) -ne 0 -or ($flags -band 524288) -ne 0
        if ($hasMessageContent) {
            Write-Check 'Message Intent' 'enabled' $true
        } else {
            Write-Check 'Message Intent' 'NOT enabled' $false
            Write-Warn '  The bot needs Message Content Intent to read messages.'
            Write-Warn '  Enable it: Discord Developer Portal > Bot > Privileged Gateway Intents'
        }
    } catch {
        Write-Check 'Message Intent' 'could not verify (API error)' $false
        Write-Warn '  Check manually: Developer Portal > Bot > Privileged Gateway Intents'
    }

    # Check if bot is in any guilds
    try {
        $guilds = Invoke-RestMethod -Uri 'https://discord.com/api/v10/users/@me/guilds?limit=1' -Headers $discordHeaders -TimeoutSec 10 -ErrorAction Stop
        if ($guilds -and $guilds.Count -gt 0) {
            Write-Check 'Bot Guilds' "in at least 1 server" $true
        } else {
            Write-Check 'Bot Guilds' 'not in any server yet' $false
            Write-Warn '  Invite the bot first: Developer Portal > OAuth2 > URL Generator'
            Write-Warn '  Scopes: bot, applications.commands'
        }
    } catch {
        Write-Check 'Bot Guilds' 'could not check' $false
    }
} catch {
    $discordStatus = $null
    if ($_.Exception.Response) {
        try { $discordStatus = [int]$_.Exception.Response.StatusCode } catch {}
    }
    if ($discordStatus -eq 401) {
        Write-Check 'Discord Bot' 'Invalid token (401 Unauthorized)' $false
        $script:validationOk = $false
    } else {
        $errMsg = $_.Exception.Message
        if ($errMsg.Length -gt 60) { $errMsg = $errMsg.Substring(0, 57) + '...' }
        Write-Check 'Discord Bot' "API unreachable ($errMsg)" $false
        Write-Warn '  Network issue? Bot may still work if the API is temporarily down.'
    }
}

# ── GitHub Token (if set) ──
$ghToken = [Environment]::GetEnvironmentVariable('GITHUB_TOKEN','Process')
if ($ghToken) {
    # Detect token type
    $ghTokenType = 'unknown'
    if ($ghToken -match '^ghp_')         { $ghTokenType = 'PAT (classic)' }
    elseif ($ghToken -match '^github_pat_') { $ghTokenType = 'PAT (fine-grained)' }
    elseif ($ghToken -match '^gho_')     { $ghTokenType = 'OAuth' }
    elseif ($ghToken -match '^ghu_')     { $ghTokenType = 'User-to-server' }
    elseif ($ghToken -match '^ghs_')     { $ghTokenType = 'Server-to-server' }

    try {
        $ghHeaders = @{
            Authorization = "token $ghToken"
            'User-Agent'  = 'discord-copilot-agent/1.0'
        }
        $ghResponse = Invoke-WebRequest -Uri 'https://api.github.com/user' -Headers $ghHeaders -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
        $ghUser = ($ghResponse.Content | ConvertFrom-Json).login
        Write-Check 'GitHub User' "$ghUser ($ghTokenType)" $true

        # Rate limit info
        $rateRemain = $ghResponse.Headers['X-RateLimit-Remaining']
        $rateLimit  = $ghResponse.Headers['X-RateLimit-Limit']
        if ($rateRemain -is [array]) { $rateRemain = $rateRemain[0] }
        if ($rateLimit -is [array])  { $rateLimit  = $rateLimit[0] }
        if ($rateRemain -and $rateLimit) {
            $rateOk = [int]$rateRemain -gt 100
            Write-Check 'Rate Limit' "$rateRemain/$rateLimit remaining" $rateOk
            if (-not $rateOk) { Write-Warn '  Rate limit is low. Consider waiting or using a different token.' }
        }

        # Scope checks (classic PATs return X-OAuth-Scopes; fine-grained PATs don't)
        $scopeHeader = $ghResponse.Headers['X-OAuth-Scopes']
        if ($scopeHeader -is [array]) { $scopes = $scopeHeader[0] } else { $scopes = [string]$scopeHeader }

        if ($scopes) {
            # Classic PAT — check individual scopes
            $scopeList = ($scopes -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
            $hasRepo     = $scopeList -contains 'repo'
            $hasWorkflow = $scopeList -contains 'workflow'

            if ($hasRepo) {
                Write-Check 'Scope: repo' 'granted (clone, push, PRs)' $true
            } else {
                Write-Check 'Scope: repo' 'MISSING' $false
                Write-Warn '  Required for private repos, pushing, and creating PRs.'
            }

            if ($hasWorkflow) {
                Write-Check 'Scope: workflow' 'granted' $true
            } else {
                Write-Check 'Scope: workflow' 'not set (optional)' $true
                Write-Info '  Needed only if the agent modifies .github/workflows/ files.'
            }

            # Show all scopes for transparency
            if (-not $hasRepo) {
                Write-Warn "  Current scopes: $scopes"
            }
        } else {
            # Fine-grained PAT or no scopes returned
            Write-Check 'Scopes' 'n/a (fine-grained PAT)' $true
            Write-Info '  Ensure token has: Contents (read/write) + Pull requests (read/write)'
            Write-Info '  and access to the target repository.'
        }

        # Check if token can access the specific repo
        $repoPath = $RepoUrl -replace '\.git$', '' -replace '^https?://github\.com/', '' -replace '^git@github\.com:', ''
        if ($repoPath -and $repoPath -match '^[^/]+/[^/]+$') {
            try {
                $repoInfo = Invoke-RestMethod -Uri "https://api.github.com/repos/$repoPath" -Headers $ghHeaders -TimeoutSec 10 -ErrorAction Stop
                $repoPerms = @()
                if ($repoInfo.permissions.push)  { $repoPerms += 'push' }
                if ($repoInfo.permissions.pull)  { $repoPerms += 'pull' }
                if ($repoInfo.permissions.admin) { $repoPerms += 'admin' }
                $permStr = $repoPerms -join ', '
                $canPush = [bool]$repoInfo.permissions.push
                Write-Check 'Repo Perms' "$repoPath ($permStr)" $canPush
                if (-not $canPush) {
                    Write-Warn '  Token can read the repo but cannot push. Agent needs push access.'
                }
            } catch {
                $repoStatus = $null
                if ($_.Exception.Response) {
                    try { $repoStatus = [int]$_.Exception.Response.StatusCode } catch {}
                }
                if ($repoStatus -eq 404) {
                    Write-Check 'Token→Repo' "$repoPath (not found or no access)" $false
                    Write-Warn '  Token cannot see this repo. Check repo name and token permissions.'
                } elseif ($repoStatus -eq 403) {
                    Write-Check 'Token→Repo' "$repoPath (forbidden)" $false
                    Write-Warn '  Token is valid but not authorized for this repository.'
                } else {
                    Write-Check 'Token→Repo' "$repoPath (could not check)" $false
                }
            }
        }
    } catch {
        $ghStatus = $null
        if ($_.Exception.Response) {
            try { $ghStatus = [int]$_.Exception.Response.StatusCode } catch {}
        }
        if ($ghStatus -eq 401) {
            Write-Check 'GitHub Token' 'Invalid token (401 Unauthorized)' $false
            Write-Warn '  Create a new token: https://github.com/settings/tokens'
        } else {
            $ghErr = $_.Exception.Message
            if ($ghErr.Length -gt 60) { $ghErr = $ghErr.Substring(0, 57) + '...' }
            Write-Check 'GitHub Token' "API error ($ghErr)" $false
            Write-Warn '  Network issue? Continuing without validation.'
        }
    }
} else {
    Write-Check 'GitHub Token' 'not set (optional)' $true
}

# ── Repository URL accessibility (git) ──
try {
    $lsOutput = & git ls-remote --exit-code $RepoUrl HEAD 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Check 'Git Access' 'reachable' $true
    } else {
        $lsErr = ($lsOutput | Out-String).Trim()
        if ($lsErr.Length -gt 60) { $lsErr = $lsErr.Substring(0, 57) + '...' }
        Write-Check 'Git Access' "unreachable ($lsErr)" $false
        Write-Warn '  Check URL, SSH keys, or network. Clone step may fail.'
    }
} catch {
    Write-Check 'Git Access' "error: $($_.Exception.Message)" $false
    Write-Warn '  git ls-remote failed. Clone step may fail.'
}

Write-Host "       $([char]0x2514)$(([string][char]0x2500) * 44)" -ForegroundColor DarkGray

if (-not $script:validationOk) {
    Write-Host ''
    Write-Host '  ' -NoNewline
    Write-Host ' VALIDATION FAILED ' -ForegroundColor Black -BackgroundColor Red
    Write-Host ''
    Write-Host '  Fix the issues above and re-run the script.' -ForegroundColor Yellow
    Write-Host '  Discord token: ' -ForegroundColor DarkGray -NoNewline
    Write-Host 'https://discord.com/developers/applications' -ForegroundColor Cyan
    Write-Host '  GitHub token:  ' -ForegroundColor DarkGray -NoNewline
    Write-Host 'https://github.com/settings/tokens' -ForegroundColor Cyan
    Write-Host ''
    exit 1
} else {
    Write-Ok 'All credentials validated'
}

# ──────────────────────────────────────────────────────────────────────────────
# 4) Derive project name & paths
# ──────────────────────────────────────────────────────────────────────────────

Write-Step 4 8 'Paths'

$ProjectName = [System.IO.Path]::GetFileNameWithoutExtension($RepoUrl) -replace '\.git$', ''
$ProjectName = $ProjectName.Split('/')[-1]

$Base       = if ($env:BASE_ROOT)       { $env:BASE_ROOT }       else { Join-Path $env:USERPROFILE '.local\share\discord-agent' }
$Repos      = Join-Path $Base 'repos'
$App        = Join-Path $Base 'app'
$Workspaces = if ($env:WORKSPACES_ROOT) { $env:WORKSPACES_ROOT } else { Join-Path $Base 'workspaces' }
$RepoDir    = Join-Path $Repos $ProjectName

$colW = 14
Write-Host "       $([char]0x250C)$(([string][char]0x2500) * 50)" -ForegroundColor DarkGray
@(
    @('Project',    $ProjectName),
    @('Base',       $Base),
    @('Repo',       $RepoDir),
    @('App',        $App),
    @('Workspaces', $Workspaces)
) | ForEach-Object {
    Write-Host "       $([char]0x2502) " -ForegroundColor DarkGray -NoNewline
    Write-Host ("$($_[0]):".PadRight($colW)) -ForegroundColor Cyan -NoNewline
    Write-Host $_[1] -ForegroundColor White
}
Write-Host "       $([char]0x2514)$(([string][char]0x2500) * 50)" -ForegroundColor DarkGray

foreach ($dir in @($Repos, (Join-Path $App 'src'), $Workspaces)) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

# ──────────────────────────────────────────────────────────────────────────────
# 5) Clone or update repo
# ──────────────────────────────────────────────────────────────────────────────

Write-Step 5 8 'Repository'

if (Test-Path (Join-Path $RepoDir '.git')) {
    Write-Info 'Updating existing repo...'
    try { git -C $RepoDir fetch --all --prune 2>&1 | Out-Null } catch {}
    try { git -C $RepoDir pull --ff-only 2>&1 | Out-Null } catch { Write-Warn 'pull failed (diverged?) - using existing state' }
    Write-Ok 'Repo updated'
} else {
    Write-Info "Cloning $RepoUrl ..."
    git clone $RepoUrl $RepoDir
    Write-Ok 'Repo cloned'
}

# ──────────────────────────────────────────────────────────────────────────────
# 6) Copy application files from src/
# ──────────────────────────────────────────────────────────────────────────────

Write-Step 6 8 'Source files'

# Copy package.json and src/ from the script directory to the app directory
$SrcDir = Join-Path $ScriptDir 'src'
if (-not (Test-Path $SrcDir)) {
    Write-Fatal "Source directory not found: $SrcDir"
}

$AppSrc = Join-Path $App 'src'
if (-not (Test-Path $AppSrc)) { New-Item -ItemType Directory -Path $AppSrc -Force | Out-Null }

# Helper: write UTF-8 without BOM (Node.js expects this)
function Copy-Utf8File {
    param([string]$Source, [string]$Dest)
    $parentDir = Split-Path -Parent $Dest
    if (-not (Test-Path $parentDir)) { New-Item -ItemType Directory -Path $parentDir -Force | Out-Null }
    $content = [System.IO.File]::ReadAllText($Source, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($Dest, $content, (New-Object System.Text.UTF8Encoding $false))
}

# Copy package.json
Copy-Utf8File (Join-Path $ScriptDir 'src\package.json') (Join-Path $App 'package.json')
Write-FileProgress 'package.json' 1 12

# Copy all source files
$sourceFiles = Get-ChildItem $SrcDir -Filter '*.mjs' | Sort-Object Name
$i = 1
foreach ($file in $sourceFiles) {
    $i++
    Copy-Utf8File $file.FullName (Join-Path $AppSrc $file.Name)
    Write-FileProgress $file.Name $i 12
}

$totalFiles = $i
Write-Ok "$totalFiles source files copied"

# ──────────────────────────────────────────────────────────────────────────────
# 7) Install dependencies
# ──────────────────────────────────────────────────────────────────────────────

Write-Step 7 8 'Dependencies'

Write-Info 'Running npm install ...'
Push-Location $App
try {
    if (Test-Path 'package-lock.json') {
        npm ci --loglevel=error
    } else {
        npm install --loglevel=error
    }
    $pkgCount = (Get-ChildItem (Join-Path $App 'node_modules') -Directory -ErrorAction SilentlyContinue).Count
    Write-Ok "$pkgCount packages installed"
} finally {
    Pop-Location
}

# ──────────────────────────────────────────────────────────────────────────────
# 8) Launch
# ──────────────────────────────────────────────────────────────────────────────

Write-Step 8 8 'Launch'

$elapsed = '{0:mm\:ss}' -f ((Get-Date) - $script:StartTime)

# ── Summary ──
Write-Host ''
$hl = ([string][char]0x2550) * 48
Write-Host "    $([char]0x2554)$hl$([char]0x2557)" -ForegroundColor DarkCyan
Write-Host "    $([char]0x2551)" -ForegroundColor DarkCyan -NoNewline
Write-Host '  Setup complete ' -ForegroundColor Green -NoNewline
Write-Host "$([char]0x2714)" -ForegroundColor Green -NoNewline
Write-Host "                               $([char]0x2551)" -ForegroundColor DarkCyan
Write-Host "    $([char]0x2560)$(([string][char]0x2500) * 48)$([char]0x2563)" -ForegroundColor DarkCyan
@(
    @('  Project:',  $ProjectName),
    @('  Repo:',     (Split-Path $RepoDir -Leaf)),
    @('  Runtime:',  "Node.js $(node -v)"),
    @('  Elapsed:',  $elapsed)
) | ForEach-Object {
    Write-Host "    $([char]0x2551)" -ForegroundColor DarkCyan -NoNewline
    Write-Host ("$($_[0])".PadRight(13)) -ForegroundColor Gray -NoNewline
    Write-Host ("$($_[1])".PadRight(35)) -ForegroundColor White -NoNewline
    Write-Host "$([char]0x2551)" -ForegroundColor DarkCyan
}
Write-Host "    $([char]0x255A)$hl$([char]0x255D)" -ForegroundColor DarkCyan
Write-Host ''

# ── Go ──
Write-Host '    ' -NoNewline
Write-Host " $([char]0x25BA) STARTING BOT " -ForegroundColor Black -BackgroundColor Green -NoNewline
Write-Host '  press ' -ForegroundColor DarkGray -NoNewline
Write-Host 'Ctrl+C' -ForegroundColor Yellow -NoNewline
Write-Host ' to stop' -ForegroundColor DarkGray
Write-Host ''

$env:PROJECT_NAME      = $ProjectName
$env:REPO_PATH         = $RepoDir
$env:ADMIN_USER_ID     = [Environment]::GetEnvironmentVariable('ADMIN_USER_ID','Process')
$env:STARTUP_CHANNEL_ID = [Environment]::GetEnvironmentVariable('STARTUP_CHANNEL_ID','Process')

& node (Join-Path $App 'src\bot.mjs')
