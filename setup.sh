#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# Open WebUI CTF Complete Setup Script
# Hardened NVIDIA setup (no PPA), macOS support
# ==========================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values for non-interactive mode
INSTALL_PREREQUISITES=false
SETUP_CTF=false
AUTO_REBOOT=false
NON_INTERACTIVE=false

# Internal flags
REBOOT_REQUIRED=false
LINUX_OS=""
LINUX_VER=""
ON_MAC=false

# -------------------------
# Output helpers
# -------------------------
print_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $*"; }

# -------------------------
# Usage
# -------------------------
show_usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -p, --prerequisites    Install system prerequisites (Docker, NVIDIA drivers where applicable)
  -c, --ctf              Setup CTF environment
  -a, --all              Install prerequisites AND setup CTF environment
  -r, --auto-reboot      Automatically reboot if required (non-interactive)
  -n, --non-interactive  Run in non-interactive mode (assumes yes to prompts where safe)
  -h, --help             Show this help message

Examples:
  $0 --all
  $0 --prerequisites
  $0 --ctf
  $0 --all --auto-reboot --non-interactive
EOF
}

# -------------------------
# Arg parsing
# -------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--prerequisites) INSTALL_PREREQUISITES=true; shift;;
        -c|--ctf)           SETUP_CTF=true; shift;;
        -a|--all)           INSTALL_PREREQUISITES=true; SETUP_CTF=true; shift;;
        -r|--auto-reboot)   AUTO_REBOOT=true; shift;;
        -n|--non-interactive) NON_INTERACTIVE=true; shift;;
        -h|--help)          show_usage; exit 0;;
        *) print_error "Unknown option: $1"; show_usage; exit 1;;
    esac
done

# -------------------------
# Root check (Linux only)
# -------------------------
check_root_linux() {
    if $ON_MAC; then return 0; fi
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root on Linux (use sudo)."
        exit 1
    fi
}

# -------------------------
# OS detection
# -------------------------
detect_os() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        ON_MAC=true
        print_info "Detected macOS $(sw_vers -productVersion) ($(uname -m))"
        return
    fi

    ON_MAC=false
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        LINUX_OS="$ID"
        LINUX_VER="$VERSION_ID"
        print_info "Detected OS: $LINUX_OS $LINUX_VER"
    else
        print_error "Cannot detect OS. This script supports Ubuntu, Debian, and macOS."
        exit 1
    fi

    case "$LINUX_OS" in
        ubuntu|debian) : ;;
        *) print_error "Unsupported Linux distro: $LINUX_OS. Only Ubuntu/Debian are supported."; exit 1;;
    esac
}

# -------------------------
# WSL detection
# -------------------------
detect_wsl() {
    if [[ -f /proc/version ]] && grep -qiE "(microsoft|wsl)" /proc/version; then
        return 0
    fi
    if [[ -f /proc/sys/fs/binfmt_misc/WSLInterop ]]; then
        return 0
    fi
    return 1
}

# -------------------------
# System updates (Linux)
# -------------------------
install_updates_linux() {
    print_info "Updating system packages..."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
    print_success "System packages updated"
}

# -------------------------
# Basic prerequisites (Linux)
# -------------------------
install_prerequisites_linux() {
    print_info "Installing basic prerequisites..."
    local pkgs="apt-transport-https ca-certificates curl gnupg lsb-release software-properties-common wget git build-essential alsa-utils"
    if ! detect_wsl; then
        pkgs="$pkgs linux-headers-$(uname -r)"
    else
        print_info "Skipping linux-headers installation in WSL"
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs
    print_success "Basic prerequisites installed"
}

# -------------------------
# macOS prerequisites
# -------------------------
ensure_brew() {
    if command -v brew >/dev/null 2>&1; then
        print_success "Homebrew present"
        return
    fi
    print_info "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    print_success "Homebrew installed"
    # Ensure brew available in this shell
    if [[ -d "/opt/homebrew/bin" ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -d "/usr/local/bin" ]]; then
        eval "$(/usr/local/bin/brew shellenv)" || true
    fi
}

install_prerequisites_macos() {
    print_info "Installing macOS prerequisites..."
    ensure_brew
    brew update

    # Prefer Docker Desktop (works on Intel & Apple Silicon)
    if ! brew list --cask docker >/dev/null 2>&1; then
        brew install --cask docker
        print_info "Docker Desktop installed. Start it once to finish setup."
    else
        print_success "Docker Desktop already installed"
    fi

    # Optional: Colima (for CLI-only Docker runtime)
    if ! command -v colima >/dev/null 2>&1; then
        brew install colima
        print_info "Colima installed (optional). To use: 'colima start' then 'docker context use default'."
    fi

    # Git, wget, core build tools
    brew install git wget || true
    print_success "macOS prerequisites installed"
}

# -------------------------
# NVIDIA detection (Linux)
# -------------------------
detect_nvidia_gpu_linux() {
    if detect_wsl; then
        print_warning "WSL detected. GPU support is managed by Windows host; skipping Linux NVIDIA driver install."
        return 1
    fi
    if command -v lspci >/dev/null 2>&1 && lspci | grep -iq nvidia; then
        print_info "NVIDIA GPU detected"
        return 0
    fi
    print_warning "No NVIDIA GPU detected. Skipping NVIDIA driver installation."
    return 1
}

nvidia_driver_active() {
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

nvidia_packages_installed() {
    dpkg -l | awk '{print $2}' | grep -Eq '^nvidia-(driver|kernel-common|kernel-dkms|headless|utils|settings)' && return 0 || return 1
}

# -------------------------
# Nouveau blacklist (Linux)
# -------------------------
ensure_blacklist_nouveau() {
    if [[ -f /etc/modprobe.d/blacklist-nouveau.conf ]]; then
        return
    fi
    print_info "Blacklisting nouveau to avoid conflicts..."
    cat >/etc/modprobe.d/blacklist-nouveau.conf <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
    update-initramfs -u || true
    REBOOT_REQUIRED=true
}

# -------------------------
# Enable required apt components (Ubuntu/Debian)
# -------------------------
enable_apt_components() {
    # Ensure restricted (Ubuntu) and non-free/non-free-firmware (Debian) are enabled
    if [[ "$LINUX_OS" == "ubuntu" ]]; then
        if ! grep -E "^[^#].* $(lsb_release -cs) (main|universe|multiverse|restricted)" /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null | grep -q restricted; then
            print_info "Enabling 'restricted' component for Ubuntu..."
            add-apt-repository -y restricted
        fi
    elif [[ "$LINUX_OS" == "debian" ]]; then
        if ! grep -E "^[^#].* (non-free|non-free-firmware)" /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null >/dev/null; then
            print_info "Enabling 'non-free non-free-firmware' for Debian..."
            sed -i 's/ main$/ main non-free non-free-firmware/g' /etc/apt/sources.list
        fi
    fi
    apt-get update
}

# -------------------------
# Install NVIDIA drivers (stable, no PPA)
# -------------------------
install_nvidia_drivers_linux() {
    if detect_wsl; then
        print_info "Configuring NVIDIA Container Toolkit for WSL (driver provided by Windows host)..."
        # keyring for libnvidia-container
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
        curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
          | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
          | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y nvidia-container-toolkit
        nvidia-ctk runtime configure --runtime=docker || true
        if service docker restart 2>/dev/null; then
            print_success "Docker restarted with NVIDIA runtime (WSL)"
        else
            print_warning "Could not restart Docker automatically in WSL. Run: sudo service docker restart"
        fi
        return
    fi

    if ! detect_nvidia_gpu_linux; then
        return
    fi

    if nvidia_driver_active; then
        print_success "NVIDIA drivers already active (nvidia-smi OK). Skipping driver install."
    else
        print_info "Installing NVIDIA drivers from official distro repositories (no PPA)..."
        enable_apt_components
        ensure_blacklist_nouveau

        if [[ "$LINUX_OS" == "ubuntu" ]]; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y ubuntu-drivers-common
            # Determine the recommended driver without enabling the graphics-drivers PPA
            RECOMMENDED=$(ubuntu-drivers devices 2>/dev/null | awk '/recommended/ {print $3}' | head -n1 || true)
            if [[ -n "${RECOMMENDED:-}" ]]; then
                print_info "Installing recommended package: $RECOMMENDED"
                DEBIAN_FRONTEND=noninteractive apt-get install -y "$RECOMMENDED"
            else
                # Fallback to autoinstall (still without PPA)
                print_info "No explicit recommendation parsed; using 'ubuntu-drivers autoinstall' (distro repos only)."
                ubuntu-drivers autoinstall || true
            fi
        else # Debian
            DEBIAN_FRONTEND=noninteractive apt-get install -y nvidia-driver firmware-misc-nonfree
        fi

        REBOOT_REQUIRED=true
        print_warning "Kernel modules were changed. A system reboot is likely required for NVIDIA drivers to become active."
    fi

    # NVIDIA Container Toolkit (Linux)
    print_info "Installing NVIDIA Container Toolkit for Docker..."
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
      | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y nvidia-container-toolkit
    nvidia-ctk runtime configure --runtime=docker || true

    # Restart docker if present
    if systemctl list-unit-files | grep -q "^docker.service"; then
        systemctl restart docker || true
        print_success "Docker restarted with NVIDIA runtime"
    else
        print_warning "Docker systemd service not found. Start/restart Docker manually if needed."
    fi

    if ! nvidia_driver_active; then
        print_warning "NVIDIA drivers not yet active. Reboot required."
    else
        print_success "NVIDIA drivers are active."
    fi
}

# -------------------------
# Docker install
# -------------------------
install_docker_linux() {
    print_info "Installing Docker (Linux)..."
    apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

    curl -fsSL "https://download.docker.com/linux/${LINUX_OS}/gpg" | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/${LINUX_OS} \
      $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list >/dev/null

    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

    if detect_wsl; then
        print_info "Attempting to start Docker in WSL..."
        service docker start || true
        sleep 3
        if ! docker version >/dev/null 2>&1; then
            print_warning "Docker may not be running. In WSL, start manually (sudo service docker start) or use Docker Desktop with WSL2 integration."
        fi
    else
        systemctl enable docker || true
        systemctl start docker || true
        if ! systemctl is-active --quiet docker; then
            print_error "Docker service failed to start. Attempting legacy service start..."
            service docker start || true
            sleep 3
            systemctl is-active --quiet docker || { print_error "Docker service not running. Check system logs."; exit 1; }
        fi
        print_success "Docker service is running"
    fi

    if [[ -n "${SUDO_USER:-}" ]]; then
        usermod -aG docker "$SUDO_USER" || true
        print_info "Added $SUDO_USER to docker group (log out/in for effect)."
    fi
    print_success "Docker installed (Linux)"
}

install_docker_macos() {
    print_info "Ensuring Docker Desktop is installed (macOS)..."
    ensure_brew
    if ! brew list --cask docker >/dev/null 2>&1; then
        brew install --cask docker
    fi
    print_success "Docker Desktop present"
    print_info "If Docker CLI fails, open Docker Desktop once to finish setup."
}

# -------------------------
# Configure Docker for NVIDIA (Linux/WSL)
# -------------------------
configure_docker_nvidia() {
    if $ON_MAC; then return; fi

    if detect_wsl; then
        print_info "Configuring Docker for NVIDIA (WSL)..."
        if ! command -v nvidia-ctk >/dev/null 2>&1; then
            print_warning "NVIDIA Container Toolkit not found; skipping."
            return
        fi
    elif ! detect_nvidia_gpu_linux; then
        return
    fi

    if detect_wsl; then
        if ! docker version >/dev/null 2>&1; then
            print_warning "Docker not running in WSL; skipping NVIDIA Docker configuration."
            return
        fi
    else
        if ! systemctl is-active --quiet docker; then
            print_warning "Docker is not running; skipping NVIDIA Docker configuration."
            return
        fi
    fi

    mkdir -p /etc/docker
    cat >/etc/docker/daemon.json <<'EOF'
{
  "default-runtime": "nvidia",
  "runtimes": {
    "nvidia": {
      "path": "nvidia-container-runtime",
      "runtimeArgs": []
    }
  }
}
EOF

    if detect_wsl; then
        service docker restart 2>/dev/null || print_warning "Restart Docker manually: sudo service docker restart"
    else
        systemctl restart docker || true
    fi
    print_success "Docker configured for NVIDIA GPU support"
}

# -------------------------
# Verification
# -------------------------
verify_installations() {
    print_info "Verifying installations..."

    if command -v docker >/dev/null 2>&1; then
        print_success "Docker: $(docker --version)"
    else
        print_error "Docker installation failed"
        exit 1
    fi

    if docker compose version >/dev/null 2>&1; then
        print_success "Docker Compose: $(docker compose version)"
    else
        print_error "Docker Compose installation failed"
        exit 1
    fi

    if $ON_MAC; then
        print_info "macOS detected: NVIDIA verification not applicable."
        return
    fi

    if detect_wsl; then
        print_info "WSL environment - NVIDIA driver managed by Windows host."
        if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
            print_success "NVIDIA GPU accessible in WSL"
            nvidia-smi || true
        else
            print_info "nvidia-smi not accessible. Ensure GPU drivers are installed on Windows host."
        fi
    elif detect_nvidia_gpu_linux; then
        if nvidia_driver_active; then
            print_success "NVIDIA drivers installed and working"
            nvidia-smi || true
        else
            print_warning "NVIDIA drivers installed but not yet active. Reboot required."
            REBOOT_REQUIRED=true
        fi
    fi
}

# -------------------------
# GPU docker-compose override
# -------------------------
create_gpu_override() {
    print_info "Creating docker-compose override for GPU mode..."
    cat > docker-compose.override.yml << 'EOF'
# This override file enables GPU support for systems with NVIDIA GPUs
version: '3.8'

services:
  ollama:
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]

  open-webui:
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]

  jupyter:
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
EOF
    print_success "Created docker-compose.override.yml for GPU mode"
}

# -------------------------
# AWS Bedrock Configuration
# -------------------------
configure_bedrock() {
    print_info "Configuring AWS Bedrock integration..."

    if [[ ! -f .env ]]; then
        print_error ".env file not found!"
        exit 1
    fi

    # Prompt for AWS credentials
    echo ""
    echo "🔐 AWS Bedrock Configuration"
    echo "=============================="
    echo ""

    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        print_info "Running in non-interactive mode. Using credentials from .env file."
        return
    fi

    read -p "Configure AWS Bedrock? [y/N] " -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Skipping AWS Bedrock configuration"
        return
    fi

    echo "Enter your AWS credentials for Bedrock access:"
    echo "(These will be stored in the .env file)"
    echo ""

    read -p "AWS Access Key ID: " AWS_KEY
    read -sp "AWS Secret Access Key: " AWS_SECRET
    echo ""
    read -p "AWS Region [us-east-1]: " AWS_REG
    AWS_REG=${AWS_REG:-us-east-1}

    # Update .env file with AWS credentials
    sed -i "s/AWS_ACCESS_KEY_ID=.*/AWS_ACCESS_KEY_ID=${AWS_KEY}/" .env
    sed -i "s/AWS_SECRET_ACCESS_KEY=.*/AWS_SECRET_ACCESS_KEY=${AWS_SECRET}/" .env
    sed -i "s/AWS_DEFAULT_REGION=.*/AWS_DEFAULT_REGION=${AWS_REG}/" .env
    sed -i "s/AWS_REGION=.*/AWS_REGION=${AWS_REG}/" .env

    print_success "AWS Bedrock configuration saved to .env file"
}

# -------------------------
# CTF setup
# -------------------------
setup_ctf_environment() {
    echo ""
    echo "🏁 Initializing Open WebUI CTF Environment"
    echo "=========================================="

    # Configure Bedrock if needed
    configure_bedrock

    GPU_AVAILABLE=false

    if $ON_MAC; then
        print_info "macOS detected; NVIDIA GPU path not applicable. Running CPU-only by default."
    elif detect_wsl; then
        print_info "WSL: attempting to detect GPU availability..."
        if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
            GPU_AVAILABLE=true
            create_gpu_override
            print_success "GPU detected in WSL"
        else
            print_info "No GPU detected in WSL (or not exposed). Using CPU-only."
        fi
    elif command -v lspci >/dev/null 2>&1 && lspci | grep -iq nvidia && nvidia_driver_active; then
        GPU_AVAILABLE=true
        create_gpu_override
        print_success "GPU detected and drivers working (Linux)"
    else
        print_info "No GPU detected or drivers not active. Using CPU-only."
    fi

    if [[ "$GPU_AVAILABLE" == "false" ]] && [[ -f docker-compose.override.yml ]]; then
        rm -f docker-compose.override.yml
        print_info "Removed docker-compose.override.yml for CPU-only mode"
    fi

    if [[ -f .env ]]; then
        echo "📋 Loading environment variables from .env"
        set -a; # export
        # shellcheck disable=SC2046
        export $(grep -v '^#' .env | xargs) || true
        set +a
    fi

    echo "🔨 Building Docker images..."
    docker compose build

    echo "🚀 Starting all services..."
    docker compose up -d

    echo "⏳ Waiting for services to be ready..."
    sleep 30

    echo "✅ Verifying services..."
    docker compose ps

    echo ""
    echo "✅ CTF environment setup complete!"
    echo ""
    echo "📋 Access Information:"
    echo "- Open WebUI: http://localhost:${OPENWEBUI_PORT:-4242}"
    echo "- Bedrock Gateway: http://localhost:${BEDROCK_PORT:-8081}"
    echo "- Jupyter: http://localhost:${JUPYTER_PORT:-8888}"
    echo "- Jupyter Token: ${JUPYTER_TOKEN:-AntiSyphonBlackHillsTrainingFtw!}"
    echo ""
    echo "🔐 Bedrock Configuration:"
    echo "- API Base URL: http://localhost:${BEDROCK_PORT:-8081}/api/v1"
    echo "- API Key: ${BEDROCK_API_KEY:-bedrock}"
    echo ""
    echo "🔐 Login Credentials:"
    echo "- Admin: ${CTF_ADMIN_EMAIL:-admin@ctf.local} / ${CTF_ADMIN_PASSWORD:-ctf_admin_password}"
    echo "- User: ${CTF_USER_EMAIL:-ctf@ctf.local} / ${CTF_USER_PASSWORD:-Hellollmworld!}"
    echo ""
    echo "🚩 CTF Challenges:"
    echo "- Challenge 1-6: Prompt injection challenges"
    echo "- Challenge 7: Code interpreter challenge"
    echo "- Challenge 8: Exploit the calculator tool"
    echo "- Challenge 9: RAG"
    echo "- Challenge 10: Email Summarizer"
    echo "- Challenge 11: Multi-modal"
    echo ""
    echo "🚩 CTF Flags:"
    echo "- Docker volume flag: /app/backend/data/ctf/flag.txt in open-webui container"
    echo "- Jupyter flag: /home/jovyan/flag.txt and /home/jovyan/work/flag.txt in jupyter container"
    echo ""

    if [[ "$GPU_AVAILABLE" == "false" ]]; then
        echo "⚠️  Running in CPU-only mode"
    else
        echo "✅ Running with GPU support enabled"
    fi

    if detect_wsl; then
        echo ""
        echo "📌 WSL Note: GPU support requires proper setup on Windows host"
    fi
}

# -------------------------
# Main
# -------------------------
main() {
    echo "======================================"
    echo "Open WebUI CTF Complete Setup Script"
    echo "======================================"
    echo ""

    detect_os
    if ! $ON_MAC; then
        check_root_linux
    fi

    # Interactive selections
    if [[ "$INSTALL_PREREQUISITES" == "false" && "$SETUP_CTF" == "false" && "$NON_INTERACTIVE" == "false" ]]; then
        if $ON_MAC; then
            read -p "Install system prerequisites (Docker, etc.) for macOS? [y/N] " -n 1 -r; echo
            [[ $REPLY =~ ^[Yy]$ ]] && INSTALL_PREREQUISITES=true
            echo ""
            read -p "Setup the CTF environment now? [y/N] " -n 1 -r; echo
            [[ $REPLY =~ ^[Yy]$ ]] && SETUP_CTF=true
        else
            read -p "Install system prerequisites (Docker, NVIDIA drivers)? [y/N] " -n 1 -r; echo
            [[ $REPLY =~ ^[Yy]$ ]] && INSTALL_PREREQUISITES=true
            echo ""
            read -p "Setup the CTF environment now? [y/N] " -n 1 -r; echo
            [[ $REPLY =~ ^[Yy]$ ]] && SETUP_CTF=true
        fi
    fi

    # Prerequisites
    if [[ "$INSTALL_PREREQUISITES" == "true" ]]; then
        print_info "Installing system prerequisites..."

        if $ON_MAC; then
            install_prerequisites_macos
            install_docker_macos
            verify_installations
            print_info "System prerequisites installation complete (macOS)!"
        else
            install_updates_linux
            install_prerequisites_linux
            install_nvidia_drivers_linux
            install_docker_linux
            configure_docker_nvidia
            verify_installations
            print_info "System prerequisites installation complete (Linux)!"

            # Reboot logic (Linux only) if drivers were touched
            if ! detect_wsl; then
                if ${REBOOT_REQUIRED}; then
                    print_warning "NVIDIA drivers were installed/updated. A reboot is likely required."
                    if [[ "$NON_INTERACTIVE" == "true" ]]; then
                        if [[ "$AUTO_REBOOT" == "true" ]]; then
                            print_info "Auto-reboot enabled. System will reboot in 10 seconds."
                            print_info "After reboot, re-run '$0 --ctf' to continue CTF setup."
                            sleep 10
                            reboot
                        else
                            print_warning "Reboot required but auto-reboot not enabled. Please reboot, then run '$0 --ctf'."
                            exit 0
                        fi
                    else
                        read -p "Reboot now? [y/N] " -n 1 -r; echo
                        if [[ $REPLY =~ ^[Yy]$ ]]; then
                            print_info "Rebooting in 10 seconds. After reboot, run '$0 --ctf'."
                            sleep 10
                            reboot
                        else
                            print_warning "Please reboot manually and then run '$0 --ctf' to continue CTF setup."
                            exit 0
                        fi
                    fi
                fi
            fi
        fi
    fi

    # CTF
    if [[ "$SETUP_CTF" == "true" ]]; then
        if ! command -v docker >/dev/null 2>&1; then
            print_error "Docker is not installed. Run '$0 --prerequisites' first."
            exit 1
        fi
        setup_ctf_environment
    fi

    if [[ "$INSTALL_PREREQUISITES" == "false" && "$SETUP_CTF" == "false" ]]; then
        print_warning "No actions selected. Use -h for help."
        show_usage
        exit 0
    fi

    print_success "Setup complete!"
}

main

