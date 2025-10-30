#!/bin/bash

# DSpace Docker Installation and Setup Script with Auto-Install
# This script automates Docker installation and DSpace setup for Ubuntu

set -e  # Exit on any error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Cleanup flag
CLEANUP_ON_EXIT=false

# Function to print colored messages
print_message() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Cleanup function
cleanup_on_failure() {
    if [ "$CLEANUP_ON_EXIT" = true ]; then
        print_warning "Cleaning up due to failure..."
        cd "$(dirname "$0")"
        if [ -d "dspace-angular" ]; then
            cd dspace-angular
            docker compose -p d9 -f docker/docker-compose.yml -f docker/docker-compose-rest.yml down 2>/dev/null || true
        fi
    fi
}

# Set trap for cleanup
trap cleanup_on_failure EXIT

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check OS
check_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" != "ubuntu" && "$ID_LIKE" != *"ubuntu"* && "$ID_LIKE" != *"debian"* ]]; then
            print_error "This script only supports Ubuntu/Debian-based systems."
            print_error "Detected OS: $ID"
            exit 1
        fi
    else
        print_error "Cannot determine OS. This script requires Ubuntu/Debian."
        exit 1
    fi
}

# Function to install Docker on Ubuntu
install_docker_ubuntu() {
    print_step "Installing Docker on Ubuntu..."
    
    # Update package index
    sudo apt-get update
    
    # Install prerequisites
    sudo apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release
    
    # Add Docker's official GPG key
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    
    # Set up the repository
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Install Docker Engine
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    # Start and enable Docker
    sudo systemctl start docker
    sudo systemctl enable docker
    
    # Add current user to docker group
    sudo usermod -aG docker $USER
    
    print_message "Docker installed successfully!"
    print_warning "Docker group membership added. Restarting script with proper permissions..."
    
    # Re-execute script with new group permissions
    exec sg docker "$0 $@"
}

# Function to install Git
install_git() {
    print_step "Installing Git..."
    
    sudo apt-get update
    sudo apt-get install -y git
    
    print_message "Git installed successfully!"
}

# Function to validate email
validate_email() {
    local email=$1
    if [[ $email =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Function to wait for container to be ready
wait_for_container() {
    local container_name=$1
    local max_wait=60
    local elapsed=0
    
    print_message "Waiting for container '$container_name' to be ready..."
    
    while [ $elapsed -lt $max_wait ]; do
        if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
            sleep 2  # Give it a moment to fully initialize
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    
    print_error "Container '$container_name' failed to start within ${max_wait} seconds"
    return 1
}

# Function to wait for database
wait_for_database() {
    print_message "Waiting for database to be ready..."
    local max_attempts=30
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        # First check if container is running
        if ! docker ps --format '{{.Names}}' | grep -q "^dspacedb$"; then
            print_warning "Database container not running yet... (attempt $((attempt + 1))/$max_attempts)"
            sleep 5
            attempt=$((attempt + 1))
            continue
        fi
        
        # Then check if PostgreSQL is ready
        if docker compose -p d9 -f docker/docker-compose.yml exec -T dspacedb pg_isready -U dspace >/dev/null 2>&1; then
            print_message "Database is ready!"
            return 0
        fi
        
        attempt=$((attempt + 1))
        if [ $attempt -eq $max_attempts ]; then
            print_error "Database failed to start. Please check logs."
            docker compose -p d9 -f docker/docker-compose.yml -f docker/docker-compose-rest.yml logs dspacedb
            return 1
        fi
        print_warning "Waiting for database... (attempt $attempt/$max_attempts)"
        sleep 5
    done
    
    return 1
}

# Main installation function
install_docker() {
    print_message "Installing Docker for Ubuntu..."
    install_docker_ubuntu
}

# Check OS compatibility
print_message "Checking OS compatibility..."
check_os

# Check prerequisites
print_message "Checking prerequisites..."

# Check and install Docker
if ! command_exists docker; then
    print_warning "Docker is not installed."
    read -p "Would you like to install Docker automatically? (Y/n): " install_docker_choice
    
    if [[ ! $install_docker_choice =~ ^[Nn]$ ]]; then
        install_docker
        
        # Verify installation
        if ! command_exists docker; then
            print_error "Docker installation failed or requires system restart."
            exit 1
        fi
    else
        print_error "Docker is required to continue. Please install it manually."
        echo "Visit: https://docs.docker.com/get-docker/"
        exit 1
    fi
else
    print_message "Docker is already installed."
fi

# Check Docker service status
if ! docker ps >/dev/null 2>&1; then
    print_warning "Docker daemon is not running or requires elevated privileges."
    print_message "Attempting to start Docker service..."
    sudo systemctl start docker
    sleep 5
    
    # Check again
    if ! docker ps >/dev/null 2>&1; then
        print_error "Cannot connect to Docker daemon. You may need to be in the docker group."
        print_message "Attempting to run with docker group permissions..."
        exec sg docker "$0 $@"
    fi
fi

# Check and install Git
if ! command_exists git; then
    print_warning "Git is not installed."
    read -p "Would you like to install Git automatically? (Y/n): " install_git_choice
    
    if [[ ! $install_git_choice =~ ^[Nn]$ ]]; then
        install_git
    else
        print_error "Git is required to continue. Please install it manually."
        echo "Download from: https://git-scm.com/downloads"
        exit 1
    fi
else
    print_message "Git is already installed."
fi

print_message "Prerequisites check passed!"

# Enable cleanup on failure from this point
CLEANUP_ON_EXIT=true

# Clone DSpace Angular repository
print_message "Cloning DSpace Angular repository..."
if [ -d "dspace-angular" ]; then
    print_warning "dspace-angular directory already exists."
    cd dspace-angular
    
    # Check if directory is a git repository
    if [ -d ".git" ]; then
        print_message "Fetching latest changes..."
        git fetch origin
        
        # Handle dirty working directory
        if ! git diff-index --quiet HEAD -- 2>/dev/null; then
            print_warning "Local changes detected. Stashing changes..."
            git stash
        fi
        
        git checkout main
        git pull origin main
    else
        print_error "dspace-angular exists but is not a git repository."
        exit 1
    fi
else
    if ! git clone https://github.com/DSpace/dspace-angular.git; then
        print_error "Failed to clone repository."
        exit 1
    fi
    cd dspace-angular
fi

# Switch to main branch
print_message "Ensuring we're on main branch..."
git checkout main

# Pull latest Docker images
print_message "Pulling latest Docker images (this may take a while)..."
docker compose -f docker/docker-compose.yml -f docker/docker-compose-rest.yml pull

# Ask user if they want to rebuild Angular UI locally
read -p "Do you want to rebuild the Angular UI locally? (y/N): " rebuild_ui
if [[ $rebuild_ui =~ ^[Yy]$ ]]; then
    print_message "Building Angular UI Docker image..."
    docker compose -f docker/docker-compose.yml build
fi

# Start DSpace services
print_message "Starting DSpace services (Database, REST API and Angular UI)..."
docker compose -p d9 -f docker/docker-compose.yml -f docker/docker-compose-rest.yml up -d

# Wait for database container to start
if ! wait_for_container "dspacedb"; then
    print_error "Database container failed to start."
    exit 1
fi

# Wait for database to be ready
if ! wait_for_database; then
    exit 1
fi

# Verify all required containers are running
print_message "Verifying all containers are running..."
required_containers=("dspace" "dspace-angular" "dspacesolr" "dspacedb")
all_running=true

for container in "${required_containers[@]}"; do
    if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        print_message "✓ $container is running"
    else
        print_error "✗ $container is not running!"
        print_error "Please check the logs: docker compose -p d9 -f docker/docker-compose.yml -f docker/docker-compose-rest.yml logs $container"
        all_running=false
    fi
done

if [ "$all_running" = false ]; then
    exit 1
fi

# Ask user about test data
echo ""
print_message "Choose test data option:"
echo "1) Import AIP test data (recommended for quick setup)"
echo "2) Import Configurable Entities test data"
echo "3) Skip test data import"
read -p "Enter your choice (1/2/3): " data_choice

case $data_choice in
    1)
        print_message "Creating administrator account..."
        docker compose -p d9 -f docker/cli.yml run --rm dspace-cli create-administrator -e test@test.edu -f admin -l user -p admin -c en
        
        print_message "Importing AIP test data (this may take several minutes)..."
        docker compose -p d9 -f docker/cli.yml -f ./docker/cli.ingest.yml run --rm dspace-cli
        ;;
    2)
        print_message "Shutting down containers to load Entities test data..."
        docker compose -p d9 -f docker/docker-compose.yml -f docker/docker-compose-rest.yml down
        
        # Remove volumes if they exist
        volumes=$(docker volume ls -q --filter name=d9)
        if [ -n "$volumes" ]; then
            print_warning "Removing existing volumes..."
            echo "$volumes" | xargs docker volume rm
        fi
        
        print_message "Starting containers with Entities test data..."
        docker compose -p d9 -f docker/docker-compose.yml -f docker/docker-compose-rest.yml -f docker/db.entities.yml up -d
        
        # Wait for database again
        if ! wait_for_container "dspacedb"; then
            print_error "Database container failed to start."
            exit 1
        fi
        
        if ! wait_for_database; then
            exit 1
        fi
        
        print_message "Loading Entities test assetstore and reindexing..."
        docker compose -p d9 -f docker/cli.yml -f docker/cli.assetstore.yml run --rm dspace-cli
        ;;
    3)
        print_message "Skipping test data import..."
        ;;
    *)
        print_warning "Invalid choice. Skipping test data import..."
        ;;
esac

# Create administrator account if not already created
if [ "$data_choice" != "1" ]; then
    read -p "Create administrator account? (Y/n): " create_admin
    if [[ ! $create_admin =~ ^[Nn]$ ]]; then
        admin_email=""
        while true; do
            read -p "Enter admin email (default: test@test.edu): " admin_email
            admin_email=${admin_email:-test@test.edu}
            
            if validate_email "$admin_email"; then
                break
            else
                print_error "Invalid email format. Please try again."
            fi
        done
        
        read -p "Enter admin password (default: admin): " admin_password
        admin_password=${admin_password:-admin}
        
        if [ ${#admin_password} -lt 4 ]; then
            print_warning "Password is short. Consider using a stronger password."
        fi
        
        print_message "Creating administrator account..."
        docker compose -p d9 -f docker/cli.yml run --rm dspace-cli create-administrator -e "$admin_email" -f admin -l user -p "$admin_password" -c en
    fi
fi

# Disable cleanup trap on success
CLEANUP_ON_EXIT=false
trap - EXIT

# Display completion message
echo ""
echo "================================================"
print_message "DSpace installation complete!"
echo "================================================"
echo ""
echo "Access your DSpace instance at:"
echo "  User Interface: http://localhost:4000/"
echo "  REST API: http://localhost:8080/server/"
echo ""

if [ "$data_choice" != "3" ]; then
    echo "Admin Login:"
    if [ "$data_choice" == "1" ]; then
        echo "  Email: test@test.edu"
        echo "  Password: admin"
    elif [ -n "$admin_email" ]; then
        echo "  Email: $admin_email"
        echo "  Password: $admin_password"
    fi
    echo ""
fi

echo "Useful commands:"
echo "  View logs: docker compose -p d9 -f docker/docker-compose.yml -f docker/docker-compose-rest.yml logs -f"
echo "  Stop services: docker compose -p d9 -f docker/docker-compose.yml -f docker/docker-compose-rest.yml down"
echo "  Restart services: docker compose -p d9 -f docker/docker-compose.yml -f docker/docker-compose-rest.yml restart"
echo "  Clean up everything: docker compose -p d9 -f docker/docker-compose.yml -f docker/docker-compose-rest.yml down && docker system prune --volumes"
echo ""

# Ask if user wants to view logs
read -p "Would you like to view the logs now? (y/N): " view_logs
if [[ $view_logs =~ ^[Yy]$ ]]; then
    docker compose -p d9 -f docker/docker-compose.yml -f docker/docker-compose-rest.yml logs -f
fi
