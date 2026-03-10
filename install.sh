#!/bin/bash
#
# OpenClaw (Clawbot) Docker Installer
# One-command setup for OpenClaw on Docker
#
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/phioranex/openclaw-docker/main/install.sh)
#
# Or with options:
#   bash <(curl -fsSL https://raw.githubusercontent.com/phioranex/openclaw-docker/main/install.sh) --no-start
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Config
IMAGE="ghcr.io/phioranex/openclaw-docker:latest"
REPO_URL="https://github.com/phioranex/openclaw-docker"
COMPOSE_URL="https://raw.githubusercontent.com/phioranex/openclaw-docker/main/docker-compose.yml"

# Multi-instance: username (required for setup)
USERNAME=""
INSTANCE_HOME=""
COMPOSE_PROJECT=""
GATEWAY_PORT=""
DASHBOARD_PORT=""

# Detect if we have a TTY (for Docker interactive mode)
if [ -t 0 ]; then
    DOCKER_TTY_FLAG=""
else
    DOCKER_TTY_FLAG="-T"
fi

# Flags
NO_START=false
SKIP_ONBOARD=false
PULL_ONLY=false
# Default host network (port rule 10010/10015/... still applies); use --bridge for bridge mode
HOST_NETWORK=true

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --no-start)
            NO_START=true
            shift
            ;;
        --skip-onboard)
            SKIP_ONBOARD=true
            shift
            ;;
        --pull-only)
            PULL_ONLY=true
            shift
            ;;
        --host-network)
            HOST_NETWORK=true
            shift
            ;;
        --bridge)
            HOST_NETWORK=false
            shift
            ;;
        --username)
            USERNAME="$2"
            shift 2
            ;;
        --install-dir)
            INSTALL_DIR="$2"
            shift 2
            ;;
        --help|-h)
            echo "OpenClaw (Clawbot) Docker Installer"
            echo ""
            echo "Usage: install.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --username NAME     Instance username (creates /home/NAME, used as stack prefix)"
            echo "  --install-dir DIR  Installation directory (default: /home/<username>/openclaw)"
            echo "  --no-start         Don't start the gateway after setup"
            echo "  --skip-onboard     Skip onboarding wizard"
            echo "  --pull-only        Only pull the image, don't set up"
            echo "  --host-network    Use host network (default); ports 10010/10015/... on host"
            echo "  --bridge          Use bridge network and port mapping instead of host"
            echo "  --help, -h          Show this help message"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

# Functions
print_banner() {
    echo -e "${RED}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                                                              ║"
    echo "║    ____                    _____ _                           ║"
    echo "║   / __ \\\\                  / ____| |                          ║"
    echo "║  | |  | |_ __   ___ _ __ | |    | | __ ___      __           ║"
    echo "║  | |  | | '_ \\\\ / _ \\\\ '_ \\\\| |    | |/ _\\\` \\\\ \\\\ /\\\\ / /           ║"
    echo "║  | |__| | |_) |  __/ | | | |____| | (_| |\\\\ V  V /            ║"
    echo "║   \\\\____/| .__/ \\\\___|_| |_|\\\\_____|_|\\\\__,_| \\\\_/\\\\_/             ║"
    echo "║         | |                                                  ║"
    echo "║         |_|                                                  ║"
    echo "║                                                              ║"
    echo "║              Docker Installer by Phioranex                   ║"
    echo "║                                                              ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# Get user's home directory, handling sudo correctly
get_user_home() {
    if [ -n "$SUDO_USER" ]; then
        # Running with sudo - use the actual user's home
        local user_home
        user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
        if [ -z "$user_home" ]; then
            # Fallback to eval if getent fails
            user_home=$(eval echo ~"$SUDO_USER")
        fi
        echo "$user_home"
    else
        # Running normally
        echo "$HOME"
    fi
}

log_step() {
    echo -e "\n${BLUE}▶${NC} ${BOLD}$1${NC}"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
}

check_command() {
    if command -v "$1" &> /dev/null; then
        log_success "$1 found"
        return 0
    else
        log_error "$1 not found"
        return 1
    fi
}

# Validate username: only letters, numbers, underscore, hyphen
validate_username() {
    local name="$1"
    if [ -z "$name" ]; then
        log_error "Username is required"
        return 1
    fi
    if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "Username must contain only letters, numbers, underscore and hyphen"
        return 1
    fi
    return 0
}

# Find first free port pair starting at base, step 5 (10010, 10015, 10020...)
# Sets GATEWAY_PORT and DASHBOARD_PORT (gateway+1)
find_free_port_pair() {
    local base=10010
    local step=5
    while true; do
        local gw=$base
        local dash=$((base + 1))
        if ! port_in_use "$gw" && ! port_in_use "$dash"; then
            GATEWAY_PORT=$gw
            DASHBOARD_PORT=$dash
            return 0
        fi
        base=$((base + step))
        if [ "$base" -gt 65535 ]; then
            log_error "No free port pair found"
            return 1
        fi
    done
}

port_in_use() {
    local port=$1
    if command -v ss &>/dev/null; then
        ss -tuln 2>/dev/null | grep -q ":$port "
        return $?
    fi
    if command -v lsof &>/dev/null; then
        lsof -i ":$port" -sTCP:LISTEN -t &>/dev/null
        return $?
    fi
    if command -v netstat &>/dev/null; then
        netstat -an 2>/dev/null | grep -q "\.$port .*LISTEN"
        return $?
    fi
    # Fallback: try binding (bash builtin)
    (echo >/dev/tcp/127.0.0.1/"$port") 2>/dev/null && return 0
    return 1
}

# Main script
print_banner

log_step "Checking prerequisites..."

# Check Docker
if ! check_command docker; then
    echo -e "\n${RED}Docker is required but not installed.${NC}"
    echo "Install Docker: https://docs.docker.com/get-docker/"
    exit 1
fi

# Check Docker Compose
if docker compose version &> /dev/null; then
    log_success "Docker Compose found (plugin)"
    COMPOSE_CMD="docker compose"
elif command -v docker-compose &> /dev/null; then
    log_success "Docker Compose found (standalone)"
    COMPOSE_CMD="docker-compose"
else
    log_error "Docker Compose not found"
    echo -e "\n${RED}Docker Compose is required but not installed.${NC}"
    echo "Install Docker Compose: https://docs.docker.com/compose/install/"
    exit 1
fi

# Check Docker is running and capture output for better error reporting
DOCKER_INFO_OUTPUT=$(docker info 2>&1)
DOCKER_INFO_EXIT=$?

if [ $DOCKER_INFO_EXIT -ne 0 ]; then
    log_error "Docker is not running or you don't have permission to access it"
    
    # Check if it's a permission issue
    if [ "$(id -u)" -ne 0 ] && echo "$DOCKER_INFO_OUTPUT" | grep -qi "permission denied"; then
        echo -e "\n${YELLOW}Tip: You may need to run this script with sudo or add your user to the docker group:${NC}"
        echo -e "  ${CYAN}sudo usermod -aG docker \$USER${NC}"
        echo -e "  ${CYAN}(then log out and log back in)${NC}"
        echo -e "\n${YELLOW}Or run the installer with sudo:${NC}"
        echo -e "  ${CYAN}sudo bash <(curl -fsSL https://raw.githubusercontent.com/phioranex/openclaw-docker/main/install.sh)${NC}"
    else
        echo -e "\n${RED}Please start Docker and try again.${NC}"
    fi
    exit 1
fi
log_success "Docker is running"

# Resolve username for multi-instance (required for setup, not for --pull-only)
if [ "$PULL_ONLY" = false ]; then
    if [ -z "$USERNAME" ]; then
        if [ -t 0 ]; then
            echo -e "\n${BOLD}Instance username (e.g. abc → /Users/abc on macOS, /home/abc on Linux; stack abc-openclaw):${NC}"
            read -r USERNAME
        fi
        if [ -z "$USERNAME" ]; then
            log_error "Username is required. Use --username NAME or run interactively."
            exit 1
        fi
    fi
    if ! validate_username "$USERNAME"; then
        exit 1
    fi
    # macOS uses /Users, Linux uses /home
    if [ "$(uname -s)" = "Darwin" ]; then
        INSTANCE_HOME="/Users/$USERNAME"
    else
        INSTANCE_HOME="/home/$USERNAME"
    fi
    COMPOSE_PROJECT="${USERNAME}-openclaw"
    [ -z "$INSTALL_DIR" ] && INSTALL_DIR="${OPENCLAW_INSTALL_DIR:-$INSTANCE_HOME/openclaw}"
fi

# Pull only mode
if [ "$PULL_ONLY" = true ]; then
    log_step "Pulling OpenClaw image..."
    docker pull "$IMAGE"
    log_success "Image pulled successfully!"
    echo -e "\n${GREEN}Done!${NC} Run the installer again without --pull-only to complete setup."
    exit 0
fi

log_step "Setting up installation directory..."
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"
log_success "Created $INSTALL_DIR"

log_step "Creating instance home and data directories..."
if ! mkdir -p "$INSTANCE_HOME"; then
    log_error "Cannot create $INSTANCE_HOME (may need root). Try: sudo $0 --username $USERNAME"
    exit 1
fi
# Set ownership of instance home for container user (UID 1000) first; with sudo, add group for host user
if [ "$(id -u)" -eq 0 ]; then
    if [ -n "$SUDO_USER" ]; then
        SUDO_GID=$(id -g "$SUDO_USER")
        chown 1000:"$SUDO_GID" "$INSTANCE_HOME"
        chmod 775 "$INSTANCE_HOME"
        log_success "Set $INSTANCE_HOME to UID 1000 (container) with group $SUDO_USER"
    else
        chown 1000:1000 "$INSTANCE_HOME"
        chmod 755 "$INSTANCE_HOME"
        log_success "Set $INSTANCE_HOME ownership to 1000:1000 (container user)"
    fi
else
    chmod 755 "$INSTANCE_HOME" 2>/dev/null || true
fi
OPENCLAW_DIR="$INSTANCE_HOME/.openclaw"
mkdir -p "$OPENCLAW_DIR"
mkdir -p "$OPENCLAW_DIR/workspace"
log_success "Created $INSTANCE_HOME and $OPENCLAW_DIR"

log_step "Downloading docker-compose.yml..."
curl -fsSL "$COMPOSE_URL" -o docker-compose.yml

# Replace host mount path with instance home (multi-instance data isolation)
if grep -q "~/.openclaw" docker-compose.yml; then
    sed -i.bak "s|~/.openclaw|$OPENCLAW_DIR|g" docker-compose.yml
    rm -f docker-compose.yml.bak
    log_success "Updated docker-compose.yml mounts to $OPENCLAW_DIR"
fi

# Container names with username prefix (e.g. abc-openclaw-gateway, abc-openclaw-socat)
# Remove any existing container_name lines to avoid duplicate key (template or previous run)
sed -i.bak '/^    container_name:/d' docker-compose.yml
rm -f docker-compose.yml.bak
awk -v p="$COMPOSE_PROJECT" '
  /^  openclaw-gateway:/  { print; print "    container_name: " p "-gateway"; next }
  /^  socat-proxy:/       { print; print "    container_name: " p "-socat"; next }
  /^  openclaw-cli:/      { print; print "    container_name: " p "-cli"; next }
  { print }
' docker-compose.yml > docker-compose.yml.tmp && mv docker-compose.yml.tmp docker-compose.yml

# Port allocation: always use 10010, 10015, 10020... (find first free pair)
find_free_port_pair

# Network: default host (ports on host directly), or bridge with 0.0.0.0 mapping
if [ "$HOST_NETWORK" = true ]; then
    log_success "Using host network: gateway $GATEWAY_PORT, dashboard $DASHBOARD_PORT (direct on host)"
    # Remove ports block and add network_mode: host
    sed -i.bak '/^    ports:$/d;/^      - "18789:18789"$/d;/^      - "18790:18790"$/d' docker-compose.yml
    awk '/tty: true/ { if (++tty==1) { print; print "    network_mode: \"host\""; next } }1' docker-compose.yml > docker-compose.yml.tmp && mv docker-compose.yml.tmp docker-compose.yml
    # Gateway listens on 18789 in container/host; use two socats to expose GATEWAY_PORT and DASHBOARD_PORT
    # Socat 1 (existing): dashboard on DASHBOARD_PORT -> 127.0.0.1:18789
    sed -i.bak "s|TCP-LISTEN:18790,fork,bind=0.0.0.0,reuseaddr TCP:127.0.0.1:18789|TCP-LISTEN:${DASHBOARD_PORT},fork,bind=0.0.0.0,reuseaddr TCP:127.0.0.1:18789|" docker-compose.yml
    # Socat 2 (new): gateway on GATEWAY_PORT -> 127.0.0.1:18789 (insert before openclaw-cli)
    awk -v gw="$GATEWAY_PORT" -v p="$COMPOSE_PROJECT" '
      /^  openclaw-cli:/ { print "  socat-gateway:"; print "    container_name: " p "-socat-gateway"; print "    image: alpine/socat"; print "    restart: unless-stopped"; print "    network_mode: \"service:openclaw-gateway\""; print "    command: \"TCP-LISTEN:"gw",fork,bind=0.0.0.0,reuseaddr TCP:127.0.0.1:18789\""; print "" }
      { print }
    ' docker-compose.yml > docker-compose.yml.tmp && mv docker-compose.yml.tmp docker-compose.yml
else
    log_success "Using bridge: gateway $GATEWAY_PORT, dashboard $DASHBOARD_PORT (bound to 0.0.0.0)"
    sed -i.bak "s|\"18789:18789\"|\"0.0.0.0:${GATEWAY_PORT}:18789\"|" docker-compose.yml
    sed -i.bak "s|\"18790:18790\"|\"0.0.0.0:${DASHBOARD_PORT}:18790\"|" docker-compose.yml
fi
rm -f docker-compose.yml.bak

log_success "Downloaded docker-compose.yml"

# Fix permissions for container access
# Docker container runs as node user (UID 1000, GID 1000)
# Ensure the directory is writable by the container user
if [ "$(id -u)" -eq 0 ]; then
    # Running as root/sudo - set ownership to UID 1000 (node user in container)
    # and grant group access to the actual user (if using sudo)
    if [ -n "$SUDO_USER" ]; then
        # Get the sudo user's primary group
        SUDO_GID=$(id -g "$SUDO_USER")
        # Set ownership: UID 1000 (container), GID to sudo user's group
        chown -R 1000:"$SUDO_GID" "$OPENCLAW_DIR"
        # Allow group read/write access
        chmod -R u+rwX,g+rwX,o-rwx "$OPENCLAW_DIR"
        log_success "Set ownership to UID 1000 with group access for $SUDO_USER"
    else
        # Running as actual root user, not via sudo
        chown -R 1000:1000 "$OPENCLAW_DIR"
        chmod -R 755 "$OPENCLAW_DIR"
        log_success "Set ownership to UID 1000 (container user)"
    fi
else
    # Running as non-root user
    # Try 775 first (safer than 777)
    if chmod -R 775 "$OPENCLAW_DIR" 2>/dev/null; then
        ACTUAL_PERMS="775"
        log_warning "Running as non-root user, set permissions to 775"
    else
        # Fallback to 777 if 775 fails (e.g., not the owner)
        chmod -R 777 "$OPENCLAW_DIR"
        ACTUAL_PERMS="777"
        log_warning "Could not set 775 permissions (not owner?), using 777 instead"
    fi
    log_warning "For better security on Synology/NAS, consider running with sudo"
fi

log_success "Created $OPENCLAW_DIR (config)"
log_success "Created $OPENCLAW_DIR/workspace (workspace)"

log_step "Pulling OpenClaw image..."
docker pull "$IMAGE"
log_success "Image pulled successfully!"

# Onboarding
if [ "$SKIP_ONBOARD" = false ]; then
    log_step "Initializing OpenClaw configuration..."
    echo -e "${YELLOW}Setting up configuration and workspace...${NC}\n"
    
    log_step "Running onboarding wizard..."
    echo -e "${YELLOW}This will configure your AI provider and channels.${NC}"
    echo -e "${YELLOW}Follow the prompts to complete setup.${NC}\n"
    
    # Run onboarding interactively (works with bash process substitution)
    if ! $COMPOSE_CMD -p "$COMPOSE_PROJECT" run --rm openclaw-cli onboard; then
        log_warning "Onboarding was cancelled or failed"
        echo -e "${YELLOW}You can run it later with:${NC} cd $INSTALL_DIR && $COMPOSE_CMD -p $COMPOSE_PROJECT run --rm openclaw-cli onboard"
    else
        log_success "Onboarding complete!"
    fi
fi

# Start gateway
if [ "$NO_START" = false ]; then
    log_step "Starting OpenClaw gateway..."
    $COMPOSE_CMD -p "$COMPOSE_PROJECT" up -d openclaw-gateway
    
    # Wait for gateway to be ready
    echo -n "Waiting for gateway to start"
    for i in {1..30}; do
        if curl -s "http://localhost:${GATEWAY_PORT}/health" &> /dev/null; then
            echo ""
            log_success "Gateway is running!"
            break
        fi
        echo -n "."
        sleep 1
    done
    
    if ! curl -s "http://localhost:${GATEWAY_PORT}/health" &> /dev/null; then
        echo ""
        log_warning "Gateway may still be starting. Check logs with: docker logs ${COMPOSE_PROJECT}-gateway"
    fi
fi

# Success message
echo -e "\n${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                                                              ║${NC}"
echo -e "${GREEN}║              🎉 OpenClaw installed successfully! 🎉           ║${NC}"
echo -e "${GREEN}║                                                              ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"

echo -e "\n${BOLD}Quick reference:${NC}"
echo -e "  ${CYAN}Instance:${NC}       $COMPOSE_PROJECT (user: $USERNAME)"
echo -e "  ${CYAN}Dashboard:${NC}      http://localhost:${DASHBOARD_PORT}/?token=YOUR_TOKEN"
echo -e "  ${CYAN}Gateway:${NC}        http://localhost:${GATEWAY_PORT}"
echo -e "  ${CYAN}From other machines:${NC} Use this host's IP (e.g. http://<host-ip>:${DASHBOARD_PORT}). Ensure firewall allows ports ${GATEWAY_PORT}, ${DASHBOARD_PORT}."
if [ "$HOST_NETWORK" = false ]; then
    echo -e "  ${CYAN}Using bridge.${NC} To use host network (default), reinstall without ${CYAN}--bridge${NC}."
fi
echo -e "  ${CYAN}Config:${NC}         $OPENCLAW_DIR"
echo -e "  ${CYAN}Install dir:${NC}    $INSTALL_DIR"

echo -e "\n${BOLD}Useful commands:${NC}"
echo -e "  ${CYAN}View logs:${NC}      cd $INSTALL_DIR && $COMPOSE_CMD -p $COMPOSE_PROJECT logs -f openclaw-gateway"
echo -e "  ${CYAN}Stop:${NC}           cd $INSTALL_DIR && $COMPOSE_CMD -p $COMPOSE_PROJECT down"
echo -e "  ${CYAN}Start:${NC}          cd $INSTALL_DIR && $COMPOSE_CMD -p $COMPOSE_PROJECT up -d openclaw-gateway"
echo -e "  ${CYAN}Restart:${NC}        cd $INSTALL_DIR && $COMPOSE_CMD -p $COMPOSE_PROJECT restart openclaw-gateway"
echo -e "  ${CYAN}CLI:${NC}            cd $INSTALL_DIR && $COMPOSE_CMD -p $COMPOSE_PROJECT run --rm openclaw-cli <command>"
echo -e "  ${CYAN}Update:${NC}         docker pull $IMAGE && cd $INSTALL_DIR && $COMPOSE_CMD -p $COMPOSE_PROJECT up -d"

echo -e "\n${BOLD}Documentation:${NC}  https://docs.openclaw.ai"
echo -e "${BOLD}Support:${NC}        https://discord.gg/clawd"
echo -e "${BOLD}Docker image:${NC}   $REPO_URL"

echo -e "\n${YELLOW}Happy automating! 🤖🦞${NC}\n"
