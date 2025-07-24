#!/bin/bash
set -e

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

# Function to show usage
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -p, --prerequisites    Install system prerequisites (Docker, NVIDIA drivers)"
    echo "  -c, --ctf             Setup CTF environment"
    echo "  -a, --all             Install prerequisites AND setup CTF environment"
    echo "  -r, --auto-reboot     Automatically reboot if required (non-interactive)"
    echo "  -n, --non-interactive Run in non-interactive mode (assumes yes to all prompts)"
    echo "  -h, --help            Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 --all              # Install everything"
    echo "  $0 --prerequisites    # Only install system prerequisites"
    echo "  $0 --ctf              # Only setup CTF environment"
    echo "  $0 --all --auto-reboot --non-interactive  # Full automated setup"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--prerequisites)
            INSTALL_PREREQUISITES=true
            shift
            ;;
        -c|--ctf)
            SETUP_CTF=true
            shift
            ;;
        -a|--all)
            INSTALL_PREREQUISITES=true
            SETUP_CTF=true
            shift
            ;;
        -r|--auto-reboot)
            AUTO_REBOOT=true
            shift
            ;;
        -n|--non-interactive)
            NON_INTERACTIVE=true
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Function to print colored output
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Function to detect OS
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    else
        print_error "Cannot detect OS. This script requires Debian or Ubuntu."
        exit 1
    fi

    if [[ "$OS" != "debian" && "$OS" != "ubuntu" ]]; then
        print_error "This script only supports Debian and Ubuntu."
        exit 1
    fi

    print_info "Detected OS: $OS $VER"
}

# Function to install system updates
install_updates() {
    print_info "Updating system packages..."
    apt-get update
    apt-get upgrade -y
    print_success "System packages updated"
}

# Function to install basic prerequisites
install_prerequisites() {
    print_info "Installing basic prerequisites..."
    apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        software-properties-common \
        wget \
        git \
        build-essential \
        linux-headers-$(uname -r) \
        alsa-utils
    print_success "Basic prerequisites installed"
}

# Function to detect NVIDIA GPU
detect_nvidia_gpu() {
    print_info "Checking for NVIDIA GPU..."
    if lspci | grep -i nvidia > /dev/null; then
        print_info "NVIDIA GPU detected"
        return 0
    else
        print_warning "No NVIDIA GPU detected. Skipping NVIDIA driver installation."
        return 1
    fi
}

# Function to create docker-compose override for GPU mode
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

# Function to install NVIDIA drivers
install_nvidia_drivers() {
    if ! detect_nvidia_gpu; then
        return
    fi

    print_info "Installing NVIDIA drivers and CUDA toolkit..."
    
    # Remove old NVIDIA installations
    apt-get remove --purge -y nvidia* cuda* 2>/dev/null || true
    apt-get autoremove -y

    # Add NVIDIA repository
    if [[ "$OS" == "ubuntu" ]]; then
        # For Ubuntu
        # First install ubuntu-drivers-common
        apt-get install -y ubuntu-drivers-common
        
        # Add the graphics drivers PPA
        add-apt-repository -y ppa:graphics-drivers/ppa
        apt-get update
        
        # Install recommended driver
        ubuntu-drivers autoinstall
    else
        # For Debian
        apt-get update
        apt-get install -y nvidia-driver firmware-misc-nonfree
    fi

    # Install NVIDIA Container Toolkit for Docker
    print_info "Installing NVIDIA Container Toolkit..."
    
    # Remove old GPG key method and use the new method
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    
    # Add the repository with the new GPG key location
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
      sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
      sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    
    # Update and install
    apt-get update
    apt-get install -y nvidia-container-toolkit
    
    # Configure Docker to use NVIDIA runtime
    nvidia-ctk runtime configure --runtime=docker
    
    # Check if Docker service exists before trying to restart
    if systemctl list-unit-files | grep -q "^docker.service"; then
        systemctl restart docker
        print_success "Docker restarted with NVIDIA runtime"
    else
        print_warning "Docker service not found. You may need to start Docker manually."
    fi
    
    print_success "NVIDIA drivers and container toolkit installed"
    print_warning "A system reboot may be required for NVIDIA drivers to take effect"
}

# Function to install Docker
install_docker() {
    print_info "Installing Docker..."
    
    # Remove old Docker installations
    apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

    # Add Docker's official GPG key
    curl -fsSL https://download.docker.com/linux/$OS/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

    # Set up the stable repository
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/$OS \
      $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Install Docker Engine
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

    # Enable and start Docker
    systemctl enable docker
    systemctl start docker
    
    # Verify Docker is running
    if ! systemctl is-active --quiet docker; then
        print_error "Docker service failed to start"
        print_info "Trying to start Docker manually..."
        service docker start
        sleep 5
        if ! systemctl is-active --quiet docker; then
            print_error "Docker service still not running. Please check system logs."
            exit 1
        fi
    fi
    
    print_success "Docker service is running"

    # Add current user to docker group (if not root)
    if [ "$SUDO_USER" ]; then
        usermod -aG docker $SUDO_USER
        print_info "Added $SUDO_USER to docker group. User needs to log out and back in for this to take effect."
    fi

    print_success "Docker installed successfully"
}

# Function to configure Docker for NVIDIA
configure_docker_nvidia() {
    if ! detect_nvidia_gpu; then
        return
    fi

    print_info "Configuring Docker for NVIDIA GPU support..."
    
    # First check if Docker is running
    if ! systemctl is-active --quiet docker; then
        print_warning "Docker is not running. Skipping NVIDIA configuration."
        print_info "Please start Docker and run 'nvidia-ctk runtime configure --runtime=docker' manually."
        return
    fi
    
    # Configure Docker daemon
    cat > /etc/docker/daemon.json <<EOF
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

    # Restart Docker
    systemctl restart docker
    
    print_success "Docker configured for NVIDIA GPU support"
}

# Function to verify installations
verify_installations() {
    print_info "Verifying installations..."
    
    # Check Docker
    if docker --version > /dev/null 2>&1; then
        print_success "Docker: $(docker --version)"
    else
        print_error "Docker installation failed"
        exit 1
    fi

    # Check Docker Compose
    if docker compose version > /dev/null 2>&1; then
        print_success "Docker Compose: $(docker compose version)"
    else
        print_error "Docker Compose installation failed"
        exit 1
    fi

    # Check NVIDIA (if GPU present)
    if detect_nvidia_gpu; then
        if nvidia-smi > /dev/null 2>&1; then
            print_success "NVIDIA drivers installed and working"
            nvidia-smi
        else
            print_warning "NVIDIA drivers installed but not yet active. Please reboot."
        fi
    fi
}

# Main CTF setup function (simplified)
setup_ctf_environment() {
    echo ""
    echo "🏁 Initializing Open WebUI CTF Environment"
    echo "=========================================="

    # Check for GPU and create override file if needed
    GPU_AVAILABLE=false
    if lspci | grep -i nvidia > /dev/null && nvidia-smi > /dev/null 2>&1; then
        GPU_AVAILABLE=true
        print_info "GPU detected and NVIDIA drivers working - Creating GPU configuration"
        create_gpu_override
    else
        GPU_AVAILABLE=false
        print_info "No GPU detected or NVIDIA drivers not working - Using CPU-only configuration"
        # Remove any existing override file for clean CPU-only setup
        if [ -f docker-compose.override.yml ]; then
            rm docker-compose.override.yml
            print_info "Removed existing docker-compose.override.yml for CPU-only mode"
        fi
    fi

    # Load environment variables if .env exists
    if [ -f .env ]; then
        echo "📋 Loading environment variables from .env"
        export $(cat .env | grep -v '^#' | xargs)
    fi

    # Build and start all services
    echo "🔨 Building Docker images..."
    docker compose build

    echo "🚀 Starting all services..."
    docker compose up -d

    echo "⏳ Waiting for services to be ready..."
    sleep 30

    # Verify services are running
    echo "✅ Verifying services..."
    docker compose ps

    echo ""
    echo "✅ CTF environment setup complete!"
    echo ""
    echo "📋 Access Information:"
    echo "- Open WebUI: http://localhost:${OPENWEBUI_PORT:-4242}"
    echo "- Jupyter: http://localhost:${JUPYTER_PORT:-8888}"
    echo "- Jupyter Token: ${JUPYTER_TOKEN:-AntiSyphonBlackHillsTrainingFtw!}"
    echo ""
    echo "🔐 Login Credentials:"
    echo "- Admin: ${CTF_ADMIN_EMAIL:-admin@ctf.local} / ${CTF_ADMIN_PASSWORD:-ctf_admin_password}"
    echo "- User: ${CTF_USER_EMAIL:-ctf@ctf.local} / ${CTF_USER_PASSWORD:-Hellollmworld!}"
    echo ""
    echo "🚩 CTF Challenges:"
    echo "- Challenge 1-5: Prompt injection challenges"
    echo "- Challenge 6: Code interpreter challenge"
    echo "- Challenge 7: Exploit the calculator tool"
    echo ""
    echo "🚩 CTF Flags:"
    echo "- Docker volume flag: /app/backend/data/ctf/flag.txt in open-webui container"
    echo "- Jupyter flag: /home/jovyan/flag.txt and /home/jovyan/work/flag.txt in jupyter container"
    echo ""
    
    if [[ "$GPU_AVAILABLE" == "false" ]]; then
        echo "⚠️  Running in CPU-only mode (no GPU detected or drivers not working)"
    else
        echo "✅ Running with GPU support enabled"
    fi
}

# Main execution
main() {
    echo "======================================"
    echo "Open WebUI CTF Complete Setup Script"
    echo "======================================"
    echo ""

    # Check if running as root
    check_root

    # Detect OS
    detect_os

    # If no arguments provided and not non-interactive, run interactive mode
    if [[ "$INSTALL_PREREQUISITES" == "false" && "$SETUP_CTF" == "false" && "$NON_INTERACTIVE" == "false" ]]; then
        # Interactive mode - ask user what they want to do
        read -p "Do you want to install system prerequisites (Docker, NVIDIA drivers)? [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            INSTALL_PREREQUISITES=true
        fi

        echo ""
        read -p "Do you want to setup the CTF environment? [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            SETUP_CTF=true
        fi
    fi

    # Install prerequisites if requested
    if [[ "$INSTALL_PREREQUISITES" == "true" ]]; then
        print_info "Installing system prerequisites..."
        
        # Install system updates
        install_updates

        # Install prerequisites
        install_prerequisites

        # Install NVIDIA drivers
        install_nvidia_drivers

        # Install Docker
        install_docker

        # Configure Docker for NVIDIA
        configure_docker_nvidia

        # Verify installations
        verify_installations

        print_info "System prerequisites installation complete!"
        
        # Check if reboot is needed for NVIDIA
        if detect_nvidia_gpu && ! nvidia-smi > /dev/null 2>&1; then
            print_warning "NVIDIA drivers require a system reboot to become active."
            
            if [[ "$NON_INTERACTIVE" == "true" ]]; then
                if [[ "$AUTO_REBOOT" == "true" ]]; then
                    print_info "Auto-reboot enabled. System will reboot in 10 seconds."
                    print_info "Please run '$0 --ctf' after reboot to continue CTF setup."
                    sleep 10
                    reboot
                else
                    print_warning "Reboot required but auto-reboot not enabled."
                    print_warning "Please reboot manually and run '$0 --ctf' to continue CTF setup."
                    exit 0
                fi
            else
                read -p "Do you want to reboot now? [y/N] " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    print_info "System will reboot in 10 seconds. Please run '$0 --ctf' after reboot to continue CTF setup."
                    sleep 10
                    reboot
                else
                    print_warning "Please reboot manually and run '$0 --ctf' to continue CTF setup."
                    exit 0
                fi
            fi
        fi
    fi

    # Setup CTF environment if requested
    if [[ "$SETUP_CTF" == "true" ]]; then
        # Check if Docker is installed
        if ! command -v docker &> /dev/null; then
            print_error "Docker is not installed. Please run '$0 --prerequisites' first."
            exit 1
        fi
        
        setup_ctf_environment
    fi

    if [[ "$INSTALL_PREREQUISITES" == "false" && "$SETUP_CTF" == "false" ]]; then
        print_warning "No actions were selected. Use -h for help."
        show_usage
        exit 0
    fi

    print_success "Setup complete!"
}

# Run main function
main