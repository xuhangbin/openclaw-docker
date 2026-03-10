#
# OpenClaw (Clawbot) Docker Installer - Windows PowerShell Version
# One-command setup for OpenClaw on Docker for Windows
# Feature parity with install.sh (multi-instance, port allocation, host/bridge)
#
# Usage:
#   irm https://raw.githubusercontent.com/phioranex/openclaw-docker/main/install.ps1 | iex
#
# Or with options:
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/phioranex/openclaw-docker/main/install.ps1))) -NoStart
#

param(
    [string]$Username = "",
    [string]$InstallDir = "",
    [switch]$NoStart,
    [switch]$SkipOnboard,
    [switch]$PullOnly,
    [switch]$HostNetwork,
    [switch]$Bridge,
    [switch]$Help
)

# Config
$Image = "ghcr.io/phioranex/openclaw-docker:latest"
$RepoUrl = "https://github.com/phioranex/openclaw-docker"
$ComposeUrl = "https://raw.githubusercontent.com/phioranex/openclaw-docker/main/docker-compose.yml"

# Default host network (same as install.sh); -Bridge switches to bridge mode
if (-not $Bridge) { $HostNetwork = $true }

# Error handling
$ErrorActionPreference = "Stop"

# Resolved at runtime when not PullOnly
$InstanceHome = ""
$ComposeProject = ""
$OpenClawDir = ""
$GatewayPort = 0
$DashboardPort = 0
$ComposeFile = ""

# Functions
function Write-Banner {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Red
    Write-Host "║                                                              ║" -ForegroundColor Red
    Write-Host "║    ____                    _____ _                           ║" -ForegroundColor Red
    Write-Host "║   / __ \                  / ____| |                          ║" -ForegroundColor Red
    Write-Host "║  | |  | |_ __   ___ _ __ | |    | | __ ___      __           ║" -ForegroundColor Red
    Write-Host "║  | |  | | '_ \ / _ \ '_ \| |    | |/ _`` \ \ /\ / /           ║" -ForegroundColor Red
    Write-Host "║  | |__| | |_) |  __/ | | | |____| | (_| |\ V  V /            ║" -ForegroundColor Red
    Write-Host "║   \____/| .__/ \___|_| |_|\_____|_|\__,_| \_/\_/             ║" -ForegroundColor Red
    Write-Host "║         | |                                                  ║" -ForegroundColor Red
    Write-Host "║         |_|                                                  ║" -ForegroundColor Red
    Write-Host "║                                                              ║" -ForegroundColor Red
    Write-Host "║              Docker Installer by Phioranex                   ║" -ForegroundColor Red
    Write-Host "║                                                              ║" -ForegroundColor Red
    Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Red
    Write-Host ""
}

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "▶ $Message" -ForegroundColor Blue
}

function Write-Success {
    param([string]$Message)
    Write-Host "✓ $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "⚠ $Message" -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Message)
    Write-Host "✗ $Message" -ForegroundColor Red
}

function Test-Command {
    param([string]$Command)
    try {
        Get-Command $Command -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    }
}

# Validate username: only letters, numbers, underscore, hyphen
function Test-UsernameValid {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) {
        Write-Err "Username is required"
        return $false
    }
    if ($Name -notmatch '^[a-zA-Z0-9_-]+$') {
        Write-Err "Username must contain only letters, numbers, underscore and hyphen"
        return $false
    }
    return $true
}

# Check if a port is in use (Windows)
function Test-PortInUse {
    param([int]$Port)
    try {
        $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
        return $null -ne $conn
    } catch {
        return $false
    }
}

# Find first free port pair: 10010/10011, 10015/10016, 10020/10021 ...
function Get-FreePortPair {
    $base = 10010
    $step = 5
    while ($base -le 65534) {
        $gw = $base
        $dash = $base + 1
        if (-not (Test-PortInUse $gw) -and -not (Test-PortInUse $dash)) {
            return @($gw, $dash)
        }
        $base += $step
    }
    throw "No free port pair found"
}

# Show help
if ($Help) {
    Write-Host "OpenClaw (Clawbot) Docker Installer - Windows"
    Write-Host ""
    Write-Host "Usage: install.ps1 [OPTIONS]"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -Username NAME     Instance username (e.g. abc → C:\Users\abc; stack abc-openclaw)"
    Write-Host "  -InstallDir DIR    Installation directory (default: C:\Users\<username>\openclaw)"
    Write-Host "  -NoStart           Don't start the gateway after setup"
    Write-Host "  -SkipOnboard       Skip onboarding wizard"
    Write-Host "  -PullOnly          Only pull the image, don't set up"
    Write-Host "  -HostNetwork       Use host network (default); ports 10010/10015/... on host"
    Write-Host "  -Bridge            Use bridge network and port mapping instead of host"
    Write-Host "  -Help              Show this help message"
    return
}

# Main script
Write-Banner

Write-Step "Checking prerequisites..."

if (Test-Command docker) {
    Write-Success "docker found"
} else {
    Write-Err "docker not found"
    Write-Host ""
    Write-Host "Docker is required but not installed." -ForegroundColor Red
    Write-Host "Install Docker Desktop: https://docs.docker.com/desktop/install/windows-install/" -ForegroundColor Yellow
    exit 1
}

$ComposeCmd = ""
try {
    docker compose version 2>$null | Out-Null
    Write-Success "Docker Compose found (plugin)"
    $ComposeCmd = "docker compose"
} catch {
    if (Test-Command docker-compose) {
        Write-Success "Docker Compose found (standalone)"
        $ComposeCmd = "docker-compose"
    } else {
        Write-Err "Docker Compose not found"
        Write-Host ""
        Write-Host "Docker Compose is required but not installed." -ForegroundColor Red
        Write-Host "It usually comes with Docker Desktop." -ForegroundColor Yellow
        exit 1
    }
}

try {
    docker info 2>$null | Out-Null
    Write-Success "Docker is running"
} catch {
    Write-Err "Docker is not running"
    Write-Host ""
    Write-Host "Please start Docker Desktop and try again." -ForegroundColor Red
    exit 1
}

# Pull only mode
if ($PullOnly) {
    Write-Step "Pulling OpenClaw image..."
    docker pull $Image
    Write-Success "Image pulled successfully!"
    Write-Host ""
    Write-Host "Done! Run the installer again without -PullOnly to complete setup." -ForegroundColor Green
    exit 0
}

# Resolve username (required for setup)
if ([string]::IsNullOrWhiteSpace($Username)) {
    $defaultUser = $env:USERNAME
    Write-Host ""
    Write-Host "Instance username (e.g. $defaultUser → C:\Users\$defaultUser; stack ${defaultUser}-openclaw): " -NoNewline -ForegroundColor White
    $Username = Read-Host
    if ([string]::IsNullOrWhiteSpace($Username)) {
        $Username = $defaultUser
    }
}
if (-not (Test-UsernameValid $Username)) {
    exit 1
}

# Instance home and project (Windows: C:\Users\<username>)
$InstanceHome = "C:\Users\$Username"
if ($Username -eq $env:USERNAME) {
    $InstanceHome = $env:USERPROFILE
}
$ComposeProject = "${Username}-openclaw"
if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    $InstallDir = "$InstanceHome\openclaw"
}
$OpenClawDir = "$InstanceHome\.openclaw"
$ComposeFile = "$InstallDir\docker-compose.yml"

# Port allocation
$pair = Get-FreePortPair
$GatewayPort = $pair[0]
$DashboardPort = $pair[1]

Write-Step "Setting up installation directory..."
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Push-Location $InstallDir
try {
    Write-Success "Created $InstallDir"

    Write-Step "Creating instance data directories..."
    New-Item -ItemType Directory -Force -Path $InstanceHome | Out-Null
    New-Item -ItemType Directory -Force -Path $OpenClawDir | Out-Null
    New-Item -ItemType Directory -Force -Path "$OpenClawDir\workspace" | Out-Null
    Write-Success "Created $InstanceHome and $OpenClawDir"

    Write-Step "Downloading docker-compose.yml..."
    Invoke-WebRequest -Uri $ComposeUrl -OutFile $ComposeFile -UseBasicParsing

    $content = Get-Content $ComposeFile -Raw

    # Replace placeholder with username
    $content = $content -replace '\$REPLACE_WITH_USERNAME\$', $Username

    # Replace ~/.openclaw with instance path
    $content = $content -replace '~/.openclaw', $OpenClawDir.Replace('\', '/')
    Write-Success "Updated docker-compose.yml mounts to $OpenClawDir"

    # Remove existing container_name lines
    $content = $content -replace '(?m)^    container_name:.*\r?\n', ''

    # Add container_name after each service (gateway, socat-proxy, openclaw-cli)
    $content = $content -replace '(\r?\n  openclaw-gateway:\r?\n)', "`n  openclaw-gateway:`n    container_name: ${ComposeProject}-gateway`n"
    $content = $content -replace '(\r?\n  socat-proxy:\r?\n)', "`n  socat-proxy:`n    container_name: ${ComposeProject}-socat`n"
    $content = $content -replace '(\r?\n  openclaw-cli:\r?\n)', "`n  openclaw-cli:`n    container_name: ${ComposeProject}-cli`n"

    if ($HostNetwork) {
        Write-Success "Using host network: gateway $GatewayPort, dashboard $DashboardPort (direct on host)"
        # Comment out ports block
        $content = $content -replace '(?m)^    ports:\r?\n', "    # ports (host mode: not used)`n"
        $content = $content -replace '(?m)^      - "18789:18789"\r?\n', "    #   - `"${GatewayPort}:18789`"`n"
        $content = $content -replace '(?m)^      - "18790:18790"\r?\n', "    #   - `"${DashboardPort}:18790`"`n"
        # Add network_mode: host after first tty: true (gateway only)
        $content = [regex]::Replace($content, '(\r?\n    tty: true\r?\n)', "`n    tty: true`n    network_mode: `"host`"`n", 1)
        # Socat-proxy: dashboard on DASHBOARD_PORT -> GATEWAY_PORT
        $content = $content -replace 'TCP-LISTEN:18790,fork,bind=0\.0\.0\.0,reuseaddr TCP:127\.0\.0\.1:18789', "TCP-LISTEN:${DashboardPort},fork,bind=0.0.0.0,reuseaddr TCP:127.0.0.1:${GatewayPort}"
        # Insert socat-gateway before openclaw-cli
        $socatGateway = @"

  socat-gateway:
    container_name: ${ComposeProject}-socat-gateway
    image: alpine/socat
    restart: unless-stopped
    network_mode: "service:openclaw-gateway"
    command: "TCP-LISTEN:${GatewayPort},fork,bind=0.0.0.0,reuseaddr TCP:127.0.0.1:18789"

"@
        $content = $content -replace '(\r?\n  openclaw-cli:\r?\n)', "$socatGateway`n  openclaw-cli:`n"
    } else {
        Write-Success "Using bridge: gateway $GatewayPort, dashboard $DashboardPort (bound to 0.0.0.0)"
        $content = $content -replace '18789:18789', "0.0.0.0:${GatewayPort}:18789"
        $content = $content -replace '18790:18790', "0.0.0.0:${DashboardPort}:18790"
    }

    # Gateway listen port
    $content = $content -replace 'command: \["gateway"\]', "command: [`"gateway`", `"--port`", `"$GatewayPort`"]"

    Set-Content -Path $ComposeFile -Value $content.TrimEnd() -NoNewline

    # Validate compose
    $composeParts = $ComposeCmd -split " ", 2
    $configArgs = @("-f", $ComposeFile, "config", "-q")
    if ($composeParts.Count -eq 2) {
        & $composeParts[0] $composeParts[1] @configArgs 2>&1 | Out-Null
    } else {
        & $composeParts[0] @configArgs 2>&1 | Out-Null
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Generated docker-compose.yml is invalid. Check $ComposeFile"
        exit 1
    }
    Write-Success "Downloaded and configured docker-compose.yml"

    Write-Success "Created $OpenClawDir (config)"
    Write-Success "Created $OpenClawDir\workspace (workspace)"

    Write-Step "Pulling OpenClaw image..."
    docker pull $Image
    Write-Success "Image pulled successfully!"

    # Onboarding
    if (-not $SkipOnboard) {
        Write-Step "Initializing OpenClaw configuration..."
        Write-Host "Setting up configuration and workspace..." -ForegroundColor Yellow
        Write-Host ""
        Write-Step "Running onboarding wizard..."
        Write-Host "This will configure your AI provider and channels." -ForegroundColor Yellow
        Write-Host "Follow the prompts to complete setup." -ForegroundColor Yellow
        Write-Host ""

        $runArgs = @("-f", $ComposeFile, "-p", $ComposeProject, "run", "-T", "--rm", "openclaw-cli", "onboard")
        if ($composeParts.Count -eq 2) {
            & $composeParts[0] $composeParts[1] @runArgs
        } else {
            & $composeParts[0] @runArgs
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "Onboarding was cancelled or failed"
            Write-Host "You can run it later with: cd $InstallDir; $ComposeCmd -f $ComposeFile -p $ComposeProject run --rm openclaw-cli onboard" -ForegroundColor Yellow
        } else {
            Write-Success "Onboarding complete!"
        }
    }

    # Start gateway
    if (-not $NoStart) {
        Write-Step "Starting OpenClaw gateway..."
        $upArgs = @("-f", $ComposeFile, "-p", $ComposeProject, "up", "-d", "openclaw-gateway")
        if ($composeParts.Count -eq 2) {
            & $composeParts[0] $composeParts[1] @upArgs
        } else {
            & $composeParts[0] @upArgs
        }

        Write-Host "Waiting for gateway to start" -NoNewline
        $healthy = $false
        for ($i = 0; $i -lt 30; $i++) {
            try {
                $response = Invoke-WebRequest -Uri "http://localhost:${GatewayPort}/health" -TimeoutSec 1 -UseBasicParsing -ErrorAction SilentlyContinue
                if ($response.StatusCode -eq 200) {
                    $healthy = $true
                    Write-Host ""
                    Write-Success "Gateway is running!"
                    break
                }
            } catch { }
            Write-Host "." -NoNewline
            Start-Sleep -Seconds 1
        }
        if (-not $healthy) {
            try {
                $r = Invoke-WebRequest -Uri "http://localhost:${GatewayPort}/health" -TimeoutSec 1 -UseBasicParsing -ErrorAction SilentlyContinue
                if ($r.StatusCode -ne 200) { throw }
            } catch {
                Write-Host ""
                Write-Warn "Gateway may still be starting. Check logs with: docker logs ${ComposeProject}-gateway"
            }
        }
    }

    # Success message
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║                                                              ║" -ForegroundColor Green
    Write-Host "║              🎉 OpenClaw installed successfully! 🎉           ║" -ForegroundColor Green
    Write-Host "║                                                              ║" -ForegroundColor Green
    Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Green

    Write-Host ""
    Write-Host "Quick reference:" -ForegroundColor White
    Write-Host "  Instance:         $ComposeProject (user: $Username)" -ForegroundColor Cyan
    Write-Host "  Gateway container: ${ComposeProject}-gateway (use this name for docker logs)" -ForegroundColor Cyan
    Write-Host "  Compose file:    $ComposeFile" -ForegroundColor Cyan
    Write-Host "  Dashboard:       http://localhost:${DashboardPort}/?token=YOUR_TOKEN" -ForegroundColor Cyan
    Write-Host "  Gateway:         http://localhost:${GatewayPort}" -ForegroundColor Cyan
    Write-Host "  From other machines: Use this host's IP (e.g. http://<host-ip>:${DashboardPort}). Ensure firewall allows ports $GatewayPort, $DashboardPort." -ForegroundColor Cyan
    if (-not $HostNetwork) {
        Write-Host "  Using bridge. To use host network (default), reinstall without -Bridge." -ForegroundColor Cyan
    }
    Write-Host "  Config:          $OpenClawDir" -ForegroundColor Cyan
    Write-Host "  Install dir:     $InstallDir" -ForegroundColor Cyan

    Write-Host ""
    Write-Host "Useful commands:" -ForegroundColor White
    Write-Host "  View logs:       cd $InstallDir; $ComposeCmd -f $ComposeFile -p $ComposeProject logs -f openclaw-gateway" -ForegroundColor Cyan
    Write-Host "  Stop:            cd $InstallDir; $ComposeCmd -f $ComposeFile -p $ComposeProject down" -ForegroundColor Cyan
    Write-Host "  Start:           cd $InstallDir; $ComposeCmd -f $ComposeFile -p $ComposeProject up -d openclaw-gateway" -ForegroundColor Cyan
    Write-Host "  Restart:         cd $InstallDir; $ComposeCmd -f $ComposeFile -p $ComposeProject restart openclaw-gateway" -ForegroundColor Cyan
    Write-Host "  CLI:             cd $InstallDir; $ComposeCmd -f $ComposeFile -p $ComposeProject run --rm openclaw-cli <command>" -ForegroundColor Cyan
    Write-Host "  Update:          docker pull $Image; cd $InstallDir; $ComposeCmd -f $ComposeFile -p $ComposeProject up -d" -ForegroundColor Cyan

    Write-Host ""
    Write-Host "Documentation:  https://docs.openclaw.ai" -ForegroundColor White
    Write-Host "Support:        https://discord.gg/clawd" -ForegroundColor White
    Write-Host "Docker image:   $RepoUrl" -ForegroundColor White

    Write-Host ""
    Write-Host "Happy automating! 🤖🦞" -ForegroundColor Yellow
    Write-Host ""
} finally {
    Pop-Location
}
