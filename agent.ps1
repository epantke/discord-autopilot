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
            $preview = $clip.Substring(0, [Math]::Min(6, $clip.Length)) + '...' + $clip.Substring([Math]::Max(0, $clip.Length - 4))
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
    Write-Host '  Needed for private repos and higher API rate limits.' -ForegroundColor Gray
    Write-Host '  Create one at: ' -ForegroundColor DarkGray -NoNewline
    Write-Host 'https://github.com/settings/tokens' -ForegroundColor Cyan
    Write-Host '  Required scopes: ' -ForegroundColor DarkGray -NoNewline
    Write-Host 'repo' -ForegroundColor White
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
        # preserve any extra keys from existing .env
        if (Test-Path $EnvFile) {
            $known = @('DISCORD_TOKEN','REPO_URL','GITHUB_TOKEN')
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
    try {
        $ghHeaders = @{
            Authorization = "token $ghToken"
            'User-Agent'  = 'discord-copilot-agent/1.0'
        }
        $ghResponse = Invoke-WebRequest -Uri 'https://api.github.com/user' -Headers $ghHeaders -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
        $ghUser = ($ghResponse.Content | ConvertFrom-Json).login
        $scopeHeader = $ghResponse.Headers['X-OAuth-Scopes']
        if ($scopeHeader -is [array]) { $scopes = $scopeHeader[0] } else { $scopes = [string]$scopeHeader }
        $hasRepoScope = $scopes -match '\brepo\b'
        if ($hasRepoScope) {
            Write-Check 'GitHub Token' "$ghUser (repo scope $([char]0x2714))" $true
        } else {
            Write-Check 'GitHub Token' "$ghUser (missing 'repo' scope)" $false
            Write-Warn "  Current scopes: $scopes"
            Write-Warn "  Private repos and push may not work without 'repo' scope."
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

# ── Repository URL accessibility ──
try {
    $lsOutput = & git ls-remote --exit-code $RepoUrl HEAD 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Check 'Repo Access' 'reachable' $true
    } else {
        $lsErr = ($lsOutput | Out-String).Trim()
        if ($lsErr.Length -gt 60) { $lsErr = $lsErr.Substring(0, 57) + '...' }
        Write-Check 'Repo Access' "unreachable ($lsErr)" $false
        Write-Warn '  Check URL, SSH keys, or network. Clone step may fail.'
    }
} catch {
    Write-Check 'Repo Access' "error: $($_.Exception.Message)" $false
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
# 6) Write application files
# ──────────────────────────────────────────────────────────────────────────────

Write-Step 6 8 'Source files'

# Helper: write UTF-8 without BOM (Node.js expects this)
function Write-Utf8File {
    param([string]$Path, [string]$Content)
    $parentDir = Split-Path -Parent $Path
    if (-not (Test-Path $parentDir)) { New-Item -ItemType Directory -Path $parentDir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false))
}
$script:fileNum = 0

# ── package.json ─────────────────────────────────────────────────────────────

$script:fileNum++; Write-FileProgress 'package.json' $script:fileNum 12
Write-Utf8File (Join-Path $App 'package.json') @'
{
  "name": "discord-copilot-agent",
  "version": "1.0.0",
  "type": "module",
  "private": true,
  "scripts": {
    "start": "node src/bot.mjs"
  },
  "dependencies": {
    "discord.js": "^14.16.0",
    "@github/copilot-sdk": "^0.1.25",
    "better-sqlite3": "^11.0.0"
  }
}
'@

# ── src/logger.mjs ──────────────────────────────────────────────────────────

$script:fileNum++; Write-FileProgress 'src/logger.mjs' $script:fileNum 12
Write-Utf8File (Join-Path $App 'src\logger.mjs') @'
const LOG_LEVELS = { debug: 0, info: 1, warn: 2, error: 3 };
const LEVEL = LOG_LEVELS[process.env.LOG_LEVEL?.toLowerCase()] ?? LOG_LEVELS.info;

function emit(level, component, message, data) {
  if (LOG_LEVELS[level] < LEVEL) return;
  const entry = {
    ts: new Date().toISOString(),
    level,
    component,
    msg: message,
  };
  if (data !== undefined) entry.data = data;
  const out = level === "error" ? process.stderr : process.stdout;
  try {
    out.write(JSON.stringify(entry) + "\n");
  } catch {
    out.write(`{"ts":"${entry.ts}","level":"${level}","component":"${component}","msg":"${String(message).replace(/"/g, '\\'+'"')}","serializeError":true}\n`);
  }
}

export function createLogger(component) {
  return {
    debug: (msg, data) => emit("debug", component, msg, data),
    info: (msg, data) => emit("info", component, msg, data),
    warn: (msg, data) => emit("warn", component, msg, data),
    error: (msg, data) => emit("error", component, msg, data),
  };
}
'@

# ── src/secret-scanner.mjs ──────────────────────────────────────────────────

$script:fileNum++; Write-FileProgress 'src/secret-scanner.mjs' $script:fileNum 12
Write-Utf8File (Join-Path $App 'src\secret-scanner.mjs') @'
import { createLogger } from "./logger.mjs";

const log = createLogger("secrets");

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

const envValues = new Set();
for (const [key, val] of Object.entries(process.env)) {
  if (val && val.length >= 8 && /TOKEN|SECRET|KEY|PASSWORD|CREDENTIAL/i.test(key)) {
    envValues.add(val);
  }
}

const REDACTED = "[REDACTED]";

export function redactSecrets(text) {
  if (!text) return { clean: text, found: [] };
  let clean = text;
  const found = [];

  for (const { label, re } of TOKEN_PATTERNS) {
    const global = new RegExp(re.source, re.flags.includes("g") ? re.flags : re.flags + "g");
    const replaced = clean.replace(global, REDACTED);
    if (replaced !== clean) {
      found.push(label);
      clean = replaced;
    }
  }

  for (const val of envValues) {
    if (clean.includes(val)) {
      found.push("ENV value");
      clean = clean.split(val).join(REDACTED);
    }
  }

  if (found.length > 0) {
    log.warn("Secrets redacted", { labels: found });
  }

  return { clean, found };
}
'@

# ── src/config.mjs ──────────────────────────────────────────────────────────

$script:fileNum++; Write-FileProgress 'src/config.mjs' $script:fileNum 12
Write-Utf8File (Join-Path $App 'src\config.mjs') @'
import { join } from "node:path";
import { homedir } from "node:os";
import { createLogger } from "./logger.mjs";

const log = createLogger("config");

const DISCORD_TOKEN = process.env.DISCORD_TOKEN;
if (!DISCORD_TOKEN) {
  log.error("DISCORD_TOKEN is not set. Export it and restart.");
  process.exit(1);
}

const BASE_ROOT =
  process.env.BASE_ROOT || join(homedir(), ".local", "share", "discord-agent");
const WORKSPACES_ROOT =
  process.env.WORKSPACES_ROOT || join(BASE_ROOT, "workspaces");
const REPOS_ROOT = join(BASE_ROOT, "repos");
const STATE_DB_PATH = join(BASE_ROOT, "state.sqlite");

const PROJECT_NAME = process.env.PROJECT_NAME || "default";
const REPO_PATH = process.env.REPO_PATH || join(REPOS_ROOT, PROJECT_NAME);

function csvToSet(envVal) {
  if (!envVal) return null;
  return new Set(envVal.split(",").map((s) => s.trim()).filter(Boolean));
}

const ALLOWED_GUILDS = csvToSet(process.env.ALLOWED_GUILDS);
const ALLOWED_CHANNELS = csvToSet(process.env.ALLOWED_CHANNELS);
const ADMIN_ROLE_IDS = csvToSet(process.env.ADMIN_ROLE_IDS);

function safeInt(envVal, fallback) {
  const n = parseInt(envVal, 10);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

const DISCORD_EDIT_THROTTLE_MS = safeInt(
  process.env.DISCORD_EDIT_THROTTLE_MS, 1500
);
const DEFAULT_GRANT_MODE = "ro";
const DEFAULT_GRANT_TTL_MIN = 30;
const TASK_TIMEOUT_MS = safeInt(
  process.env.TASK_TIMEOUT_MS, 30 * 60_000
);
const RATE_LIMIT_WINDOW_MS = safeInt(
  process.env.RATE_LIMIT_WINDOW_MS, 60_000
);
const RATE_LIMIT_MAX = safeInt(
  process.env.RATE_LIMIT_MAX, 10
);

export {
  DISCORD_TOKEN,
  BASE_ROOT,
  WORKSPACES_ROOT,
  REPOS_ROOT,
  STATE_DB_PATH,
  PROJECT_NAME,
  REPO_PATH,
  ALLOWED_GUILDS,
  ALLOWED_CHANNELS,
  ADMIN_ROLE_IDS,
  DISCORD_EDIT_THROTTLE_MS,
  DEFAULT_GRANT_MODE,
  DEFAULT_GRANT_TTL_MIN,
  TASK_TIMEOUT_MS,
  RATE_LIMIT_WINDOW_MS,
  RATE_LIMIT_MAX,
};
'@

# ── src/state.mjs ───────────────────────────────────────────────────────────

$script:fileNum++; Write-FileProgress 'src/state.mjs' $script:fileNum 12
Write-Utf8File (Join-Path $App 'src\state.mjs') @'
import Database from "better-sqlite3";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { STATE_DB_PATH } from "./config.mjs";

mkdirSync(dirname(STATE_DB_PATH), { recursive: true });

const db = new Database(STATE_DB_PATH);
db.pragma("journal_mode = WAL");
db.pragma("foreign_keys = ON");

// ── Migrations ──────────────────────────────────────────────────────────────

db.exec(`CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)`);

function getSchemaVersion() {
  const row = db.prepare("SELECT version FROM schema_version").get();
  return row ? row.version : 0;
}

function setSchemaVersion(v) {
  db.exec("DELETE FROM schema_version");
  db.prepare("INSERT INTO schema_version (version) VALUES (?)").run(v);
}

const migrations = [
  (db) => {
    db.exec(`
      CREATE TABLE IF NOT EXISTS sessions (
        channel_id    TEXT PRIMARY KEY,
        project_name  TEXT NOT NULL,
        workspace_path TEXT NOT NULL,
        branch        TEXT NOT NULL,
        status        TEXT NOT NULL DEFAULT 'idle',
        created_at    TEXT NOT NULL DEFAULT (datetime('now'))
      );
      CREATE TABLE IF NOT EXISTS grants (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        channel_id  TEXT NOT NULL,
        path        TEXT NOT NULL,
        mode        TEXT NOT NULL DEFAULT 'ro',
        expires_at  TEXT NOT NULL,
        UNIQUE(channel_id, path)
      );
      CREATE TABLE IF NOT EXISTS task_history (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        channel_id   TEXT NOT NULL,
        prompt       TEXT NOT NULL,
        status       TEXT NOT NULL DEFAULT 'running',
        started_at   TEXT NOT NULL DEFAULT (datetime('now')),
        completed_at TEXT
      );
      CREATE INDEX IF NOT EXISTS idx_task_history_channel
        ON task_history(channel_id, started_at DESC);
      CREATE INDEX IF NOT EXISTS idx_grants_channel
        ON grants(channel_id);
    `);
  },
  (db) => {
    db.exec(`ALTER TABLE task_history ADD COLUMN timeout_ms INTEGER`);
  },
];

function runMigrations() {
  const current = getSchemaVersion();
  if (current >= migrations.length) return;
  const upgrade = db.transaction(() => {
    for (let i = current; i < migrations.length; i++) migrations[i](db);
    setSchemaVersion(migrations.length);
  });
  upgrade();
}

runMigrations();

// ── Sessions ────────────────────────────────────────────────────────────────
const stmtUpsertSession = db.prepare(`
  INSERT INTO sessions (channel_id, project_name, workspace_path, branch, status)
  VALUES (@channelId, @projectName, @workspacePath, @branch, @status)
  ON CONFLICT(channel_id) DO UPDATE SET
    project_name   = excluded.project_name,
    workspace_path = excluded.workspace_path,
    branch         = excluded.branch,
    status         = excluded.status
`);
const stmtGetSession = db.prepare(`SELECT * FROM sessions WHERE channel_id = ?`);
const stmtAllSessions = db.prepare(`SELECT * FROM sessions`);
const stmtUpdateSessionStatus = db.prepare(`UPDATE sessions SET status = ? WHERE channel_id = ?`);
const stmtDeleteSession = db.prepare(`DELETE FROM sessions WHERE channel_id = ?`);

export function upsertSession(channelId, projectName, workspacePath, branch, status = "idle") {
  stmtUpsertSession.run({ channelId, projectName, workspacePath, branch, status });
}
export function getSession(channelId) { return stmtGetSession.get(channelId) || null; }
export function getAllSessions() { return stmtAllSessions.all(); }
export function updateSessionStatus(channelId, status) { stmtUpdateSessionStatus.run(status, channelId); }
export function deleteSession(channelId) { stmtDeleteSession.run(channelId); }

// ── Grants ──────────────────────────────────────────────────────────────────
const stmtUpsertGrant = db.prepare(`
  INSERT INTO grants (channel_id, path, mode, expires_at)
  VALUES (@channelId, @path, @mode, @expiresAt)
  ON CONFLICT(channel_id, path) DO UPDATE SET
    mode = excluded.mode, expires_at = excluded.expires_at
`);
const stmtGetGrants = db.prepare(`SELECT * FROM grants WHERE channel_id = ?`);
const stmtDeleteGrant = db.prepare(`DELETE FROM grants WHERE channel_id = ? AND path = ?`);
const stmtDeleteExpiredGrants = db.prepare(`DELETE FROM grants WHERE expires_at <= datetime('now')`);
const stmtDeleteGrantsByChannel = db.prepare(`DELETE FROM grants WHERE channel_id = ?`);

export function upsertGrant(channelId, grantPath, mode, expiresAt) {
  stmtUpsertGrant.run({ channelId, path: grantPath, mode, expiresAt });
}
export function getGrants(channelId) { return stmtGetGrants.all(channelId); }
export function deleteGrant(channelId, grantPath) { stmtDeleteGrant.run(channelId, grantPath); }
export function deleteExpiredGrants() { return stmtDeleteExpiredGrants.run(); }
export function deleteGrantsByChannel(channelId) { stmtDeleteGrantsByChannel.run(channelId); }

// ── Task History ────────────────────────────────────────────────────────────
const stmtInsertTask = db.prepare(`INSERT INTO task_history (channel_id, prompt, status) VALUES (?, ?, 'running')`);
const stmtCompleteTask = db.prepare(`UPDATE task_history SET status = ?, completed_at = datetime('now') WHERE id = ?`);
const stmtLatestTask = db.prepare(`SELECT * FROM task_history WHERE channel_id = ? ORDER BY started_at DESC LIMIT 1`);
const stmtTaskHistory = db.prepare(`SELECT * FROM task_history WHERE channel_id = ? ORDER BY started_at DESC LIMIT ?`);

export function insertTask(channelId, prompt) { return stmtInsertTask.run(channelId, prompt).lastInsertRowid; }
export function completeTask(taskId, status) { stmtCompleteTask.run(status, taskId); }
export function getLatestTask(channelId) { return stmtLatestTask.get(channelId) || null; }
export function getTaskHistory(channelId, limit = 10) { return stmtTaskHistory.all(channelId, limit); }

// ── Cleanup ─────────────────────────────────────────────────────────────────
export function purgeExpiredGrants() { return deleteExpiredGrants().changes; }

let dbClosed = false;

export function closeDb() {
  if (dbClosed) return;
  dbClosed = true;
  db.close();
}
'@

# ── src/policy-engine.mjs ───────────────────────────────────────────────────

$script:fileNum++; Write-FileProgress 'src/policy-engine.mjs' $script:fileNum 12
Write-Utf8File (Join-Path $App 'src\policy-engine.mjs') @'
import { realpathSync } from "node:fs";
import { resolve, sep } from "node:path";
import { createLogger } from "./logger.mjs";

const log = createLogger("policy");

function safePath(p) {
  try { return realpathSync(resolve(p)); } catch { return resolve(p); }
}

export function isInsideWorkspace(targetPath, workspaceRoot) {
  const resolvedTarget = safePath(targetPath);
  const resolvedRoot = safePath(workspaceRoot);
  return resolvedTarget === resolvedRoot || resolvedTarget.startsWith(resolvedRoot + sep);
}

const GIT_PUSH_PATTERNS = [
  /\bgit\s+push\b/i, /\bgit\s+remote\s+.*push\b/i,
  /\bgh\s+pr\s+create\b/i, /\bgh\s+pr\s+merge\b/i, /\bgh\s+pr\s+push\b/i,
];
const COMPOUND_SPLIT = /\s*(?:&&|\|\||[;|\n])\s*/;
const SUBSHELL_WRAPPER = /^\s*(?:sh|bash|zsh|dash)\s+-c\s+['"](.+)['"]\s*$/i;

function extractSubCommands(command) {
  const parts = command.split(COMPOUND_SPLIT).filter(Boolean);
  const result = [];
  for (const part of parts) {
    result.push(part);
    const m = SUBSHELL_WRAPPER.exec(part);
    if (m) result.push(...m[1].split(COMPOUND_SPLIT).filter(Boolean));
  }
  return result;
}

export function isGitPushCommand(command) {
  return extractSubCommands(command).some((part) =>
    GIT_PUSH_PATTERNS.some((re) => re.test(part))
  );
}

export function isGranted(targetPath, grants, requiredMode = "ro") {
  const resolvedTarget = safePath(targetPath);
  for (const [grantPath, grant] of grants) {
    if (Date.now() > grant.expiry) continue;
    const resolvedGrant = safePath(grantPath);
    const isUnder = resolvedTarget === resolvedGrant || resolvedTarget.startsWith(resolvedGrant + sep);
    if (!isUnder) continue;
    if (requiredMode === "ro") return true;
    if (requiredMode === "rw" && grant.mode === "rw") return true;
  }
  return false;
}

const SHELL_TOOLS = new Set(["shell", "bash", "run_in_terminal", "terminal"]);
const READ_TOOLS = new Set(["read_file", "list_directory", "search_files", "grep_search", "file_search", "semantic_search"]);
const WRITE_TOOLS = new Set(["write_file", "create_file", "delete_file", "replace_string_in_file", "edit_file", "rename_file"]);

function extractPath(a) { return a?.path || a?.filePath || a?.file || a?.directory || a?.target || null; }
function extractCommand(a) { return a?.command || a?.cmd || a?.input || ""; }
function extractCwd(a) { return a?.cwd || a?.workingDirectory || null; }

export function evaluateToolUse(toolName, toolArgs, workspaceRoot, grants) {
  if (SHELL_TOOLS.has(toolName)) {
    const cmd = extractCommand(toolArgs);
    if (isGitPushCommand(cmd)) {
      log.warn("Push blocked", { command: cmd });
      return { decision: "deny", reason: `git push requires Discord approval. Command: ${cmd}`, gate: "push" };
    }
    const cwd = extractCwd(toolArgs);
    if (cwd && !isInsideWorkspace(cwd, workspaceRoot) && !isGranted(cwd, grants, "ro")) {
      return { decision: "deny", reason: `Shell cwd outside workspace: ${cwd}`, gate: "outside" };
    }
    const cdMatch = cmd.match(/\bcd\s+["']?([^\s"';&|]+)/);
    if (cdMatch) {
      const cdTarget = resolve(workspaceRoot, cdMatch[1]);
      if (!isInsideWorkspace(cdTarget, workspaceRoot) && !isGranted(cdTarget, grants, "ro")) {
        return { decision: "deny", reason: `Shell cd outside workspace: ${cdTarget}`, gate: "outside" };
      }
    }
    return { decision: "allow" };
  }
  if (READ_TOOLS.has(toolName)) {
    const fp = extractPath(toolArgs);
    if (!fp) return { decision: "allow" };
    if (isInsideWorkspace(fp, workspaceRoot) || isGranted(fp, grants, "ro")) return { decision: "allow" };
    log.warn("Read access denied", { path: fp });
    return { decision: "deny", reason: `Read access outside workspace denied: ${fp}`, gate: "outside" };
  }
  if (WRITE_TOOLS.has(toolName)) {
    const fp = extractPath(toolArgs);
    if (!fp) return { decision: "allow" };
    if (isInsideWorkspace(fp, workspaceRoot) || isGranted(fp, grants, "rw")) return { decision: "allow" };
    log.warn("Write access denied", { path: fp });
    return { decision: "deny", reason: `Write access outside workspace denied: ${fp}`, gate: "outside" };
  }
  return { decision: "allow" };
}
'@

# ── src/grants.mjs ──────────────────────────────────────────────────────────

$script:fileNum++; Write-FileProgress 'src/grants.mjs' $script:fileNum 12
Write-Utf8File (Join-Path $App 'src\grants.mjs') @'
import { DEFAULT_GRANT_MODE, DEFAULT_GRANT_TTL_MIN } from "./config.mjs";
import {
  upsertGrant, deleteGrant, getGrants as dbGetGrants,
  deleteGrantsByChannel, purgeExpiredGrants,
} from "./state.mjs";
import { createLogger } from "./logger.mjs";

const log = createLogger("grants");
const grantStore = new Map();

function channelGrants(channelId) {
  if (!grantStore.has(channelId)) grantStore.set(channelId, new Map());
  return grantStore.get(channelId);
}

export function getActiveGrants(channelId) {
  const grants = channelGrants(channelId);
  const now = Date.now();
  for (const [p, g] of grants) {
    if (now > g.expiry) { clearTimeout(g.timer); grants.delete(p); }
  }
  return grants;
}

export function addGrant(channelId, grantPath, mode, ttlMinutes) {
  mode = mode || DEFAULT_GRANT_MODE;
  ttlMinutes = ttlMinutes ?? DEFAULT_GRANT_TTL_MIN;
  const expiry = Date.now() + ttlMinutes * 60_000;
  const expiresAt = new Date(expiry).toISOString();
  upsertGrant(channelId, grantPath, mode, expiresAt);
  const grants = channelGrants(channelId);
  const existing = grants.get(grantPath);
  if (existing?.timer) clearTimeout(existing.timer);
  const timer = setTimeout(() => { revokeGrant(channelId, grantPath); }, ttlMinutes * 60_000);
  timer.unref();
  grants.set(grantPath, { mode, expiry, timer });
  log.info("Grant added", { channelId, path: grantPath, mode, ttlMinutes });
  return { path: grantPath, mode, ttlMinutes, expiresAt };
}

export function revokeGrant(channelId, grantPath) {
  const grants = channelGrants(channelId);
  const existing = grants.get(grantPath);
  if (existing?.timer) clearTimeout(existing.timer);
  grants.delete(grantPath);
  deleteGrant(channelId, grantPath);
  log.info("Grant revoked", { channelId, path: grantPath });
  return true;
}

export function revokeAllGrants(channelId) {
  const grants = channelGrants(channelId);
  for (const [, g] of grants) { if (g.timer) clearTimeout(g.timer); }
  grants.clear();
  deleteGrantsByChannel(channelId);
}

export function restoreGrants(channelId) {
  const rows = dbGetGrants(channelId);
  const now = Date.now();
  for (const row of rows) {
    const expiry = new Date(row.expires_at).getTime();
    if (expiry <= now) continue;
    const grants = channelGrants(channelId);
    const timer = setTimeout(() => { revokeGrant(channelId, row.path); }, expiry - now);
    timer.unref();
    grants.set(row.path, { mode: row.mode, expiry, timer });
  }
}

export function startGrantCleanup(intervalMs = 60_000) {
  const timer = setInterval(() => { purgeExpiredGrants(); }, intervalMs);
  timer.unref();
  return timer;
}
'@

# ── src/discord-output.mjs ──────────────────────────────────────────────────

$script:fileNum++; Write-FileProgress 'src/discord-output.mjs' $script:fileNum 12
Write-Utf8File (Join-Path $App 'src\discord-output.mjs') @'
import { DISCORD_EDIT_THROTTLE_MS } from "./config.mjs";
import { AttachmentBuilder } from "discord.js";
import { redactSecrets } from "./secret-scanner.mjs";

export class DiscordOutput {
  constructor(channel) {
    this.channel = channel;
    this.buffer = "";
    this.message = null;
    this.lastEdit = 0;
    this.editTimer = null;
    this.finished = false;
    this._flushing = false;
    this._flushQueued = false;
  }

  append(text) {
    if (this.finished) return;
    this.buffer += text;
    this._scheduleEdit();
  }

  async status(text) {
    if (this.finished) return;
    try {
      if (this.buffer.length + text.length + 2 < 1900) {
        this.buffer += `\n${text}`;
        this._scheduleEdit();
        return;
      }
      await this.flush();
      this.buffer = text;
      this._scheduleEdit();
    } catch { /* swallow */ }
  }

  async finish(epilogue = "") {
    this.finished = true;
    if (this.editTimer) { clearTimeout(this.editTimer); this.editTimer = null; }
    if (epilogue) this.buffer += `\n${epilogue}`;
    try {
      await this.flush();
    } catch {
      // Best-effort final flush
    }
  }

  async flush() {
    if (!this.buffer) return;
    if (this._flushing) { this._flushQueued = true; return; }
    this._flushing = true;
    const content = redactSecrets(this.buffer).clean;
    this.buffer = "";

    try {
      if (content.length <= 1990) {
        if (this.message) await this.message.edit(content);
        else this.message = await this.channel.send(content);
      } else {
        await this._sendAsAttachment(content);
        this.message = null;
      }
    } catch (err) {
      if (err.code === 10008 || err.code === 50005) {
        this.message = null;
        try {
          if (content.length <= 1990) this.message = await this.channel.send(content);
          else await this._sendAsAttachment(content);
        } catch { /* give up */ }
      }
    } finally {
      this._flushing = false;
      if (this._flushQueued) { this._flushQueued = false; await this.flush(); }
    }
  }

  async _sendAsAttachment(content) {
    const attachment = new AttachmentBuilder(Buffer.from(content, "utf-8"), {
      name: "output.txt", description: "Agent output (too large for a message)",
    });
    await this.channel.send({ files: [attachment] });
  }

  _scheduleEdit() {
    if (this.finished || this.editTimer) return;
    const elapsed = Date.now() - this.lastEdit;
    const delay = Math.max(0, DISCORD_EDIT_THROTTLE_MS - elapsed);
    this.editTimer = setTimeout(async () => {
      this.editTimer = null;
      this.lastEdit = Date.now();
      await this.flush();
    }, delay);
  }
}
'@

# ── src/push-approval.mjs ───────────────────────────────────────────────────

$script:fileNum++; Write-FileProgress 'src/push-approval.mjs' $script:fileNum 12
Write-Utf8File (Join-Path $App 'src\push-approval.mjs') @'
import {
  EmbedBuilder, ActionRowBuilder, ButtonBuilder, ButtonStyle,
} from "discord.js";
import { execSync } from "node:child_process";
import { redactSecrets } from "./secret-scanner.mjs";

export async function createPushApprovalRequest(channel, workspacePath, command) {
  let diffSummary = "";
  let logSummary = "";

  try {
    diffSummary = redactSecrets(
      execSync("git diff --stat HEAD~1 2>nul || git diff --stat", {
        cwd: workspacePath, encoding: "utf-8", timeout: 10_000, shell: true,
      }).slice(0, 900)
    ).clean;
  } catch { diffSummary = "(diff unavailable)"; }

  try {
    logSummary = redactSecrets(
      execSync("git log --oneline -5", {
        cwd: workspacePath, encoding: "utf-8", timeout: 5_000,
      }).slice(0, 500)
    ).clean;
  } catch { logSummary = "(log unavailable)"; }

  const embed = new EmbedBuilder()
    .setTitle("\u{1F680} Push Approval Required")
    .setColor(0xff9900)
    .setDescription(`The agent wants to execute:\n\`\`\`\n${command.slice(0, 200)}\n\`\`\``)
    .addFields(
      { name: "Recent Commits", value: `\`\`\`\n${logSummary}\n\`\`\``, inline: false },
      { name: "Diff Summary", value: `\`\`\`\n${diffSummary}\n\`\`\``, inline: false },
      { name: "Workspace", value: workspacePath, inline: true }
    )
    .setTimestamp();

  const row = new ActionRowBuilder().addComponents(
    new ButtonBuilder().setCustomId("push_approve").setLabel("\u2705 Approve Push").setStyle(ButtonStyle.Success),
    new ButtonBuilder().setCustomId("push_reject").setLabel("\u274C Reject Push").setStyle(ButtonStyle.Danger)
  );

  let msg;
  try {
    msg = await channel.send({ embeds: [embed], components: [row] });
  } catch (err) {
    return { approved: false, user: `(send failed: ${err.message})` };
  }

  return new Promise((resolve) => {
    const collector = msg.createMessageComponentCollector({
      filter: (i) => i.customId === "push_approve" || i.customId === "push_reject",
      max: 1, time: 600_000,
    });

    collector.on("collect", async (interaction) => {
      const approved = interaction.customId === "push_approve";
      const label = approved ? "\u2705 Push approved" : "\u274C Push rejected";
      const color = approved ? 0x00cc00 : 0xcc0000;
      const updatedEmbed = EmbedBuilder.from(embed)
        .setColor(color)
        .setFooter({ text: `${label} by ${interaction.user.tag}` });
      try {
        await interaction.update({ embeds: [updatedEmbed], components: [] });
      } catch {}

      resolve({ approved, user: interaction.user.tag });
    });

    collector.on("end", (collected) => {
      if (collected.size === 0) {
        msg.edit({ components: [] }).catch(() => {});
        resolve({ approved: false, user: "(timeout)" });
      }
    });
  });
}

export async function executePush(channel, workspacePath, command) {
  try {
    const output = execSync(command, {
      cwd: workspacePath, encoding: "utf-8", timeout: 60_000,
    });

    const embed = new EmbedBuilder()
      .setTitle("\u2705 Push Successful").setColor(0x00cc00)
      .setDescription(`\`\`\`\n${(output || "(no output)").slice(0, 1800)}\n\`\`\``)
      .setTimestamp();

    const row = new ActionRowBuilder().addComponents(
      new ButtonBuilder().setCustomId("create_pr").setLabel("\u{1F4DD} Create PR").setStyle(ButtonStyle.Primary)
    );

    const msg = await channel.send({ embeds: [embed], components: [row] });

    const collector = msg.createMessageComponentCollector({
      filter: (i) => i.customId === "create_pr", max: 1, time: 600_000,
    });

    collector.on("collect", async (interaction) => {
      try { await interaction.deferUpdate(); } catch {}
      try {
        const prOutput = execSync("gh pr create --fill 2>&1", {
          cwd: workspacePath, encoding: "utf-8", timeout: 30_000, shell: true,
        });
        const prEmbed = new EmbedBuilder()
          .setTitle("\u{1F4DD} PR Created").setColor(0x6e5494)
          .setDescription(redactSecrets(prOutput.slice(0, 1800)).clean).setTimestamp();
        await msg.edit({ embeds: [embed, prEmbed], components: [] });
      } catch (err) {
        const errEmbed = new EmbedBuilder()
          .setTitle("\u274C PR Creation Failed").setColor(0xcc0000)
          .setDescription(`\`\`\`\n${(err.stderr || err.message || "").slice(0, 1000)}\n\`\`\``).setTimestamp();
        await msg.edit({ embeds: [embed, errEmbed], components: [] });
      }
    });

    collector.on("end", (collected) => {
      if (collected.size === 0) msg.edit({ components: [] }).catch(() => {});
    });

    return { success: true, output };
  } catch (err) {
    const embed = new EmbedBuilder()
      .setTitle("\u274C Push Failed").setColor(0xcc0000)
      .setDescription(`\`\`\`\n${(err.stderr || err.message || "").slice(0, 1800)}\n\`\`\``).setTimestamp();
    await channel.send({ embeds: [embed] });
    return { success: false, error: err.message };
  }
}
'@

# ── src/copilot-client.mjs ──────────────────────────────────────────────────

$script:fileNum++; Write-FileProgress 'src/copilot-client.mjs' $script:fileNum 12
Write-Utf8File (Join-Path $App 'src\copilot-client.mjs') @'
import { CopilotClient } from "@github/copilot-sdk";
import { evaluateToolUse } from "./policy-engine.mjs";
import { getActiveGrants } from "./grants.mjs";
import { createLogger } from "./logger.mjs";

const log = createLogger("copilot");
const approveAll = () => ({ kind: "approved" });
let client = null;

export function getCopilotClient() {
  if (!client) {
    client = new CopilotClient({ useStdio: true, autoRestart: true });
  }
  return client;
}

export async function createAgentSession(opts) {
  const {
    channelId, workspacePath,
    onPushRequest, onOutsideRequest,
    onDelta, onToolStart, onToolComplete, onIdle, onUserQuestion,
  } = opts;

  const copilot = getCopilotClient();

  const session = await copilot.createSession({
    workingDirectory: workspacePath,
    streaming: true,
    onPermissionRequest: approveAll,

    onUserInputRequest: async (request) => {
      if (onUserQuestion) {
        const answer = await onUserQuestion(request.question, request.choices);
        return { answer, wasFreeform: !request.choices };
      }
      return { answer: "No user available. Proceed with your best judgment.", wasFreeform: true };
    },

    hooks: {
      onPreToolUse: async (input) => {
        const grants = getActiveGrants(channelId);
        const result = evaluateToolUse(input.toolName, input.toolArgs, workspacePath, grants);
        if (result.decision === "allow") return { permissionDecision: "allow" };

        if (result.gate === "push") {
          if (onPushRequest) {
            const command = input.toolArgs?.command || input.toolArgs?.cmd || "";
            const { approved } = await onPushRequest(command);
            if (approved) return { permissionDecision: "allow" };
          }
          return {
            permissionDecision: "deny",
            additionalContext: "Push was denied. Do NOT retry pushing.",
          };
        }

        if (result.gate === "outside") {
          if (onOutsideRequest) onOutsideRequest(result.reason);
          return {
            permissionDecision: "deny",
            additionalContext: `Access denied: ${result.reason}. Use /grant first.`,
          };
        }

        return { permissionDecision: "deny", additionalContext: result.reason || "Denied by policy." };
      },

      onErrorOccurred: async (input) => {
        log.error("Agent error", { error: input.error, context: input.errorContext });
        return { errorHandling: "skip" };
      },
    },

    systemMessage: {
      content: [
        `You are an autonomous coding agent working in: ${workspacePath}`,
        "You may freely edit files, run tests, lint, build, and create git branches/commits within the workspace.",
        "IMPORTANT RULES:",
        "1. You CANNOT git push or publish PRs without explicit user approval.",
        "2. You CANNOT access files outside the workspace without explicit grants.",
        "3. If a push is denied, inform the user and stop retrying.",
        "4. If file access is denied, tell the user which path you need and ask them to use /grant.",
        "5. Always run tests before suggesting a push.",
        "6. Provide clear summaries of what you changed and why.",
      ].join("\n"),
    },
  });

  if (onDelta) session.on("assistant.message_delta", (e) => { onDelta(e.data?.deltaContent || ""); });
  if (onToolStart) session.on("tool.execution_start", (e) => { onToolStart(e.data?.toolName || "unknown"); });
  if (onToolComplete) session.on("tool.execution_complete", (e) => {
    onToolComplete(e.data?.toolName || "unknown", e.data?.success ?? true, e.data?.error);
  });
  if (onIdle) session.on("session.idle", () => { onIdle(); });

  return session;
}

export async function stopCopilotClient() {
  if (client) {
    const c = client;
    client = null;
    try { await c.stop(); } catch {}
  }
}
'@

# ── src/session-manager.mjs ─────────────────────────────────────────────────

$script:fileNum++; Write-FileProgress 'src/session-manager.mjs' $script:fileNum 12
Write-Utf8File (Join-Path $App 'src\session-manager.mjs') @'
import { execSync } from "node:child_process";
import { mkdirSync, existsSync } from "node:fs";
import { join } from "node:path";
import { WORKSPACES_ROOT, PROJECT_NAME, REPO_PATH, TASK_TIMEOUT_MS } from "./config.mjs";
import {
  upsertSession, getSession, getAllSessions,
  updateSessionStatus, deleteSession as dbDeleteSession,
  insertTask, completeTask,
  getTaskHistory as dbGetTaskHistory,
} from "./state.mjs";
import { createAgentSession } from "./copilot-client.mjs";
import { getActiveGrants, restoreGrants, revokeAllGrants } from "./grants.mjs";
import { DiscordOutput } from "./discord-output.mjs";
import { createPushApprovalRequest } from "./push-approval.mjs";
import { createLogger } from "./logger.mjs";

const log = createLogger("session");
const sessions = new Map();

function createWorktree(channelId) {
  const wsRoot = join(WORKSPACES_ROOT, PROJECT_NAME);
  mkdirSync(wsRoot, { recursive: true });
  const worktreePath = join(wsRoot, channelId);

  if (existsSync(worktreePath)) {
    let branch;
    try {
      branch = execSync("git branch --show-current", {
        cwd: worktreePath, encoding: "utf-8", stdio: ["pipe", "pipe", "pipe"],
      }).trim();
    } catch { branch = `agent/${channelId.slice(-8)}-recovered`; }
    return { workspacePath: worktreePath, branch };
  }

  const branchName = `agent/${channelId.slice(-8)}-${Date.now().toString(36)}`;
  try { execSync(`git branch "${branchName}" HEAD`, { cwd: REPO_PATH, stdio: "pipe" }); } catch {}
  try {
    execSync(`git worktree add "${worktreePath}" "${branchName}"`, { cwd: REPO_PATH, stdio: "pipe" });
  } catch (err) { if (!existsSync(worktreePath)) throw err; }

  return { workspacePath: worktreePath, branch: branchName };
}

export async function getOrCreateSession(channelId, channel) {
  if (sessions.has(channelId)) return sessions.get(channelId);

  const dbRow = getSession(channelId);
  let workspacePath, branch;
  if (dbRow && existsSync(dbRow.workspace_path)) {
    workspacePath = dbRow.workspace_path; branch = dbRow.branch;
  } else {
    const wt = createWorktree(channelId);
    workspacePath = wt.workspacePath; branch = wt.branch;
  }

  // Create Copilot session with policy hooks — retry once on transient failure
  let copilotSession;
  for (let attempt = 1; attempt <= 2; attempt++) {
    try {
      copilotSession = await createAgentSession({
    channelId, workspacePath,
    onPushRequest: async (command) => createPushApprovalRequest(channel, workspacePath, command),
    onOutsideRequest: (reason) => {
      channel.send(`\u26D4 **Access Denied**\n${reason}\n\nUse \`/grant path:<path> mode:ro ttl:30\` to allow.`).catch(() => {});
    },
    onDelta: (text) => { sessions.get(channelId)?.output?.append(text); },
    onToolStart: (toolName) => { sessions.get(channelId)?.output?.status(`\u{1F527} \`${toolName}\`\u2026`); },
    onToolComplete: (toolName, success, error) => {
      const ctx = sessions.get(channelId);
      const icon = success ? "\u2705" : "\u274C";
      ctx?.output?.status(`${icon} \`${toolName}\`${error ? `: ${error}` : ""}`);
    },
    onIdle: () => {
      const ctx = sessions.get(channelId);
      if (ctx) { ctx.output?.finish("\u2728 **Task complete.**"); ctx.status = "idle"; updateSessionStatus(channelId, "idle"); }
    },
    onUserQuestion: async (question, choices) => {
      await channel.send(`\u2753 **Agent asks:**\n${question}${choices ? `\nOptions: ${choices.join(", ")}` : ""}`);
      try {
        const collected = await channel.awaitMessages({ max: 1, time: 300_000, filter: (m) => !m.author.bot });
        return collected.first()?.content || "No answer provided.";
      } catch { return "No answer within timeout."; }
    },
  });
      break; // success
    } catch (err) {
      if (attempt >= 2) throw err;
      log.warn("Session creation failed, retrying", { channelId, error: err.message });
      await new Promise((r) => setTimeout(r, 2_000));
    }
  }

  const ctx = {
    copilotSession, workspacePath, branch, status: "idle",
    currentTask: null, queue: [], output: null, taskId: null,
    paused: false, _aborted: false,
  };
  sessions.set(channelId, ctx);
  upsertSession(channelId, PROJECT_NAME, workspacePath, branch, "idle");
  log.info("Session created", { channelId, branch, workspace: workspacePath });
  restoreGrants(channelId);
  return ctx;
}

export async function enqueueTask(channelId, channel, prompt, outputChannel) {
  const ctx = await getOrCreateSession(channelId, channel);
  return new Promise((resolve, reject) => {
    ctx.queue.push({ prompt, resolve, reject, outputChannel: outputChannel || channel });
    processQueue(channelId, channel);
  });
}

async function processQueue(channelId, channel) {
  const ctx = sessions.get(channelId);
  if (!ctx || ctx.status === "working" || ctx.paused || ctx.queue.length === 0) return;

  const { prompt, resolve, reject, outputChannel } = ctx.queue.shift();
  ctx.status = "working";
  updateSessionStatus(channelId, "working");
  ctx.output = new DiscordOutput(outputChannel);
  ctx.taskId = insertTask(channelId, prompt);
  log.info("Task started", { channelId, taskId: ctx.taskId, prompt: prompt.slice(0, 100) });

  let timeoutTimer;
  try {
    const timeout = new Promise((_, rej) => { timeoutTimer = setTimeout(() => rej(new Error("Task timed out")), TASK_TIMEOUT_MS); timeoutTimer.unref(); });
    const response = await Promise.race([ctx.copilotSession.sendAndWait({ prompt }), timeout]);
    clearTimeout(timeoutTimer);
    completeTask(ctx.taskId, "completed");
    log.info("Task completed", { channelId, taskId: ctx.taskId });
    ctx.status = "idle"; updateSessionStatus(channelId, "idle");
    resolve(response);
  } catch (err) {
    clearTimeout(timeoutTimer);
    if (ctx._aborted) { ctx._aborted = false; }
    else if (err.message === "Task timed out") {
      log.warn("Task timed out", { channelId, taskId: ctx.taskId, timeoutMs: TASK_TIMEOUT_MS });
      ctx._aborted = true;
      try { ctx.copilotSession.abort(); } catch {}
      completeTask(ctx.taskId, "aborted");
      ctx.output?.finish(`\u23F1 **Task timed out** after ${Math.round(TASK_TIMEOUT_MS / 60_000)} min.`);
      ctx.status = "idle"; updateSessionStatus(channelId, "idle");
    } else {
      completeTask(ctx.taskId, "failed");
      ctx.status = "idle"; updateSessionStatus(channelId, "idle");
      ctx.output?.finish(`\u274C **Error:** ${err.message}`);
    }
    reject(err);
  } finally {
    ctx.output = null;
    if (!ctx.paused) processQueue(channelId, channel);
  }
}

export async function approvePendingPush(channelId, channel) {
  const ctx = sessions.get(channelId);
  if (!ctx) return { found: false };
  await channel.send("\u2139\uFE0F Use the **Approve Push** button on the push request message.");
  return { found: true };
}

export function getSessionStatus(channelId) {
  const ctx = sessions.get(channelId);
  if (!ctx) return null;
  const grants = getActiveGrants(channelId);
  const grantList = [];
  for (const [p, g] of grants) {
    grantList.push({ path: p, mode: g.mode, expiresIn: Math.max(0, Math.round((g.expiry - Date.now()) / 60_000)) });
  }
  return { status: ctx.status, paused: ctx.paused, workspace: ctx.workspacePath, branch: ctx.branch, queueLength: ctx.queue.length, grants: grantList };
}

export async function resetSession(channelId) {
  const ctx = sessions.get(channelId);
  if (ctx) {
    try { ctx.copilotSession.abort(); } catch {}
    try { ctx.copilotSession.destroy(); } catch {}
    for (const item of ctx.queue) {
      try { item.reject(new Error("Session reset")); } catch {}
    }
  }
  sessions.delete(channelId);
  try { revokeAllGrants(channelId); } catch (err) { log.error("Failed to revoke grants on reset", { channelId, error: err.message }); }
  try { dbDeleteSession(channelId); } catch (err) { log.error("Failed to delete session from DB", { channelId, error: err.message }); }
}

export function hardStop(channelId, clearQueue = true) {
  const ctx = sessions.get(channelId);
  if (!ctx) return { found: false };
  const wasWorking = ctx.status === "working";
  let queueCleared = 0;
  if (wasWorking) {
    ctx._aborted = true;
    try { ctx.copilotSession.abort(); } catch {}
    if (ctx.taskId) { completeTask(ctx.taskId, "aborted"); ctx.taskId = null; }
    ctx.output?.finish("\u{1F6D1} **Task aborted by user.**");
    ctx.output = null; ctx.status = "idle"; updateSessionStatus(channelId, "idle");
  }
  if (clearQueue && ctx.queue.length > 0) {
    queueCleared = ctx.queue.length;
    for (const item of ctx.queue) item.reject(new Error("Cleared by /stop"));
    ctx.queue = [];
  }
  return { found: true, wasWorking, queueCleared };
}

export function pauseSession(channelId) {
  const ctx = sessions.get(channelId);
  if (!ctx) return { found: false };
  ctx.paused = true;
  return { found: true };
}

export function resumeSession(channelId, channel) {
  const ctx = sessions.get(channelId);
  if (!ctx) return { found: false };
  const wasPaused = ctx.paused;
  ctx.paused = false;
  if (wasPaused && ctx.queue.length > 0) processQueue(channelId, channel);
  return { found: true, wasPaused };
}

export function clearQueue(channelId) {
  const ctx = sessions.get(channelId);
  if (!ctx) return { found: false, cleared: 0 };
  const cleared = ctx.queue.length;
  for (const item of ctx.queue) item.reject(new Error("Queue cleared"));
  ctx.queue = [];
  return { found: true, cleared };
}

export function getQueueInfo(channelId) {
  const ctx = sessions.get(channelId);
  if (!ctx) return null;
  return { paused: ctx.paused, length: ctx.queue.length, items: ctx.queue.map((q, i) => ({ index: i + 1, prompt: q.prompt.slice(0, 100) })) };
}

export function getTaskHistory(channelId, limit = 10) { return dbGetTaskHistory(channelId, limit); }
export function getStoredSessions() { return getAllSessions(); }
'@

# ── src/bot.mjs ──────────────────────────────────────────────────────────────

$script:fileNum++; Write-FileProgress 'src/bot.mjs' $script:fileNum 12
Write-Utf8File (Join-Path $App 'src\bot.mjs') @'
import {
  Client, GatewayIntentBits, REST, Routes,
  SlashCommandBuilder, EmbedBuilder, AttachmentBuilder,
} from "discord.js";
import {
  DISCORD_TOKEN, ALLOWED_GUILDS, ALLOWED_CHANNELS,
  ADMIN_ROLE_IDS, PROJECT_NAME, DISCORD_EDIT_THROTTLE_MS,
  DEFAULT_GRANT_MODE, DEFAULT_GRANT_TTL_MIN,
  BASE_ROOT, WORKSPACES_ROOT, REPO_PATH,
  RATE_LIMIT_WINDOW_MS, RATE_LIMIT_MAX,
} from "./config.mjs";
import {
  enqueueTask, getSessionStatus, approvePendingPush, resetSession,
  hardStop, pauseSession, resumeSession, clearQueue, getQueueInfo, getTaskHistory,
} from "./session-manager.mjs";
import { addGrant, revokeGrant, startGrantCleanup, restoreGrants } from "./grants.mjs";
import { closeDb, getAllSessions } from "./state.mjs";
import { stopCopilotClient } from "./copilot-client.mjs";
import { redactSecrets } from "./secret-scanner.mjs";
import { createLogger } from "./logger.mjs";
import { execSync } from "node:child_process";

const log = createLogger("bot");

const commands = [
  new SlashCommandBuilder().setName("task").setDescription("Send a task to the coding agent")
    .addStringOption((o) => o.setName("prompt").setDescription("Task description").setRequired(true)),
  new SlashCommandBuilder().setName("status").setDescription("Show current agent session status"),
  new SlashCommandBuilder().setName("approve_push").setDescription("Approve a pending git push"),
  new SlashCommandBuilder().setName("grant").setDescription("Grant agent access to a path outside workspace")
    .addStringOption((o) => o.setName("path").setDescription("Absolute path to grant").setRequired(true))
    .addStringOption((o) => o.setName("mode").setDescription("Access mode").addChoices({ name: "Read Only", value: "ro" }, { name: "Read/Write", value: "rw" }))
    .addIntegerOption((o) => o.setName("ttl").setDescription("TTL in minutes (default: 30)").setMinValue(1).setMaxValue(1440)),
  new SlashCommandBuilder().setName("revoke").setDescription("Revoke agent access to a path")
    .addStringOption((o) => o.setName("path").setDescription("Absolute path to revoke").setRequired(true)),
  new SlashCommandBuilder().setName("reset").setDescription("Reset the agent session for this channel"),
  new SlashCommandBuilder().setName("stop").setDescription("Hard stop \u2014 abort the running task immediately")
    .addBooleanOption((o) => o.setName("clear_queue").setDescription("Also clear all pending tasks (default: true)")),
  new SlashCommandBuilder().setName("pause").setDescription("Pause queue processing"),
  new SlashCommandBuilder().setName("resume").setDescription("Resume queue processing after a pause"),
  new SlashCommandBuilder().setName("queue").setDescription("View or manage the task queue")
    .addStringOption((o) => o.setName("action").setDescription("What to do").addChoices({ name: "List", value: "list" }, { name: "Clear", value: "clear" })),
  new SlashCommandBuilder().setName("history").setDescription("Show recent task history")
    .addIntegerOption((o) => o.setName("limit").setDescription("Number of tasks (default: 10)").setMinValue(1).setMaxValue(50)),
  new SlashCommandBuilder().setName("config").setDescription("View current bot configuration"),
  new SlashCommandBuilder().setName("diff").setDescription("Show git diff for the agent workspace")
    .addStringOption((o) => o.setName("mode").setDescription("Diff mode").addChoices({ name: "Summary (stat)", value: "stat" }, { name: "Full diff", value: "full" }, { name: "Staged only", value: "staged" })),
  new SlashCommandBuilder().setName("branch").setDescription("Manage agent branches")
    .addStringOption((o) => o.setName("action").setDescription("What to do").addChoices({ name: "List branches", value: "list" }, { name: "Show current", value: "current" }, { name: "Create new", value: "create" }, { name: "Switch", value: "switch" }))
    .addStringOption((o) => o.setName("name").setDescription("Branch name (for create/switch)")),
];

function isAllowed(interaction) {
  if (ALLOWED_GUILDS && !ALLOWED_GUILDS.has(interaction.guildId)) return false;
  if (ALLOWED_CHANNELS && !ALLOWED_CHANNELS.has(interaction.channelId)) return false;
  if (ADMIN_ROLE_IDS) {
    const roles = interaction.member?.roles?.cache;
    if (roles && ![...ADMIN_ROLE_IDS].some((id) => roles.has(id))) return false;
  }
  return true;
}

function isAdmin(interaction) {
  if (!ADMIN_ROLE_IDS) return true;
  const roles = interaction.member?.roles?.cache;
  return roles ? [...ADMIN_ROLE_IDS].some((id) => roles.has(id)) : false;
}

const rateLimitMap = new Map();
function isRateLimited(interaction) {
  if (isAdmin(interaction)) return false;
  const userId = interaction.user.id;
  const now = Date.now();
  let ts = rateLimitMap.get(userId);
  if (!ts) { ts = []; rateLimitMap.set(userId, ts); }
  const cutoff = now - RATE_LIMIT_WINDOW_MS;
  while (ts.length > 0 && ts[0] <= cutoff) ts.shift();
  if (ts.length >= RATE_LIMIT_MAX) return true;
  ts.push(now);
  return false;
}

async function registerCommands(clientId) {
  const rest = new REST({ version: "10" }).setToken(DISCORD_TOKEN);
  const body = commands.map((c) => c.toJSON());
  if (ALLOWED_GUILDS && ALLOWED_GUILDS.size > 0) {
    for (const guildId of ALLOWED_GUILDS) {
      try {
        await rest.put(Routes.applicationGuildCommands(clientId, guildId), { body });
        log.info("Registered commands", { guildId });
      } catch (err) {
        log.error("Failed to register commands for guild", { guildId, error: err.message });
      }
    }
  } else {
    await rest.put(Routes.applicationCommands(clientId), { body });
    log.info("Registered global commands");
  }
}

const client = new Client({
  intents: [GatewayIntentBits.Guilds, GatewayIntentBits.GuildMessages, GatewayIntentBits.MessageContent],
});

client.once("ready", async () => {
  log.info("Logged in", { tag: client.user.tag });
  try { await registerCommands(client.user.id); } catch (err) {
    log.error("Failed to register commands", { error: err.message });
  }
  startGrantCleanup();
  for (const row of getAllSessions()) restoreGrants(row.channel_id);
  log.info("Bot ready", { project: PROJECT_NAME });
});

client.on("interactionCreate", async (interaction) => {
  if (!interaction.isChatInputCommand() && !interaction.isButton()) return;
  if (interaction.isButton()) return;
  if (!isAllowed(interaction)) { await interaction.reply({ content: "\u26D4 No permission.", ephemeral: true }); return; }
  if (isRateLimited(interaction)) {
    await interaction.reply({ content: `\u23F3 Rate limited. Max ${RATE_LIMIT_MAX} commands per ${Math.round(RATE_LIMIT_WINDOW_MS / 1000)}s.`, ephemeral: true });
    return;
  }

  const { commandName, channelId } = interaction;
  const channel = interaction.channel;

  try {
    switch (commandName) {
      case "task": {
        const prompt = interaction.options.getString("prompt");
        await interaction.reply(`\u{1F4CB} **Task queued:** ${prompt}`);
        let outputChannel = channel;
        try {
          const reply = await interaction.fetchReply();
          const thread = await reply.startThread({ name: `Task: ${prompt.slice(0, 90)}`, autoArchiveDuration: 1440 });
          outputChannel = thread;
        } catch (err) {
          log.warn("Failed to create thread, using channel", { error: err.message });
        }
        enqueueTask(channelId, channel, prompt, outputChannel).catch((err) => {
          outputChannel.send(`\u274C **Task failed:** ${err.message}`).catch(() => {});
        });
        break;
      }
      case "status": {
        const st = getSessionStatus(channelId);
        if (!st) { await interaction.reply({ content: "No active session.", ephemeral: true }); break; }
        const grantLines = st.grants.length ? st.grants.map((g) => `\`${g.path}\` (${g.mode}, ${g.expiresIn}min)`).join("\n") : "None";
        const embed = new EmbedBuilder().setTitle("\u{1F4CA} Agent Status")
          .setColor(st.paused ? 0xff6600 : st.status === "working" ? 0x3498db : 0x2ecc71)
          .addFields(
            { name: "Status", value: st.paused ? `${st.status} (\u23F8 paused)` : st.status, inline: true },
            { name: "Branch", value: st.branch, inline: true },
            { name: "Queue", value: `${st.queueLength} pending`, inline: true },
            { name: "Workspace", value: `\`${st.workspace}\``, inline: false },
            { name: "Active Grants", value: grantLines, inline: false },
          ).setTimestamp();
        await interaction.reply({ embeds: [embed] });
        break;
      }
      case "approve_push": {
        await interaction.deferReply();
        const res = await approvePendingPush(channelId, channel);
        await interaction.editReply(res.found ? "\u2705 Push approval noted." : "No active session.");
        break;
      }
      case "grant": {
        const grantPath = interaction.options.getString("path");
        const mode = interaction.options.getString("mode") || "ro";
        const ttl = interaction.options.getInteger("ttl") || 30;
        if (!grantPath.startsWith("/") && !/^[A-Z]:\\/i.test(grantPath)) {
          await interaction.reply({ content: "\u26A0\uFE0F Path must be absolute.", ephemeral: true }); break;
        }
        const result = addGrant(channelId, grantPath, mode, ttl);
        const ts = Math.floor(new Date(result.expiresAt).getTime() / 1000);
        await interaction.reply(`\u2705 **Granted** \`${mode}\` access to \`${grantPath}\` for **${ttl} min** (expires <t:${ts}:R>).`);
        break;
      }
      case "revoke": {
        revokeGrant(channelId, interaction.options.getString("path"));
        await interaction.reply(`\u{1F512} **Revoked** access to \`${interaction.options.getString("path")}\`.`);
        break;
      }
      case "reset": {
        await interaction.deferReply();
        await resetSession(channelId);
        await interaction.editReply("\u{1F504} Session reset.");
        break;
      }
      case "stop": {
        const clearQ = interaction.options.getBoolean("clear_queue") ?? true;
        const result = hardStop(channelId, clearQ);
        if (!result.found) { await interaction.reply({ content: "No active session.", ephemeral: true }); break; }
        const parts = [result.wasWorking ? "Aborted running task" : "No task running"];
        if (result.queueCleared > 0) parts.push(`cleared ${result.queueCleared} queued`);
        await interaction.reply(`\u{1F6D1} **Stopped.** ${parts.join(", ")}.`);
        break;
      }
      case "pause": {
        const result = pauseSession(channelId);
        if (!result.found) { await interaction.reply({ content: "No active session.", ephemeral: true }); break; }
        await interaction.reply("\u23F8 **Queue paused.** Use `/resume` or `/stop`.");
        break;
      }
      case "resume": {
        const result = resumeSession(channelId, channel);
        if (!result.found) { await interaction.reply({ content: "No active session.", ephemeral: true }); break; }
        if (!result.wasPaused) { await interaction.reply({ content: "Not paused.", ephemeral: true }); break; }
        await interaction.reply("\u25B6\uFE0F **Queue resumed.**");
        break;
      }
      case "queue": {
        const action = interaction.options.getString("action") || "list";
        if (action === "clear") {
          const result = clearQueue(channelId);
          if (!result.found) { await interaction.reply({ content: "No active session.", ephemeral: true }); break; }
          await interaction.reply(result.cleared > 0 ? `\u{1F5D1} Cleared **${result.cleared}** task(s).` : "Queue empty.");
          break;
        }
        const info = getQueueInfo(channelId);
        if (!info) { await interaction.reply({ content: "No active session.", ephemeral: true }); break; }
        if (info.length === 0) { await interaction.reply({ content: "Queue empty.", ephemeral: true }); break; }
        const lines = info.items.map((i) => `**${i.index}.** ${i.prompt}`);
        const embed = new EmbedBuilder().setTitle(`\u{1F4CB} Queue (${info.length})`)
          .setColor(info.paused ? 0xff6600 : 0x3498db).setDescription(lines.join("\n"))
          .setFooter({ text: info.paused ? "\u23F8 Paused" : "Active" });
        await interaction.reply({ embeds: [embed] });
        break;
      }
      case "history": {
        const limit = interaction.options.getInteger("limit") || 10;
        const tasks = getTaskHistory(channelId, limit);
        if (!tasks.length) { await interaction.reply({ content: "No history.", ephemeral: true }); break; }
        const icons = { completed: "\u2705", failed: "\u274C", running: "\u23F3", aborted: "\u{1F6D1}" };
        const lines = tasks.map((t) => {
          const p = t.prompt.length > 60 ? t.prompt.slice(0, 60) + "\u2026" : t.prompt;
          const time = t.started_at ? `<t:${Math.floor(new Date(t.started_at + "Z").getTime() / 1000)}:R>` : "";
          return `${icons[t.status] || "\u2754"} ${p} ${time}`;
        });
        const embed = new EmbedBuilder().setTitle(`\u{1F4DC} History (${tasks.length})`)
          .setColor(0x9b59b6).setDescription(lines.join("\n")).setTimestamp();
        await interaction.reply({ embeds: [embed] });
        break;
      }
      case "config": {
        const embed = new EmbedBuilder().setTitle("\u2699\uFE0F Config").setColor(0x95a5a6)
          .addFields(
            { name: "Project", value: PROJECT_NAME, inline: true },
            { name: "Repo", value: `\`${REPO_PATH}\``, inline: true },
            { name: "Base", value: `\`${BASE_ROOT}\``, inline: false },
            { name: "Workspaces", value: `\`${WORKSPACES_ROOT}\``, inline: false },
            { name: "Edit Throttle", value: `${DISCORD_EDIT_THROTTLE_MS}ms`, inline: true },
            { name: "Grant Mode", value: DEFAULT_GRANT_MODE, inline: true },
            { name: "Grant TTL", value: `${DEFAULT_GRANT_TTL_MIN}min`, inline: true },
            { name: "Guilds", value: ALLOWED_GUILDS ? [...ALLOWED_GUILDS].join(", ") : "*(all)*", inline: false },
            { name: "Channels", value: ALLOWED_CHANNELS ? [...ALLOWED_CHANNELS].join(", ") : "*(all)*", inline: false },
            { name: "Admins", value: ADMIN_ROLE_IDS ? [...ADMIN_ROLE_IDS].join(", ") : "*(all)*", inline: false },
          ).setTimestamp();
        await interaction.reply({ embeds: [embed], ephemeral: true });
        break;
      }
      case "diff": {
        const st = getSessionStatus(channelId);
        if (!st) { await interaction.reply({ content: "No active session.", ephemeral: true }); break; }
        const mode = interaction.options.getString("mode") || "stat";
        const gitCmd = mode === "stat" ? "git diff --stat" : mode === "staged" ? "git diff --cached" : "git diff";
        await interaction.deferReply();
        try {
          const output = execSync(gitCmd, { cwd: st.workspace, encoding: "utf-8", timeout: 15_000 });
          if (!output.trim()) { await interaction.editReply("No changes."); break; }
          const clean = redactSecrets(output).clean;
          if (clean.length <= 1900) await interaction.editReply(`\`\`\`diff\n${clean}\n\`\`\``);
          else {
            const att = new AttachmentBuilder(Buffer.from(clean, "utf-8"), { name: "diff.txt" });
            await interaction.editReply({ files: [att] });
          }
        } catch (err) { await interaction.editReply(`\u274C \`${gitCmd}\` failed: ${err.message}`); }
        break;
      }
      case "branch": {
        const st = getSessionStatus(channelId);
        if (!st) { await interaction.reply({ content: "No active session.", ephemeral: true }); break; }
        const action = interaction.options.getString("action") || "current";
        const branchName = interaction.options.getString("name");
        if (action === "current") { await interaction.reply(`Branch: \`${st.branch}\``); break; }
        if (action === "list") {
          try {
            const b = execSync("git branch --list", { cwd: st.workspace, encoding: "utf-8", timeout: 5_000 }).trim();
            await interaction.reply(`\`\`\`\n${b}\n\`\`\``);
          } catch (err) { await interaction.reply(`\u274C ${err.message}`); }
          break;
        }
        if (!branchName) { await interaction.reply({ content: `Provide a branch name for \`${action}\`.`, ephemeral: true }); break; }
        if (!/^[\w.\/-]{1,100}$/.test(branchName)) {
          await interaction.reply({ content: "\u26A0\uFE0F Invalid branch name. Only letters, digits, `.`, `/`, `-`, `_` allowed (max 100 chars).", ephemeral: true });
          break;
        }
        if (st.status === "working") { await interaction.reply({ content: "\u26A0\uFE0F Stop task first.", ephemeral: true }); break; }
        await interaction.deferReply();
        if (action === "create") {
          try { execSync(`git checkout -b "${branchName}"`, { cwd: st.workspace, encoding: "utf-8", timeout: 10_000 });
            await interaction.editReply(`\u2705 Created \`${branchName}\`.`);
          } catch (err) { await interaction.editReply(`\u274C ${err.message}`); }
          break;
        }
        if (action === "switch") {
          try { execSync(`git checkout "${branchName}"`, { cwd: st.workspace, encoding: "utf-8", timeout: 10_000 });
            await interaction.editReply(`\u2705 Switched to \`${branchName}\`.`);
          } catch (err) { await interaction.editReply(`\u274C ${err.message}`); }
          break;
        }
        break;
      }
      default: await interaction.reply({ content: "Unknown command.", ephemeral: true });
    }
  } catch (err) {
    log.error("Command error", { command: commandName, error: err.message });
    const reply = interaction.deferred || interaction.replied
      ? (msg) => interaction.editReply(msg)
      : (msg) => interaction.reply({ content: msg, ephemeral: true });
    await reply(`\u274C Error: ${err.message}`).catch(() => {});
  }
});

client.on("messageCreate", async (message) => {
  if (message.author.bot || !message.channel.isThread()) return;
  const parent = message.channel.parent;
  if (!parent) return;
  const parentId = parent.id;
  if (ALLOWED_CHANNELS && !ALLOWED_CHANNELS.has(parentId)) return;
  if (message.channel.ownerId !== client.user.id) return;
  const prompt = message.content.trim();
  if (!prompt) return;
  log.info("Follow-up in thread", { channelId: parentId, threadId: message.channel.id });
  enqueueTask(parentId, parent, prompt, message.channel).catch((err) => {
    message.channel.send(`\u274C **Follow-up failed:** ${err.message}`).catch(() => {});
  });
});

async function shutdown(signal) {
  log.info("Shutting down", { signal });
  try { client.destroy(); } catch (err) { log.error("Client destroy failed", { error: err.message }); }
  try { await stopCopilotClient(); } catch (err) { log.error("Copilot stop failed", { error: err.message }); }
  try { closeDb(); } catch (err) { log.error("DB close failed", { error: err.message }); }
  process.exit(0);
}

process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("unhandledRejection", (err) => { log.error("Unhandled rejection", { error: err?.message || String(err) }); });

client.on("error", (err) => {
  log.error("Discord client error", { error: err.message });
});

client.on("warn", (msg) => {
  log.warn("Discord client warning", { message: msg });
});

client.on("shardDisconnect", (event, shardId) => {
  log.warn("Shard disconnected", { shardId, code: event?.code });
});

client.on("shardReconnecting", (shardId) => {
  log.info("Shard reconnecting", { shardId });
});

client.on("shardResume", (shardId) => {
  log.info("Shard resumed", { shardId });
});

log.info("Starting Discord bot");
client.login(DISCORD_TOKEN).catch((err) => {
  log.error("Failed to login to Discord", { error: err.message });
  process.exit(1);
});
'@

Write-Ok '12 source files written'

# ──────────────────────────────────────────────────────────────────────────────
# 7) Install dependencies
# ──────────────────────────────────────────────────────────────────────────────

Write-Step 7 8 'Dependencies'

Write-Info 'Running npm install ...'
Push-Location $App
try {
    if (Test-Path 'package-lock.json') {
        npm ci --loglevel=warn
    } else {
        npm install --loglevel=warn
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

$env:PROJECT_NAME = $ProjectName
$env:REPO_PATH    = $RepoDir

& node (Join-Path $App 'src\bot.mjs')
