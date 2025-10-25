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

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
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
    print_warning "You may need to log out and back in for group changes to take effect."
    print_warning "Or run: newgrp docker"
}

# Function to install Git
install_git() {
    print_step "Installing Git..."
    
    sudo apt-get update
    sudo apt-get install -y git
    
    print_message "Git installed successfully!"
}

# Main installation function
install_docker() {
    print_message "Installing Docker for Ubuntu..."
    install_docker_ubuntu
}

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
        print_error "Cannot connect to Docker daemon. Please ensure Docker is running."
        exit 1
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

# Clone DSpace Angular repository
print_message "Cloning DSpace Angular repository..."
if [ -d "dspace-angular" ]; then
    print_warning "dspace-angular directory already exists. Skipping clone."
    cd dspace-angular
else
    git clone https://github.com/DSpace/dspace-angular.git
    cd dspace-angular
fi

# Switch to main branch
print_message "Switching to main branch..."
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

print_message "Waiting for database to initialize (60 seconds)..."
sleep 60

# Check if database is ready
print_message "Verifying database connection..."
max_attempts=10
attempt=0
while [ $attempt -lt $max_attempts ]; do
    if docker compose -p d9 -f docker/docker-compose.yml exec -T dspacedb pg_isready -U dspace > /dev/null 2>&1; then
        print_message "Database is ready!"
        break
    fi
    attempt=$((attempt + 1))
    if [ $attempt -eq $max_attempts ]; then
        print_error "Database failed to start. Please check logs."
        docker compose -p d9 -f docker/docker-compose.yml -f docker/docker-compose-rest.yml logs dspacedb
        exit 1
    fi
    print_warning "Waiting for database... (attempt $attempt/$max_attempts)"
    sleep 10
done

# Verify all required containers are running
print_message "Verifying all containers are running..."
required_containers=("dspace" "dspace-angular" "dspacesolr" "dspacedb")
for container in "${required_containers[@]}"; do
    if docker ps --format '{{.Names}}' | grep -q "$container"; then
        print_message "✓ $container is running"
    else
        print_error "✗ $container is not running!"
        print_error "Please check the logs: docker compose -p d9 -f docker/docker-compose.yml -f docker/docker-compose-rest.yml logs $container"
        exit 1
    fi
done

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
        
        print_warning "Removing existing volumes..."
        docker volume rm $(docker volume ls -q --filter name=d9) 2>/dev/null || true
        
        print_message "Starting containers with Entities test data..."
        docker compose -p d9 -f docker/docker-compose.yml -f docker/docker-compose-rest.yml -f docker/db.entities.yml up -d
        
        print_message "Waiting for database to initialize (60 seconds)..."
        sleep 60
        
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
        read -p "Enter admin email (default: test@test.edu): " admin_email
        admin_email=${admin_email:-test@test.edu}
        
        read -p "Enter admin password (default: admin): " admin_password
        admin_password=${admin_password:-admin}
        
        print_message "Creating administrator account..."
        docker compose -p d9 -f docker/cli.yml run --rm dspace-cli create-administrator -e "$admin_email" -f admin -l user -p "$admin_password" -c en
    fi
fi

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
    if [ "$data_choice" == "1" ] || [ -z "$admin_email" ]; then
        echo "  Email: test@test.edu"
        echo "  Password: admin"
    else
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
